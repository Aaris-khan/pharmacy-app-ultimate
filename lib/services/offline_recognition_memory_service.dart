import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/medicine.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';

/// Private, bounded learning memory for recurring OCR recognition mistakes.
///
/// Only explicit pharmacist-confirmed saves may teach this store. It never
/// stores the full OCR document, dates, batch, price, quantity or location.
/// Identity aliases remain product-scoped. Salt corrections are additionally
/// field-scoped and are activated only when independent evidence in the same
/// frame supports that exact pharmacist-reviewed medicine identity.
class OfflineRecognitionMemoryService {
  OfflineRecognitionMemoryService._();

  static final OfflineRecognitionMemoryService instance =
      OfflineRecognitionMemoryService._();

  static const _schemaVersion = 1;
  static const _maxRows = 16000;
  static const _saltAliasPrefix = 'salt:';
  Database? _database;
  Future<void>? _initializing;

  Future<void> _initialize() =>
      _initializing ??= _open().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _open() async {
    if (_database != null) return;
    final support = await getApplicationSupportDirectory();
    _database = await openDatabase(
      '${support.path}/aaris_offline_recognition_memory.db',
      version: _schemaVersion,
      onCreate: (db, _) async {
        await db.execute('''
CREATE TABLE recognition_aliases (
  identity_key TEXT NOT NULL,
  alias TEXT NOT NULL,
  normalized_alias TEXT NOT NULL,
  support INTEGER NOT NULL,
  last_confirmed INTEGER NOT NULL,
  PRIMARY KEY(identity_key, normalized_alias)
)
''');
        await db.execute(
          'CREATE INDEX idx_recognition_alias ON recognition_aliases(normalized_alias)',
        );
        await db.execute(
          'CREATE INDEX idx_recognition_recent ON recognition_aliases(last_confirmed)',
        );
      },
    );
  }

