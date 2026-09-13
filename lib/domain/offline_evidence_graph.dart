import 'dart:math';

import 'medicine_understanding.dart';
import 'regulatory_medicine_code.dart';
import 'search.dart';

/// A bounded correlation graph over OCR/barcode frames.
///
/// Adjacent video frames are often almost the same observation. Counting each
/// frame as independent evidence makes long videos look more certain than one
/// good photograph. This graph connects near-duplicate observations and exposes
/// one best representative per connected component. Machine-readable medicine
/// identifiers are first-class evidence, but a shared GTIN proves only product
/// identity — not that two different pack sides are the same visual observation.
class OfflineEvidenceGroup {
  const OfflineEvidenceGroup({
    required this.representative,
    required this.support,
    required this.maxQuality,
  });

  final MedicineFrameEvidence representative;
  final int support;
  final double maxQuality;
}

class OfflineEvidenceGraph {
  const OfflineEvidenceGraph({
    required this.groups,
    required this.observedFrames,
  });

  final List<OfflineEvidenceGroup> groups;
  final int observedFrames;

  int get independentObservations => groups.length;
  int get correlatedDuplicates => max(0, observedFrames - groups.length);

  /// Diagnostic only. This is not a probability and never authorizes writes.
  double get independenceRatio => observedFrames <= 0
      ? 0
      : (groups.length / observedFrames).clamp(0, 1).toDouble();
}

OfflineEvidenceGraph buildOfflineEvidenceGraph(
  Iterable<MedicineFrameEvidence> source, {
  int maxFrames = 12,
}) {
  final frames = source
      .where(_hasGraphEvidence)
      .take(max(1, maxFrames))
      .toList(growable: false);
  if (frames.isEmpty) {
    return const OfflineEvidenceGraph(
      groups: <OfflineEvidenceGroup>[],
      observedFrames: 0,
    );
  }

  final signatures = frames.map(_FrameSignature.fromFrame).toList();
  final parent = List<int>.generate(frames.length, (index) => index);

  int root(int value) {
    var node = value;
    while (parent[node] != node) {
      parent[node] = parent[parent[node]];
      node = parent[node];
    }
    return node;
  }

  void union(int left, int right) {
    final a = root(left);
    final b = root(right);
    if (a != b) parent[b] = a;
  }

  // O(n²) is intentional and bounded: at most twelve frames enter this graph.
  // It avoids maintaining another mutable index and keeps isolate behavior fully
  // deterministic.
  for (var left = 0; left < frames.length; left++) {
    for (var right = left + 1; right < frames.length; right++) {
      if (_frameCorrelation(signatures[left], signatures[right]) >= .82) {
        union(left, right);
      }
    }
  }

  final members = <int, List<int>>{};
  for (var index = 0; index < frames.length; index++) {
    members.putIfAbsent(root(index), () => <int>[]).add(index);
  }

  final groups = <OfflineEvidenceGroup>[];
  for (final indexes in members.values) {
    var best = indexes.first;
    var bestUtility = _frameUtility(frames[best], signatures[best]);
    var maxQuality = frames[best].quality.clamp(0, 1).toDouble();
    for (final index in indexes.skip(1)) {
      final quality = frames[index].quality.clamp(0, 1).toDouble();
      maxQuality = max(maxQuality, quality);
      final utility = _frameUtility(frames[index], signatures[index]);
      if (utility > bestUtility ||
          (utility == bestUtility &&
              frames[index].sequence < frames[best].sequence)) {
        best = index;
        bestUtility = utility;
      }
    }
    groups.add(
      OfflineEvidenceGroup(
        representative: frames[best],
        support: indexes.length,
        maxQuality: maxQuality,
      ),
    );
  }

  groups.sort((a, b) {
    final quality = b.maxQuality.compareTo(a.maxQuality);
    if (quality != 0) return quality;
    return a.representative.sequence.compareTo(b.representative.sequence);
  });
  return OfflineEvidenceGraph(
    groups: List<OfflineEvidenceGroup>.unmodifiable(groups),
    observedFrames: frames.length,
  );
}

bool _hasGraphEvidence(MedicineFrameEvidence frame) =>
    searchText(frame.text).isNotEmpty || frame.allBarcodes.isNotEmpty;

class _FrameSignature {
  const _FrameSignature(
    this.tokens,
    this.trigrams,
    this.richness,
    this.machine,
  );

  factory _FrameSignature.fromFrame(MedicineFrameEvidence frame) {
    final normalized = searchText(frame.text);
    final tokens = normalized
        .split(' ')
        .where((value) => value.length >= 2)
        .take(48)
        .toSet();
    final compact = normalized.replaceAll(' ', '');
    final trigrams = <String>{};
    for (
      var index = 0;
      index + 3 <= compact.length && trigrams.length < 72;
      index++
    ) {
      trigrams.add(compact.substring(index, index + 3));
    }
    final richness = (tokens.length / 24).clamp(0, 1).toDouble();
    return _FrameSignature(
      tokens,
      trigrams,
      richness,
      _MachineAnchor.fromFrame(frame),
    );
  }

