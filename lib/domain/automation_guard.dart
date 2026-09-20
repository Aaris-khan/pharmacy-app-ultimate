import 'inventory_integrity.dart';
import 'medicine.dart';

class InventoryIntegrityMutationBlock {
  const InventoryIntegrityMutationBlock({
    required this.message,
    required this.stockIds,
  });

  final String message;
  final List<String> stockIds;
}

List<InventoryIntegrityIssue> _lotConflicts(
  Iterable<Medicine> records, {
  Iterable<Medicine>? relevantTo,
}) => conflictingLotFactIssues(
  medicines: records,
  relevantTo: relevantTo,
);

Map<String, Set<String>> _barcodeIdentityConflicts(
  Iterable<Medicine> records, {
  Set<String>? onlyBarcodes,
}) {
  if (onlyBarcodes != null && onlyBarcodes.isEmpty) {
    return const <String, Set<String>>{};
  }
  final groups = <String, List<Medicine>>{};
  for (final medicine in records) {
    if (medicine.archived) continue;
    final barcode = medicine.barcode.trim();
    if (barcode.isEmpty ||
        (onlyBarcodes != null && !onlyBarcodes.contains(barcode))) {
      continue;
    }
    groups.putIfAbsent(barcode, () => <Medicine>[]).add(medicine);
  }

  final conflicts = <String, Set<String>>{};
  for (final entry in groups.entries) {
    if (entry.value.map((medicine) => medicine.identity).toSet().length < 2) {
      continue;
    }
    conflicts[entry.key] = entry.value.map((medicine) => medicine.id).toSet();
  }
  return conflicts;
}

List<InventoryIntegrityIssue> _newLotConflictsFrom({
  required Iterable<InventoryIntegrityIssue> existing,
  required Iterable<InventoryIntegrityIssue> proposed,
}) => proposed.where((issue) {
  final proposedIds = issue.stockIds.toSet();
  return !existing.any((old) {
    final oldIds = old.stockIds.toSet();
    return proposedIds.every(oldIds.contains);
  });
}).toList(growable: false);

Map<String, Set<String>> _newBarcodeIdentityConflictsFrom({
  required Map<String, Set<String>> existing,
  required Map<String, Set<String>> proposed,
}) => {
  for (final entry in proposed.entries)
    if (existing[entry.key] == null ||
        !entry.value.every(existing[entry.key]!.contains))
      entry.key: entry.value,
};

/// Returns only physical-lot contradictions that are genuinely introduced by
/// the proposed state. A reduced subset of a conflict that already existed is
/// not treated as new, so a pharmacist can repair or archive bad rows without
/// being trapped by the safety gate.
List<InventoryIntegrityIssue> newlyIntroducedLotConflicts({
  required Iterable<Medicine> before,
  required Iterable<Medicine> after,
  required DateTime today,
  Iterable<Medicine>? relevantTo,
}) {
  final existing = _lotConflicts(before, relevantTo: relevantTo);
  final proposed = _lotConflicts(after, relevantTo: relevantTo);
  return _newLotConflictsFrom(existing: existing, proposed: proposed);
}

bool _introducesFutureManufactureDate({
  required Medicine? before,
  required Medicine after,
  required DateTime today,
}) {
  if (after.archived || after.sold || after.mfg == null) return false;
  final day = civilDay(today);
  if (!civilDay(after.mfg!).isAfter(day)) return false;
  if (before == null || before.archived || before.sold || before.mfg == null) {
    return true;
  }
  return !civilDay(before.mfg!).isAfter(day);
}

bool _stockStateChanged(Medicine before, Medicine after) =>
    before.quantity != after.quantity ||
    before.sold != after.sold ||
    before.soldAt != after.soldAt ||
    before.soldQuantity != after.soldQuantity ||
    before.soldUnitPricePaise != after.soldUnitPricePaise;

bool _identityFactsChanged(Medicine before, Medicine after) =>
    before.identity != after.identity ||
    normalize(before.batchNumber) != normalize(after.batchNumber) ||
    normalize(before.barcode) != normalize(after.barcode) ||
    normalize(before.manufacturer) != normalize(after.manufacturer) ||
    normalize(before.brand) != normalize(after.brand) ||
    before.mfg != after.mfg ||
    before.expiry != after.expiry;

bool _canParticipateInLotConflict(Medicine medicine) {
  if (medicine.archived || medicine.sold) return false;
  if (normalize(medicine.batchNumber).isEmpty) return false;
  return normalize(medicine.barcode).isNotEmpty ||
      normalize(medicine.manufacturer).isNotEmpty ||
      normalize(medicine.brand).isNotEmpty;
}

