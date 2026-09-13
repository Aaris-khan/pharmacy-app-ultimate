import 'medicine_scan_commit.dart';
import 'medicine_understanding.dart';
import 'regulatory_medicine_code.dart';
import 'search.dart';

enum MedicineScanFocus {
  ready,
  imageQuality,
  medicineIdentity,
  composition,
  strength,
  dosageForm,
  lotDetails,
  machineCode,
  review,
}

class MedicineScanGuidance {
  const MedicineScanGuidance({
    required this.focus,
    required this.message,
    required this.readyForAutomaticHandoff,
  });

  final MedicineScanFocus focus;
  final String message;
  final bool readyForAutomaticHandoff;
}

class MedicineScanEvidenceWindow {
  const MedicineScanEvidenceWindow({
    required this.frames,
    required this.startedNewPack,
  });

  final List<MedicineFrameEvidence> frames;
  final bool startedNewPack;
}

/// Maintains the evidence window for the explicit "scan one pack" camera lane.
///
/// A validated machine identifier is a safe session-boundary signal. If a new
/// frame proves that the camera is now looking at a different GTIN, or at an
/// explicitly different lot/serial of the same product, old OCR is retired
/// instead of being allowed to contaminate the new pack. Frames without a trusted
/// machine anchor cannot force a reset; ambiguity remains review-only.
MedicineScanEvidenceWindow mergeSinglePackMedicineEvidence(
  Iterable<MedicineFrameEvidence> existing,
  MedicineFrameEvidence incoming, {
  int maxFrames = 18,
}) {
  final prior = existing.take(maxFrames).toList(growable: false);
  final incomingAnchor = _machineAnchor(incoming);
  _ScanMachineAnchor? currentAnchor;
  for (final frame in prior.reversed) {
    final candidate = _machineAnchor(frame);
    if (candidate.gtin.isNotEmpty) {
      currentAnchor = candidate;
      break;
    }
  }

  final switched = currentAnchor != null &&
      incomingAnchor.gtin.isNotEmpty &&
      _differentPhysicalPack(currentAnchor, incomingAnchor);
  if (switched) {
    return MedicineScanEvidenceWindow(
      frames: List<MedicineFrameEvidence>.unmodifiable([incoming]),
      startedNewPack: true,
    );
  }

  final values = <MedicineFrameEvidence>[...prior, incoming];
  if (values.length > maxFrames) {
    values.removeRange(0, values.length - maxFrames);
  }
  return MedicineScanEvidenceWindow(
    frames: List<MedicineFrameEvidence>.unmodifiable(values),
    startedNewPack: false,
  );
}

/// Chooses the highest-value next observation for a one-pack camera session.
///
/// This is active perception, not another medicine classifier. It never fills a
/// field and never authorizes an inventory write. It only decides whether the
/// current evidence is sufficient to move to the normal review pipeline or what
/// physical pack region would reduce uncertainty most. At most one targeted
/// follow-up still is requested; after that Aaris fails closed to review.
MedicineScanGuidance nextBestMedicineScanGuidance(
  MedicineScanDraft? draft, {
  double evidenceQuality = 1,
  String physicalGuidance = '',
  int captureAttempts = 0,
}) {
  if (draft == null) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.medicineIdentity,
      message: 'Show the medicine name or barcode clearly.',
      readyForAutomaticHandoff: false,
    );
  }

  // Physical focus/lighting is an independent channel. Fix it before asking a
  // semantic question because another view of the same blurry label adds little
  // information. MedicineFrameEvidence.quality is intentionally physical only.
  if (physicalGuidance.trim().isNotEmpty && evidenceQuality < .48) {
    return MedicineScanGuidance(
      focus: MedicineScanFocus.imageQuality,
      message: physicalGuidance.trim(),
      readyForAutomaticHandoff: false,
    );
  }

  final machineIdentity = _trustedMachineReadableIdentity(draft.barcode);
  if (machineIdentity) {
    final trustedBatch = _trustedField(draft, 'batchNumber', .82);
    final trustedExpiry = _trustedField(draft, 'expiry', .78);

    // A checksum/GS1-valid GTIN is authoritative product identity, but stock is
    // lot-aware. Give the first deliberate still one chance to collect Batch +
    // EXP instead of ending the session at product identity alone. After the
    // bounded second still, hand off to review rather than trapping the user.
    if (captureAttempts < 2 && (!trustedBatch || !trustedExpiry)) {
      return const MedicineScanGuidance(
        focus: MedicineScanFocus.lotDetails,
        message: 'Product found. Now show Batch/Lot and EXP clearly.',
        readyForAutomaticHandoff: false,
      );
    }
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.ready,
      message: 'Medicine code captured. Review the details.',
      readyForAutomaticHandoff: true,
    );
  }

  // One targeted recapture is the maximum. A camera loop must never hold the
  // pharmacist hostage trying to manufacture certainty from missing evidence.
  if (captureAttempts >= 2) {
    return MedicineScanGuidance(
      focus: MedicineScanFocus.review,
      message: draft.overallConfidence >= .78
          ? 'Review the captured details before saving.'
          : 'Some details are still uncertain. Review them before saving.',
      readyForAutomaticHandoff: true,
    );
  }

  final salt = draft.field('salt');
  if (_weakOrConflicted(salt, .78)) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.composition,
      message: 'Show the Composition / Each tablet contains side clearly.',
      readyForAutomaticHandoff: false,
    );
  }

  final strength = draft.field('strength');
  if (_weakOrConflicted(strength, .78)) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.strength,
      message: 'Show the printed strength, for example 500 mg or 5 mg/ml.',
      readyForAutomaticHandoff: false,
    );
  }

  final brand = draft.field('brand');
  final name = draft.field('name');
  if (_weakOrConflicted(brand, .78) && _weakOrConflicted(name, .78)) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.medicineIdentity,
      message: 'Show the front side with the medicine or brand name.',
      readyForAutomaticHandoff: false,
    );
  }

  final form = draft.field('form');
  if (_weakOrConflicted(form, .78)) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.dosageForm,
      message: 'Show where Tablet, Capsule, Syrup, Injection or form is printed.',
      readyForAutomaticHandoff: false,
    );
  }

  final identityIssue = scanQuickIdentityIssue(draft);
  if (identityIssue.isNotEmpty) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.machineCode,
      message: 'Show the barcode/DataMatrix or another clear identity side.',
      readyForAutomaticHandoff: false,
    );
  }

  final mfg = draft.field('mfg');
  final expiry = draft.field('expiry');
  final batch = draft.field('batchNumber');
  if (mfg.conflicted || expiry.conflicted || batch.conflicted) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.lotDetails,
      message: 'Show Batch/Lot, MFG and EXP together in one clear view.',
      readyForAutomaticHandoff: false,
    );
  }

  // Expiry is especially valuable for pharmacy stock lifecycle. It is optional
  // for manual editing, but a first camera still should actively seek it before
  // an automatic handoff when the rest of identity is already coherent.
  if (!_trustedField(draft, 'expiry', .78)) {
    return const MedicineScanGuidance(
      focus: MedicineScanFocus.lotDetails,
      message: 'Show the EXP/Expiry date clearly.',
      readyForAutomaticHandoff: false,
    );
  }

  return const MedicineScanGuidance(
    focus: MedicineScanFocus.ready,
    message: 'Details captured. Continue to review.',
    readyForAutomaticHandoff: true,
  );
}

