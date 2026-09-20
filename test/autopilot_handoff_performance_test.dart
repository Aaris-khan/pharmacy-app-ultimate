import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Autopilot payload preparation yields for a larger snapshot', () async {
    final records = <String, Medicine>{
      for (var i = 0; i < 257; i++)
        'cooperative-$i': Medicine(
          id: 'cooperative-$i',
          name: 'Medicine $i',
          quantity: 10,
          unitPricePaise: 100,
          location: 'Shelf A',
          expiry: DateTime(2027, 12, 31),
        ),
    };
    final controller = PharmacyController(
      MemoryInventoryStorage(InventorySnapshot(records: records)),
      clock: () => DateTime(2026, 9, 20, 10),
      backgroundSearch: false,
    );
    await controller.initialize();
    final supervisor = AarisAutopilotSupervisor(
      controller,
      debounce: Duration.zero,
      startImmediately: false,
    );
    addTearDown(() {
      supervisor.dispose();
      controller.dispose();
    });

    supervisor.refreshNow();
    for (var attempt = 0; attempt < 100; attempt++) {
      if (supervisor.currentWorkQueue != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(supervisor.currentWorkQueue, isNotNull);
    expect(supervisor.debugHandoffYieldCount, greaterThan(0));
  });
}
