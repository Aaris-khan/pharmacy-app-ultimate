import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'scan search keeps an explicit manual recovery path beside catalog results',
    () {
      final source = File('lib/ui/search_screen.dart').readAsStringSync();

      expect(
        source,
        contains(r"'Scope · ${scopeTitle(widget.scope, settings)}"),
      );
      expect(
        source,
        contains(
          'if (_scan != null &&\n'
          '                    widget.database &&\n'
          '                    !_catalogLoading)',
        ),
      );
      expect(
        source,
        isNot(
          contains(
            '!_catalogLoading &&\n'
            '                    _catalogHits.isEmpty',
          ),
        ),
      );
    },
  );

  test('destructive inventory confirmations are visually explicit', () {
    final source = File('lib/ui/editor_screen.dart').readAsStringSync();

    expect(source, contains('bool destructive = false'));
    expect(source, contains('backgroundColor: red'));
    expect(source, contains('foregroundColor: Colors.white'));
    expect(
      RegExp(r'destructive:\s*true').allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('global inventory removal keeps its final action visibly destructive', () {
    final source = File('lib/ui/profile_screen.dart').readAsStringSync();

    expect(source, contains("backgroundColor: red"));
    expect(source, contains("child: const Text('Remove all')"));
  });

  test('management navigation describes the screen the user actually opens', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains("label: 'Insights'"));
    expect(source, contains('Icons.insights_outlined'));
    expect(source, isNot(contains("label: 'Calculator'")));
  });

  test('snapshot uses on-hand inventory value instead of summing unit costs', () {
    final source = File('lib/ui/stats_screen.dart').readAsStringSync();

    expect(source, contains("label: 'Inventory value'"));
    expect(source, contains('inventory.onHandValue'));
    expect(
      source,
      isNot(contains('_money(inventory.totalEnteredAmountPaise)')),
    );
  });

  test('medicine editor exposes the stock facts its model already persists', () {
    final source = File('lib/ui/editor_screen.dart').readAsStringSync();

    expect(source, contains("'Stock quantity'"));
    expect(source, contains("label: 'Medicine form'"));
    expect(source, contains("'Unit cost (₹)'"));
    expect(source, contains('DropdownButtonFormField<String>'));
    expect(source, contains('bool _matchesOriginalRecord()'));
    expect(
      source,
      contains('floatingLabelBehavior: FloatingLabelBehavior.always'),
      reason: 'Saved values must not hide their field meaning.',
    );
  });

  test('filled app form fields keep their labels after entry', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(
      source,
      contains('floatingLabelBehavior: FloatingLabelBehavior.auto'),
    );
    expect(
      source,
      isNot(contains('floatingLabelBehavior: FloatingLabelBehavior.never')),
    );
  });

  test('raised action labels honor text scaling instead of shrinking text', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class RaisedActionButton');
    final end = source.indexOf('BoxDecoration depthDecoration', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final actionSource = source.substring(start, end);

    expect(actionSource, contains('ConstrainedBox('));
    expect(actionSource, contains('maxLines: 2'));
    expect(actionSource, isNot(contains('FittedBox(')));
  });

  test('filled date fields keep MFG/EXP meaning visible', () {
    final source = File('lib/ui/date_field.dart').readAsStringSync();

    expect(
      source,
      contains('floatingLabelBehavior: FloatingLabelBehavior.always'),
    );
  });
  test('expiry precision controls grow with accessibility text', () {
    final source = File('lib/ui/editor_screen.dart').readAsStringSync();
    final start = source.indexOf('Widget _expiryMode');
    final end = source.indexOf('@override\n  Widget build', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final modeSource = source.substring(start, end);

    expect(modeSource, contains('ConstrainedBox('));
    expect(modeSource, contains('maxLines: 2'));
    expect(modeSource, isNot(contains('FittedBox(')));
  });

  test('today work cards keep actionable text readable', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();
    final start = source.indexOf('class _HomeWorkRow');
    final end = source.indexOf('class _OverviewTile', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final taskSource = source.substring(start, end);

    expect(RegExp(r'maxLines:\s*2').allMatches(taskSource).length, 2);
    expect(taskSource, isNot(contains('maxLines: 1')));
  });

  test('bottom navigation adapts instead of crushing labels on small screens', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains('navigationWidth < 380'));
    expect(source, contains('navigationLabelHeight > 15'));
    expect(
      source,
      contains('NavigationDestinationLabelBehavior.onlyShowSelected'),
    );
    expect(source, contains('height: navigationHeight'));
  });

  test('saved medicine matches keep enough identity visible before selection', () {
    final source =
        File('lib/ui/medicine_review_screen.dart').readAsStringSync();
    final start = source.indexOf('Widget _matchCard(');
    expect(start, greaterThanOrEqualTo(0));
    final matchSource = source.substring(start);

    expect(matchSource, contains('maxLines: 2'));
    expect(
      matchSource,
      contains('crossAxisAlignment: CrossAxisAlignment.start'),
    );
  });

  test('medicine cards do not force manufacturer identity to one line', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class MedicineCard');
    final end = source.indexOf('class _ExpiryBorder', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final cardSource = source.substring(start, end);

    expect(cardSource, contains('record.manufacturer'));
    expect(
      RegExp(
        r'record\.manufacturer,[\s\S]{0,180}maxLines:\s*2',
      ).hasMatch(cardSource),
      isTrue,
    );
  });

}
