import 'package:aaris_pharmacy/domain/local_context_budget.dart';
import 'package:aaris_pharmacy/domain/medicine_understanding.dart';
import 'package:aaris_pharmacy/services/local_scan_turn.dart';
import 'package:flutter_test/flutter_test.dart';

const _draft = MedicineScanDraft(
  fields: <String, ExtractedMedicineField>{
    'name': ExtractedMedicineField(
      value: 'MOXIYES-D',
      confidence: .91,
      support: 1,
    ),
    'brand': ExtractedMedicineField(
      value: 'MOXIYES-D',
      confidence: .91,
      support: 1,
    ),
    'form': ExtractedMedicineField(
      value: 'Drops',
      confidence: .84,
      support: 1,
    ),
    'expiry': ExtractedMedicineField(
      value: '2027-04',
      confidence: .88,
      support: 1,
    ),
  },
  rawText: 'MOXIYES-D\n10 ml\nMFG 05/2026\nEXP 04/2027\nEye Drops',
  searchKeywords: 'moxiyes d eye drops',
  frameSequences: <int>[0],
  expiryMonthOnly: true,
  mfgMonthOnly: true,
  overallConfidence: .86,
);

void main() {
  test('empty local-model output never reaches JSON decode or breaks preview', () async {
    var calls = 0;

    final result = await runLocalScanTurn(
      draft: _draft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async {
        calls++;
        return '';
      },
    );

    expect(identical(result, _draft), isTrue);
    expect(calls, greaterThanOrEqualTo(1));
    expect(calls, lessThanOrEqualTo(2));
  });

  test('truncated JSON fails closed to deterministic scan evidence', () async {
    var calls = 0;

    final result = await runLocalScanTurn(
      draft: _draft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async {
        calls++;
        return '{"fields":{"brand":';
      },
    );

    expect(identical(result, _draft), isTrue);
    expect(calls, greaterThanOrEqualTo(1));
    expect(calls, lessThanOrEqualTo(2));
  });

  test('native context exhaustion preserves the offline draft', () async {
    final result = await runLocalScanTurn(
      draft: _draft,
      sourceLimit: 5000,
      outputTokens: 512,
      checkCurrent: () {},
      generate: (handoff, outputTokens) async {
        throw const LocalContextBudgetFailure(
          inputTokens: 2000,
          outputTokens: 512,
          contextTokens: 2048,
        );
      },
    );

    expect(identical(result, _draft), isTrue);
  });
}
