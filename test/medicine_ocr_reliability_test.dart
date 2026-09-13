import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/medicine_ocr_reliability.dart';

void main() {
  test('zero detector confidence is unavailable rather than bad OCR', () {
    expect(usableMedicineOcrConfidence(0), isNull);
    expect(usableMedicineOcrConfidence(0.0), isNull);
    expect(usableMedicineOcrConfidence(null), isNull);
  });

  test('positive detector confidence is safely bounded', () {
    expect(usableMedicineOcrConfidence(.73), .73);
    expect(usableMedicineOcrConfidence(2), 1);
  });

  test('frame OCR confidence is bounded and duplicate-safe', () {
    final score = robustMedicineOcrConfidence(const [
      MedicineOcrConfidenceSample(text: 'Paracetamol 650 mg', confidence: .91),
      MedicineOcrConfidenceSample(text: ' paracetamol  650 mg ', confidence: .74),
      MedicineOcrConfidenceSample(text: 'EXP 10/2027', confidence: .62),
      MedicineOcrConfidenceSample(text: 'BATCH A12', confidence: .84),
    ]);
    expect(score, isNotNull);
    expect(score!, inInclusiveRange(0, 1));
    expect(score, greaterThan(.65));
    expect(score, lessThan(.92));
  });

  test('unavailable detector sentinel cannot drag robust score to zero', () {
    final score = robustMedicineOcrConfidence(const [
      MedicineOcrConfidenceSample(text: 'DOLO 650', confidence: 0),
      MedicineOcrConfidenceSample(text: 'Paracetamol 650 mg', confidence: .88),
    ]);
    expect(score, .88);
  });

  test('all unavailable detector confidences remain unknown', () {
    expect(
      robustMedicineOcrConfidence(const [
        MedicineOcrConfidenceSample(text: 'DOLO 650', confidence: null),
        MedicineOcrConfidenceSample(text: 'EXP 10/2027', confidence: 0),
      ]),
      isNull,
    );
  });
}
