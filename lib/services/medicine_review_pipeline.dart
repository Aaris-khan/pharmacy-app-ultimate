import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/medicine.dart';
import '../domain/medicine_resolution_v2.dart';
import '../domain/medicine_scan_commit.dart';
import '../domain/medicine_understanding.dart';
import 'ai_service.dart';
import 'canonical_medicine_catalog_service.dart';
import 'cloud_scan_ai_service.dart';
import 'local_ai_service.dart';
import 'local_brain_route_policy.dart';
import 'offline_recognition_memory_service.dart';

enum MedicineReviewInputKind { prepared, localEvidence, cloudEvidence }

class MedicineReviewInput {
  const MedicineReviewInput._({
    required this.kind,
    required this.evidence,
    required this.preparedDrafts,
    required this.autoSaveReadyDrafts,
  });

  const MedicineReviewInput.prepared(List<MedicineScanDraft> drafts)
      : this._(
          kind: MedicineReviewInputKind.prepared,
          evidence: const <MedicineFrameEvidence>[],
          preparedDrafts: drafts,
          autoSaveReadyDrafts: false,
        );

  const MedicineReviewInput.localEvidence(
    List<MedicineFrameEvidence> evidence, {
    bool autoSaveReadyDrafts = false,
  }) : this._(
          kind: MedicineReviewInputKind.localEvidence,
          evidence: evidence,
          preparedDrafts: const <MedicineScanDraft>[],
          autoSaveReadyDrafts: autoSaveReadyDrafts,
        );

  const MedicineReviewInput.cloudEvidence(List<MedicineFrameEvidence> evidence)
      : this._(
          kind: MedicineReviewInputKind.cloudEvidence,
          evidence: evidence,
          preparedDrafts: const <MedicineScanDraft>[],
          autoSaveReadyDrafts: false,
        );

  final MedicineReviewInputKind kind;
  final List<MedicineFrameEvidence> evidence;
  final List<MedicineScanDraft> preparedDrafts;
  final bool autoSaveReadyDrafts;
}

class PreparedMedicineReviewDraft {
  const PreparedMedicineReviewDraft({
    required this.draft,
    this.autoSaveVerifier,
  });

  final MedicineScanDraft draft;
  final ScanAutoSaveVerifier? autoSaveVerifier;
}

class MedicineReviewPreparation {
  const MedicineReviewPreparation({
    required this.drafts,
    this.ignoredFrames = 0,
    this.warning = '',
    this.routeLabel = '',
  });

  final List<PreparedMedicineReviewDraft> drafts;
  final int ignoredFrames;
  final String warning;
  final String routeLabel;
}

/// One authoritative preparation pipeline for every medicine-review entrypoint.
///
/// Capture sources may differ, but review semantics do not. Prepared durable
/// queue drafts are never reinterpreted. Local evidence keeps the existing
/// Offline Core + optional Local AI route. Explicit cloud evidence keeps the
/// strict bounded-evidence privacy boundary. All three routes return the same
/// review model consumed by one UI.
class MedicineReviewPipeline {
  MedicineReviewPipeline({CloudScanAiService? cloud})
      : _cloud = cloud ?? CloudScanAiService();

  final CloudScanAiService _cloud;
  final Map<String, MedicineScanDraft> _semanticCache =
      <String, MedicineScanDraft>{};

  void cancel() => _cloud.cancel();

  Future<MedicineReviewPreparation> prepare(
    MedicineReviewInput input,
    Iterable<Medicine> records,
  ) async {
    switch (input.kind) {
      case MedicineReviewInputKind.prepared:
        return MedicineReviewPreparation(
          drafts: List<PreparedMedicineReviewDraft>.unmodifiable(
            input.preparedDrafts.map(
              (draft) => PreparedMedicineReviewDraft(draft: draft),
            ),
          ),
        );
      case MedicineReviewInputKind.localEvidence:
        _validateEvidence(input.evidence);
        return _prepareLocal(input.evidence, records);
      case MedicineReviewInputKind.cloudEvidence:
        _validateEvidence(input.evidence);
        return _prepareCloud(input.evidence, records);
    }
  }

  void _validateEvidence(List<MedicineFrameEvidence> evidence) {
    if (evidence.isEmpty ||
        evidence.every(
          (item) => item.text.trim().isEmpty && item.barcode.trim().isEmpty,
        )) {
      throw const FormatException('No barcode or medicine text was captured.');
    }
  }

