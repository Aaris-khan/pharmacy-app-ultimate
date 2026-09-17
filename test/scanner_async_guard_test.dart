import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/ui/scanner_screen.dart';

void main() {
  test('scanner wait deadline does not cancel the active OCR lease', () async {
    final active = Completer<bool>();

    final completed = await scannerWorkCompletedWithin(
      active.future,
      timeout: const Duration(milliseconds: 15),
    );

    expect(completed, isFalse);
    expect(active.isCompleted, isFalse);

    active.complete(true);
    await expectLater(active.future, completion(isTrue));
  });

  test('scanner wait accepts idle and already completed work', () async {
    expect(
      await scannerWorkCompletedWithin<void>(
        null,
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
    expect(
      await scannerWorkCompletedWithin(
        Future<bool>.value(true),
        timeout: const Duration(milliseconds: 15),
      ),
      isTrue,
    );
  });
}
