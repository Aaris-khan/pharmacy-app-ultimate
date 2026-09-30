import 'medicine.dart';

/// Reads a printed dosage form from OCR without turning the whole package into
/// a fuzzy-search problem.
///
/// Exact aliases remain authoritative. A second, deliberately tiny recovery
/// lane accepts one insertion/deletion/substitution only for distinctive
/// medicine-form words that preserve their first three letters. This recovers
/// unseen OCR damage such as LOTIOH -> Lotion while refusing broad neighbours
/// such as MOTION -> Lotion. Powder is excluded from fuzzy recovery because the
/// common word "power" is only one edit away.
String recognizeMedicineFormFromText(String raw) {
  final normalized = normalize(raw);
  if (normalized.isEmpty) return '';

  for (final entry in _medicineFormAliasesBySpecificity) {
    if (entry.key == 'other') continue;
    final pattern = RegExp(
      r'(?:^|[^a-z0-9])' + RegExp.escape(entry.key) + r'(?:$|[^a-z0-9])',
      caseSensitive: false,
    );
    if (pattern.hasMatch(normalized)) return entry.value;
  }

  final recovered = <String>{};
  var inspected = 0;
  for (final match in RegExp(r'[a-z0-9]+').allMatches(normalized)) {
    if (inspected++ >= 48) break;
    final token = match.group(0) ?? '';
    if (token.length < 4 || token.length > 12) continue;

    for (final entry in _medicineFormFuzzyTargets.entries) {
      final target = entry.key;
      if ((token.length - target.length).abs() > 1) continue;
      if (!_sharesMedicineFormAnchor(token, target)) continue;
      if (_withinOneMedicineFormEdit(token, target)) {
        recovered.add(entry.value);
        if (recovered.length > 1) return '';
      }
    }
  }
  return recovered.length == 1 ? recovered.single : '';
}

final List<MapEntry<String, String>> _medicineFormAliasesBySpecificity =
    medicineFormAliases.entries.toList(growable: false)
      ..sort((left, right) {
        final byLength = right.key.length.compareTo(left.key.length);
        return byLength != 0 ? byLength : left.key.compareTo(right.key);
      });

final Map<String, String> _medicineFormFuzzyTargets = <String, String>{
  for (final form in forms)
    if (form != 'Other' && form != 'Powder' && form.length >= 5)
      form.toLowerCase(): form,
};

bool _sharesMedicineFormAnchor(String observed, String canonical) {
  if (observed.length < 3 || canonical.length < 3) return false;
  return observed.substring(0, 3) == canonical.substring(0, 3);
}

bool _withinOneMedicineFormEdit(String observed, String canonical) {
  if (observed == canonical) return true;
  final delta = observed.length - canonical.length;
  if (delta.abs() > 1) return false;

  if (delta == 0) {
    var mismatches = 0;
    for (var index = 0; index < observed.length; index++) {
      if (observed.codeUnitAt(index) == canonical.codeUnitAt(index)) continue;
      mismatches++;
      if (mismatches > 1) return false;
    }
    return mismatches == 1;
  }

  final longer = delta > 0 ? observed : canonical;
  final shorter = delta > 0 ? canonical : observed;
  var longIndex = 0;
  var shortIndex = 0;
  var skipped = false;
  while (longIndex < longer.length && shortIndex < shorter.length) {
    if (longer.codeUnitAt(longIndex) == shorter.codeUnitAt(shortIndex)) {
      longIndex++;
      shortIndex++;
      continue;
    }
    if (skipped) return false;
    skipped = true;
    longIndex++;
  }
  return true;
}
