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
  });
}
