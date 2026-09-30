import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V45', () {
    test('recovers a long dosage form glued to the medicine token', () {
      expect(normalizeMedicineOcrLine('CANDIDLOTION'), 'CANDID LOTION');
      expect(normalizeMedicineOcrLine('CALPOLTABLETS'), 'CALPOL TABLETS');
    });

    test('recovers a no-space combination conjunction only between doses', () {
      expect(
        normalizeMedicineOcrLine(
          'PARACETAMOL500MGWITHCAFFEINE65MG',
        ),
        'PARACETAMOL 500MG + CAFFEINE 65MG',
      );
      expect(
        normalizeMedicineOcrLine('KEEPWITHCHILDREN'),
        'KEEPWITHCHILDREN',
      );
    });

    test('resolver separates brand, lotion form and combination ingredients', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 45,
              quality: .98,
              text: '''PRODUCTNAMECANDIDLOTION
COMPOSITION PARACETAMOL500MGWITHCAFFEINE65MG''',
            ).toMessage(),
          ],
          'knowledge': const <Map<String, Object?>>[],
          'catalog': const <Map<String, Object?>>[],
        }),
      );

      expect(result.drafts, hasLength(1));
      final draft = result.drafts.single;
      expect(draft.name.toLowerCase(), contains('candid'));
      expect(draft.form, 'Lotion');
      expect(draft.salt.toLowerCase(), contains('paracetamol'));
      expect(draft.salt.toLowerCase(), contains('caffeine'));
      expect(draft.strength.toLowerCase(), contains('500 mg'));
      expect(draft.strength.toLowerCase(), contains('65 mg'));
    });
  });
}