  /// Learns compact OCR corrections only after an explicit human-confirmed
  /// save. Name/brand variants become identity memory. A single-ingredient salt
  /// correction is stored in a separate namespace so it can never become a
  /// global product-name shortcut.
  ///
  /// Recognition-memory failure is intentionally non-authoritative: inventory
  /// save has already succeeded and callers keep operating normally.
  Future<void> learnFromConfirmedScan(
    MedicineScanDraft draft,
    Medicine confirmed,
  ) async {
    final identityAliases = deriveLearnableIdentityAliases(draft, confirmed);
    final saltAliases = deriveLearnableSaltAliases(draft, confirmed);
    if (identityAliases.isEmpty && saltAliases.isEmpty) return;
    try {
      await _initialize();
      final db = _database;
      if (db == null) return;
      final identityKey = recognitionIdentityKey(
        name: confirmed.name,
        brand: confirmed.brand,
        salt: confirmed.salt,
        strength: confirmed.strength,
        form: confirmed.form,
      );
      if (identityKey.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        Future<void> remember(String alias, String normalized) async {
          if (alias.trim().isEmpty || normalized.isEmpty) return;
          await txn.rawInsert(
            '''INSERT INTO recognition_aliases
               (identity_key, alias, normalized_alias, support, last_confirmed)
               VALUES (?, ?, ?, 1, ?)
               ON CONFLICT(identity_key, normalized_alias) DO UPDATE SET
                 alias=excluded.alias,
                 support=MIN(recognition_aliases.support + 1, 1000000),
                 last_confirmed=excluded.last_confirmed''',
            <Object?>[identityKey, alias, normalized, now],
          );
        }

        for (final alias in identityAliases.take(8)) {
          final normalized = searchText(alias);
          if (normalized.length < 3 || normalized.length > 40) continue;
          await remember(alias, normalized);
        }
        for (final alias in saltAliases.take(4)) {
          final normalized = _storedSaltAliasKey(alias);
          if (normalized.isEmpty || normalized.length > 72) continue;
          await remember(alias, normalized);
        }

        final countRows = await txn.rawQuery(
          'SELECT COUNT(*) AS count FROM recognition_aliases',
        );
        final count = countRows.isEmpty
            ? 0
            : (countRows.first['count'] as num?)?.toInt() ?? 0;
        final overflow = max(0, count - _maxRows);
        if (overflow > 0) {
          await txn.rawDelete(
            '''DELETE FROM recognition_aliases WHERE rowid IN (
                 SELECT rowid FROM recognition_aliases
                 ORDER BY last_confirmed ASC, support ASC
                 LIMIT ?
               )''',
            <Object?>[overflow],
          );
        }
      });
    } catch (_) {
      // A local-learning accelerator must never make capture/review unavailable.
    }
  }

  /// Adds previously confirmed OCR memory only to matching current local
  /// medicine identities. Identity aliases use recency-weighted collision
  /// evidence. Salt corrections additionally require the learned typo and an
  /// independent identity anchor to co-occur in the same OCR frame, preventing
  /// one medicine in a video/import from teaching another medicine by accident.
  ///
  /// If the memory DB is absent/corrupt/unavailable, the exact original
  /// knowledge list is returned.
  Future<List<MedicineKnowledgeEntry>> enrichKnowledge(
    List<MedicineKnowledgeEntry> knowledge,
    List<MedicineFrameEvidence> evidence,
  ) async {
    if (knowledge.isEmpty || evidence.isEmpty) return knowledge;
    try {
      await _initialize();
      final db = _database;
      if (db == null) return knowledge;

      final identityEvidenceKeys = _evidenceAliasKeys(evidence)
          .take(96)
          .toList(growable: false);
      final saltEvidenceKeys = _evidenceSaltAliasKeys(evidence)
          .take(96)
          .map((key) => '$_saltAliasPrefix$key')
          .toList(growable: false);
      final keys = <String>{
        ...identityEvidenceKeys,
        ...saltEvidenceKeys,
      }.take(192).toList(growable: false);
      if (keys.isEmpty) return knowledge;

      final placeholders = List.filled(keys.length, '?').join(',');
      final rows = await db.rawQuery(
        '''SELECT identity_key, alias, normalized_alias, support, last_confirmed
           FROM recognition_aliases
           WHERE normalized_alias IN ($placeholders)
           ORDER BY support DESC, last_confirmed DESC
           LIMIT 256''',
        keys,
      );
      if (rows.isEmpty) return knowledge;

      final byAlias = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final normalized = row['normalized_alias'];
        if (normalized is! String || normalized.isEmpty) continue;
        byAlias
            .putIfAbsent(normalized, () => <Map<String, Object?>>[])
            .add(row);
      }

      // Identity aliases are allowed to accelerate product recognition only
      // when an ambiguous alias has a materially dominant, reasonably recent
      // pharmacist-confirmed mapping. The exponential half-life prevents old
      // mistakes from owning a typo forever while preserving repeated evidence.
      final learnedIdentity = <String, List<String>>{};
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in byAlias.entries) {
        if (entry.key.startsWith(_saltAliasPrefix)) continue;
        final collision = entry.value;
        final weightByIdentity = <String, double>{};
        final supportByIdentity = <String, int>{};
        for (final row in collision) {
          final identity = row['identity_key'];
          final support = row['support'];
          if (identity is! String || support is! num) continue;
          final count = max(1, support.toInt());
          final last = row['last_confirmed'];
          final lastConfirmed = last is num ? last.toInt() : now;
          final ageDays = max(0, now - lastConfirmed) / 86400000.0;
          final recency = pow(.5, ageDays / 180.0).toDouble();
          final weight = count * recency;
          weightByIdentity.update(
            identity,
            (value) => value + weight,
            ifAbsent: () => weight,
          );
          supportByIdentity.update(
            identity,
            (value) => value + count,
            ifAbsent: () => count,
          );
        }
        if (weightByIdentity.isEmpty) continue;
        final ranked = weightByIdentity.entries.toList(growable: false)
          ..sort((a, b) {
            final weight = b.value.compareTo(a.value);
            return weight != 0 ? weight : a.key.compareTo(b.key);
          });
        final winner = ranked.first;
        if (ranked.length > 1) {
          final runner = ranked[1];
          final total = ranked.fold<double>(0, (sum, item) => sum + item.value);
          final posterior = total <= 0 ? 0.0 : winner.value / total;
          final ratio = runner.value <= 0 ? double.infinity : winner.value / runner.value;
          final dominant =
              (supportByIdentity[winner.key] ?? 0) >= 2 &&
              posterior >= .64 &&
              ratio >= 1.75;
          if (!dominant) continue;
        }

        for (final row in collision) {
          if (row['identity_key'] != winner.key) continue;
          final alias = row['alias'];
          if (alias is! String || alias.trim().isEmpty) continue;
          final values = learnedIdentity.putIfAbsent(
            winner.key,
            () => <String>[],
          );
          if (!values.contains(alias) && values.length < 12) values.add(alias);
          break;
        }
      }

      final knowledgeByIdentity = <String, List<MedicineKnowledgeEntry>>{};
      for (final item in knowledge) {
        final identity = recognitionIdentityKey(
          name: item.name,
          brand: item.brand,
          salt: item.salt,
          strength: item.strength,
          form: item.form,
        );
        if (identity.isEmpty) continue;
        knowledgeByIdentity
            .putIfAbsent(identity, () => <MedicineKnowledgeEntry>[])
            .add(item);
      }
      final frameContexts = _recognitionFrameContexts(evidence);
      final learnedSalt = <String, List<String>>{};
      for (final entry in byAlias.entries) {
        if (!entry.key.startsWith(_saltAliasPrefix)) continue;
        final aliasKey = entry.key.substring(_saltAliasPrefix.length);
        if (aliasKey.isEmpty) continue;
        for (final row in entry.value) {
          final identity = row['identity_key'];
          final alias = row['alias'];
          if (identity is! String || alias is! String || alias.trim().isEmpty) {
            continue;
          }
          final knownEntries = knowledgeByIdentity[identity];
          if (knownEntries == null || knownEntries.isEmpty) continue;
          final identityAliases =
              learnedIdentity[identity] ?? const <String>[];
          final supported = knownEntries.any(
            (item) => _saltCorrectionContextSupports(
              item,
              aliasKey,
              frameContexts,
              identityAliases,
            ),
          );
          if (!supported) continue;
          final values = learnedSalt.putIfAbsent(identity, () => <String>[]);
          if (!values.contains(alias) && values.length < 8) values.add(alias);
        }
      }

      if (learnedIdentity.isEmpty && learnedSalt.isEmpty) return knowledge;

      var changed = false;
      final result = <MedicineKnowledgeEntry>[];
      for (final item in knowledge) {
        final identity = recognitionIdentityKey(
          name: item.name,
          brand: item.brand,
          salt: item.salt,
          strength: item.strength,
          form: item.form,
        );
        final identityAliases = learnedIdentity[identity];
        final saltAliases = learnedSalt[identity];
        if ((identityAliases == null || identityAliases.isEmpty) &&
            (saltAliases == null || saltAliases.isEmpty)) {
          result.add(item);
          continue;
        }
        final mergedIdentityAliases = <String>{
          ...?identityAliases,
          ...item.ocrAliases,
        }.take(24).toList(growable: false);
        final mergedSaltAliases = <String>{
          ...?saltAliases,
          ...item.saltOcrAliases,
        }.take(24).toList(growable: false);
        result.add(
          MedicineKnowledgeEntry(
            name: item.name,
            brand: item.brand,
            salt: item.salt,
            strength: item.strength,
            form: item.form,
            manufacturer: item.manufacturer,
            barcode: item.barcode,
            aliases: item.aliases,
            ocrAliases: mergedIdentityAliases,
            saltOcrAliases: mergedSaltAliases,
          ),
        );
        changed = true;
      }
      return changed
          ? List<MedicineKnowledgeEntry>.unmodifiable(result)
          : knowledge;
    } catch (_) {
      return knowledge;
    }
  }
}

