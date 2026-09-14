final _medicineOcrPresentationArtifacts = RegExp(
  r'[\u00AD\u034F\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]',
);

final _medicineOcrUnitBoundNumber = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)(?=\s*(?:mcg|ug|µg|μg|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?![A-Za-z]))',
  caseSensitive: false,
);

String _cleanMedicineOcrLine(String value) => value
    // Unicode bidi/zero-width controls are formatting code points, not word
    // separators. Replacing them with spaces split real medicine tokens such as
    // PARA<Cf>CETAMOL and weakened name/salt matching. Soft hyphens, combining
    // grapheme joiners and Arabic layout marks are presentation artifacts too;
    // removing them prevents invisible OCR metadata from fragmenting identity.
    // The geometry-aware date parser keeps its own one-for-one offset-preserving
    // normalization where character offsets are semantically required.
    .replaceAll(_medicineOcrPresentationArtifacts, '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _repairMedicineOcrDigitToken(String value) => value
    .replaceAll(RegExp('[Oo]'), '0')
    .replaceAll(RegExp('[IlL]'), '1');

String _canonicalMedicineOcrSurface(String value) {
  var result = value
      .replaceAll(RegExp(r'[\u00A0\u2007\u202F\u3000]'), ' ')
      .replaceAll(RegExp(r'[／⁄∕]'), '/')
      .replaceAll(RegExp(r'[‐‑‒–—−]'), '-')
      .replaceAll(RegExp(r'[٫．]'), '.')
      .replaceAll(RegExp(r'[µμ]'), 'u');

  // Normalize the full-width ASCII block before downstream field extraction.
  // This recovers full-width medicine names, Latin units and punctuation while
  // preserving the exact semantic characters (Ａ→A, ｍ→m, ５→5).
  result = result.replaceAllMapped(RegExp(r'[\uFF01-\uFF5E]'), (match) {
    return String.fromCharCode(match[0]!.codeUnitAt(0) - 0xFEE0);
  });

  // Devanagari, Arabic-Indic and Eastern Arabic-Indic digits are ordinary
  // numeric evidence. Converting them to ASCII once at the OCR boundary lets
  // every existing strength/form/search heuristic consume the same value.
  result = result.replaceAllMapped(RegExp(r'[०-९٠-٩۰-۹]'), (match) {
    final code = match[0]!.codeUnitAt(0);
    final zero = code >= 0x0966
        ? 0x0966
        : code >= 0x06F0
        ? 0x06F0
        : 0x0660;
    return (code - zero).toString();
  });

  // O/0 and I/l/1 are repaired only inside a numeric token immediately owned
  // by a pharmaceutical unit. At least one real digit is required, so product
  // words such as OIL/ILL can never be converted into invented strengths.
  result = result.replaceAllMapped(_medicineOcrUnitBoundNumber, (match) {
    final token = match[1]!;
    if (!RegExp(r'\d').hasMatch(token)) return token;
    return _repairMedicineOcrDigitToken(token);
  });

  return result.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Canonical OCR surface consumed by both flattened text and geometry evidence.
/// The transformation is semantic-preserving and intentionally bounded.
String normalizeMedicineOcrLine(String value) =>
    _canonicalMedicineOcrSurface(_cleanMedicineOcrLine(value));

/// Preserve printed punctuation/numbers when deduplicating OCR. Fuzzy string
/// similarity is not identity: 650 vs 850 mg and 0.5 vs 5 mg can be >96% similar
/// on a long composition line. Both readings must reach the conflict resolver.
///
/// Unicode presentation variants, compatible full-width ASCII and decimal/digit
/// scripts are canonicalized without changing their numeric meaning. Tightly
/// bounded O/0/I/l repair is allowed only when a real digit token is immediately
/// followed by a pharmaceutical unit.
String medicineOcrLineKey(String value) =>
    normalizeMedicineOcrLine(value).toLowerCase();

List<String> mergeMedicineOcrLines(Iterable<String> raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final line in raw.take(500)) {
    // Feed downstream extraction a semantically canonical OCR surface rather
    // than forcing every field resolver to reimplement Unicode normalization.
    // This remains human-auditable: only compatibility glyphs/digit scripts and
    // unit-bound OCR confusions are repaired; words and numeric values otherwise
    // remain untouched.
    final value = normalizeMedicineOcrLine(line);
    if (value.length < 2 || !seen.add(value.toLowerCase())) continue;
    result.add(value);
  }
  // Do not move later dose/date lines before their intervening product headings.
  // LocalScanEvidence is responsible for bounded, explicitly separated spans.
  return result;
}

double medicineOcrLineQuality(String value) {
  final clean = normalizeMedicineOcrLine(value);
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
