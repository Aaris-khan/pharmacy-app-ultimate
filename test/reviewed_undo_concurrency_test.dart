import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Medicine stock(String id, {String name = 'Dolo'}) => Medicine.fromJson({
      'id': id,
      'name': name,
      'strength': '650 mg',
      'form': 'Tablet',
      'quantity': 10,
      'expiry': '2027-12',
      'revision': 1,
    });

Future<PharmacyController> controller() async {
  final value = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await value.initialize();
  return value;
}

void main() {
  group('reviewed Undo', () {
    test('applies only the exact latest event that was reviewed', () async {
      final value = await controller();
      addTearDown(value.dispose);

      await value.save(stock('a'), expectedRevision: 0);
      final review = value.reviewUndo();
      await value.applyUndo(review);

      expect(value.snapshot.records, isEmpty);
      expect(value.snapshot.events.first['undone'], isFalse);
      expect(value.snapshot.events.first['label'], contains('Undo:'));
    });

    test('rejects a stale review after newer activity is saved', () async {
      final value = await controller();
      addTearDown(value.dispose);

      await value.save(stock('a'), expectedRevision: 0);
      final review = value.reviewUndo();
      await value.save(
        stock('b', name: 'Crocin'),
        expectedRevision: value.snapshot.revision,
      );

      await expectLater(value.applyUndo(review), throwsStateError);

      expect(value.snapshot.records.keys, containsAll(<String>['a', 'b']));
      expect(value.snapshot.events.first['label'], contains('Crocin'));
      expect(value.snapshot.events.first['undone'], isFalse);
    });

    test('rejects when a newer write is already queued ahead of apply', () async {
      final value = await controller();
      addTearDown(value.dispose);

      await value.save(stock('a'), expectedRevision: 0);
      final review = value.reviewUndo();

      final newerWrite = value.save(
        stock('b', name: 'Crocin'),
        expectedRevision: value.snapshot.revision,
      );
      final staleUndo = value.applyUndo(review);

      await newerWrite;
      await expectLater(staleUndo, throwsStateError);

      expect(value.snapshot.records.keys, containsAll(<String>['a', 'b']));
      expect(value.snapshot.events.first['label'], contains('Crocin'));
    });
  });
}
