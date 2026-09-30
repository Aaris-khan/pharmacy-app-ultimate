import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedMedicineField _field(String value, {double confidence = .92}) =>
    ExtractedMedicineField(
      value: value,
      confidence: confidence,
      support: 2,
    );

void main() {
  group('release catalogue OCR bridge', () {
    test('merged brand and ingredient-dose tokens resolve one coherent product', () {
      const product = CanonicalMedicineProduct(
        productId: 'curated:montek-lc:10-5:tablet',
        revision: 9001,
        name: 'Montek LC',
        brand: 'Montek LC',
        salt: 'Montelukast Sodium + Levocetirizine Hydrochloride',
        strength: '10 mg + 5 mg',
        form: 'Tablet',
        manufacturer: 'Example Pharma',
        verified: true,
        priorWeight: .7,
      );
      final draft = MedicineScanDraft(
        fields: <String, ExtractedMedicineField>{
          'name': _field('MONTEKLC'),
          'brand': _field('MONTEKLC'),
          'strength': _field('10 mg + 5 mg'),
          'form': _field('Tablet'),
        },
        rawText:
            'MONTEKLC\nMontelukastSodium10mg + LevocetirizineHydrochloride5mg\nTABLETS',
        searchKeywords:
            'monteklc montelukastsodium10mg levocetirizinehydrochloride5mg tablet',
        frameSequences: const <int>[0],
        overallConfidence: .91,
      );

      final result = MedicineProductResolverV2(
        localKnowledge: const <MedicineKnowledgeEntry>[],
        catalogue: const <CanonicalMedicineProduct>[product],
      ).reconcile(
        MedicineUnderstandingResult(drafts: <MedicineScanDraft>[draft]),
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            sequence: 0,
            quality: .96,
            text:
                'MONTEKLC\nMontelukastSodium10mg + LevocetirizineHydrochloride5mg\nTABLETS',
          ),
        ],
      );

      final resolved = result.drafts.single;
      expect(resolved.name, 'Montek LC');
      expect(resolved.brand, 'Montek LC');
      expect(
        resolved.salt,
        'Montelukast Sodium + Levocetirizine Hydrochloride',
      );
      expect(resolved.strength, '10 mg + 5 mg');
      expect(resolved.form, 'Tablet');
      expect(resolved.needsReview, isFalse);
    });
  });
}