  Future<MedicineReviewPreparation> _prepareLocal(
    List<MedicineFrameEvidence> evidence,
    Iterable<Medicine> records,
  ) async {
    final local = LocalAiService.instance;
    var warning = '';
    String? scanModelId;

    try {
      final brainEnabled = await LocalBrainRoutePolicy.enabled();
      if (brainEnabled) {
        scanModelId = await LocalBrainRoutePolicy.captureModelId(local);
        if (scanModelId == null) {
          warning = local.hasSelection && local.scannerEnabled && !local.scanReady
              ? 'Local AI is not ready yet. Aaris kept the on-device result.'
              : 'Local AI is unavailable right now. Aaris kept the on-device result.';
        }
      }
    } catch (_) {
      scanModelId = null;
      warning = 'Local AI could not be checked. Aaris kept the on-device result.';
    }

    final baseKnowledge = medicineKnowledgeFromRecords(records);
    final knowledge =
        await OfflineRecognitionMemoryService.instance.enrichKnowledge(
      baseKnowledge,
      evidence,
    );
    final catalogue = await CanonicalMedicineCatalogService.instance
        .candidatesForEvidence(evidence);

    final payload = await compute(
      understandMedicineEvidenceV2Message,
      <String, Object?>{
        'evidence': evidence
            .map((item) => item.toMessage())
            .toList(growable: false),
        'knowledge': knowledge
            .map((entry) => entry.toMessage())
            .toList(growable: false),
        'catalog': catalogue
            .map((entry) => entry.toMessage())
            .toList(growable: false),
      },
    );
    final understanding = MedicineUnderstandingResult.fromMessage(payload);
    if (understanding.drafts.isEmpty) {
      throw const FormatException(
        'No medicine could be read. Take a closer, steadier scan.',
      );
    }

    final prepared = <PreparedMedicineReviewDraft>[];
    var localBrainUsed = false;
    for (final original in understanding.drafts) {
      var draft = original;
      ScanAutoSaveVerifier? autoSaveVerifier;
      final leasedModelId = scanModelId;
      if (leasedModelId != null) {
        try {
          final mayReason = await LocalBrainRoutePolicy.mayReasonWith(
            local,
            leasedModelId,
          );
          if (!mayReason) {
            scanModelId = null;
            warning =
                'Local AI changed or became busy. Aaris kept the on-device result.';
          } else {
            final routedModelId = local.activeId;
            if (routedModelId == null) {
              scanModelId = null;
              warning =
                  'Local AI became unavailable. Aaris kept the on-device result.';
            } else {
              final key = '$routedModelId:${jsonEncode(original.toMessage())}';
              final candidate = _semanticCache[key] ??
                  await _understandWithRecovery(
                    local,
                    routedModelId,
                    original,
                  );
              final leaseStillValid =
                  await LocalBrainRoutePolicy.mayReasonWith(
                        local,
                        routedModelId,
                      ) &&
                      local.activeId == routedModelId;
              if (leaseStillValid) {
                draft = candidate;
                _semanticCache[key] = candidate;
                localBrainUsed = true;
                if (local.isModelScanVerified(routedModelId)) {
                  autoSaveVerifier = ScanAutoSaveVerifier.localAi;
                }
                scanModelId = routedModelId;
              } else {
                scanModelId = null;
                warning =
                    'Local AI changed during review. Aaris kept the on-device result.';
              }
            }
          }
        } catch (_) {
          warning =
              'Local AI could not finish this scan. Aaris kept the on-device result.';
        }
      }
      prepared.add(
        PreparedMedicineReviewDraft(
          draft: draft,
          autoSaveVerifier: autoSaveVerifier,
        ),
      );
    }

    return MedicineReviewPreparation(
      drafts: List<PreparedMedicineReviewDraft>.unmodifiable(prepared),
      ignoredFrames: understanding.ignoredFrames,
      warning: warning,
      routeLabel: localBrainUsed ? 'Aaris Brain' : 'Aaris Offline Core',
    );
  }

