import 'package:aaris_pharmacy/domain/medicine_strength.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('medicine strength equivalence', () {
    test('normalizes mass units without changing dose meaning', () {
      expect(medicineStrengthEquivalent('0.5 g', '500 mg'), isTrue);
      expect(medicineStrengthEquivalent('1000 mcg', '1 mg'), isTrue);
      expect(medicineStrengthEquivalent('500 mg', '50 mg'), isFalse);
    });

    test('normalizes explicit concentration denominators', () {
      expect(
        medicineStrengthEquivalent('250 mg/5 mL', '50 mg/mL'),
        isTrue,
      );
      expect(
        medicineStrengthEquivalent('1000 mcg/mL', '1 mg/mL'),
        isTrue,
      );
      expect(
        medicineStrengthEquivalent('250 mg/5 mL', '250 mg/mL'),
        isFalse,
      );
    });

    test('converts only percentages with an explicit physical basis', () {
      expect(medicineStrengthEquivalent('1% w/v', '10 mg/mL'), isTrue);
      expect(medicineStrengthEquivalent('2.5% w/v', '25 mg/mL'), isTrue);
      expect(medicineStrengthEquivalent('1% w/w', '10 mg/g'), isTrue);

      // Bare percent is intentionally ambiguous: never guess w/w versus w/v.
      expect(medicineStrengthEquivalent('1%', '10 mg/mL'), isFalse);
      expect(medicineStrengthEquivalent('1% w/w', '10 mg/mL'), isFalse);
    });

    test('preserves ordered multi-ingredient dose alignment', () {
      expect(
        medicineStrengthEquivalent('0.5 g + 125 mg', '500 mg + 125 mg'),
        isTrue,
      );
      expect(
        medicineStrengthEquivalent('500 mg + 125 mg', '125 mg + 500 mg'),
        isFalse,
      );
    });
  });
}
