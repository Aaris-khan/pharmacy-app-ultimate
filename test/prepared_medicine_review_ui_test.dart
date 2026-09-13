import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('durable intake shows one simple preview and one-at-a-time review', () {
    final panel = File('lib/ui/medicine_intake_panel.dart').readAsStringSync();
    final review = File(
      'lib/ui/prepared_medicine_review_screen.dart',
    ).readAsStringSync();

    expect(panel, contains('PreparedMedicineReviewScreen('));
    expect(panel, contains('final preview = job.drafts.isEmpty'));
    expect(panel, isNot(contains('job.drafts.take(3)')));
    expect(panel, contains('Next reviews them one at a time.'));

    expect(review, contains("'Scanned medicine'"));
    expect(review, contains("'Next'"));
    expect(review, contains('matching medicine'));
    expect(review, contains('similar medicine'));
    expect(review, contains('rankIntakeMatches('));
    expect(review, isNot(contains('AUTO-FILLED FACTS')));
    expect(review, isNot(contains('SCAN REVIEW')));
    expect(review, isNot(contains('trusted physical-lot evidence')));
    expect(review, isNot(contains('source-verified Local AI')));
  });
}
