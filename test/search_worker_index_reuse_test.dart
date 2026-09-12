import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/inventory.dart';
import '../lib/services/search_worker.dart';
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
}
