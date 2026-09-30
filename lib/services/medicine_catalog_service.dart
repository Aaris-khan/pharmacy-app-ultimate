import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../domain/medicine.dart';
import '../domain/medicine_discovery.dart';
import '../domain/medicine_resolution_v2.dart';
import '../domain/medicine_strength.dart';
import '../domain/medicine_understanding.dart';
import '../domain/search.dart';
import 'canonical_medicine_catalog_service.dart';
import 'catalog_release_sync_service.dart';

abstract interface class MedicineCatalogProvider {
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  });
}

/// Public-catalog discovery used only after the local pharmacy database cannot
/// confidently identify a scan.
///
/// The service intentionally returns identity metadata only. Expiry, MFG,
/// quantity, price and pharmacy location are never sourced from the internet.
class MedicineCatalogService {
  MedicineCatalogService({
    http.Client? client,
    List<MedicineCatalogProvider>? providers,
    bool? releaseFirst,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _releaseFirst = releaseFirst ?? providers == null,
       _providers = providers == null
           ? <MedicineCatalogProvider>[]
           : List<MedicineCatalogProvider>.of(providers) {
    if (_providers.isEmpty) {
      _providers.addAll([
        ReleaseCatalogProvider(),
        OpenFdaNdcProvider(_client),
        RxNormProvider(_client),
      ]);
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final bool _releaseFirst;
  final List<MedicineCatalogProvider> _providers;
  final Map<String, _CatalogCacheEntry> _cache = <String, _CatalogCacheEntry>{};
  final Map<String, Future<List<MedicineCatalogCandidate>>> _inflight =
      <String, Future<List<MedicineCatalogCandidate>>>{};

  Future<List<MedicineCatalogCandidate>> search({
    String barcode = '',
    String text = '',
    int limit = 12,
  }) async {
    final cleanBarcode = barcode.trim();
    final cleanText = _catalogQuery(text);
    if (cleanBarcode.isEmpty && cleanText.isEmpty) return const [];
    final boundedLimit = min(limit, 12);
    final key = '$cleanBarcode|$cleanText|$boundedLimit';
    final now = DateTime.now();
    final cached = _cache[key];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.values;
    }
    final running = _inflight[key];
    if (running != null) return running;

    final future = _searchProviders(
      barcode: cleanBarcode,
      text: cleanText,
      limit: boundedLimit,
    ).then((values) {
      _cache[key] = _CatalogCacheEntry(
        values,
        now.add(Duration(minutes: values.isEmpty ? 5 : 360)),
      );
      while (_cache.length > 64) {
        _cache.remove(_cache.keys.first);
      }
      return values;
    }).whenComplete(() {
      // Do not use `() => _inflight.remove(key)` here. Map.remove returns the
      // removed Future; whenComplete would then await that Future. Because the
      // removed value is this same in-flight completion Future, that creates a
      // self-referential completion cycle and the catalog lookup never settles.
      _inflight.remove(key);
    });
    _inflight[key] = future;
    return future;
  }

  /// Scan-aware public lookup. OCR is first reduced by the same deterministic
  /// V2 semantic pipeline used by intake, then providers receive a compact
  /// identity query instead of an arbitrary slice of packaging text. Results
  /// are re-ranked against observed brand/salt/strength/form evidence; hard
  /// contradictions are demoted but never silently rewritten.
  Future<List<MedicineCatalogCandidate>> searchScan({
    String barcode = '',
    String text = '',
    List<MedicineFrameEvidence> evidence = const <MedicineFrameEvidence>[],
    int limit = 12,
  }) async {
    MedicineScanDraft? draft;
    if (evidence.isNotEmpty) {
      try {
        final understood = MedicineUnderstandingResult.fromMessage(
          understandMedicineEvidenceV2Message(<String, Object?>{
            'evidence': evidence
                .take(maxMedicineEvidenceFrames)
                .map((value) => value.toMessage())
                .toList(growable: false),
            'knowledge': const <Object?>[],
            'catalog': const <Object?>[],
          }),
        );
        if (understood.drafts.length == 1) draft = understood.drafts.single;
      } catch (_) {
        // Public discovery is fail-open. Raw OCR remains a valid fallback query
        // even if a future semantic rule cannot interpret this scan.
      }
    }

    final smartText = draft == null ? text : _catalogScanQuery(draft, text);
    var candidates = await search(
      barcode: barcode,
      text: smartText,
      limit: limit,
    );

    if (candidates.isEmpty &&
        searchText(smartText) != searchText(text) &&
        text.trim().isNotEmpty) {
      candidates = await search(barcode: barcode, text: text, limit: limit);
    }
    if (draft == null || candidates.isEmpty) return candidates;
    return _rerankCatalogCandidatesForScan(candidates, draft, barcode);
  }

  Future<List<MedicineCatalogCandidate>> _searchProviders({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    if (_releaseFirst && _providers.isNotEmpty) {
      // The GitHub Release mirror is already local after a verified sync. Give
      // it first refusal so a strong match avoids sending OCR/query text to
      // third-party APIs. Weak/empty mirror results still fail open to the
      // existing public providers for coverage.
      final release = await _searchProvider(
        _providers.first,
        barcode: barcode,
        text: text,
        limit: limit,
      );
      if (release.any((candidate) => candidate.score >= .90)) {
        return _rankCandidates(<List<MedicineCatalogCandidate>>[
          release,
        ], limit);
      }

      final fallback = await Future.wait(
        _providers.skip(1).map(
          (provider) => _searchProvider(
            provider,
            barcode: barcode,
            text: text,
            limit: limit,
          ),
        ),
      );
      return _rankCandidates(
        <List<MedicineCatalogCandidate>>[release, ...fallback],
        limit,
      );
    }

    final groups = await Future.wait(
      _providers.map(
        (provider) => _searchProvider(
          provider,
          barcode: barcode,
          text: text,
          limit: limit,
        ),
      ),
    );
    return _rankCandidates(groups, limit);
  }

  Future<List<MedicineCatalogCandidate>> _searchProvider(
    MedicineCatalogProvider provider, {
    required String barcode,
    required String text,
    required int limit,
  }) async {
    try {
      return await provider
          .search(
            barcode: barcode,
            text: text,
            limit: limit,
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // One catalogue being unavailable must not block another provider or the
      // local-first pharmacy workflow.
      return <MedicineCatalogCandidate>[];
    }
  }

  List<MedicineCatalogCandidate> _rankCandidates(
    Iterable<List<MedicineCatalogCandidate>> groups,
    int limit,
  ) {
    final best = <String, MedicineCatalogCandidate>{};
    for (final candidate in groups.expand((items) => items)) {
      if (candidate.seed.name.trim().isEmpty) continue;
      final key = candidate.seed.identityKey;
      final previous = best[key];
      if (previous == null || candidate.score > previous.score) {
        best[key] = candidate;
      }
    }

    final results = best.values.toList()
      ..sort((a, b) {
        final score = b.score.compareTo(a.score);
        if (score != 0) return score;
        return searchText(a.seed.name).compareTo(searchText(b.seed.name));
      });
    return results.take(limit).toList(growable: false);
  }

  void close() {
    _cache.clear();
    _inflight.clear();
    if (_ownsClient) _client.close();
  }
}

class _CatalogCacheEntry {
  const _CatalogCacheEntry(this.values, this.expiresAt);

  final List<MedicineCatalogCandidate> values;
  final DateTime expiresAt;
}

/// Release-backed local catalogue used only from explicit Online Search.
class ReleaseCatalogProvider implements MedicineCatalogProvider {
  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    try {
      await CatalogReleaseSyncService.instance
          .syncIfNeeded()
          .timeout(const Duration(milliseconds: 1800));
    } catch (_) {
      // Search remains available through the already-verified local revision
      // and other public providers when GitHub is slow or unavailable.
    }

    final products = await CanonicalMedicineCatalogService.instance
        .candidatesForEvidence(
          <MedicineFrameEvidence>[
            MedicineFrameEvidence(
              barcode: barcode,
              text: text,
              source: 'Online catalogue lookup',
            ),
          ],
          limit: min(max(limit * 3, 24), 48),
        );
    final query = _catalogQuery(text);
    return products
        .map((product) {
          final exactBarcode =
              barcode.trim().isNotEmpty &&
              product.barcodes.any(
                (value) =>
                    _catalogBarcodeKey(value) == _catalogBarcodeKey(barcode),
              );
          final seed = MedicineDraftSeed(
            name: product.displayName,
            brand: product.brand,
            manufacturer: product.manufacturer,
            salt: product.salt,
            strength: product.strength,
            form: product.form,
            barcode: exactBarcode ? barcode.trim() : '',
            source: product.source,
            sourceId: product.productId,
          );
          return MedicineCatalogCandidate(
            seed: seed,
            score: exactBarcode
                ? 1.0
                : _candidateScore(seed, query, providerFloor: .70),
            provider: 'Aaris catalogue',
            reason: exactBarcode
                ? 'Exact verified catalogue barcode'
                : 'Versioned release catalogue',
          );
        })
        .where((candidate) => candidate.seed.name.trim().isNotEmpty)
        .take(limit)
        .toList(growable: false);
  }
}

String _catalogBarcodeKey(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (const <int>{8, 12, 13, 14}.contains(digits.length)) {
    return digits.padLeft(14, '0');
  }
  return value.trim().toLowerCase();
}

class OpenFdaNdcProvider implements MedicineCatalogProvider {
  OpenFdaNdcProvider(this.client);

  final http.Client client;

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    if (barcode.isNotEmpty) {
      final exact = await _query(
        'openfda.upc:"${_queryLiteral(barcode)}"',
        limit,
        queryText: text,
        barcode: barcode,
        barcodeExact: true,
      );
      if (exact.isNotEmpty) return exact;
    }

    final terms = _searchTerms(text);
    if (terms.isEmpty) return const [];
    for (final term in terms.take(3)) {
      final expression = [
        'brand_name:$term*',
        'generic_name:$term*',
        'active_ingredients.name:$term*',
      ].join(' ');
      final found = await _query(
        expression,
        limit,
        queryText: text,
        barcode: barcode,
      );
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  Future<List<MedicineCatalogCandidate>> _query(
    String search,
    int limit, {
    required String queryText,
    required String barcode,
    bool barcodeExact = false,
  }) async {
    final uri = Uri.https('api.fda.gov', '/drug/ndc.json', {
      'search': search,
      'limit': '${min(limit, 12)}',
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw StateError('openFDA returned ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const [];
    final raw = decoded['results'];
    if (raw is! List) return const [];
    return parseResults(
      raw,
      queryText: queryText,
      barcode: barcode,
      barcodeExact: barcodeExact,
    );
  }

  static List<MedicineCatalogCandidate> parseResults(
    List<dynamic> rows, {
    required String queryText,
    required String barcode,
    bool barcodeExact = false,
  }) {
    final results = <MedicineCatalogCandidate>[];
    for (final value in rows) {
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      String string(String key) =>
          (row[key] is String ? row[key] as String : '').trim();

      final brand = string('brand_name');
      final generic = string('generic_name');
      final manufacturer = string('labeler_name');
      final form = normalizeForm(string('dosage_form'));
      final productNdc = string('product_ndc');
      final activeComponents = <(String, String)>[];
      final active = row['active_ingredients'];
      if (active is List) {
        for (final item in active) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final name = map['name'];
          if (name is! String || name.trim().isEmpty) continue;
          final rawStrength = map['strength'];
          final strength = rawStrength is String
              ? _normalizeCatalogStrength(rawStrength)
              : '';
          activeComponents.add((name.trim(), strength));
        }
      }

      final ingredients = activeComponents
          .map((component) => component.$1)
          .toList(growable: false);
      final salt = ingredients.isNotEmpty ? ingredients.join(' + ') : generic;
      final strength =
          activeComponents.isNotEmpty &&
              activeComponents.every((component) => component.$2.isNotEmpty)
          ? activeComponents.map((component) => component.$2).join(' + ')
          : '';
      final name = brand.isNotEmpty ? brand : (generic.isNotEmpty ? generic : salt);
      if (name.isEmpty) continue;
      final seed = MedicineDraftSeed(
        name: name,
        brand: brand,
        manufacturer: manufacturer,
        salt: salt,
        strength: strength,
        form: form,
        barcode: barcodeExact ? barcode : '',
        source: 'openFDA NDC',
        sourceId: productNdc,
      );
      final score = barcodeExact
          ? 1.0
          : _candidateScore(seed, queryText, providerFloor: .64);
      results.add(
        MedicineCatalogCandidate(
          seed: seed,
          score: score,
          provider: 'openFDA',
          reason: barcodeExact
              ? 'Exact catalog barcode'
              : 'Public product catalog',
        ),
      );
    }
    return results;
  }
}

class RxNormProvider implements MedicineCatalogProvider {
  RxNormProvider(this.client);

  final http.Client client;

  @override
  Future<List<MedicineCatalogCandidate>> search({
    required String barcode,
    required String text,
    required int limit,
  }) async {
    if (text.trim().isEmpty) return const [];
    final uri = Uri.https('rxnav.nlm.nih.gov', '/REST/approximateTerm.json', {
      'term': text,
      'maxEntries': '${min(limit, 10)}',
      'option': '1',
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      throw StateError('RxNorm returned ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const [];
    final group = decoded['approximateGroup'];
    if (group is! Map) return const [];
    final raw = group['candidate'];
    if (raw is! List) return const [];
    return parseResults(raw, queryText: text);
  }

  static List<MedicineCatalogCandidate> parseResults(
    List<dynamic> rows, {
    required String queryText,
  }) {
    final results = <MedicineCatalogCandidate>[];
    for (final value in rows) {
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      final rawName = row['name'];
      if (rawName is! String || rawName.trim().isEmpty) continue;
      final parsed = _rxSeed(rawName.trim(), '${row['rxcui'] ?? ''}');
      final rank = int.tryParse('${row['rank'] ?? ''}') ?? 99;
      final lexical = double.tryParse('${row['score'] ?? ''}') ?? 0;
      final normalizedLexical = lexical <= 0 ? 0.0 : lexical / (lexical + 8);
      final localScore = _candidateScore(parsed, queryText, providerFloor: .60);
      final score =
          (localScore + normalizedLexical * .08 - min(rank - 1, 5) * .015)
              .clamp(.55, .95)
              .toDouble();
      results.add(
        MedicineCatalogCandidate(
          seed: parsed,
          score: score,
          provider: 'RxNorm',
          reason: 'Normalized medicine concept',
        ),
      );
    }
    return results;
  }
}

MedicineDraftSeed _rxSeed(String raw, String rxcui) {
  final brandMatch = RegExp(r'\\[([^\\]]+)\\]').firstMatch(raw);
  final brand = brandMatch?.group(1)?.trim() ?? '';
  final withoutBrand = raw
      .replaceAll(RegExp(r'\\s*\\[[^\\]]+\\]\\s*'), ' ')
      .replaceAll(RegExp(r'\\s+'), ' ')
      .trim();
  final form = _catalogFormFromText(withoutBrand);
  final strengthPattern = RegExp(
    // Keep denominator quantities with their units. Ingredient separators in
    // normalized RxNorm names use a slash surrounded by spaces, while dose
    // concentrations such as 250 MG/5 ML do not.
    r'\\b\\d+(?:\\.\\d+)?\\s*(?:mcg|ug|mg|g|gm|ml|l|meq|mmol|mol|unt|unit|units|iu|%)'
    r'(?:\\s*/\\s*(?:(?:\\d+(?:\\.\\d+)?\\s*)?(?:mcg|ug|mg|g|gm|ml|l|dose|actuation|actuat|tablet|capsule|packet|patch|hour|hr|unt|unit|units|iu)))?\\b',
    caseSensitive: false,
  );

  final parts = withoutBrand
      .split(RegExp(r'\\s+/\\s+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .take(6)
      .toList(growable: false);
  final components = <(String, String)>[];
  var complete = parts.isNotEmpty;
  for (final part in parts) {
    final match = strengthPattern.firstMatch(part);
    if (match == null) {
      complete = false;
      continue;
    }
    final ingredient = part.substring(0, match.start).trim();
    final dose = match.group(0)?.replaceAll(RegExp(r'\\s+'), ' ').trim() ?? '';
    if (ingredient.isEmpty || dose.isEmpty) {
      complete = false;
      continue;
    }
    components.add((ingredient, dose));
  }

  String generic;
  String strength;
  if (components.isNotEmpty) {
    generic = components.map((value) => value.$1).join(' + ');
    // Never pair the wrong dose with a combination ingredient. If one
    // slash-delimited component cannot be parsed, keep the ingredients that
    // were observed but abstain from a combined canonical strength.
    strength = complete && components.length == parts.length
        ? components.map((value) => value.$2).join(' + ')
        : '';
  } else {
    generic = withoutBrand
        .replaceAll(medicineFormPresentationPattern, ' ')
        .replaceAll(
          RegExp(
            r'\\b(?:oral|topical|ophthalmic|otic|nasal|inhalation|rectal|vaginal|sublingual|buccal|transdermal|extended\\s+release|delayed\\s+release)\\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\\s+'), ' ')
        .trim();
    strength = '';
  }

  if (generic.isEmpty) generic = withoutBrand;
  final name = brand.isNotEmpty ? brand : generic;
  return MedicineDraftSeed(
    name: name,
    brand: brand,
    salt: generic,
    strength: strength,
    form: form,
    source: 'RxNorm',
    sourceId: rxcui,
  );
}

String _normalizeCatalogStrength(String raw) {
  var value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  value = value.replaceFirst(RegExp(r'\s*/\s*1\s*$'), '');
  return value.trim();
}

String _catalogFormFromText(String raw) {
  final normalized = normalize(raw);
  if (normalized.isEmpty) return '';
  final aliases = medicineFormAliases.entries
      .where((entry) => entry.key != 'other')
      .toList(growable: false)
    ..sort((left, right) => right.key.length.compareTo(left.key.length));
  for (final entry in aliases) {
    final pattern =
        '(?:^|[^a-z])' + RegExp.escape(entry.key) + r'(?:$|[^a-z])';
    if (RegExp(pattern, caseSensitive: false).hasMatch(normalized)) {
      return entry.value;
    }
  }
  return '';
}

String _catalogScanQuery(MedicineScanDraft draft, String fallback) {
  final parts = <String>[];
  final seen = <String>{};
  void add(String value) {
    final clean = value.trim();
    final key = searchText(clean);
    if (key.isEmpty || !seen.add(key)) return;
    parts.add(clean);
  }
  add(draft.brand);
  add(draft.name);
  add(draft.salt);
  add(draft.strength);
  add(draft.form);
  // The semantic draft can intentionally abstain from a weak standalone form
  // line. A literal known form printed anywhere in the same scan is still safe
  // identity evidence for public-catalog retrieval, so preserve that signal.
  add(_catalogFormFromText(fallback));
  if (parts.isEmpty) return fallback;
  final joined = parts.join(' ');
  return joined.length <= 420 ? joined : joined.substring(0, 420);
}

double _catalogTextSimilarity(String left, String right) {
  final a = searchText(left);
  final b = searchText(right);
  if (a.isEmpty || b.isEmpty) return 0;
  return max(
    orderedSimilarity(a, b),
    orderedSimilarity(a.replaceAll(' ', ''), b.replaceAll(' ', '')),
  ).clamp(0, 1).toDouble();
}

double _catalogSaltSimilarity(String left, String right) {
  List<String> components(String value) => value
      .split(RegExp(r'\s*(?:\+|;|\band\b|\bwith\b)\s*', caseSensitive: false))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .take(6)
      .toList(growable: false);
  final a = components(left), b = components(right);
  if (a.isEmpty || b.isEmpty) return _catalogTextSimilarity(left, right);
  if (a.length == 1 && b.length == 1) return _catalogTextSimilarity(a.single, b.single);

  double directed(List<String> source, List<String> target) {
    var sum = 0.0;
    for (final item in source) {
      var best = 0.0;
      for (final candidate in target) {
        best = max(best, _catalogTextSimilarity(item, candidate));
      }
      sum += best;
    }
    return sum / source.length;
  }
  return ((directed(a, b) + directed(b, a)) / 2).clamp(0, 1).toDouble();
}

double _catalogStrengthSimilarity(String left, String right) {
  final a = medicineStrengthKey(_normalizeCatalogStrength(left));
  final b = medicineStrengthKey(_normalizeCatalogStrength(right));
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  return _catalogTextSimilarity(a, b);
}

List<MedicineCatalogCandidate> _rerankCatalogCandidatesForScan(
  List<MedicineCatalogCandidate> candidates,
  MedicineScanDraft draft,
  String scanBarcode,
) {
  final ranked = <MedicineCatalogCandidate>[];
  final scanBarcodeKey = _catalogBarcodeKey(scanBarcode);

  for (final candidate in candidates) {
    final seed = candidate.seed;
    var mass = 0.0;
    var agreement = 0.0;
    final agreed = <String>[];
    final conflicts = <String>[];

    void observe({
      required String label,
      required ExtractedMedicineField observed,
      required String canonical,
      required double weight,
      required double Function(String, String) similarity,
      double conflictFloor = .56,
      double conflictConfidence = .80,
    }) {
      if (observed.isEmpty || canonical.trim().isEmpty) return;
      final score = similarity(observed.value, canonical);
      mass += weight;
      agreement += score * weight;
      if (score >= .86) agreed.add(label);
      if (!observed.conflicted &&
          observed.confidence >= conflictConfidence &&
          score < conflictFloor) {
        conflicts.add(label);
      }
    }

    final observedIdentity =
        draft.field('brand').isEmpty ? draft.field('name') : draft.field('brand');
    final canonicalIdentity =
        seed.brand.trim().isNotEmpty ? seed.brand : seed.name;
    observe(
      label: 'brand',
      observed: observedIdentity,
      canonical: canonicalIdentity,
      weight: .32,
      similarity: _catalogTextSimilarity,
    );
    observe(
      label: 'salt',
      observed: draft.field('salt'),
      canonical: seed.salt,
      weight: .28,
      similarity: _catalogSaltSimilarity,
      conflictFloor: .54,
    );
    observe(
      label: 'strength',
      observed: draft.field('strength'),
      canonical: seed.strength,
      weight: .26,
      similarity: _catalogStrengthSimilarity,
      conflictFloor: .74,
      conflictConfidence: .72,
    );

    final observedForm = draft.field('form');
    final canonicalForm = normalizeForm(seed.form);
    if (!observedForm.isEmpty && canonicalForm.isNotEmpty && canonicalForm != 'Other') {
      final observedCanonical = normalizeForm(observedForm.value);
      final formScore =
          observedCanonical.isNotEmpty && observedCanonical == canonicalForm ? 1.0 : 0.0;
      mass += .14;
      agreement += formScore * .14;
      if (formScore == 1) agreed.add('form');
      if (!observedForm.conflicted && observedForm.confidence >= .78 && formScore == 0) {
        conflicts.add('form');
      }
    }

    final candidateBarcodeKey = _catalogBarcodeKey(seed.barcode);
    final exactBarcode =
        scanBarcodeKey.isNotEmpty &&
        candidateBarcodeKey.isNotEmpty &&
        scanBarcodeKey == candidateBarcodeKey;

    var score = candidate.score;
    if (mass > 0) {
      final structuredAgreement = (agreement / mass).clamp(0, 1).toDouble();
      score = candidate.score * .64 + structuredAgreement * .36;
      if (agreed.length >= 2) score += min(.045, agreed.length * .012);
      if (conflicts.isNotEmpty) score -= min(.42, conflicts.length * .21);
    }
    if (exactBarcode) score = 1.0;
    score = score.clamp(.40, 1.0).toDouble();

    final reason = exactBarcode
        ? 'Exact catalogue barcode'
        : conflicts.isNotEmpty
        ? 'Check scan conflict: ${conflicts.join(', ')}'
        : agreed.isNotEmpty
        ? 'Scan agrees: ${agreed.toSet().join(', ')}'
        : candidate.reason;

    ranked.add(MedicineCatalogCandidate(
      seed: candidate.seed,
      score: score,
      provider: candidate.provider,
      reason: reason,
    ));
  }

  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0
        ? byScore
        : searchText(a.seed.name).compareTo(searchText(b.seed.name));
  });
  return ranked;
}

double _candidateScore(
  MedicineDraftSeed seed,
  String queryText, {
  required double providerFloor,
}) {
  final query = searchText(queryText);
  if (query.isEmpty) return providerFloor;
  final document = searchText([
    seed.name,
    seed.brand,
    seed.salt,
    seed.strength,
    seed.form,
    seed.manufacturer,
  ].join(' '));
  final queryTokens = query
      .split(' ')
      .where((token) => token.length >= 2)
      .toList();
  final docTokens = document
      .split(' ')
      .where((token) => token.isNotEmpty)
      .toList();
  if (queryTokens.isEmpty || docTokens.isEmpty) return providerFloor;

  var exact = 0;
  var best = 0.0;
  for (final token in queryTokens.take(12)) {
    if (docTokens.contains(token)) exact++;
    for (final candidate in docTokens.take(28)) {
      best = max(best, orderedSimilarity(token, candidate));
    }
  }
  final exactFraction = exact / queryTokens.length;
  return (providerFloor + exactFraction * .20 + best * .13)
      .clamp(providerFloor, .97)
      .toDouble();
}

String _catalogQuery(String raw) {
  if (raw.trim().isEmpty) return '';
  // Stock-specific date lines must never influence public identity lookup.
  // Remove common labelled EXP/MFG fragments before general normalization, and
  // then discard standalone date-shaped tokens as a second line of defence.
  var withoutStockDates = raw.replaceAll(
    RegExp(
      r'\b(?:exp(?:iry|ires)?|use\s*by|use\s*before|mfg|mfd|manufactured)\b\s*[:.-]?\s*\d{1,4}(?:[./-]\d{1,4}){1,2}',
      caseSensitive: false,
    ),
    ' ',
  );
  withoutStockDates = withoutStockDates.replaceAll(
    RegExp(r'\b\d{1,2}[./-]\d{1,2}(?:[./-]\d{2,4})?\b'),
    ' ',
  );
  final value = _repairCatalogFragments(searchText(withoutStockDates));
  if (value.isEmpty) return '';
  const noise = {
    'exp',
    'expiry',
    'expires',
    'mfg',
    'mfd',
    'manufactured',
    'batch',
    'batchno',
    'lot',
    'mrp',
    'price',
    'rs',
    'inr',
    'use',
    'before',
    'after',
    'schedule',
    'store',
    'storage',
    'keep',
    'away',
    'children',
    'tablets',
    'tablet',
    'capsules',
    'capsule',
  };
  final tokens = value
      .split(' ')
      .where((token) => token.isNotEmpty)
      .where((token) => !noise.contains(token))
      .take(14)
      .toList();
  return tokens.join(' ');
}

String _repairCatalogFragments(String value) {
  final parts = value
      .split(' ')
      .where((part) => part.isNotEmpty)
      .take(80)
      .toList(growable: false);
  final output = <String>[];
  var index = 0;
  while (index < parts.length) {
    if (parts[index].length == 1 &&
        RegExp(r'^[a-z]$').hasMatch(parts[index])) {
      final joined = StringBuffer();
      var end = index;
      while (end < parts.length &&
          parts[end].length == 1 &&
          RegExp(r'^[a-z]$').hasMatch(parts[end]) &&
          joined.length < 20) {
        joined.write(parts[end]);
        end++;
      }
      if (joined.length >= 3) {
        output.add(joined.toString());
        index = end;
        continue;
      }
    }

    if (parts[index].length == 1 &&
        RegExp(r'^\d$').hasMatch(parts[index])) {
      final joined = StringBuffer();
      var end = index;
      while (end < parts.length &&
          parts[end].length == 1 &&
          RegExp(r'^\d$').hasMatch(parts[end]) &&
          joined.length < 5) {
        joined.write(parts[end]);
        end++;
      }
      if (end < parts.length) {
        final plainUnit = RegExp(
          r'^(?:mcg|ug|mg|gm|g|ml|meq|iu|units?)$',
        ).firstMatch(parts[end]);
        if (joined.length >= 2 && plainUnit != null) {
          output.add(joined.toString());
          output.add(parts[end]);
          index = end + 1;
          continue;
        }

        // searchText may already compact the final digit with its unit:
        // "6 5 0 mg" -> "6 5 0mg". Join only this tightly-bounded shape.
        final digitUnit = RegExp(
          r'^(\d)(mcg|ug|mg|gm|g|ml|meq|iu|units?)$',
        ).firstMatch(parts[end]);
        if (joined.isNotEmpty &&
            digitUnit != null &&
            joined.length < 5) {
          output.add('${joined.toString()}${digitUnit.group(1)!}');
          output.add(digitUnit.group(2)!);
          index = end + 1;
          continue;
        }
      }
    }

    final gluedDose = RegExp(
      r'^([a-z]{4,})(\d+(?:[.]\d+)?)(mcg|ug|mg|gm|g|ml|meq|iu|units?)$',
    ).firstMatch(parts[index]);
    if (gluedDose != null) {
      output.add(gluedDose.group(1)!);
      output.add(gluedDose.group(2)!);
      output.add(gluedDose.group(3)!);
      index++;
      continue;
    }

    output.add(parts[index]);
    index++;
  }
  return output.join(' ');
}

List<String> _searchTerms(String value) {
  final tokens = searchText(value)
      .split(' ')
      .where((token) => RegExp(r'^[a-z][a-z0-9]{2,}$').hasMatch(token))
      .where(
        (token) =>
            !const {
              'tablet',
              'tablets',
              'capsule',
              'capsules',
              'syrup',
              'injection',
              'cream',
              'ointment',
              'medicine',
              'mg',
              'ml',
              'manufactured',
              'manufacturer',
            }.contains(token),
      )
      .toList();
  tokens.sort((a, b) => b.length.compareTo(a.length));
  return tokens;
}

String _queryLiteral(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
