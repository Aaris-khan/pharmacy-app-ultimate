import 'dart:math';

import 'medicine_understanding.dart';
import 'search.dart';

/// Enforces the physical-source cardinality contract before pharmacist review.
///
/// A camera/photo lane represents one physical pack even when OCR views disagree
/// enough for the temporal grouper to emit several draft hypotheses. Showing all
/// of those hypotheses as separate medicines is both confusing and unsafe. For a
/// single-pack source we choose the strongest coherent identity, preserve useful
/// lot facts from complementary sibling views, and deliberately cap confidence so
/// a segmentation disagreement can never become a silent auto-save.
///
/// Video/list lanes keep every medicine draft; their source semantics explicitly
/// allow multiple physical products.
List<MedicineScanDraft> normalizeMedicineReviewDrafts(
  Iterable<MedicineScanDraft> source, {
  required bool singlePackExpected,
}) {
  final drafts = source.toList(growable: false);
  if (!singlePackExpected || drafts.length <= 1) {
    return List<MedicineScanDraft>.unmodifiable(drafts);
  }

  final primaryIndex = _primaryDraftIndex(drafts);
  final primary = drafts[primaryIndex];
  final fields = Map<String, ExtractedMedicineField>.of(primary.fields);

  // Keep identity anchored to one coherent hypothesis. Sibling OCR views may
  // flag disagreement, but must never donate a different product identity and
  // create a synthetic hybrid medicine.
  for (final key in const <String>[
    'name',
    'brand',
    'salt',
    'strength',
    'form',
    'manufacturer',
  ]) {
    final current = fields[key];
    if (current == null || current.isEmpty) continue;
    if (_hasStrongDisagreement(key, drafts)) {
      fields[key] = ExtractedMedicineField(
        value: current.value,
        confidence: min(current.confidence, .74).toDouble(),
        support: current.support,
        conflicted: true,
      );
    }
  }

  // Lot facts can legitimately live on a different face of the same pack. Merge
  // them across sibling views, but make any contradictory observation explicit.
  for (final key in const <String>['mfg', 'expiry', 'batchNumber', 'barcode']) {
    final merged = _mergeObservedField(key, drafts);
    if (merged != null) fields[key] = merged;
  }

  final rawText = _boundedJoined(
    drafts.map((draft) => draft.rawText),
    maxCharacters: 30000,
  );
  final keywords = _boundedJoined(
    drafts.map((draft) => draft.searchKeywords),
    separator: ' ',
    maxCharacters: 8000,
  );
  final sequences = drafts
      .expand((draft) => draft.frameSequences)
      .toSet()
      .toList(growable: false)
    ..sort();

  final ordered = List<int>.generate(drafts.length, (index) => index)
    ..sort((a, b) {
      final score = _draftScore(drafts[b]).compareTo(_draftScore(drafts[a]));
      return score != 0 ? score : a.compareTo(b);
    });

  String firstPrinted(String Function(MedicineScanDraft draft) read) {
    for (final index in ordered) {
      final value = read(drafts[index]).trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  final collapsed = MedicineScanDraft(
    fields: fields,
    rawText: rawText,
    searchKeywords: keywords,
    frameSequences: sequences,
    expiryMonthOnly: primary.expiryMonthOnly,
    mfgMonthOnly: primary.mfgMonthOnly,
    printedPackSize: firstPrinted((draft) => draft.printedPackSize),
    printedMrp: firstPrinted((draft) => draft.printedMrp),
    // Multiple draft hypotheses from a source that promised one physical pack
    // are themselves uncertainty evidence. Keep the preview useful but force a
    // human confirmation boundary instead of allowing quick/automatic save.
    overallConfidence: min(primary.overallConfidence, .74).toDouble(),
  );

  return List<MedicineScanDraft>.unmodifiable(<MedicineScanDraft>[collapsed]);
}

int _primaryDraftIndex(List<MedicineScanDraft> drafts) {
  var best = 0;
  var bestScore = double.negativeInfinity;
  for (var index = 0; index < drafts.length; index++) {
    final score = _draftScore(drafts[index]);
    if (score > bestScore) {
      best = index;
      bestScore = score;
    }
  }
  return best;
}

double _draftScore(MedicineScanDraft draft) {
  var score = draft.overallConfidence.clamp(0, 1) * 5.0;
  const weights = <String, double>{
    'name': 2.5,
    'brand': 1.8,
    'salt': 1.8,
    'strength': 1.25,
    'form': .9,
    'manufacturer': .45,
    'barcode': 2.1,
    'batchNumber': .35,
    'mfg': .35,
    'expiry': .55,
  };

  for (final entry in weights.entries) {
    final field = draft.field(entry.key);
    if (field.isEmpty) continue;
    final confidence = field.confidence.clamp(0, 1).toDouble();
    final support = min(max(field.support, 0), 4);
    score += entry.value * (.52 + confidence * .48);
    score += entry.value * support * .045;
    if (field.conflicted) score -= entry.value * .9;
  }

  final name = searchText(draft.name);
  if (_looksLikePackagingInstruction(name)) score -= 4.0;
  if (draft.name.trim().length < 3) score -= .8;
  if (draft.salt.trim().isNotEmpty && draft.strength.trim().isNotEmpty) {
    score += .55;
  }
  if (draft.brand.trim().isNotEmpty && draft.form.trim().isNotEmpty) {
    score += .35;
  }
  score += min(draft.frameSequences.toSet().length, 6) * .04;
  return score;
}

bool _looksLikePackagingInstruction(String value) {
  if (value.isEmpty) return false;
  const phrases = <String>[
    'shake well',
    'before use',
    'for therapeutic use',
    'not for sale',
    'government supply',
    'batch no',
    'mfg date',
    'manufacturing date',
    'expiry date',
    'exp date',
    'keep out of reach',
    'store below',
  ];
  return phrases.any(value.contains);
}

bool _hasStrongDisagreement(String key, List<MedicineScanDraft> drafts) {
  final values = <String>{};
  for (final draft in drafts) {
    final field = draft.field(key);
    if (field.isEmpty || field.confidence < .68) continue;
    final normalized = _fieldKey(key, field.value);
    if (normalized.isNotEmpty) values.add(normalized);
    if (values.length > 1) return true;
  }
  return false;
}

ExtractedMedicineField? _mergeObservedField(
  String key,
  List<MedicineScanDraft> drafts,
) {
  final buckets = <String, _ObservedFieldBucket>{};
  for (final draft in drafts) {
    final field = draft.field(key);
    if (field.isEmpty) continue;
    final normalized = _fieldKey(key, field.value);
    if (normalized.isEmpty) continue;
    final bucket = buckets.putIfAbsent(
      normalized,
      () => _ObservedFieldBucket(field.value),
    );
    bucket.add(field);
  }
  if (buckets.isEmpty) return null;

  final ranked = buckets.values.toList(growable: false)
    ..sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      return a.value.compareTo(b.value);
    });
  final winner = ranked.first;
  final contradiction =
      ranked.length > 1 || winner.anyConflict || winner.distinctRawValues > 1;
  final confidence = contradiction
      ? min(winner.bestConfidence, .74).toDouble()
      : winner.bestConfidence;

  return ExtractedMedicineField(
    value: winner.value,
    confidence: confidence,
    support: min(winner.support, 999),
    conflicted: contradiction,
  );
}