bool _hasFutureManufactureDate(Medicine medicine, DateTime today) =>
    !medicine.archived &&
    !medicine.sold &&
    medicine.mfg != null &&
    civilDay(medicine.mfg!).isAfter(civilDay(today));

/// Persistence-boundary policy for the authoritative medicine database.
///
/// This is the deterministic safety kernel underneath manual UI, Aaris Brain,
/// scanner review and AI-reviewed writes. It protects three operational facts
/// that must never depend on whichever caller happened to initiate a mutation:
///
/// * strongly anchored physical lots may not gain contradictory saved facts;
/// * one barcode may not silently become authoritative for different medicine
///   identities, because scanner exact-match automation would become unsafe;
/// * active stock may not newly acquire an impossible future manufacturing date,
///   and existing future-MFG rows cannot move stock until corrected.
///
/// Existing bad data remains repairable: note-only edits, archive/removal, and a
/// correction that actually resolves the unsafe condition are allowed. Undo and
/// explicitly reviewed backup recovery are handled by the persistence layer and
/// bypass this prospective guard so exact historical recovery remains possible.
InventoryIntegrityMutationBlock? inventoryIntegrityMutationBlock({
  required Map<String, Medicine> before,
  required Map<String, Medicine> after,
  required Iterable<String> touchedStockIds,
  required DateTime today,
}) {
  final touched = touchedStockIds.toSet();
  if (touched.isEmpty) return null;

  // Quantity/SOLD updates are the latency-sensitive daily path. If no row is
  // added, restored or identity-edited, the change cannot introduce a new lot
  // or barcode contradiction (except SOLD -> active, which falls through).
  // Evaluate only the pre-existing safety facts needed by touched rows instead
  // of rebuilding before/after integrity graphs several times.
  var stockOnly = true;
  var hasStockMovement = false;
  final stockMovementLotWitnesses = <Medicine>[];
  final stockMovementBarcodes = <String>{};
  for (final id in touched) {
    final old = before[id];
    final next = after[id];
    if (old == null ||
        next == null ||
        old.archived != next.archived ||
        _identityFactsChanged(old, next) ||
        (old.sold && !next.sold)) {
      stockOnly = false;
      break;
    }
    if (next.archived) continue;
    if (!_stockStateChanged(old, next)) continue;
    hasStockMovement = true;
    if (_canParticipateInLotConflict(old)) {
      stockMovementLotWitnesses.add(old);
    }
    final barcode = old.barcode.trim();
    if (barcode.isNotEmpty) stockMovementBarcodes.add(barcode);
  }

  if (stockOnly) {
    if (!hasStockMovement) return null;

    final lotIds = stockMovementLotWitnesses.isEmpty
        ? const <String>{}
        : _lotConflicts(
            before.values,
            relevantTo: stockMovementLotWitnesses,
          ).expand((issue) => issue.stockIds).toSet();
    final barcodeIds = stockMovementBarcodes.isEmpty
        ? const <String>{}
        : _barcodeIdentityConflicts(
            before.values,
            onlyBarcodes: stockMovementBarcodes,
          ).values.expand((ids) => ids).toSet();

    for (final id in touched) {
      final old = before[id]!;
      final next = after[id]!;
      if (next.archived || !_stockStateChanged(old, next)) continue;
      final futureMfg = _hasFutureManufactureDate(old, today);
      final blocked =
          lotIds.contains(id) || barcodeIds.contains(id) || futureMfg;
      if (!blocked) continue;
      final reason = barcodeIds.contains(id)
          ? 'a barcode identity conflict'
          : futureMfg
          ? 'a manufacturing date in the future'
          : 'conflicting saved batch facts';
      return InventoryIntegrityMutationBlock(
        stockIds: List.unmodifiable(<String>[id]),
        message:
            'Aaris paused this stock movement because this row has $reason. Open Needs attention, verify the physical pack, and correct or archive the unsafe row before changing quantity or SOLD state. Nothing was changed.',
      );
    }
    return null;
  }

  final integrityWitnesses = <Medicine>[];
  final relevantBarcodes = <String>{};
  for (final id in touched) {
    final old = before[id];
    final next = after[id];
    if (old != null) {
      integrityWitnesses.add(old);
      final barcode = old.barcode.trim();
      if (barcode.isNotEmpty) relevantBarcodes.add(barcode);
    }
    if (next != null) {
      integrityWitnesses.add(next);
      final barcode = next.barcode.trim();
      if (barcode.isNotEmpty) relevantBarcodes.add(barcode);
    }
  }

  // Only touched rows can introduce or perpetuate a new unsafe relationship.
  // Scan the before/after inventories once per rule, but materialize groups only
  // for the touched rows' old/new lot anchors and barcodes. Unrelated historical
  // conflicts remain visible in Needs Attention without taxing every edit.
  final beforeLotIssues = _lotConflicts(
    before.values,
    relevantTo: integrityWitnesses,
  );
  final afterLotIssues = _lotConflicts(
    after.values,
    relevantTo: integrityWitnesses,
  );
  final introducedLots = _newLotConflictsFrom(
    existing: beforeLotIssues,
    proposed: afterLotIssues,
  );
  if (introducedLots.isNotEmpty) {
    final ids = introducedLots.expand((issue) => issue.stockIds).toSet().toList()
      ..sort();
    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(ids),
      message:
          'Aaris blocked this change because it would create conflicting saved facts for a strongly matched physical batch. Verify the batch, barcode, expiry and manufacturing date instead of saving two contradictory versions of the same lot. Nothing was changed.',
    );
  }

  final beforeBarcodeGroups = _barcodeIdentityConflicts(
    before.values,
    onlyBarcodes: relevantBarcodes,
  );
  final afterBarcodeGroups = _barcodeIdentityConflicts(
    after.values,
    onlyBarcodes: relevantBarcodes,
  );
  final introducedBarcodes = _newBarcodeIdentityConflictsFrom(
    existing: beforeBarcodeGroups,
    proposed: afterBarcodeGroups,
  );
  if (introducedBarcodes.isNotEmpty) {
    final ids = introducedBarcodes.values.expand((ids) => ids).toSet().toList()
      ..sort();
    final barcode = introducedBarcodes.keys.first;
    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(ids),
      message:
          'Aaris blocked this change because barcode $barcode would point to different medicine identities. Verify the physical packs or correct the barcode before scanner or stock automation can trust it. Nothing was changed.',
    );
  }

  for (final id in touched) {
    final next = after[id];
    if (next == null) continue;
    if (_introducesFutureManufactureDate(
      before: before[id],
      after: next,
      today: today,
    )) {
      return InventoryIntegrityMutationBlock(
        stockIds: List.unmodifiable(<String>[id]),
        message:
            'Aaris blocked this change because it would save active stock with a manufacturing date in the future. Verify the printed MFG date before saving; nothing was changed.',
      );
    }
  }

  final beforeLotIds = beforeLotIssues
      .expand((issue) => issue.stockIds)
      .toSet();
  final afterLotIds = afterLotIssues
      .expand((issue) => issue.stockIds)
      .toSet();
  final beforeBarcodeIds = beforeBarcodeGroups.values.expand((ids) => ids).toSet();
  final afterBarcodeIds = afterBarcodeGroups.values.expand((ids) => ids).toSet();

  for (final id in touched) {
    final old = before[id];
    final next = after[id];
    if (old == null || next == null || next.archived) continue;

    final beforeFuture = _hasFutureManufactureDate(old, today);
    final blockedBefore =
        beforeLotIds.contains(id) ||
        beforeBarcodeIds.contains(id) ||
        beforeFuture;
    if (!blockedBefore) continue;

    final afterFuture = _hasFutureManufactureDate(next, today);
    final blockedAfter =
        afterLotIds.contains(id) ||
        afterBarcodeIds.contains(id) ||
        afterFuture;
    final stockStateChanged = _stockStateChanged(old, next);
    final identityFactsChanged = _identityFactsChanged(old, next);

    if (!stockStateChanged && !identityFactsChanged) continue;
    if (!blockedAfter && identityFactsChanged) continue;

    final reason = beforeBarcodeIds.contains(id)
        ? 'a barcode identity conflict'
        : beforeFuture
        ? 'a manufacturing date in the future'
        : 'conflicting saved batch facts';
    return InventoryIntegrityMutationBlock(
      stockIds: List.unmodifiable(<String>[id]),
      message: stockStateChanged
          ? 'Aaris paused this stock movement because this row has $reason. Open Needs attention, verify the physical pack, and correct or archive the unsafe row before changing quantity or SOLD state. Nothing was changed.'
          : 'Aaris blocked this identity/batch edit because the row would still have $reason after saving. Resolve the unsafe facts completely first; nothing was changed.',
    );
  }

  return null;
}

void ensureIntegritySafeInventoryMutation({
  required Map<String, Medicine> before,
  required Map<String, Medicine> after,
  required Iterable<String> touchedStockIds,
  required DateTime today,
}) {
  final block = inventoryIntegrityMutationBlock(
    before: before,
    after: after,
    touchedStockIds: touchedStockIds,
    today: today,
  );
  if (block != null) throw StateError(block.message);
}
