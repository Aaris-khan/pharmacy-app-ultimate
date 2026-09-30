import 'package:aaris_pharmacy/domain/medicine_form_recognition.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/medicine_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V51 bounded dosage-form OCR recovery', () {
    test('recovers unseen one-edit medicine form damage', () {
      expect(recognizeMedicineFormFromText('CANDID LOTIOH'), 'Lotion');
      expect(recognizeMedicineFormFromText('OINMENT'), 'Ointment');
      expect(recognizeMedicineFormFromText('SUSPENSIN'), 'Suspension');
      expect(recognizeMedicineFormFromText('CREM'), 'Cream');
    });

    test('does not turn nearby ordinary words into dosage forms', () {
      expect(recognizeMedicineFormFromText('MOTION SICKNESS'), isEmpty);
      expect(recognizeMedicineFormFromText('HIGH POWER FORMULA'), isEmpty);
      expect(recognizeMedicineFormFromText('DREAM BIG'), isEmpty);
    });

    test('deterministic scan extraction uses the shared recovery engine', () {
      const text = 'CANDID\nCLOTRIMAZOLE 1% W/V\nLOTIOH';
      final result = const MedicineUnderstandingEngine().understand(
        const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: text,
            source: 'test',
            sequence: 1,
            quality: .98,
          ),
        ],
      );

      expect(result.drafts, hasLength(1));
      expect(result.drafts.single.form, 'Lotion');
    });

    test('scan-aware catalogue query keeps recovered form evidence', () async {
      final provider = _RecordingProvider();
      final service = MedicineCatalogService(
        providers: <MedicineCatalogProvider>[provider],
        releaseFirst: false,
      );
      addTearDown(service.close);

      const text = 'CANDID\nCLOTRIMAZOLE 1% W/V\nLOTIOH';
      await service.searchScan(
        text: text,
        evidence: const <MedicineFrameEvidence>[
          MedicineFrameEvidence(
            text: text,
            source: 'test',
            sequence: 2,
            quality: .98,
          ),
        ],
      );

      expect(provider.lastText.toLowerCase(), contains('lotion'));
    });
  });
}

class _RecordingProvider implements MedicineCatalogProvider {
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
