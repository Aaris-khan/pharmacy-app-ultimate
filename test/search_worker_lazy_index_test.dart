import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/inventory.dart';
import '../lib/domain/medicine.dart';
import '../lib/services/search_worker.dart';

void main() {
  test('empty browse defers fuzzy indexing until a query', () async {
    final worker = SearchWorker();
    addTearDown(worker.close);

    final record = Medicine(
      id: 'browse-first',
      name: 'Example item',
      expiry: DateTime.utc(2027, 1, 1),
      quantity: 10,
    );
    const settings = WarningSettings();
    final today = DateTime.utc(2026, 9, 10);

    final browse = await worker.search(
      [record],
      1,
      '',
      SearchScope.all,
      settings,
      today,
    );
    expect(browse.single.id, record.id);
    expect(worker.debugIndexBuilds, 0);

    final typed = await worker.search(
      [record],
      1,
      'Example',
      SearchScope.all,
      settings,
      today,
    );
    expect(typed.single.id, record.id);
    expect(worker.debugIndexBuilds, 1);
  });
}
