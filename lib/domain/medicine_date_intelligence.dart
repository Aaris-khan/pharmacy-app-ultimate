import 'dart:math';

import 'medicine_date_parser.dart';
import 'medicine_understanding.dart';
import 'offline_evidence_graph.dart';

export 'medicine_date_parser.dart'
    show ParsedMedicineDate, parseMedicineDateText;

enum MedicineDateRole { manufacturing, expiry, unknown }

class MedicineDateEvidence {
  const MedicineDateEvidence({
    required this.date,
    required this.role,
    required this.confidence,
    required this.support,
    this.explicitLabel = false,
  });

  final ParsedMedicineDate date;
  final MedicineDateRole role;
  final double confidence;
  final int support;
  final bool explicitLabel;
}

class MedicineDateResolution {
  const MedicineDateResolution({
    this.manufacturing,
    this.expiry,
    this.conflicted = false,
    this.expired = false,
  });

  final MedicineDateEvidence? manufacturing;
  final MedicineDateEvidence? expiry;
  final bool conflicted;
  final bool expired;

  bool get isEmpty => manufacturing == null && expiry == null;
}

/// V10 deterministic temporal reasoning. Current time is supporting evidence,
/// never the only rule: a past date may be manufacturing OR an already-expired
/// expiry. Strong labels, chronological pairs and plausible shelf-life always
/// outrank the simple past/future heuristic.
MedicineDateResolution inferMedicineDateIntelligence({
  required Iterable<MedicineFrameEvidence> frames,
  required DateTime referenceDate,
  String existingMfg = '',
  String existingExpiry = '',
  double existingMfgConfidence = 0,
  double existingExpiryConfidence = 0,
}) {
  final evidence = <MedicineDateEvidence>[];
  final grouped = <String, MedicineDateEvidence>{};
  final today = DateTime.utc(
    referenceDate.year,
    referenceDate.month,
    referenceDate.day,
  );

  void remember(MedicineDateEvidence item) {
    final key = '${item.role.name}|${item.date.value}';
    final old = grouped[key];
    if (old == null) {
      grouped[key] = item;
      return;
    }
    grouped[key] = MedicineDateEvidence(
      date: item.date,
      role: item.role,
      confidence: max(old.confidence, item.confidence),
      support: old.support + item.support,
      explicitLabel: old.explicitLabel || item.explicitLabel,
    );
  }

  final existingMfgDate = parseMedicineDateText(existingMfg);
  if (existingMfgDate != null) {
    remember(
      MedicineDateEvidence(
        date: existingMfgDate,
        role: MedicineDateRole.manufacturing,
        confidence: existingMfgConfidence.clamp(.50, .995).toDouble(),
        support: 1,
        explicitLabel: existingMfgConfidence >= .84,
      ),
    );
  }
  final existingExpiryDate = parseMedicineDateText(existingExpiry);
  if (existingExpiryDate != null) {
    remember(
      MedicineDateEvidence(
        date: existingExpiryDate,
        role: MedicineDateRole.expiry,
        confidence: existingExpiryConfidence.clamp(.50, .995).toDouble(),
        support: 1,
        explicitLabel: existingExpiryConfidence >= .84,
      ),
    );
  }

  final graph = buildOfflineEvidenceGraph(frames, maxFrames: 16);
  final independentFrames = graph.groups.isEmpty
      ? frames.take(16)
      : graph.groups.map((group) => group.representative);
  for (final frame in independentFrames) {
    final quality = frame.quality.clamp(0, 1).toDouble();
    final observed = <String>{};

    for (final orderedLines in _dateLineStreams(frame)) {
      final acceptedBareCompact = _bareCompactDatePairIndexes(
        orderedLines,
        today,
      );
      for (var index = 0; index < orderedLines.length; index++) {
        final line = orderedLines[index];
        final matches = extractMedicineDateMatches(line, allowCompact: true);
        if (matches.isEmpty) continue;
        final labels = _dateLabels(line);
        for (final match in matches.take(6)) {
          var labelled = _nearestRole(match.start, match.end, labels);
          final standalone =
              matches.length == 1 && _isStandaloneDateMatch(line, match);

          if (labelled == null && labels.isEmpty && standalone) {
            if (index > 0) {
              final previousRole = _labelOnlyRole(orderedLines[index - 1]);
              if (previousRole != null) labelled = (previousRole, 24);
            }
            if (labelled == null && index + 1 < orderedLines.length) {
              final followingRole = _labelOnlyRole(orderedLines[index + 1]);
              final followedByAnotherDate =
                  index + 2 < orderedLines.length &&
                  _isStandaloneDateLine(orderedLines[index + 2]);
              if (followingRole != null && !followedByAnotherDate) {
                labelled = (followingRole, 30);
              }
            }
            if (labelled == null &&
                _adjacentNonDateLabel(orderedLines, index)) {
              continue;
            }
          }

          final role = labelled?.$1 ?? MedicineDateRole.unknown;
          if (labelled != null && role == MedicineDateRole.unknown) continue;
          if (match.compact &&
              labelled == null &&
              !acceptedBareCompact.contains(index)) {
            continue;
          }
          if (!observed.add('${role.name}|${match.date.value}')) continue;
          final distance = labelled?.$2 ?? 999;
          final explicit = labelled != null;
          final base = explicit ? (distance <= 20 ? .955 : .91) : .61;
          remember(
            MedicineDateEvidence(
              date: match.date,
              role: role,
              confidence: (base + quality * (explicit ? .035 : .055))
                  .clamp(0, .99)
                  .toDouble(),
              support: 1,
              explicitLabel: explicit,
            ),
          );
        }
      }
    }
  }

  evidence.addAll(grouped.values);
  if (evidence.isEmpty) return const MedicineDateResolution();

  MedicineDateEvidence? bestFor(MedicineDateRole role) {
    final values = evidence.where((item) => item.role == role).toList()
      ..sort(_compareEvidence);
    return values.isEmpty ? null : values.first;
  }

  var manufacturing = bestFor(MedicineDateRole.manufacturing);
  var expiry = bestFor(MedicineDateRole.expiry);
  final labelConflict =
      <MedicineDateRole>[
        MedicineDateRole.manufacturing,
        MedicineDateRole.expiry,
      ].any((role) {
        DateTime? latestStart, earliestEnd;
        for (final item in evidence.where(
          (item) =>
              item.role == role && item.explicitLabel && item.confidence >= .84,
        )) {
          final start = item.date.start, end = item.date.end;
          if (latestStart == null || start.isAfter(latestStart)) {
            latestStart = start;
          }
          if (earliestEnd == null || end.isBefore(earliestEnd)) {
            earliestEnd = end;
          }
        }
        return latestStart != null && latestStart.isAfter(earliestEnd!);
      });
  var conflicted = labelConflict;

  if (manufacturing != null && expiry != null) {
    if (!manufacturing.date.start.isBefore(expiry.date.end)) {
      conflicted = true;
    }
  }

  final uniqueByDate = <String, MedicineDateEvidence>{};
  for (final item in evidence) {
    final old = uniqueByDate[item.date.value];
    if (old == null || _compareEvidence(item, old) < 0) {
      uniqueByDate[item.date.value] = item;
    }
  }
  final unique = uniqueByDate.values.toList()
    ..sort((a, b) => a.date.start.compareTo(b.date.start));

  final pairs = <_DatePair>[];
  for (var i = 0; i < unique.length; i++) {
    for (var j = i + 1; j < unique.length; j++) {
      final earlier = unique[i];
      final later = unique[j];
      if (earlier.role == MedicineDateRole.expiry ||
          later.role == MedicineDateRole.manufacturing) {
        continue;
      }
      final days = later.date.end.difference(earlier.date.start).inDays;
      if (days < 21 || days > 8 * 366) continue;
      var score = .64;
      if (earlier.role == MedicineDateRole.manufacturing) score += .14;
      if (later.role == MedicineDateRole.expiry) score += .14;
      if (earlier.explicitLabel) score += .04;
      if (later.explicitLabel) score += .04;
      if (days >= 60 && days <= 5 * 366) {
        score += .10;
      } else {
        score += .04;
      }
      if (!earlier.date.start.isAfter(today.add(const Duration(days: 31)))) {
        score += .035;
      }
      score += later.date.end.isAfter(today) ? .045 : .015;
      score += min(.035, (earlier.support + later.support - 2) * .012);
      pairs.add(_DatePair(earlier, later, score.clamp(0, .99).toDouble()));
    }
  }
  pairs.sort((a, b) => b.score.compareTo(a.score));

  if ((manufacturing == null || expiry == null || conflicted) &&
      pairs.isNotEmpty) {
    final best = pairs.first;
    final runner = pairs.length > 1 ? pairs[1] : null;
    final separated = runner == null || best.score - runner.score >= .045;
    if (best.score >= .78 && separated) {
      final inferredConfidence = best.score.clamp(.78, .94).toDouble();
      if (manufacturing == null || conflicted) {
        manufacturing = MedicineDateEvidence(
          date: best.earlier.date,
          role: MedicineDateRole.manufacturing,
          confidence: max(best.earlier.confidence, inferredConfidence),
          support: best.earlier.support,
          explicitLabel: best.earlier.explicitLabel,
        );
      }
      if (expiry == null || conflicted) {
        expiry = MedicineDateEvidence(
          date: best.later.date,
          role: MedicineDateRole.expiry,
          confidence: max(best.later.confidence, inferredConfidence),
          support: best.later.support,
          explicitLabel: best.later.explicitLabel,
        );
      }
      conflicted = labelConflict;
    }
  }

  if (expiry == null && unique.length == 1) {
    final only = unique.single;
    final future = only.date.end.isAfter(today);
    final horizon = only.date.end.difference(today).inDays;
    if (only.role == MedicineDateRole.unknown && future && horizon <= 8 * 366) {
      expiry = MedicineDateEvidence(
        date: only.date,
        role: MedicineDateRole.expiry,
        confidence: .70,
        support: only.support,
      );
    }
  }

  if (manufacturing != null && expiry != null) {
    if (!manufacturing.date.start.isBefore(expiry.date.end)) conflicted = true;
    final gap = expiry.date.end.difference(manufacturing.date.start).inDays;
    if (gap < 21 || gap > 8 * 366) conflicted = true;
  }

  if (manufacturing != null && manufacturing.date.start.isAfter(today)) {
    conflicted = true;
  }

  final expired = expiry != null && expiry.date.end.isBefore(today);
  return MedicineDateResolution(
    manufacturing: manufacturing,
    expiry: expiry,
    conflicted: conflicted,
    expired: expired,
  );
}