/// Stable privacy-safe identity key. Raw OCR is never part of this digest.
String recognitionIdentityKey({
  required String name,
  required String brand,
  required String salt,
  required String strength,
  required String form,
}) {
  final parts = <String>[
    name,
    brand,
    salt,
    strength,
    form,
  ].map(searchText).toList(growable: false);
  if (parts.every((value) => value.isEmpty)) return '';
  return sha256.convert(parts.join('|').codeUnits).toString();
}

/// Extracts bounded OCR variants demonstrably related to the final
/// human-reviewed Name/Brand. In addition to fuzzy candidates, an explicit
/// scan-field correction may teach a more damaged spelling when that exact
/// observed value is present in raw OCR and still has enough character evidence
/// to be a plausible OCR corruption rather than a semantic jump.
List<String> deriveLearnableIdentityAliases(
  MedicineScanDraft draft,
  Medicine confirmed,
) {
  final targets = <String>{
    confirmed.name,
    confirmed.brand,
  }.map(searchText).where((value) => value.length >= 3).toSet();
  if (targets.isEmpty || draft.rawText.trim().isEmpty) return const <String>[];

  final observed = _textIdentityAliasKeys(draft.rawText);
  final scores = <String, double>{};

  void considerDirectCorrection(String observedValue, String confirmedValue) {
    final candidate = searchText(observedValue);
    final target = searchText(confirmedValue);
    if (candidate.length < 3 ||
        target.length < 3 ||
        candidate == target ||
        !observed.contains(candidate)) {
      return;
    }
    if (!_plausibleOcrCorrection(candidate, target)) return;
    scores.update(candidate, (value) => max(value, 1.05), ifAbsent: () => 1.05);
  }

  considerDirectCorrection(draft.name, confirmed.name);
  considerDirectCorrection(draft.brand, confirmed.brand);

  for (final candidate in observed) {
    if (targets.contains(candidate)) continue;
    if (RegExp(r'^\d+(?:[ ./:+-]\d+)*$').hasMatch(candidate)) continue;
    var best = 0.0;
    for (final target in targets) {
      final ratio =
          min(candidate.length, target.length) /
          max(candidate.length, target.length);
      if (ratio < .58) continue;
      best = max(best, _identitySimilarity(candidate, target));
    }
    if (best >= .74) {
      scores.update(candidate, (value) => max(value, best), ifAbsent: () => best);
    }
  }

  final ranked = scores.entries.toList(growable: false)
    ..sort((a, b) {
      final score = b.value.compareTo(a.value);
      if (score != 0) return score;
      final length = a.key.length.compareTo(b.key.length);
      return length != 0 ? length : a.key.compareTo(b.key);
    });
  return ranked.map((value) => value.key).take(8).toList(growable: false);
}

