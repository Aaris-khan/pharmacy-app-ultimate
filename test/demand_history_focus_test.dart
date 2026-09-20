import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('demand history filters inputs by product key', () {
    final source = File('lib/ui/demand_history_sheet.dart').readAsStringSync();
    expect(source, contains('(medicine) => medicine.identity == productKey'));
    expect(source, contains('(sale) => sale.productKey == productKey'));
  });
}
