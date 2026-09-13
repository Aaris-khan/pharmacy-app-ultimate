import 'dart:math';

import '../domain/local_ai_protocol.dart';
import '../domain/local_context_budget.dart';
import '../domain/local_scan_handoff.dart';
import '../domain/medicine_understanding.dart';

/// A scan is already a fresh prompt, never a continuing chat. Native context
/// admission is retried with a smaller evidence window. Empty/malformed model
/// output gets one bounded repair attempt, then safely falls back to the original
/// deterministic draft instead of allowing an optional Local AI reviewer to
/// break the medicine preview.
Future<MedicineScanDraft> runLocalScanTurn({
  required MedicineScanDraft draft,
  required int sourceLimit,
  required int outputTokens,
  required Future<String> Function(LocalScanHandoff handoff, int outputTokens)
  generate,
  required void Function() checkCurrent,
  void Function(LocalScanHandoff handoff, int attempt)? onAttempt,
}) async {
  if (outputTokens < 1 || outputTokens > 1000) {
    throw const FormatException('Invalid scan output budget.');
  }

  var limit = sourceLimit;
  var budget = outputTokens;
  var structuredFailures = 0;
  var handoff = LocalScanHandoff.fromDraft(draft, sourceLimit: limit);

  LocalScanHandoff? smallerEvidence() {
    while (limit > 256) {
      final nextLimit = max(256, limit ~/ 2);
      if (nextLimit == limit) break;
      limit = nextLimit;
      final candidate = LocalScanHandoff.fromDraft(draft, sourceLimit: limit);
      // Sparse/short labels can remain byte-identical through several nominal
      // limits. Skip those steps without spending another model generation.
      if (candidate.userPayload.length < handoff.userPayload.length) {
        return candidate;
      }
    }
    return null;
  }

  for (var attempt = 0; attempt < 4; attempt++) {
    checkCurrent();
    // Barcode-only or otherwise text-free deterministic drafts have nothing for
    // a text-only local model to verify. Preserve the safe draft immediately.
    if (handoff.sourceCharacters == 0) return draft;

    onAttempt?.call(handoff, attempt);
    checkCurrent();
    try {
      final raw = await generate(handoff, budget);
      checkCurrent();

      // Never feed an empty successful transport result into jsonDecode(). Tiny
      // GGUFs can emit EOS immediately and some chat-template parsers can also
      // temporarily withhold content. One smaller-evidence retry is useful; a
      // second empty/invalid answer proves this optional reviewer has no safe
      // contribution for the current pack, so keep deterministic extraction.
      if (raw.trim().isEmpty) {
        structuredFailures++;
        final smaller = structuredFailures < 2 ? smallerEvidence() : null;
        if (smaller != null) {
          handoff = smaller;
          continue;
        }
        return draft;
      }

      try {
        return validateLocalScan(
          draft,
          localJsonObject(raw),
          sourceLimit: limit,
        );
      } on FormatException {
        structuredFailures++;
        final smaller = structuredFailures < 2 ? smallerEvidence() : null;
        if (smaller != null) {
          handoff = smaller;
          continue;
        }
        // Fail closed to the evidence-backed deterministic result. Never repair
        // truncated JSON, invent missing braces, or trust malformed model prose.
        return draft;
      }
    } on LocalContextBudgetFailure catch (error) {
      checkCurrent();
      final available = error.contextTokens - error.inputTokens - 32;
      if (available >= min(outputTokens, 256) && available < budget) {
        budget = available;
        continue;
      }

      // Character selection is only a coarse reduction. The next native
      // admission check remains authoritative for this model's tokenizer.
      final smaller = smallerEvidence();
      if (smaller == null) return draft;
      handoff = smaller;
    }
  }

  // Local AI is an optional verifier, never the owner of the scanner's base
  // evidence. Exhausting its bounded repair/admission attempts must not surface
  // as a raw parsing error or discard the already-valid offline draft.
  return draft;
}
