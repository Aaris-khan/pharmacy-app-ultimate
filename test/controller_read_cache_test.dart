import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('derived read models reuse one snapshot and invalidate on the right boundary', () async {
    var now = DateTime(2026, 9, 12, 10);
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      clock: () => now,
      backgroundSearch: false,
    );
    await controller.initialize();
    addTearDown(controller.dispose);

    final statsDayOne = controller.stats;
    final homeDayOne = controller.homeProjection;
    final salesSnapshotOne = controller.salesOverview;

    expect(identical(statsDayOne, controller.stats), isTrue);
    expect(identical(homeDayOne, controller.homeProjection), isTrue);
    expect(identical(salesSnapshotOne, controller.salesOverview), isTrue);

    // Expiry/status projections are civil-day dependent, while all-time sales
    // analytics are not. A midnight refresh must therefore invalidate only the
    // day-sensitive read models when the inventory snapshot itself is unchanged.
    now = DateTime(2026, 9, 13, 10);
    controller.refreshDay();

    expect(identical(statsDayOne, controller.stats), isFalse);
    expect(identical(homeDayOne, controller.homeProjection), isFalse);
    expect(identical(salesSnapshotOne, controller.salesOverview), isTrue);

    final statsDayTwo = controller.stats;
    final homeDayTwo = controller.homeProjection;
    final salesBeforeWrite = controller.salesOverview;

    await controller.save(
      Medicine(
        id: 'cache-stock',
        name: 'Cache Test Medicine',
        strength: '500mg',
        form: 'Tablet',
        quantity: 10,
        expiry: DateTime(2027, 1, 1),
      ),
      expectedRevision: controller.snapshot.revision,
    );

    expect(identical(statsDayTwo, controller.stats), isFalse);
    expect(identical(homeDayTwo, controller.homeProjection), isFalse);
    expect(identical(salesBeforeWrite, controller.salesOverview), isFalse);
    expect(controller.homeProjection.activeCount, 1);
  });
}