class _DatePair {
  const _DatePair(this.earlier, this.later, this.score);
  final MedicineDateEvidence earlier;
  final MedicineDateEvidence later;
  final double score;
}

int _compareEvidence(MedicineDateEvidence a, MedicineDateEvidence b) {
  final explicit = (b.explicitLabel ? 1 : 0) - (a.explicitLabel ? 1 : 0);
  if (explicit != 0) return explicit;
  final confidence = b.confidence.compareTo(a.confidence);
  if (confidence != 0) return confidence;
  return b.support.compareTo(a.support);
}

List<List<String>> _dateLineStreams(MedicineFrameEvidence frame) {
  List<String> clean(Iterable<String> source) => source
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .take(120)
      .toList(growable: false);

  final raw = clean(frame.text.split(RegExp(r'[\r\n]+')));
  final layoutEvidence = frame.layoutLines.take(120).toList(growable: false)
    ..sort(_compareDateLayoutReadingOrder);
  final layout = clean(layoutEvidence.map((line) => line.text));
  return <List<String>>[
    if (raw.isNotEmpty) raw,
    if (layout.isNotEmpty) layout,
  ];
}

int _compareDateLayoutReadingOrder(
  MedicineTextLineEvidence left,
  MedicineTextLineEvidence right,
) {
  final leftCenterY = left.top + left.height / 2;
  final rightCenterY = right.top + right.height / 2;
  final rowTolerance = max(3.0, min(left.height, right.height) * .65);
  if ((leftCenterY - rightCenterY).abs() > rowTolerance) {
    final vertical = left.top.compareTo(right.top);
    if (vertical != 0) return vertical;
  }
  final horizontal = left.left.compareTo(right.left);
  if (horizontal != 0) return horizontal;
  final vertical = left.top.compareTo(right.top);
  if (vertical != 0) return vertical;
  return left.text.compareTo(right.text);
}

