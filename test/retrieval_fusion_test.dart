import 'package:flutter_test/flutter_test.dart';

import 'package:aaris_pharmacy/domain/retrieval_fusion.dart';

void main() {
  group('offline retrieval planning', () {
    test('rare exact terms outrank common catalogue terms', () {
      final ranked = selectInformationRichTerms(
        const <String>['paracetamol', 'dolo650', 'micro'],
        const <String, int>{'paracetamol': 24000, 'dolo650': 2, 'micro': 320},
      );

      expect(ranked, const <String>['dolo650', 'micro', 'paracetamol']);
    });

    test('unknown OCR terms lead bounded typo recovery', () {
      final ranked = selectRecoveryTerms(
        const <String>['paracetamol', 'd0l0', 'micro', 'tablet'],
        const <String, int>{
          'paracetamol': 24000,
          'micro': 320,
          'tablet': 80000,
        },
        limit: 3,
      );

      expect(ranked.first, 'd0l0');
      expect(ranked, contains('micro'));
      expect(ranked, isNot(contains('tablet')));
    });

    test('long glued medicine OCR gets bounded stable anchors', () {
      const clean = 'montelukastsodiumlevocetirizinehydrochloride';
      const noisy = 'montelukastsodiumlevxcetirizinehydrochloride';

      final cleanAnchors = boundedOcrAnchors(clean);
      final noisyAnchors = boundedOcrAnchors(noisy);

      expect(cleanAnchors, hasLength(4));
      expect(cleanAnchors.every((value) => value.length == 12), isTrue);
      expect(cleanAnchors.first, clean.substring(0, 12));
      expect(cleanAnchors.last, clean.substring(clean.length - 12));
      expect(
        cleanAnchors.toSet().intersection(noisyAnchors.toSet()).length,
        greaterThanOrEqualTo(3),
      );
    });

    test('RRF rewards independent corroboration across retrievers', () {
      final fused = reciprocalRankFuse(const <RankedRetrievalChannel>[
        RankedRetrievalChannel(ids: <String>['a', 'b', 'c']),
        RankedRetrievalChannel(ids: <String>['b', 'd', 'a']),
      ]);
      final ranked = fused.entries.toList(growable: false)
        ..sort((a, b) => b.value.compareTo(a.value));

      expect(ranked.first.key, 'b');
      expect(fused['a']!, greaterThan(fused['c']!));
      expect(fused['a']!, greaterThan(fused['d']!));
    });

    test('recovery channel can be reliability weighted', () {
      final fused = reciprocalRankFuse(const <RankedRetrievalChannel>[
        RankedRetrievalChannel(ids: <String>['exact']),
        RankedRetrievalChannel(ids: <String>['typo'], weight: .62),
      ]);

      expect(fused['exact']!, greaterThan(fused['typo']!));
    });
  });
}
