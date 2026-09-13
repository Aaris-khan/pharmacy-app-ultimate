final _medicineOcrPresentationArtifacts = RegExp(
  r'[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]',
);

String _cleanMedicineOcrLine(String value) => value
    .replaceAll(_medicineOcrPresentationArtifacts, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Preserve printed punctuation/numbers when deduplicating OCR. Fuzzy string
/// similarity is not identity: 650 vs 850 mg and 0.5 vs 5 mg can be >96% similar
/// on a long composition line. Both readings must reach the conflict resolver.
String medicineOcrLineKey(String value) =>
    _cleanMedicineOcrLine(value).toLowerCase();

List<String> mergeMedicineOcrLines(Iterable<String> raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final line in raw.take(500)) {
    final value = _cleanMedicineOcrLine(line);
    if (value.length < 2 || !seen.add(medicineOcrLineKey(value))) continue;
    result.add(value);
  }
  // Do not move later dose/date lines before their intervening product headings.
  // LocalScanEvidence is responsible for bounded, explicitly separated spans.
  return result;
}

double medicineOcrLineQuality(String value) {
  final clean = _cleanMedicineOcrLine(value);
  if (clean.isEmpty) return 0;
  var useful = 0, replacement = 0, runes = 0;
  for (final code in clean.runes) {
    runes++;
    if ((code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        (code >= 0x0660 && code <= 0x0669) ||
        (code >= 0x06F0 && code <= 0x06F9) ||
        (code >= 0x0900 && code <= 0x097F)) {
      useful++;
    }
    if (code == 0xFFFD || code == 0x7C || code == 0x7B || code == 0x7D) {
      replacement++;
    }
  }
  if (runes == 0) return 0;
  return useful / runes - replacement * .08;
}
