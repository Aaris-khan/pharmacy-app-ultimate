import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/domain/backup.dart';
import '../lib/domain/tracking.dart';
import 'domain_contract.dart';

PharmacyBackup _backup() {
  final medicine = stock(
    'stock-a',
    name: 'Dolo',
    strength: '650mg',
    notes: 'Rack A',
    quantity: 10,
  );
  final sale = SaleEvent(
    id: 'sale-a',
    stockId: medicine.id,
    medicineName: medicine.name,
    strength: medicine.strength,
    form: medicine.form,
    salt: medicine.salt,
    quantity: 2,
    occurredAt: contractToday,
    totalAmountPaise: 1200,
    savedUnitPricePaise: medicine.unitPricePaise,
  );
  return PharmacyBackup(
    createdAt: DateTime.utc(2026, 9, 12, 18, 30),
    sourceRevision: 7,
    settings: const contractSettings,
    records: {medicine.id: medicine},
    sales: {sale.id: sale},
    soldValue: 1200,
    unknownSold: 0,
  );
}

void main() {
  test('v2 backup round-trips with a deterministic SHA-256 integrity proof', () {
    final encoded = _backup().encode();
    final envelope = jsonDecode(encoded) as Map<String, dynamic>;

    expect(envelope['schema'], pharmacyBackupSchema);
    expect(
      envelope['integrity'],
      matches(RegExp(r'^sha256:[a-f0-9]{64}$')),
    );

    final parsed = PharmacyBackup.parse(encoded);
    expect(parsed.sourceRevision, 7);
    expect(parsed.records.single.name, 'Dolo');
    expect(parsed.sales.single.quantity, 2);
    expect(parsed.soldValue, 1200);
  });

  test('valid-looking fact edits are rejected when integrity no longer matches', () {
    final encoded = _backup().encode();
    final tampered = encoded.replaceFirst('"quantity": 10', '"quantity": 9');

    expect(tampered, isNot(encoded));
    expect(() => PharmacyBackup.parse(tampered), throwsFormatException);
  });

  test('legacy v1 backups remain importable after the v2 upgrade', () {
    final legacy = jsonDecode(_backup().encode()) as Map<String, dynamic>;
    legacy['schema'] = legacyPharmacyBackupSchema;
    legacy.remove('integrity');

    final parsed = PharmacyBackup.parse(jsonEncode(legacy));
    expect(parsed.records.single.id, 'stock-a');
    expect(parsed.sales.single.id, 'sale-a');
  });

  test('JSON field reordering does not break canonical integrity verification', () {
    final envelope = jsonDecode(_backup().encode()) as Map<String, dynamic>;
    final rawMedicine = Map<String, dynamic>.from(
      (envelope['medicines'] as List).single as Map,
    );
    envelope['medicines'] = [
      Map<String, dynamic>.fromEntries(
        rawMedicine.entries.toList().reversed,
      ),
    ];

    final parsed = PharmacyBackup.parse(jsonEncode(envelope));
    expect(parsed.records.single.name, 'Dolo');
  });
}