bool _weakOrConflicted(ExtractedMedicineField field, double minimum) =>
    field.value.trim().isEmpty || field.conflicted || field.confidence < minimum;

bool _trustedField(MedicineScanDraft draft, String key, double minimum) {
  final field = draft.field(key);
  return field.value.trim().isNotEmpty &&
      !field.conflicted &&
      field.confidence >= minimum;
}

bool _trustedMachineReadableIdentity(String raw) =>
    _canonicalTrustedGtin(raw).isNotEmpty;

class _ScanMachineAnchor {
  const _ScanMachineAnchor({
    required this.gtin,
    required this.lot,
    required this.serial,
  });

  final String gtin;
  final String lot;
  final String serial;
}

_ScanMachineAnchor _machineAnchor(MedicineFrameEvidence frame) {
  var gtin = '';
  var lot = '';
  var serial = '';
  for (final raw in frame.allBarcodes.take(8)) {
    final structured = parseRegulatoryMedicineCode(raw);
    if (structured != null) {
      if (gtin.isEmpty && structured.gtin.isNotEmpty) gtin = structured.gtin;
      if (lot.isEmpty && structured.batchLot.isNotEmpty) {
        lot = searchText(structured.batchLot);
      }
      if (serial.isEmpty && structured.serial.isNotEmpty) {
        serial = searchText(structured.serial);
      }
    }
    if (gtin.isEmpty) gtin = _canonicalTrustedGtin(raw);
  }
  return _ScanMachineAnchor(gtin: gtin, lot: lot, serial: serial);
}

bool _differentPhysicalPack(_ScanMachineAnchor left, _ScanMachineAnchor right) {
  if (left.gtin != right.gtin) return true;
  if (left.lot.isNotEmpty && right.lot.isNotEmpty && left.lot != right.lot) {
    return true;
  }
  if (left.serial.isNotEmpty &&
      right.serial.isNotEmpty &&
      left.serial != right.serial) {
    return true;
  }
  return false;
}

String _canonicalTrustedGtin(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  final structured = parseRegulatoryMedicineCode(value);
  if (structured != null && structured.gtin.isNotEmpty) return structured.gtin;

  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits != value || !const {8, 12, 13, 14}.contains(digits.length)) {
    return '';
  }
  var sum = 0;
  for (
    var index = digits.length - 2, position = 1;
    index >= 0;
    index--, position++
  ) {
    sum += int.parse(digits[index]) * (position.isOdd ? 3 : 1);
  }
  if ((10 - sum % 10) % 10 != int.parse(digits[digits.length - 1])) {
    return '';
  }
  return digits.padLeft(14, '0');
}
