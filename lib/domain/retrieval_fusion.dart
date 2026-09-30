/// Pure, bounded ranking primitives for the always-available offline engine.
///
/// These helpers deliberately operate on IDs and corpus document frequencies
/// only. They do not know about inventory, medicine safety, UI state, cloud AI,
/// or local LLMs. Product safety and canonicalization remain the responsibility
/// of the downstream medicine resolver.
class RankedRetrievalChannel {
  const RankedRetrievalChannel({required this.ids, this.weight = 1.0});

  final List<String> ids;
  final double weight;
}

/// Selects exact-index terms with the highest information value first.
///
/// `documentFrequency` is the number of active verified catalogue products that
/// contain a term. Rare identity terms therefore win over ubiquitous packaging
/// words. Terms absent from the exact index are intentionally excluded here;
/// they remain valuable to [selectRecoveryTerms] as possible OCR corruption.
List<String> selectInformationRichTerms(
  Iterable<String> terms,
  Map<String, int> documentFrequency, {
  int limit = 20,
}) {
  if (limit <= 0) return const <String>[];
  final unique = <String>[];
  final seen = <String>{};
  for (final raw in terms) {
    final term = raw.trim();
    if (term.isEmpty || !seen.add(term)) continue;
    if ((documentFrequency[term] ?? 0) > 0) unique.add(term);
  }

  final originalOrder = <String, int>{
    for (var index = 0; index < unique.length; index++) unique[index]: index,
  };
  unique.sort((a, b) {
    final frequency = (documentFrequency[a] ?? 0).compareTo(
      documentFrequency[b] ?? 0,
    );
    if (frequency != 0) return frequency;
    final length = b.length.compareTo(a.length);
    if (length != 0) return length;
    return (originalOrder[a] ?? 0).compareTo(originalOrder[b] ?? 0);
  });
  return List<String>.unmodifiable(unique.take(limit));
}

/// Plans typo/OCR recovery terms without letting common words monopolize work.
///
/// Unknown exact terms are tried first because they are the strongest signal of
/// a one-character OCR mutation. Known terms then follow from rarest to most
/// common. The result remains bounded before delete-neighbour expansion.
List<String> selectRecoveryTerms(
  Iterable<String> terms,
  Map<String, int> documentFrequency, {
  int limit = 18,
}) {
  if (limit <= 0) return const <String>[];
  final unique = <String>[];
  final seen = <String>{};
  for (final raw in terms) {
    final term = raw.trim();
    if (term.length < 4 || term.length > 28 || !seen.add(term)) continue;
    unique.add(term);
  }

  final originalOrder = <String, int>{
    for (var index = 0; index < unique.length; index++) unique[index]: index,
  };
  unique.sort((a, b) {
    final aFrequency = documentFrequency[a] ?? 0;
    final bFrequency = documentFrequency[b] ?? 0;
    final aUnknown = aFrequency == 0;
    final bUnknown = bFrequency == 0;
    if (aUnknown != bUnknown) return aUnknown ? -1 : 1;
    if (!aUnknown) {
      final frequency = aFrequency.compareTo(bFrequency);
      if (frequency != 0) return frequency;
    }
    final length = b.length.compareTo(a.length);
    if (length != 0) return length;
    return (originalOrder[a] ?? 0).compareTo(originalOrder[b] ?? 0);
  });
  return List<String>.unmodifiable(unique.take(limit));
}

/// Produces a tiny set of stable anchors for unusually long OCR tokens.
///
/// Pharmaceutical OCR often collapses a multi-word ingredient into one token.
/// Full-token exact lookup is excellent when OCR is perfect, but one corrupted
/// character can otherwise destroy recall. Indexing every trigram would expand
/// the catalogue aggressively, so this planner samples only a few separated
/// windows. Existing delete-neighbour recovery can then tolerate one damaged
/// character inside an anchor while keeping storage and query work bounded.
List<String> boundedOcrAnchors(
  String raw, {
  int width = 12,
  int maxAnchors = 4,
}) {
  if (maxAnchors <= 0) return const <String>[];
  final compact = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (compact.length <= 28) return const <String>[];

  final boundedWidth = width < 8
      ? 8
      : width > 16
      ? 16
      : width;
  final actualWidth = boundedWidth > compact.length
      ? compact.length
      : boundedWidth;
  final span = compact.length - actualWidth;
  if (span <= 0) return <String>[compact];

  final starts = <int>{
    0,
    (span / 3).round(),
    ((span * 2) / 3).round(),
    span,
  }.toList(growable: false)
    ..sort();

  final result = <String>[];
  final seen = <String>{};
  for (final start in starts) {
    final anchor = compact.substring(start, start + actualWidth);
    if (seen.add(anchor)) result.add(anchor);
    if (result.length >= maxAnchors) break;
  }
  return List<String>.unmodifiable(result);
}

/// Reciprocal-rank fusion for heterogeneous bounded retrievers.
///
/// RRF depends on rank rather than incomparable raw score scales, so exact-term
/// retrieval and delete-neighbour recovery can corroborate one another without
/// one channel winning merely because its numeric scoring range is larger.
/// Duplicate IDs inside one channel contribute only once.
Map<String, double> reciprocalRankFuse(
  Iterable<RankedRetrievalChannel> channels, {
  double rankConstant = 60.0,
}) {
  if (!rankConstant.isFinite || rankConstant < 1) {
    throw ArgumentError.value(rankConstant, 'rankConstant', 'must be >= 1');
  }
  final fused = <String, double>{};
  for (final channel in channels) {
    if (!channel.weight.isFinite || channel.weight <= 0) continue;
    final seen = <String>{};
    var rank = 0;
    for (final rawId in channel.ids) {
      final id = rawId.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      rank++;
      final contribution = channel.weight / (rankConstant + rank);
      fused.update(
        id,
        (value) => value + contribution,
        ifAbsent: () => contribution,
      );
    }
  }
  return Map<String, double>.unmodifiable(fused);
}