  final Set<String> tokens;
  final Set<String> trigrams;
  final double richness;
  final _MachineAnchor machine;

  bool get hasText => tokens.isNotEmpty || trigrams.isNotEmpty;
}

class _MachineAnchor {
  const _MachineAnchor({
    required this.gtins,
    required this.lots,
    required this.serials,
  });

  factory _MachineAnchor.fromFrame(MedicineFrameEvidence frame) {
    final gtins = <String>{};
    final lots = <String>{};
    final serials = <String>{};
    for (final raw in frame.allBarcodes.take(8)) {
      final structured = parseRegulatoryMedicineCode(raw);
      if (structured != null) {
        if (structured.gtin.isNotEmpty) gtins.add(structured.gtin);
        final lot = searchText(structured.batchLot);
        if (lot.isNotEmpty) lots.add(lot);
        final serial = searchText(structured.serial);
        if (serial.isNotEmpty) serials.add(serial);
      }
      final plain = _canonicalPlainGtin(raw);
      if (plain.isNotEmpty) gtins.add(plain);
    }
    return _MachineAnchor(gtins: gtins, lots: lots, serials: serials);
  }

  final Set<String> gtins;
  final Set<String> lots;
  final Set<String> serials;

  bool get hasTrustedProductId => gtins.isNotEmpty;
}

double _frameUtility(MedicineFrameEvidence frame, _FrameSignature signature) {
  final quality = frame.quality.clamp(0, 1).toDouble();
  final machineBonus = signature.machine.hasTrustedProductId ? .10 : 0.0;
  return (quality * .60 + signature.richness * .30 + machineBonus)
      .clamp(0, 1)
      .toDouble();
}

double _frameCorrelation(_FrameSignature left, _FrameSignature right) {
  final leftMachine = left.machine;
  final rightMachine = right.machine;

  // Two independently checksum/GS1-validated product identifiers that disagree
  // are a hard anti-correlation boundary. Similar box artwork cannot merge two
  // different medicines into one evidence component.
  if (leftMachine.gtins.isNotEmpty && rightMachine.gtins.isNotEmpty) {
    final shared = leftMachine.gtins.intersection(rightMachine.gtins);
    if (shared.isEmpty) return 0;

    // A shared product may still be a different physical lot/serial. Preserve
    // that contradiction instead of hiding it behind near-identical packaging.
    if (_explicitAnchorConflict(leftMachine.lots, rightMachine.lots) ||
        _explicitAnchorConflict(leftMachine.serials, rightMachine.serials)) {
      return 0;
    }
  }

  final tokenSimilarity = _jaccard(left.tokens, right.tokens);
  final trigramSimilarity = _jaccard(left.trigrams, right.trigrams);
  final visualTextSimilarity = max(tokenSimilarity, trigramSimilarity * .96);

  if (leftMachine.gtins.isNotEmpty && rightMachine.gtins.isNotEmpty) {
    // Same GTIN plus no OCR on either frame is a repeated barcode observation.
    if (!left.hasText && !right.hasText) return .99;
    // Same GTIN is not sufficient to collapse front/back complementary views.
    // It only strengthens an already-similar visual observation.
    if (visualTextSimilarity >= .52) {
      return max(.90, visualTextSimilarity);
    }
  }
  return visualTextSimilarity;
}

bool _explicitAnchorConflict(Set<String> left, Set<String> right) =>
    left.isNotEmpty && right.isNotEmpty && left.intersection(right).isEmpty;

String _canonicalPlainGtin(String raw) {
  final value = raw.trim();
  if (!RegExp(r'^\d+$').hasMatch(value) ||
      !const {8, 12, 13, 14}.contains(value.length) ||
      !_validGtin(value)) {
    return '';
  }
  return value.padLeft(14, '0');
}

bool _validGtin(String digits) {
  var sum = 0;
  for (
    var index = digits.length - 2, position = 1;
    index >= 0;
    index--, position++
  ) {
    sum += int.parse(digits[index]) * (position.isOdd ? 3 : 1);
  }
  return (10 - sum % 10) % 10 == int.parse(digits[digits.length - 1]);
}

double _jaccard(Set<String> left, Set<String> right) {
  if (left.isEmpty || right.isEmpty) return 0;
  var intersection = 0;
  final smaller = left.length <= right.length ? left : right;
  final larger = identical(smaller, left) ? right : left;
  for (final value in smaller) {
    if (larger.contains(value)) intersection++;
  }
  if (intersection == 0) return 0;
  return intersection / (left.length + right.length - intersection);
}