MedicineDateRole? _labelOnlyRole(String line) {
  if (RegExp(r'[0-9०-९٠-٩۰-۹]').hasMatch(line)) return null;
  final labels = _dateLabels(line);
  if (labels.length != 1) return null;
  final role = labels.single.$1;
  return role == MedicineDateRole.unknown ? null : role;
}

bool _labelOnlyNonDate(String line) {
  if (RegExp(r'[0-9०-९٠-٩۰-۹]').hasMatch(line)) return false;
  final labels = _dateLabels(line);
  return labels.length == 1 && labels.single.$1 == MedicineDateRole.unknown;
}

bool _adjacentNonDateLabel(List<String> lines, int index) =>
    (index > 0 && _labelOnlyNonDate(lines[index - 1])) ||
    (index + 1 < lines.length && _labelOnlyNonDate(lines[index + 1]));

Set<int> _bareCompactDatePairIndexes(List<String> lines, DateTime today) {
  final candidates = <(int, ParsedMedicineDate)>[];
  for (var index = 0; index < lines.length; index++) {
    final matches = extractMedicineDateMatches(lines[index], allowCompact: true);
    if (matches.length != 1) continue;
    final match = matches.single;
    if (!match.compact ||
        !_isStandaloneDateMatch(lines[index], match) ||
        _adjacentNonDateLabel(lines, index)) {
      continue;
    }
    candidates.add((index, match.date));
  }

  // More than two unlabeled compact values are ambiguous (lot, serial, price,
  // manufacture and expiry can all coexist). Only one clean pair is allowed to
  // contribute to chronology; a singleton remains non-authoritative.
  if (candidates.length != 2) return const <int>{};
  final first = candidates[0];
  final second = candidates[1];
  final firstBeforeSecond = first.$2.start.isBefore(second.$2.start);
  final earlier = firstBeforeSecond ? first : second;
  final later = firstBeforeSecond ? second : first;
  if (!earlier.$2.start.isBefore(later.$2.end)) return const <int>{};

  final shelfLifeDays = later.$2.end.difference(earlier.$2.start).inDays;
  if (shelfLifeDays < 60 || shelfLifeDays > 5 * 366) {
    return const <int>{};
  }
  if (earlier.$2.start.isAfter(today.add(const Duration(days: 31)))) {
    return const <int>{};
  }
  return Set<int>.unmodifiable(<int>{earlier.$1, later.$1});
}