  Future<MedicineReviewPreparation> _prepareCloud(
    List<MedicineFrameEvidence> evidence,
    Iterable<Medicine> records,
  ) async {
    var warning = '';
    var routeLabel = '';
    AiConfiguration? config;
    try {
      config = await _cloud.requireConfiguration();
      routeLabel = _cloud.routeLabel(config);
    } catch (error) {
      warning =
          '${_cleanError(error)} Aaris kept the on-device result; nothing was sent externally.';
    }

    // With a configured cloud route, private inventory knowledge, learned OCR
    // corrections and catalogue hints stay out of the provider-bound draft.
    // Without a cloud route nothing can leave the device, so the strongest local
    // deterministic fallback may use those private local sources.
    final baseKnowledge = config == null
        ? medicineKnowledgeFromRecords(records)
        : const <MedicineKnowledgeEntry>[];
    final knowledge = config == null
        ? await OfflineRecognitionMemoryService.instance.enrichKnowledge(
            baseKnowledge,
            evidence,
          )
        : const <MedicineKnowledgeEntry>[];
    final catalogue = config == null
        ? await CanonicalMedicineCatalogService.instance
            .candidatesForEvidence(evidence)
        : const <CanonicalMedicineProduct>[];

    final payload = await compute(
      understandMedicineEvidenceV2Message,
      <String, Object?>{
        'evidence': evidence
            .map((item) => item.toMessage())
            .toList(growable: false),
        'knowledge': knowledge
            .map((item) => item.toMessage())
            .toList(growable: false),
        'catalog': catalogue
            .map((item) => item.toMessage())
            .toList(growable: false),
      },
    );
    final deterministic = MedicineUnderstandingResult.fromMessage(payload);
    if (deterministic.drafts.isEmpty) {
      throw const FormatException(
        'No medicine could be read. Take a closer, steadier scan.',
      );
    }

    final prepared = <PreparedMedicineReviewDraft>[];
    for (final original in deterministic.drafts) {
      if (config == null) {
        prepared.add(PreparedMedicineReviewDraft(draft: original));
        continue;
      }
      try {
        prepared.add(
          PreparedMedicineReviewDraft(
            draft: await _cloud.refine(config, original),
          ),
        );
      } catch (error) {
        prepared.add(PreparedMedicineReviewDraft(draft: original));
        warning =
            'Cloud AI could not safely validate every medicine. Aaris kept the on-device result. ${_cleanError(error)}';
      }
    }

    return MedicineReviewPreparation(
      drafts: List<PreparedMedicineReviewDraft>.unmodifiable(prepared),
      ignoredFrames: deterministic.ignoredFrames,
      warning: warning,
      routeLabel: routeLabel.isEmpty ? 'Aaris Offline Core' : routeLabel,
    );
  }

  bool _recoverableLocalTransportFailure(Object error) {
    if (error is FormatException || error is ArgumentError) return false;
    final message = error.toString().toLowerCase();
    if (message.contains('cancel') ||
        message.contains('busy') ||
        message.contains('select a local model') ||
        message.contains('selected model is missing') ||
        message.contains('model file is incomplete') ||
        message.contains('invalid model') ||
        message.contains('unsupported context')) {
      return false;
    }
    return message.contains('runtime') ||
        message.contains('transport') ||
        message.contains('connection') ||
        message.contains('closed') ||
        message.contains('isolate') ||
        message.contains('native');
  }

  bool _localLeaseContention(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('local ai is busy') ||
        message.contains('runtime is unavailable or still processing') ||
        message.contains('runtime is busy or closing') ||
        message.contains('runtime is still processing a failed model load');
  }

  Future<bool> _routeStillOwnsScan(
    LocalAiService local,
    String routedModelId,
  ) async =>
      await LocalBrainRoutePolicy.mayReasonWith(local, routedModelId) &&
      local.activeId == routedModelId;

  Future<MedicineScanDraft> _understandWithRecovery(
    LocalAiService local,
    String routedModelId,
    MedicineScanDraft draft,
  ) async {
    var transportRecovered = false;
    while (true) {
      try {
        return await local.understand(draft);
      } catch (error, stack) {
        if (_localLeaseContention(error)) {
          if (!await _routeStillOwnsScan(local, routedModelId)) {
            throw StateError('Local AI route changed while this scan was waiting.');
          }
          continue;
        }
        if (transportRecovered || !_recoverableLocalTransportFailure(error)) {
          Error.throwWithStackTrace(error, stack);
        }
        transportRecovered = true;
        while (true) {
          try {
            await local.suspend();
            break;
          } catch (suspendError) {
            if (!_localLeaseContention(suspendError) ||
                !await _routeStillOwnsScan(local, routedModelId)) {
              Error.throwWithStackTrace(error, stack);
            }
          }
        }
        if (!await _routeStillOwnsScan(local, routedModelId)) {
          throw StateError('Local AI route changed while recovering this scan.');
        }
      }
    }
  }

  String _cleanError(Object error) => error
      .toString()
      .replaceFirst(
        RegExp(r'^(Exception|FormatException|Bad state|StateError):\s*'),
        '',
      )
      .trim();
}
