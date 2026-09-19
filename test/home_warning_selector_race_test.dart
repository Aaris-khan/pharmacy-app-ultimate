import 'dart:async';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _BlockingStorage implements InventoryStorage {
  final MemoryInventoryStorage _inner = MemoryInventoryStorage();
  final Completer<void> _firstCommitGate = Completer<void>();
  int commits = 0;

  void releaseFirstCommit() {
    if (!_firstCommitGate.isCompleted) _firstCommitGate.complete();
  }

  @override
  Future<InventorySnapshot> load() => _inner.load();

  @override
  Future<InventorySnapshot> commit(InventoryMutation mutation) async {
    commits++;
    if (commits == 1) await _firstCommitGate.future;
    return _inner.commit(mutation);
  }

  @override
  Future<void> close() => _inner.close();
}

void main() {
  testWidgets(
    'warning selector keeps a rapid last intent that returns to the baseline',
    (tester) async {
      final storage = _BlockingStorage();
      final controller = PharmacyController(
        storage,
        clock: () => DateTime(2026, 9, 20, 10),
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeScreen(controller: controller, onDatabase: () {}),
          ),
        ),
      );

      Future<void> chooseShortDays(String label) async {
        await tester.tap(find.byType(PopupMenuButton<int>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(controller.settings.shortDays, 8);
      await chooseShortDays('5 Days');

      // The first write is still blocked. Choosing the originally committed
      // value is therefore a real second intent, not a no-op.
      expect(controller.settings.shortDays, 8);
      await chooseShortDays('8 Days');

      storage.releaseFirstCommit();
      await tester.pumpAndSettle();

      expect(storage.commits, 2);
      expect(controller.settings.shortDays, 8);
      expect(controller.settings.months, 2);
      expect(controller.snapshot.revision, 2);
    },
  );
}