bool _isStandaloneDateLine(String line) {
  final matches = extractMedicineDateMatches(line, allowCompact: true);
  return matches.length == 1 && _isStandaloneDateMatch(line, matches.single);
}

bool _isStandaloneDateMatch(String line, MedicineDateMatch match) =>
    line.substring(0, match.start).trim().isEmpty &&
    line.substring(match.end).trim().isEmpty;

List<(MedicineDateRole, int, int)> _dateLabels(String line) {
  final result = <(MedicineDateRole, int, int)>[];
  for (final match in medicineExpiryLabel.allMatches(line)) {
    result.add((MedicineDateRole.expiry, match.start, match.end));
  }
  for (final match in medicineManufacturingLabel.allMatches(line)) {
    result.add((MedicineDateRole.manufacturing, match.start, match.end));
  }
  for (final match in medicineNonDateLabel.allMatches(line)) {
    result.add((MedicineDateRole.unknown, match.start, match.end));
  }
  result.sort((a, b) => a.$2.compareTo(b.$2));
  return result;
}

(MedicineDateRole, int)? _nearestRole(
  int start,
  int end,
  List<(MedicineDateRole, int, int)> labels,
) {
  (MedicineDateRole, int)? best;
  final preceding = labels.where((label) => label.$3 <= start).lastOrNull;
  if (preceding != null) {
    final distance = start - preceding.$3;
    return distance <= 56 ? (preceding.$1, distance) : null;
  }
  for (final label in labels) {
    final distance = start >= label.$3
        ? start - label.$3
        : label.$2 >= end
        ? label.$2 - end + 10
        : 0;
    if (distance > 56) continue;
    if (best == null || distance < best.$2) best = (label.$1, distance);
  }
  return best;
}