/// Learns one explicitly corrected single-ingredient OCR spelling. Combination
/// salts deliberately abstain here because a flat alias cannot safely prove
/// which component was corrected. The observed salt must be a real raw-OCR
/// witness and must still share enough character evidence with the confirmed
/// salt to reject semantic jumps such as Paracetamol -> Prednisolone.
List<String> deriveLearnableSaltAliases(
  MedicineScanDraft draft,
  Medicine confirmed,
) {
  final observedParts = _saltParts(draft.salt);
  final confirmedParts = _saltParts(confirmed.salt);
  if (observedParts.length != 1 || confirmedParts.length != 1) {
    return const <String>[];
  }
  final observed = observedParts.single.trim();
  final confirmedSalt = confirmedParts.single.trim();
  final observedKey = _saltAliasKey(observed);
  final confirmedKey = _saltAliasKey(confirmedSalt);
  if (observedKey.length < 4 ||
      observedKey.length > 56 ||
      confirmedKey.length < 4 ||
      observedKey == confirmedKey) {
    return const <String>[];
  }
  if (_saltAliasNoise.contains(observedKey)) return const <String>[];
  if (!_evidenceSaltAliasKeysFromText(draft.rawText).contains(observedKey)) {
    return const <String>[];
  }
  if (!_plausibleOcrCorrection(observedKey, confirmedKey)) {
    return const <String>[];
  }

  // Never turn a printed trade name/manufacturer into a learned salt shortcut
  // merely because the user corrected the Salt box afterwards.
  for (final other in <String>[
    confirmed.name,
    confirmed.brand,
    confirmed.manufacturer,
  ]) {
    final otherKey = _saltAliasKey(other);
    if (otherKey.isEmpty || otherKey == confirmedKey) continue;
    if (observedKey == otherKey ||
        _identitySimilarity(observedKey, otherKey) >= .92) {
      return const <String>[];
    }
  }
  return <String>[observed];
}

