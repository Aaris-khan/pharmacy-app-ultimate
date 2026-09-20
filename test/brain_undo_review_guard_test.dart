import 'dart:io';

import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine _stock(String id) => Medicine.fromJson({
  'id': id,
  'name': id,
  'quantity': 1,
});

void main() {
  test('reviewed Undo fails closed when newer activity arrives', () async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => DateTime(2026, 9, 20, 9),
      backgroundSearch: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.save(_stock('first'), expectedRevision: 0);
    final review = controller.reviewUndo();

    await controller.save(
      _stock('newer'),
      expectedRevision: controller.snapshot.revision,
    );

    await expectLater(
      controller.applyUndo(review),
      throwsA(isA<StateError>()),
    );
    expect(controller.snapshot.revision, 2);
    expect(controller.snapshot.records, contains('first'));
    expect(controller.snapshot.records, contains('newer'));
  });

  test('Brain uses the reviewed Undo token across confirmation', () {
    final source = File('lib/ui/brain_screen.dart').readAsStringSync();

    expect(
      source,
      contains('final review = widget.controller.reviewUndo();'),
    );
    expect(
      source,
      contains('await widget.controller.applyUndo(review);'),
    );
  });
}
