import 'search.dart';

// Shared lexical rule for OCR, ingredient evidence and the final add gate.
// Never read the tail of a decimal or the prefix of an unknown unit. An
// explicit concentration must be consumed in full, including its denominator.
// "1,000" is ambiguous between grouping and a decimal comma. Keep it for
// review rather than silently turning 1000 into 1. Decimal 0,125 remains valid.
const _number = r'(?![1-9]\d*,\d{3}(?!\d))\d+(?:[.,]\d+)?';
const _unit = r'(?:mcg|ug|µg|μg|mg|gm|g|ml|meq|iu|i\.u\.|units?|%)';
const _denominator = r'(?:mcg|ug|µg|μg|mg|gm|ml|g|l|dose|actuation|iu|units?)';
const _strength =
    '$_number\\s*$_unit'
    '(?:\\s*(?:w\\s*/\\s*w|w\\s*/\\s*v|v\\s*/\\s*v)'
    '|\\s*/\\s*(?:$_number\\s*)?$_denominator)?';

final medicineStrengthPattern = RegExp(
  r'(?<![a-z0-9.,/µμ\u0900-\u097f-])' +
      _strength +
      r'(?![a-z0-9µμ\u0900-\u097f]|\s*(?:/|[wv]\s*/))',
  caseSensitive: false,
);

final _completeStrength = RegExp('^$_strength\$', caseSensitive: false);

bool hasCompleteMedicineStrength(String value) {
  final text = value.trim();
  if (!_completeStrength.hasMatch(text)) return false;
  // A zero amount or denominator cannot certify an ingredient concentration.
  return RegExp(_number).allMatches(text).every((match) {
    final amount = double.tryParse(match[0]!.replaceAll(',', '.'));
    return amount != null && amount.isFinite && amount > 0;
  });
}

/// Search normalization drops %, / and +. Those characters define different
/// strengths, so retain them when comparing medical identity or disagreement.
/// This normalizes spelling/spacing only; it never converts dose units.
String medicineStrengthKey(String value) => value
    .toLowerCase()
    .replaceAll('µg', 'mcg')
    .replaceAll('μg', 'mcg')
    .replaceAll(RegExp(r'\bug\b|(?<=\d)ug\b'), 'mcg')
    .replaceAll(',', '.')
    .replaceAll(RegExp(r'i\.u\.', caseSensitive: false), 'iu')
    .splitMapJoin(
      RegExp(r'[%/+]'),
      onMatch: (match) => match[0]!,
      onNonMatch: (part) => searchText(part).replaceAll(' ', ''),
    );


/// Canonical comparison identity for strengths that are mathematically
/// equivalent without requiring a medicine-specific assumption.
///
/// Bare percentages deliberately stay percentages because `1%` may mean w/w,
/// w/v or v/v depending on the product. Explicit w/v and w/w percentages can
/// safely compare with mass concentrations, while ordinary mass units and
/// explicit denominator quantities are normalized to shared base units.
String medicineStrengthIdentityKey(String value) {
  final normalized = medicineStrengthKey(value);
  if (normalized.isEmpty) return '';

  final parts = normalized
      .split('+')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return normalized;

  final canonical = <String>[];
  for (final part in parts) {
    final converted = _canonicalComparableStrengthPart(part);
    if (converted == null) return normalized;
    canonical.add(converted);
  }
  return canonical.join('+');
}

bool medicineStrengthEquivalent(String left, String right) {
  final a = medicineStrengthIdentityKey(left);
  final b = medicineStrengthIdentityKey(right);
  return a.isNotEmpty && b.isNotEmpty && a == b;
}

String? _canonicalComparableStrengthPart(String value) {
  final percent = RegExp(
    r'^(\d+(?:[.]\d+)?)%(?:(w)/(v)|(w)/(w)|(v)/(v))?$',
  ).firstMatch(value);
  if (percent != null) {
    final amount = double.tryParse(percent.group(1)!);
    if (amount == null || !amount.isFinite || amount <= 0) return null;
    if (percent.group(2) == 'w' && percent.group(3) == 'v') {
      // x% w/v = x grams / 100 mL = x*10 mg/mL.
      return 'mass-volume:${_strengthNumberKey(amount * 10)}';
    }
    if (percent.group(4) == 'w' && percent.group(5) == 'w') {
      // x% w/w = x grams / 100 grams = x/100 mg/mg.
      return 'mass-mass:${_strengthNumberKey(amount / 100)}';
    }
    if (percent.group(6) == 'v' && percent.group(7) == 'v') {
      return 'volume-volume:${_strengthNumberKey(amount / 100)}';
    }
    // The basis of a bare percentage is not safe to infer.
    return 'percent:${_strengthNumberKey(amount)}';
  }

  final ratio = RegExp(
    r'^(\d+(?:[.]\d+)?)(mcg|mg|gm|g|ml|l)'
    r'(?:/(\d+(?:[.]\d+)?)?(mcg|mg|gm|g|ml|l))?$',
  ).firstMatch(value);
  if (ratio == null) return null;

  final numeratorAmount = double.tryParse(ratio.group(1)!);
  final numeratorUnit = ratio.group(2)!;
  if (numeratorAmount == null ||
      !numeratorAmount.isFinite ||
      numeratorAmount <= 0) {
    return null;
  }

  final denominatorUnit = ratio.group(4);
  if (denominatorUnit == null) {
    final mass = _massMilligrams(numeratorAmount, numeratorUnit);
    return mass == null ? null : 'mass:${_strengthNumberKey(mass)}';
  }

  final denominatorAmount = ratio.group(3) == null
      ? 1.0
      : double.tryParse(ratio.group(3)!);
  if (denominatorAmount == null ||
      !denominatorAmount.isFinite ||
      denominatorAmount <= 0) {
    return null;
  }

  final numeratorMass = _massMilligrams(numeratorAmount, numeratorUnit);
  final numeratorVolume = _volumeMillilitres(numeratorAmount, numeratorUnit);
  final denominatorMass = _massMilligrams(
    denominatorAmount,
    denominatorUnit,
  );
  final denominatorVolume = _volumeMillilitres(
    denominatorAmount,
    denominatorUnit,
  );

  if (numeratorMass != null && denominatorVolume != null) {
    return 'mass-volume:${_strengthNumberKey(numeratorMass / denominatorVolume)}';
  }
  if (numeratorMass != null && denominatorMass != null) {
    return 'mass-mass:${_strengthNumberKey(numeratorMass / denominatorMass)}';
  }
  if (numeratorVolume != null && denominatorVolume != null) {
    return 'volume-volume:${_strengthNumberKey(numeratorVolume / denominatorVolume)}';
  }
  return null;
}

double? _massMilligrams(double amount, String unit) {
  switch (unit) {
    case 'mcg':
      return amount / 1000;
    case 'mg':
      return amount;
    case 'gm':
    case 'g':
      return amount * 1000;
  }
  return null;
}

double? _volumeMillilitres(double amount, String unit) {
  switch (unit) {
    case 'ml':
      return amount;
    case 'l':
      return amount * 1000;
  }
  return null;
}

String _strengthNumberKey(double value) {
  var text = value.toStringAsFixed(12);
  text = text.replaceFirst(RegExp(r'[.]?0+$'), '');
  return text == '-0' ? '0' : text;
}
