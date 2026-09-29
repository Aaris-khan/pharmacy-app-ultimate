import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/editor_screen.dart';
import 'package:aaris_pharmacy/ui/import_screen.dart';
import 'package:aaris_pharmacy/ui/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _medicine() => Medicine.fromJson(<String, dynamic>{
  'id': 'ui-audit',
  'name': 'Dolo',
  'strength': '650 mg',
  'quantity': 10,
  'revision': 1,
});

Future<PharmacyController> _controller({Medicine? medicine}) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(
      InventorySnapshot(
        records: medicine == null
            ? const <String, Medicine>{}
            : <String, Medicine>{medicine.id: medicine},
      ),
    ),
    clock: () => DateTime(2026, 9, 29, 10),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  testWidgets('existing medicine cannot create an unchanged revision', (
    tester,
  ) async {
    final medicine = _medicine();
    final controller = await _controller(medicine: medicine);
    final initialRevision = controller.snapshot.revision;

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

    final save = find.widgetWithText(FilledButton, 'Save medicine');
    expect(save, findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    final nameField = find.byType(TextFormField).first;
    await tester.enterText(nameField, 'Dolo edited');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    await tester.enterText(nameField, 'Dolo');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(save).onPressed,
      isNull,
      reason:
          'Restoring the exact persisted facts must clear the semantic dirty state.',
    );

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsNothing);
    expect(controller.snapshot.revision, initialRevision);
    expect(controller.snapshot.records[medicine.id]?.revision, medicine.revision);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('manual add focuses the medicine name immediately', (
    tester,
  ) async {
    final controller = await _controller();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => openEditor(context, controller),
                child: const Text('Add medicine'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Add medicine'));
    await tester.pumpAndSettle();

    final nameFormField = find.byType(TextFormField).first;
    final editable = find.descendant(
      of: nameFormField,
      matching: find.byType(EditableText),
    );
    expect(editable, findsOneWidget);
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    expect(find.text('Stock quantity'), findsOneWidget);
    expect(find.text('Medicine form'), findsOneWidget);
    expect(find.text('Unit cost (₹)'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('stock actions stack instead of shrinking at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final controller = await _controller();
    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: Scaffold(
          body: SafeArea(
            child: SearchScreen(
              controller: controller,
              scope: SearchScope.all,
              database: true,
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder actionLabel(String label) => find.descendant(
      of: find.byType(RaisedActionButton),
      matching: find.text(label),
    ).first;

    final addY = tester.getCenter(actionLabel('Add medicine')).dy;
    final importY = tester.getCenter(actionLabel('Import stock')).dy;
    final scanY = tester.getCenter(actionLabel('Scan')).dy;
    final voiceY = tester.getCenter(actionLabel('Voice')).dy;
    final pasteY = tester.getCenter(actionLabel('Paste list')).dy;

    expect(importY, greaterThan(addY));
    expect(voiceY, greaterThan(scanY));
    expect(pasteY, greaterThan(voiceY));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('import flow protects its body from the bottom system inset', (
    tester,
  ) async {
    final controller = await _controller();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: ImportCenterScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.body, isA<SafeArea>());
    final safeArea = scaffold.body! as SafeArea;
    expect(safeArea.top, isFalse);
    expect(safeArea.bottom, isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