Set<String> _evidenceAliasKeys(List<MedicineFrameEvidence> evidence) {
  final result = <String>{};
  for (final frame in evidence.take(12)) {
    result.addAll(_textIdentityAliasKeys(frame.text));
    if (result.length >= 128) break;
  }
  return result.take(128).toSet();
}

Set<String> _textIdentityAliasKeys(String text) {
  final result = <String>{};
  for (final rawLine in text.split(RegExp(r'[\r\n]+')).take(32)) {
    final line = searchText(rawLine);
    if (line.isEmpty) continue;
    final tokens = line
        .split(' ')
        .where((value) => value.isNotEmpty)
        .take(16)
        .toList(growable: false);
    for (final token in tokens) {
      if (token.length >= 3 && token.length <= 28) result.add(token);
    }
    for (var width = 2; width <= min(3, tokens.length); width++) {
      for (var start = 0; start + width <= tokens.length; start++) {
        final phrase = tokens.sublist(start, start + width).join(' ');
        if (phrase.length >= 4 && phrase.length <= 40) result.add(phrase);
      }
    }
    if (line.length <= 40) result.add(line);
    if (result.length >= 128) break;
  }
  return result.take(128).toSet();
}

Set<String> _evidenceSaltAliasKeys(List<MedicineFrameEvidence> evidence) {
  final result = <String>{};
  for (final frame in evidence.take(12)) {
    result.addAll(_evidenceSaltAliasKeysFromText(frame.text));
    if (result.length >= 192) break;
  }
  return result.take(192).toSet();
}

Set<String> _evidenceSaltAliasKeysFromText(String text) {
  final result = <String>{};
  for (final rawLine in text.split(RegExp(r'[\r\n]+')).take(32)) {
    final line = searchText(rawLine);
    if (line.isEmpty) continue;
    final tokens = line
        .split(' ')
        .where((value) => value.isNotEmpty)
        .take(18)
        .toList(growable: false);
    for (var width = 1; width <= min(6, tokens.length); width++) {
      for (var start = 0; start + width <= tokens.length; start++) {
        final key = _saltAliasKey(tokens.sublist(start, start + width).join(' '));
        if (_validSaltAliasKey(key)) result.add(key);
        if (result.length >= 192) return result;
      }
    }
  }
  return result;
}

String _storedSaltAliasKey(String alias) {
  final key = _saltAliasKey(alias);
  return _validSaltAliasKey(key) ? '$_saltAliasPrefix$key' : '';
}

String _saltAliasKey(String value) => _ocrFoldIdentity(searchText(value))
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+'), '');

bool _validSaltAliasKey(String key) {
  if (key.length < 4 || key.length > 56) return false;
  final letters = RegExp(r'[a-z\u0900-\u097f]').allMatches(key).length;
  return letters >= 3;
}

List<String> _saltParts(String value) => value
    .split(RegExp(r'\s*(?:\+|;)\s*'))
    .map((part) => part.trim())
    .where((part) => part.isNotEmpty)
    .take(8)
    .toList(growable: false);

const _saltAliasNoise = <String>{
  'tablet',
  'tablets',
  'capsule',
  'capsules',
  'syrup',
  'suspension',
  'injection',
  'cream',
  'ointment',
  'drops',
  'composition',
  'contains',
  'ingredient',
  'generic',
  'medicine',
};

class _RecognitionFrameContext {
  const _RecognitionFrameContext({
    required this.identityKeys,
    required this.saltKeys,
    required this.barcodes,
  });

  final Set<String> identityKeys;
  final Set<String> saltKeys;
  final Set<String> barcodes;
}

