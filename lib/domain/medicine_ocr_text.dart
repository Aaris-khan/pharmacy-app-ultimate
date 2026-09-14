final _medicineOcrPresentationArtifacts = RegExp(
  r'[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]',
);

String _cleanMedicineOcrLine(String value) => value
    // Unicode bidi/zero-width controls are formatting code points, not word
    // separators. Replacing them with spaces split real medicine tokens such as
    // PARA<Cf> CETAMOL and weakened name/salt matching. Remove them here; the
    // geometry-aware date parser keeps its own one-for-one offset-preserving
    // normalization where character offsets are semantically required.
    .replaceAll(_medicineOcrPresentationArtifacts, '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _canonicalMedicineOcrSurface(String value) {
  var result = value
      .replaceAll(RegExp(r'[\u00A0\u2007\u202F]'), ' ')
      .replaceAll(RegExp(r'[／⁄∕]'), '/')
      .replaceAll(RegExp(r'[‐‑‒–—−]'), '-');
  result = result.replaceAllMapped(RegExp(r'[०-९٠-٩۰-۹０-９]'), (match) {
    final code = match[0]!.codeUnitAt(0);
    final zero = code >= 0xFF10
        ? 0xFF10
        : code >= 0x0966
        ? 0x0966
        : code >= 0x06F0
        ? 0x06F0
        : 0x0660;
    return (code - zero).toString();
  });
  return result;
}

/// Preserve printed punctuation/numbers when deduplicating OCR. Fuzzy string
/// similarity is not identity: 650 vs 850 mg and 0.5 vs 5 mg can be >96% similar
/// on a long composition line. Both readings must reach the conflict resolver.
///
/// Script-specific decimal glyphs and Unicode presentation variants are only
/// canonicalized for the dedupe key. The original readable line is retained for
/// review/audit, while equivalent Hindi/Arabic/full-width OCR streams contribute
/// one evidence vote instead of artificially inflating confidence.
String medicineOcrLineKey(String value) => _canonicalMedicineOcrSurface(
  _cleanMedicineOcrLine(value),
).toLowerCase();

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
        (code >= 0x0966 && code <= 0x096F) ||
        (code >= 0xFF10 && code <= 0xFF19) ||
        (code >= 0x0900 && code <= 0x097F) ||
        code == 0x00B5 ||
        code == 0x03BC) {
      useful++;
    }
    if (code == 0xFFFD || code == 0x7C || code == 0x7B || code == 0x7D) {
      replacement++;
    }
  }
  if (runes == 0) return 0;
  // This value is consumed as a bounded quality signal. Corrupt OCR can contain
  // many replacement glyphs, so keep the public contract mathematically inside
  // [0, 1] instead of leaking a negative score into duplicate-selection logic.
  return (useful / runes - replacement * .08).clamp(0.0, 1.0).toDouble();
}
