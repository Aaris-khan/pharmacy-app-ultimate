final _medicineOcrPresentationArtifacts = RegExp(
  r'[\u00AD\u034F\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]',
);
final _medicineOcrWhitespace = RegExp(r'\s+');
final _medicineOcrCompatibilitySpaces = RegExp(r'[\u00A0\u2007\u202F\u3000]');
final _medicineOcrSlashVariants = RegExp(r'[／⁄∕]');
final _medicineOcrDashVariants = RegExp(r'[‐‑‒–—−]');
final _medicineOcrDecimalVariants = RegExp(r'[٫．]');
final _medicineOcrMicroVariants = RegExp(r'[µμ]');
final _medicineOcrFullWidthAscii = RegExp(r'[\uFF01-\uFF5E]');
final _medicineOcrScriptDigits = RegExp(r'[०-९٠-٩۰-۹]');
final _medicineOcrAsciiDigit = RegExp(r'\d');
final _medicineOcrDigitO = RegExp('[Oo]');
final _medicineOcrDigitOne = RegExp('[IlL]');

final _medicineOcrUnitBoundNumber = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)(?=\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrSeparatedDigitsBeforeUnit = RegExp(
  r'(?<![A-Za-z0-9])((?:[0-9]\s+){1,4}[0-9])(?=\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%|milligram(?:me)?s?|microgram(?:me)?s?|millilit(?:er|re)s?|gram(?:me)?s?|international\s+units?|per\s*cent|percent)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrSpacedDecimal = RegExp(
  r'(?<!\d)(\d{1,7})\s*([.,])\s*(\d{1,4})(?!\d)',
);
final _medicineOcrSpelledUnit = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)\s*(milligram(?:me)?s?|microgram(?:me)?s?|millilit(?:er|re)s?|gram(?:me)?s?|international\s+units?|per\s*cent|percent)(?![A-Za-z])',
  caseSensitive: false,
);
final _medicineOcrThousandsBeforeUnit = RegExp(
  r'(?<!\d)([1-9]\d{0,2}),(\d{3})(?=\s*(?:mcg|ug|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)(?![A-Za-z]))',
  caseSensitive: false,
);
final _medicineOcrMlConfusion = RegExp(
  r'(?<![A-Za-z0-9])([0-9OoIlL]{1,7}(?:[.,][0-9OoIlL]{1,4})?)\s*m[1Il](?![A-Za-z])',
  caseSensitive: false,
);
final _medicineOcrPerConcentration = RegExp(
  r'(?<![A-Za-z0-9])(\d+(?:[.,]\d+)?\s*(?:mcg|ug|mg|gm|g|meq|iu|i\.u\.|units?|%))\s+per\s+(?:(\d+(?:[.,]\d+)?)\s*)?(ml|millilit(?:er|re)s?|g|gram(?:me)?s?|dose|actuation)(?![A-Za-z])',
  caseSensitive: false,
);
final _medicineOcrCompositionBasis = RegExp(
  r'(?<![A-Za-z0-9])(?:each\s+)?(\d+(?:[.,]\d+)?)\s*(ml|g)\s+(?:of\s+(?:(?:the|reconstituted)\s+)?(?:suspension|solution|syrup)\s+)?contains?\b',
  caseSensitive: false,
);
final _medicineOcrBasisOwnedStrength = RegExp(
  r'(?<![A-Za-z0-9/])(\d+(?:[.,]\d+)?\s*(?:mcg|ug|mg|gm|g|meq|iu|i\.u\.|units?))(?!\s*/)',
  caseSensitive: false,
);

String _cleanMedicineOcrLine(String value) => value
    // Unicode bidi/zero-width controls are formatting code points, not word
    // separators. Removing them keeps real medicine tokens intact while all
    // visible whitespace is still collapsed below.
    .replaceAll(_medicineOcrPresentationArtifacts, '')
    .replaceAll(_medicineOcrWhitespace, ' ')
    .trim();

