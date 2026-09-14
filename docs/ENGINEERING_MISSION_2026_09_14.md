# Aaris Pharmacy engineering mission — 14 September 2026

## Scope and verification boundary

Target: warishakhan3548-hash/updating-repository, main.
Starting commit: 84210488d776c21bc6516da1d504d46fe815bf70.

The session exposes GitHub source/object/ref operations, but no shell, Dart,
Flutter, SQLite or Android runtime. Source inspection and focused JavaScript
reasoning checks are possible; Dart execution, query-plan measurements and device
acceptance are not. No CI dispatch, APK build, Flutter analysis or Flutter tests
are authorized. Checkpoints carry [skip ci] and use non-force ref updates.
Earlier documents' recorded test results are not evidence for this pass.

## Runtime ownership traced from source

- main creates PharmacyController(SqliteInventoryStorage); PharmacyApp owns
  application lifecycle and the operational supervisor. Visited tabs are retained.
- Inventory SQLite schema v3 stores medicine/sale JSON facts by ID, metadata,
  request receipts and a 200-event audit window. Controller commands feed
  InventoryMutation; storage revalidates facts and revision in one transaction.
  Expired, sold and warning screens derive state from those same records.
- ScannerScreen owns camera generation, one frame operation and capture drain.
  MedicineVisionService runs Latin, Devanagari and barcode detectors on the same
  image, retains line geometry and quarantines conflicting trusted machine codes.
- Photo/rapid/video imports enter MedicineIntakeService's durable staging DB.
  Native MainActivity samples bounded video windows; Dart OCR feeds the same
  understandMedicineEvidenceV2Message used by interactive MedicineReviewPipeline.
  Prepared queue drafts enter MedicineReviewScreen without reinterpreting identity.
- The V2 resolver composes MedicineUnderstandingEngine with indexed canonical
  products, layout/date/GS1/regulatory/confusion checks. SearchWorker owns the
  isolate search index. Canonical and adaptive databases contain knowledge,
  not parallel authoritative inventories.
- OfflineRecognitionMemoryService learns aliases only after human save. Identity
  includes salt, strength and form; salt corrections require same-frame identity.
  Current knowledge comes from active stock, capped at 12,000 unique entries.
- LocalAiService owns the selected model and one exclusive lease; LocalAiRuntime
  owns transport epoch, native cancellation, stall/deadline and context fallback.
  runLocalScanTurn and CloudScanAiService use validateLocalScan: source quotes,
  ingredient pairs and deterministic date ownership constrain suggestions.
- MedicineReviewScreen owns source/match generations and final confirm. Editor
  owns manual fields and row revision. Persistence is authoritative before
  optional recognition feedback; provider output does not directly write stock.
- Cloud chat and cloud scan currently duplicate request/envelope adaptation.
  Both use OS secure storage, HTTPS without embedded credentials and no redirects.
  Explicit cloud scan excludes private inventory/adaptive hints from its payload.

## Concrete audit findings guiding implementation

1. Chat response timeouts measure gaps between events, allowing a steady trickle
   (including a giant unterminated SSE line) to retain a turn indefinitely.
   Scan already bounds its body deadline; both transports need bounded raw bytes.
2. Provider wire formats are duplicated across chat and scan, with every unknown
   provider treated as OpenAI-compatible. Capabilities and provider identity need
   explicit validation and shared adapters without changing medicine validators.
3. Adaptive retrieval takes the first 256 rows by support before considering
   collisions. A competing identity omitted by LIMIT can make an ambiguous alias
   appear unique. Historical support is effectively unbounded (up to one million).
4. Native video sampling computes a low-resolution hash but currently emits every
   decoded bucket. Deduplication must preserve fine date/strength changes and
   never replace product evidence with a coarse visual-similarity guess.
5. Queue OCR bypasses the interactive review's missing-text/layout reconstruction.
   Detector geometry can therefore survive one entry path and be lost in another.
6. Core dates already support many requested numeric forms; named dates glued
   directly to MFG/EXP need contextual boundary review, not global OCR replacement.
7. Existing camera and local-runtime ownership are substantial; preserve them.
   Do not introduce overlapping recognizers, timers, runtime owners or inventory DBs.

## Research informing the changes

- Dart Future.timeout does not stop the source operation:
  https://api.dart.dev/dart-async/Future/timeout.html
- Stream.timeout measures time between events:
  https://api.dart.dev/dart-async/Stream/timeout.html
- SQLite ordered/multi-column index semantics:
  https://www.sqlite.org/queryplanner.html
- Provider contracts:
  https://platform.claude.com/docs/en/build-with-claude/streaming
  https://ai.google.dev/gemini-api/docs/text-generation
  https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

Implementation and final verification evidence will be appended to this record.
