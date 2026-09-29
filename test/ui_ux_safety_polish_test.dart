import 'dart:io';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<PharmacyController> _controller(Medicine medicine) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(
      InventorySnapshot(records: <String, Medicine>{medicine.id: medicine}),
    ),
    clock: () => DateTime(2026, 9, 29, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

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

  testWidgets('destructive editor confirmations use danger styling', (
    tester,
  ) async {
    final medicine = Medicine.fromJson(<String, dynamic>{
      'id': 'destructive-ui',
      'name': 'Dolo',
      'strength': '650 mg',
      'quantity': 10,
      'revision': 1,
    });
    final controller = await _controller(medicine);

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => openEditor(
                  context,
                  controller,
                  record: medicine,
                ),
                child: const Text('Open medicine'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open medicine'));
    await tester.pumpAndSettle();

    final removeEntry = find.text('Remove stock entry');
    await tester.ensureVisible(removeEntry);
    await tester.tap(removeEntry);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Correction'));
    await tester.pumpAndSettle();

    final remove = find.widgetWithText(FilledButton, 'Remove');
    expect(remove, findsOneWidget);
    final removeStyle = tester.widget<FilledButton>(remove).style!;
    expect(removeStyle.backgroundColor?.resolve(const <WidgetState>{}), red);
    expect(
      removeStyle.foregroundColor?.resolve(const <WidgetState>{}),
      Colors.white,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final nameField = find.byType(TextFormField).first;
    await tester.ensureVisible(nameField);
    await tester.enterText(nameField, 'Dolo edited');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();

    final discard = find.widgetWithText(FilledButton, 'Discard');
    expect(discard, findsOneWidget);
    final discardStyle = tester.widget<FilledButton>(discard).style!;
    expect(discardStyle.backgroundColor?.resolve(const <WidgetState>{}), red);
    expect(
      discardStyle.foregroundColor?.resolve(const <WidgetState>{}),
      Colors.white,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
