import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/profile_screen.dart';
import '../lib/ui/removed_stock_screen.dart';

Future<PharmacyController> _controller(InventorySnapshot snapshot) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(snapshot),
    clock: () => DateTime(2026, 9, 20, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  testWidgets('removed-stock history lazily builds a large archive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final removed = <Medicine>[];
    for (var index = 0; index < 240; index++) {
      removed.add(
        archiveMedicine(
          Medicine(
            id: 'removed-$index',
            name: 'Removed Medicine ${index.toString().padLeft(3, '0')}',
            strength: '500mg',
            form: 'Tablet',
            expiry: DateTime(2027, 12, 31),
            quantity: 10,
          ),
          reason: 'Performance fixture',
          at: DateTime.utc(2026, 9, 1).add(Duration(minutes: index)),
        ),
      );
    }

    final controller = await _controller(
      InventorySnapshot(
        records: {for (final medicine in removed) medicine.id: medicine},
      ),
    );
    addTearDown(controller.dispose);

    final browse = await controller.searchArchived('');
    expect(browse.length, 240);
    final firstTitle = controller.snapshot.records[browse.first.id]!.title;
    final farTitle = controller.snapshot.records[browse[99].id]!.title;

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: RemovedStockScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(firstTitle), findsOneWidget);
    expect(find.text(farTitle), findsNothing);

    await tester.scrollUntilVisible(
      find.text(farTitle),
      700,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 50,
    );

    expect(find.text(farTitle), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('activity history lazily builds retained audit rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = List<Map<String, dynamic>>.generate(
      200,
      (index) => <String, dynamic>{
        'id': 'activity-$index',
        'revision': 200 - index,
        'label': 'Activity ${index.toString().padLeft(3, '0')}',
        'time': DateTime.utc(2026, 9, 20, 12)
            .subtract(Duration(minutes: index))
            .toIso8601String(),
        'undoable': false,
        'undone': false,
      },
      growable: false,
    );

    final controller = await _controller(
      InventorySnapshot(revision: 200, events: events),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: ActivityScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Activity 000'), findsOneWidget);
    expect(find.text('Activity 099'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Activity 099'),
      700,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 40,
    );

    expect(find.text('Activity 099'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
