import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/supplier.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/supplier_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('supplier custom labels fail inline before persistence', (
    tester,
  ) async {
    const supplier = Supplier(
      id: 'supplier-inline-validation',
      name: 'Validation Supplier',
      returnBeforeExpiryDays: 30,
      customFields: <SupplierCustomField>[
        SupplierCustomField(
          id: 'field_123456',
          label: 'Region code',
          value: 'NCR',
        ),
      ],
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          suppliers: <String, Supplier>{supplier.id: supplier},
        ),
      ),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: SupplierEditorScreen(
            controller: controller,
            supplier: supplier,
          ),
        ),
      );

      final fields = find.byType(TextFormField);
      expect(fields, findsNWidgets(7));
      await tester.enterText(fields.at(5), 'address');
      await tester.pump();
      await tester.tap(find.text('Save supplier'));
      await tester.pump();

      expect(
        find.text('This is already a built-in supplier or stock field.'),
        findsOneWidget,
      );
      expect(controller.snapshot.revision, 0);
      expect(
        controller.snapshot.suppliers[supplier.id]!.customFields.single.label,
        'Region code',
      );
    } finally {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('supplier custom label length is validated before save', (
    tester,
  ) async {
    const supplier = Supplier(
      id: 'supplier-label-length',
      name: 'Length Supplier',
      returnBeforeExpiryDays: 30,
      customFields: <SupplierCustomField>[
        SupplierCustomField(
          id: 'field_654321',
          label: 'Route',
          value: 'North',
        ),
      ],
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          suppliers: <String, Supplier>{supplier.id: supplier},
        ),
      ),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: SupplierEditorScreen(
            controller: controller,
            supplier: supplier,
          ),
        ),
      );

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(5), List<String>.filled(101, 'x').join());
      await tester.pump();
      await tester.tap(find.text('Save supplier'));
      await tester.pump();

      expect(find.text('Use 100 characters or fewer.'), findsOneWidget);
      expect(controller.snapshot.revision, 0);
    } finally {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
  testWidgets('supplier editor protects unsaved changes from back navigation', (
    tester,
  ) async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => SupplierEditorScreen(
                        controller: controller,
                      ),
                    ),
                  ),
                  child: const Text('Open supplier editor'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open supplier editor'));
      await tester.pumpAndSettle();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.first, 'Draft Supplier');
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Discard unsaved supplier changes?'), findsOneWidget);
      expect(find.text('Draft Supplier'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Save supplier'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('Open supplier editor'), findsOneWidget);
      expect(controller.snapshot.revision, 0);
    } finally {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('existing supplier avoids no-op revisions and clears reverted edits', (
    tester,
  ) async {
    const supplier = Supplier(
      id: 'supplier-semantic-dirty',
      name: 'ABC Pharma Distributor',
      returnBeforeExpiryDays: 30,
      address: 'Palwal',
      gstin: '22AAAAA0000A1Z5',
      revision: 4,
    );
    final controller = PharmacyController(
      MemoryInventoryStorage(
        InventorySnapshot(
          suppliers: <String, Supplier>{supplier.id: supplier},
        ),
      ),
      clock: () => DateTime(2026, 9, 29, 10),
      backgroundSearch: false,
    );
    await controller.initialize();

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: SupplierEditorScreen(
            controller: controller,
            supplier: supplier,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'Save supplier');
      expect(save, findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      final name = find.byType(TextFormField).first;
      await tester.enterText(name, 'ABC Pharma Distributor Updated');
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

      await tester.enterText(name, '  ABC   Pharma Distributor  ');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(save).onPressed,
        isNull,
        reason:
            'Whitespace-only differences normalize to the persisted supplier facts.',
      );

      expect(controller.snapshot.revision, 0);
      expect(controller.snapshot.suppliers[supplier.id]!.revision, 4);
      expect(tester.takeException(), isNull);
    } finally {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

}
