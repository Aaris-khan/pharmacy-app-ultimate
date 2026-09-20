import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/search.dart';
import '../lib/services/search_worker.dart';
import '../lib/state/pharmacy_controller.dart';
import 'domain_contract.dart';

void main() {
  test('stock-only revisions reuse the expensive background search index', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final original = stock(
      'drotaverine',
      name: 'Drotaverine',
      strength: '80mg',
      quantity: 10,
      price: 200,
    );
    final first = await worker.search(
      [original],
      1,
      'DOTIN 80mg',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(first.single.id, original.id);
    expect(worker.debugIndexBuilds, 1);

    final quantityOnly = original.patch({'quantity': 7});
    final afterSale = await worker.search(
      [quantityOnly],
      2,
      'DOTIN 80mg',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(afterSale.single.id, original.id);
    expect(worker.debugIndexBuilds, 1);

    final priceOnly = quantityOnly.patch({'unitPricePaise': 350});
    await worker.search(
      [priceOnly],
      3,
      'Drotaverine 80mg',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(worker.debugIndexBuilds, 1);

    final searchableEdit = priceOnly.patch({'notes': 'Emergency shelf'});
    final noteHit = await worker.search(
      [searchableEdit],
      4,
      'Emergency shelf',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(noteHit.single.id, original.id);
    expect(worker.debugIndexBuilds, 2);
  });

  test('status changes rebuild the index so scoped results stay authoritative', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final active = stock(
      'sold-later',
      name: 'Cefixime',
      expiry: '2027-01-01',
      quantity: 4,
    );
    await worker.search(
      [active],
      10,
      'Cefixime',
      SearchScope.all,
      contractSettings,
      contractToday,
    );
    expect(worker.debugIndexBuilds, 1);

    final sold = active.patch({'sold': true, 'quantity': 0});
    final soldHits = await worker.search(
      [sold],
      11,
      'Cefixime',
      SearchScope.sold,
      contractSettings,
      contractToday,
    );
    expect(soldHits.single.id, active.id);
    expect(worker.debugIndexBuilds, 2);
  });

  test('removed-stock timestamp changes invalidate stale worker ordering', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final older = stock('removed-older', name: 'Drotaverine').patch({
      'archived': true,
      'archivedAt': DateTime.utc(2026, 9, 1).toIso8601String(),
      'archiveReason': 'Removed for return',
    });
    final newer = stock('removed-newer', name: 'Drotaverine').patch({
      'archived': true,
      'archivedAt': DateTime.utc(2026, 9, 2).toIso8601String(),
      'archiveReason': 'Removed for return',
    });

    final first = await worker.browseArchived(
      [older, newer],
      20,
      limit: 100000,
    );
    expect(first.map((hit) => hit.id), [newer.id, older.id]);

    final reArchivedLater = older.patch({
      'archivedAt': DateTime.utc(2026, 9, 3).toIso8601String(),
    });
    final refreshed = await worker.browseArchived(
      [reArchivedLater, newer],
      21,
      limit: 100000,
    );

    expect(refreshed.map((hit) => hit.id), [reArchivedLater.id, newer.id]);
  });

  test('shared search projection ignores stock-only facts but catches search edits', () {
    final original = stock(
      'projection',
      name: 'Drotaverine',
      strength: '80mg',
      quantity: 10,
      price: 200,
    );

    expect(
      sameSearchProjection(
        original,
        original.patch({'quantity': 7, 'unitPricePaise': 350}),
      ),
      isTrue,
    );
    expect(
      sameSearchProjection(
        original,
        original.patch({'location': 'Shelf B'}),
      ),
      isFalse,
    );
  });

  test(
    'controller keeps search dataset stable for stock-only medicine writes',
    () async {
      final original = stock(
        'controller-projection',
        name: 'Drotaverine',
        strength: '80mg',
        quantity: 10,
        price: 200,
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {original.id: original}),
        ),
        clock: () => contractToday,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      final first = await controller.search('DOTIN 80mg', SearchScope.all);
      expect(first.single.id, original.id);
      expect(controller.debugWebSearchIndexBuilds, 1);
      final initialEpoch = controller.debugSearchDatasetEpoch;

      var live = controller.snapshot.records[original.id]!;
      await controller.save(
        live.patch(<String, dynamic>{
          'quantity': 7,
          'unitPricePaise': 350,
        }),
        expectedRevision: controller.snapshot.revision,
      );

      expect(
        controller.debugSearchDatasetEpoch,
        initialEpoch,
        reason:
            'Quantity/price changes do not alter local search membership, ranking or browse ordering.',
      );
      final afterStockOnly = await controller.search(
        'DOTIN 80mg',
        SearchScope.all,
      );
      expect(afterStockOnly.single.id, original.id);
      expect(
        controller.debugWebSearchIndexBuilds,
        1,
        reason: 'A stock-only write must not rebuild the fuzzy search index.',
      );

      live = controller.snapshot.records[original.id]!;
      await controller.save(
        live.patch(<String, dynamic>{'notes': 'Emergency shelf'}),
        expectedRevision: controller.snapshot.revision,
      );

      expect(controller.debugSearchDatasetEpoch, initialEpoch + 1);
      final noteHit = await controller.search(
        'Emergency shelf',
        SearchScope.all,
      );
      expect(noteHit.single.id, original.id);
      expect(controller.debugWebSearchIndexBuilds, 2);
    },
  );

  test(
    'removed search index ignores searchable edits to active stock',
    () async {
      final removed = archiveMedicine(
        stock(
          'removed-projection',
          name: 'Drotaverine',
          strength: '80mg',
          quantity: 4,
        ),
        reason: 'Removed for return',
        at: DateTime.utc(2026, 9, 19, 10),
      );
      final active = stock(
        'active-projection',
        name: 'Paracetamol',
        strength: '500mg',
        quantity: 20,
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(records: {removed.id: removed, active.id: active}),
        ),
        clock: () => contractToday,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      final first = await controller.searchArchived('Drotaverine');
      expect(first.single.id, removed.id);
      expect(controller.debugWebArchivedSearchIndexBuilds, 1);
      final archivedEpoch = controller.archivedSearchProjectionEpoch;
      final activeEpoch = controller.debugSearchDatasetEpoch;

      final live = controller.snapshot.records[active.id]!;
      await controller.save(
        live.patch(<String, dynamic>{'notes': 'Emergency counter'}),
        expectedRevision: controller.snapshot.revision,
      );

      expect(controller.debugSearchDatasetEpoch, activeEpoch + 1);
      expect(controller.archivedSearchProjectionEpoch, archivedEpoch);
      final afterActiveEdit = await controller.searchArchived('Drotaverine');
      expect(afterActiveEdit.single.id, removed.id);
      expect(
        controller.debugWebArchivedSearchIndexBuilds,
        1,
        reason:
            'An active-row search edit cannot invalidate the Removed Stock index.',
      );
    },
  );

  test(
    'queued writes cannot hide an earlier search projection change',
    () async {
      final searchable = stock(
        'queued-searchable',
        name: 'Cefixime',
        quantity: 8,
      );
      final stockOnly = stock(
        'queued-stock-only',
        name: 'Paracetamol',
        quantity: 12,
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(
            records: {
              searchable.id: searchable,
              stockOnly.id: stockOnly,
            },
          ),
        ),
        clock: () => contractToday,
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      await controller.search('Cefixime', SearchScope.all);
      final initialEpoch = controller.debugSearchDatasetEpoch;
      expect(controller.debugWebSearchIndexBuilds, 1);

      var liveSearchable = controller.snapshot.records[searchable.id]!;
      await controller.save(
        liveSearchable.patch(<String, dynamic>{'notes': 'Cold shelf'}),
        expectedRevision: controller.snapshot.revision,
      );

      var liveStockOnly = controller.snapshot.records[stockOnly.id]!;
      await controller.save(
        liveStockOnly.patch(<String, dynamic>{'quantity': 11}),
        expectedRevision: controller.snapshot.revision,
      );

      expect(
        controller.debugSearchDatasetEpoch,
        initialEpoch + 1,
        reason:
            'A later stock-only write must not erase an earlier searchable edit before the read cache catches up.',
      );
      final refreshed = await controller.search('Cold shelf', SearchScope.all);
      expect(refreshed.single.id, searchable.id);
      expect(controller.debugWebSearchIndexBuilds, 2);
    },
  );

}
