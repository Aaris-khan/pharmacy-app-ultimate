import 'package:aaris_pharmacy/domain/medicine_discovery.dart';
import 'package:aaris_pharmacy/domain/medicine_ocr_text.dart';
import 'package:aaris_pharmacy/domain/medicine_resolution_v2.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/medicine_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine extraction hardening V46', () {
    test('recovers adjacent ingredient-dose pairs without a printed separator', () {
      expect(
        normalizeMedicineOcrLine('PARACETAMOL500MGCAFFEINE65MG'),
        'PARACETAMOL 500MG + CAFFEINE 65MG',
      );
      expect(
        normalizeMedicineOcrLine('COMPOSITIONPARACETAMOL500MGCAFFEINE65MG'),
        'COMPOSITION PARACETAMOL 500MG + CAFFEINE 65MG',
      );
      expect(
        normalizeMedicineOcrLine('AMOXICILLIN500MGCLAVULANATE125MGTABLETS'),
        'AMOXICILLIN 500MG + CLAVULANATE 125MG TABLETS',
      );
    });

    test('does not split one ingredient from presentation or release prose', () {
      expect(normalizeMedicineOcrLine('LOTION'), 'LOTION');
      expect(normalizeMedicineOcrLine('LOTN'), 'LOTN');
      expect(normalizeMedicineOcrLine('LOT100'), 'LOT 100');
      expect(
        normalizeMedicineOcrLine('CALPOL500MGTABLETS'),
        'CALPOL 500MG TABLETS',
      );
      expect(
        normalizeMedicineOcrLine('METFORMIN500MGEXTENDEDRELEASETABLETS'),
        isNot(contains('500MG +')),
      );
    });

    test('resolver understands OCR-confused lotion plus separatorless combination', () {
      final result = MedicineUnderstandingResult.fromMessage(
        understandMedicineEvidenceV2Message(<String, Object?>{
          'evidence': <Map<String, Object?>>[
            const MedicineFrameEvidence(
              sequence: 46,
              quality: .98,
              text: '''PRODUCTNAMECANDIDLOTI0N
COMPOSITIONPARACETAMOL500MGCAFFEINE65MG''',
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

    test('online lookup receives repaired composition and canonical form clue', () async {
      final provider = _CaptureProvider();
      final service = MedicineCatalogService(providers: <MedicineCatalogProvider>[provider]);
      addTearDown(service.close);

      await service.search(
        text: 'CANDIDLOTI0N\nPARACETAMOL500MGCAFFEINE65MG',
      );

      expect(provider.lastText, contains('candid'));
      expect(provider.lastText, contains('paracetamol 500 mg'));
      expect(provider.lastText, contains('caffeine 65 mg'));
      expect(provider.lastText, contains('lotion'));
    });
  });
}

class _CaptureProvider implements MedicineCatalogProvider {
  String lastText = '';

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    lastText = text;
    return const <MedicineCatalogCandidate>[];
  }
}