String _repairMedicineOcrDigitToken(String value) => value
    .replaceAll(_medicineOcrDigitO, '0')
    .replaceAll(_medicineOcrDigitOne, '1');

String _canonicalMedicineUnitWord(String value) {
  final key = value.toLowerCase().replaceAll(_medicineOcrWhitespace, ' ').trim();
  if (key.startsWith('milligram')) return 'mg';
  if (key.startsWith('microgram')) return 'mcg';
  if (key.startsWith('millilit')) return 'ml';
  if (key.startsWith('gram')) return 'g';
  if (key.startsWith('international')) return 'iu';
  if (key == 'percent' || key == 'per cent') return '%';
  return key;
}

String _canonicalMedicineDenominatorUnit(String value) {
  final key = value.toLowerCase().replaceAll(_medicineOcrWhitespace, ' ').trim();
  if (key.startsWith('millilit')) return 'ml';
  if (key.startsWith('gram')) return 'g';
  return key;
}

String _canonicalMedicineOcrSurface(String value) {
  var result = value
      .replaceAll(_medicineOcrCompatibilitySpaces, ' ')
      .replaceAll(_medicineOcrSlashVariants, '/')
      .replaceAll(_medicineOcrDashVariants, '-')
      .replaceAll(_medicineOcrDecimalVariants, '.')
      .replaceAll(_medicineOcrMicroVariants, 'u');

  // Normalize the full-width ASCII block before downstream field extraction.
  // This recovers full-width medicine names, Latin units and punctuation while
  // preserving the exact semantic characters (Ａ→A, ｍ→m, ５→5).
  result = result.replaceAllMapped(_medicineOcrFullWidthAscii, (match) {
    return String.fromCharCode(match[0]!.codeUnitAt(0) - 0xFEE0);
  });

  // Devanagari, Arabic-Indic and Eastern Arabic-Indic digits are ordinary
  // numeric evidence. Converting them once lets every strength/date consumer
  // operate on the same bounded ASCII representation.
  result = result.replaceAllMapped(_medicineOcrScriptDigits, (match) {
    final code = match[0]!.codeUnitAt(0);
    final zero = code >= 0x0966
        ? 0x0966
        : code >= 0x06F0
        ? 0x06F0
        : 0x0660;
    return (code - zero).toString();
  });

  // OCR engines sometimes fragment a printed number into one-character tokens,
  // e.g. "6 5 0 mg". Join only a short digit run that is immediately owned by
  // a pharmaceutical unit, so dates, batch IDs and ordinary prose are untouched.
  result = result.replaceAllMapped(
    _medicineOcrSeparatedDigitsBeforeUnit,
    (match) => match[1]!.replaceAll(_medicineOcrWhitespace, ''),
  );

  // Preserve decimals when OCR inserts spaces around the punctuation. This is a
  // lexical cleanup only; date-role logic still decides whether a numeric value
  // is a date, and strength logic still requires a pharmaceutical unit.
  result = result.replaceAllMapped(
    _medicineOcrSpacedDecimal,
    (match) => '${match[1]}${match[2]}${match[3]}',
  );

  // Full-word units are common on labels and imported OCR. Canonicalize them
  // only when directly attached to a numeric token. Pure prose such as
  // "milligrams per tablet" is deliberately left alone.
  result = result.replaceAllMapped(_medicineOcrSpelledUnit, (match) {
    final number = match[1]!;
    if (!_medicineOcrAsciiDigit.hasMatch(number)) return match[0]!;
    final repaired = _repairMedicineOcrDigitToken(number);
    return '$repaired ${_canonicalMedicineUnitWord(match[2]!)}';
  });

  // A common ML/OCR confusion is lowercase-L in the volume unit being read as
  // digit one ("5 m1"). Repair only a numeric, unit-owned token.
  result = result.replaceAllMapped(_medicineOcrMlConfusion, (match) {
    final number = match[1]!;
    if (!_medicineOcrAsciiDigit.hasMatch(number)) return match[0]!;
    return '${_repairMedicineOcrDigitToken(number)} ml';
  });

  // Indian packaging commonly prints a thousands separator in 1,000 mg. The
  // downstream strength grammar treats comma as a decimal marker, so disambiguate
  // the unambiguous non-zero thousands shape before extraction. "0,500 mg"
  // remains a decimal-comma value.
  result = result.replaceAllMapped(
    _medicineOcrThousandsBeforeUnit,
    (match) => '${match[1]}${match[2]}',
  );

  // O/0 and I/l/1 are repaired only inside a numeric token immediately owned
  // by a pharmaceutical unit. At least one real digit is required, so product
  // words such as OIL/ILL can never be converted into invented strengths.
  result = result.replaceAllMapped(_medicineOcrUnitBoundNumber, (match) {
    final token = match[1]!;
    if (!_medicineOcrAsciiDigit.hasMatch(token)) return token;
    return _repairMedicineOcrDigitToken(token);
  });

  // Normalize concentration prose into the slash grammar already consumed by
  // the deterministic extractor: "125 mg per 5 millilitres" -> "125 mg/5 ml".
  // The rewrite is intentionally impossible without a numeric pharmaceutical
  // numerator, which prevents ordinary English "per" phrases from changing.
  result = result.replaceAllMapped(_medicineOcrPerConcentration, (match) {
    final denominator = match[2];
    final unit = _canonicalMedicineDenominatorUnit(match[3]!);
    return denominator == null
        ? '${match[1]}/$unit'
        : '${match[1]}/$denominator $unit';
  });

  // Liquid labels very often express the denominator before the ingredients:
  // "Each 5 ml contains Paracetamol 125 mg". The old parser consumed the
  // composition heading and then saw only "125 mg", silently losing the 5 ml
  // basis. Bind that explicit basis to numerator strengths in the same bounded
  // line before any semantic role extraction runs. Existing slash
  // concentrations are left untouched, and the rule cannot fire without both
  // an explicit numeric ml/g basis and the word "contains". The inserted
  // semicolon preserves every printed token while making the heading/ingredient
  // boundary explicit to the existing semantic segmenter.
  final basis = _medicineOcrCompositionBasis.firstMatch(result);
  if (basis != null) {
    final denominator = basis[1]!;
    final denominatorUnit = basis[2]!.toLowerCase();
    final head = result.substring(0, basis.end);
    final tail = result.substring(basis.end);
    var rewrites = 0;
    final boundTail = tail.replaceAllMapped(_medicineOcrBasisOwnedStrength, (
      match,
    ) {
      if (rewrites >= 6) return match[0]!;
      final before = tail.substring(0, match.start).trimRight();
      if (before.endsWith('/')) return match[0]!;
      rewrites++;
      return '${match[1]}/$denominator $denominatorUnit';
    });
    result = '$head;$boundTail';
  }

  return result.replaceAll(_medicineOcrWhitespace, ' ').trim();
}

/// Canonical OCR surface consumed by both flattened text and geometry evidence.
/// The transformation is semantic-preserving and intentionally bounded.
String normalizeMedicineOcrLine(String value) =>
    _canonicalMedicineOcrSurface(_cleanMedicineOcrLine(value));

/// Preserve printed punctuation/numbers when deduplicating OCR. Fuzzy string
/// similarity is not identity: 650 vs 850 mg and 0.5 vs 5 mg can be >96% similar
/// on a long composition line. Both readings must reach the conflict resolver.
String medicineOcrLineKey(String value) =>
    normalizeMedicineOcrLine(value).toLowerCase();

List<String> mergeMedicineOcrLines(Iterable<String> raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final line in raw.take(500)) {
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
        (code >= 0x0900 && code <= 0x097F)) {
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
