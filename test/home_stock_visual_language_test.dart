import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('primary navigation keeps Home conventional and makes Stock pharmacy-specific', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains('Icons.home_outlined'));
    expect(source, contains('Icons.home_rounded'));
    expect(source, contains('Icons.medication_outlined'));
    expect(source, contains('Icons.medication_rounded'));
    expect(source, isNot(contains('icon: Icons.inventory_2_outlined,\n                      selectedIcon: Icons.inventory_2_rounded')));
  });

  test('Stock screen and Home drill-down affordances use matching local-navigation cues', () {
    final stock = File('lib/ui/search_screen.dart').readAsStringSync();
    final home = File('lib/ui/home_screen.dart').readAsStringSync();

    expect(stock, contains('icon: Icons.medication_outlined'));
    expect(home, contains('Icons.chevron_right_rounded'));
    expect(home, isNot(contains('Icons.north_east_rounded')));
  });

  test('expiry warning selector preserves a full touch target and honest saving feedback', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();
    final start = source.indexOf('class _WarningSelector');
    final end = source.indexOf('class _ScanBanner', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final selector = source.substring(start, end);

    expect(selector, contains('BoxConstraints(minHeight: 48)'));
    expect(selector, contains('CircularProgressIndicator('));
    expect(selector, contains('strokeWidth: 2'));
    expect(selector, isNot(contains('Icons.sync_rounded')));
  });
}
