part of 'medicine_date_intelligence.dart';

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
  for (final label in labels) {
    final distance = label.$3 <= start
        ? start - label.$3
        : label.$2 >= end
        ? label.$2 - end + 10
        : 0;
    if (distance > 56) continue;
    if (best == null || distance < best.$2) {
      best = (label.$1, distance);
    }
  }
  return best;
}