List<_RecognitionFrameContext> _recognitionFrameContexts(
  List<MedicineFrameEvidence> evidence,
) => <_RecognitionFrameContext>[
  for (final frame in evidence.take(12))
    _RecognitionFrameContext(
      identityKeys: _textIdentityAliasKeys(frame.text),
      saltKeys: _evidenceSaltAliasKeysFromText(frame.text),
      barcodes: frame.allBarcodes
          .map(_recognitionBarcodeKey)
          .where((value) => value.length >= 6)
          .toSet(),
    ),
];

bool _saltCorrectionContextSupports(
  MedicineKnowledgeEntry entry,
  String aliasKey,
  List<_RecognitionFrameContext> contexts,
  List<String> learnedIdentityAliases,
) {
  final expectedBarcode = _recognitionBarcodeKey(entry.barcode);
  final learnedIdentityKeys = learnedIdentityAliases
      .map(searchText)
      .where((value) => value.length >= 3)
      .toSet();
  final identityTargets = <String>{
    searchText(entry.name),
    searchText(entry.brand),
  }.where((value) => value.length >= 3).toList(growable: false);

  for (final context in contexts) {
    if (!context.saltKeys.contains(aliasKey)) continue;
    if (expectedBarcode.length >= 6 &&
        context.barcodes.contains(expectedBarcode)) {
      return true;
    }
    if (learnedIdentityKeys.any(context.identityKeys.contains)) return true;
    for (final target in identityTargets) {
      for (final observed in context.identityKeys) {
        final ratio =
            min(observed.length, target.length) /
            max(observed.length, target.length);
        if (ratio < .68) continue;
        if (_identitySimilarity(observed, target) >= .86) return true;
      }
    }
  }
  return false;
}

String _recognitionBarcodeKey(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

bool _plausibleOcrCorrection(String observed, String confirmed) {
  final left = _ocrFoldIdentity(searchText(observed)).replaceAll(' ', '');
  final right = _ocrFoldIdentity(searchText(confirmed)).replaceAll(' ', '');
  if (left.length < 3 || right.length < 3) return false;
  if (left == right) return true;
  final ratio = min(left.length, right.length) / max(left.length, right.length);
  if (ratio < .42) return false;
  if (_editSimilarity(left, right) >= .62) return true;
  return ratio >= .45 && _characterDice(left, right) >= .62;
}

double _characterDice(String left, String right) {
  if (left.isEmpty || right.isEmpty) return 0;
  final counts = <int, int>{};
  for (final rune in left.runes) {
    counts.update(rune, (value) => value + 1, ifAbsent: () => 1);
  }
  var overlap = 0;
  for (final rune in right.runes) {
    final available = counts[rune] ?? 0;
    if (available <= 0) continue;
    overlap++;
    if (available == 1) {
      counts.remove(rune);
    } else {
      counts[rune] = available - 1;
    }
  }
  return (2 * overlap / (left.runes.length + right.runes.length))
      .clamp(0, 1)
      .toDouble();
}

double _identitySimilarity(String left, String right) {
  final raw = _editSimilarity(
    left.replaceAll(' ', ''),
    right.replaceAll(' ', ''),
  );
  final folded = _editSimilarity(
    _ocrFoldIdentity(left).replaceAll(' ', ''),
    _ocrFoldIdentity(right).replaceAll(' ', ''),
  );
  return max(raw, folded);
}

String _ocrFoldIdentity(String value) => value
    .toLowerCase()
    .replaceAll('0', 'o')
    .replaceAll('1', 'i')
    .replaceAll('5', 's')
    .replaceAll('8', 'b');

double _editSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  final previous = List<int>.generate(right.length + 1, (index) => index);
  final current = List<int>.filled(right.length + 1, 0);
  for (var i = 1; i <= left.length; i++) {
    current[0] = i;
    for (var j = 1; j <= right.length; j++) {
      final cost = left.codeUnitAt(i - 1) == right.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = min(
        min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    for (var j = 0; j <= right.length; j++) {
      previous[j] = current[j];
    }
  }
  final distance = previous[right.length];
  return (1 - distance / max(left.length, right.length)).clamp(0, 1).toDouble();
}
