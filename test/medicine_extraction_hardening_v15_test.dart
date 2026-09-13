import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_semantic_roles.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V15', () {
    test('recovers an unlabeled pharmacopoeial ingredient and strength', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''NOVA CV
Amoxicillin Trihydrate I.P. 500 mg
Tablets''',
          quality: .95,
        ),
      ]);

      expect(result.components, hasLength(1));
      expect(
        result.components.single.ingredient.toLowerCase(),
        'amoxicillin trihydrate',
      );
      expect(result.components.single.strength, '500 mg');
      expect(result.compositionConfidence, greaterThanOrEqualTo(.90));
      expect(result.conflicted, isFalse);
    });

    test('does not reinterpret a plain trade name plus dose as composition', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(text: 'CROCIN 500 mg\nTablets', quality: .96),
      ]);

      expect(result.components, isEmpty);
      expect(result.salt, isEmpty);
    });

    test('price and pack noise cannot become an active ingredient', () {
      final result = inferMedicineSemanticRoles(const <MedicineFrameEvidence>[
        MedicineFrameEvidence(
          text: '''MRP Rs. 500 mg
10 TABLETS x 500 mg
BATCH AB500''',
          quality: .98,
        ),
      ]);

      expect(result.components, isEmpty);
      expect(result.salt, isEmpty);
    });

    test('V2 keeps semantic recovery aligned with physical lot dates', () {
      const frame = MedicineFrameEvidence(
        text: '''NOVA CV
Amoxicillin Trihydrate I.P. 500 mg
Tablets
MFG 04/2026
EXP 04/2028''',
        sequence: 1,
        quality: .95,
      );

      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[frame.toMessage()],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
          'referenceDate': '2026-09-13T00:00:00.000Z',
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.salt.toLowerCase(), contains('amoxicillin'));
      expect(draft.strength.toLowerCase(), contains('500 mg'));
      expect(draft.mfg, '2026-04');
      expect(draft.expiry, '2028-04');
    });
  });
}