String _fieldKey(String key, String value) {
  final normalized = searchText(value);
  if (key == 'barcode' || key == 'batchNumber') {
    return normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }
  return normalized;
}

String _boundedJoined(
  Iterable<String> source, {
  String separator = '\n',
  required int maxCharacters,
}) {
  final result = StringBuffer();
  final seen = <String>{};
  for (final raw in source) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    final key = searchText(value);
    if (key.isEmpty || !seen.add(key)) continue;
    final prefix = result.isEmpty ? '' : separator;
    if (result.length + prefix.length >= maxCharacters) break;
    final remaining = maxCharacters - result.length - prefix.length;
    result
      ..write(prefix)
      ..write(value.length <= remaining ? value : value.substring(0, remaining));
    if (result.length >= maxCharacters) break;
  }
  return result.toString();
}

class _ObservedFieldBucket {
  _ObservedFieldBucket(this.value);

  final String value;
  double score = 0;
  double bestConfidence = 0;
  int support = 0;
  bool anyConflict = false;
  final Set<String> _rawValues = <String>{};

  int get distinctRawValues => _rawValues.length;

  void add(ExtractedMedicineField field) {
    final confidence = field.confidence.clamp(0, 1).toDouble();
    final boundedSupport = min(max(field.support, 1), 5);
    score += confidence * (1 + boundedSupport * .12) *
        (field.conflicted ? .55 : 1.0);
    bestConfidence = max(bestConfidence, confidence);
    support += max(field.support, 1);
    anyConflict = anyConflict || field.conflicted;
    _rawValues.add(field.value.trim().toLowerCase());
  }
}
