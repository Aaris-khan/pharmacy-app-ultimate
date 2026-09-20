import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retained AI tab keeps streaming preview work offstage', () {
    final source = File('lib/ui/ai_screen.dart').readAsStringSync();

    expect(
      source,
      contains('final active = TickerMode.valuesOf(context).enabled;'),
      reason: 'AI screen must know when its retained IndexedStack tab is hidden.',
    );
    expect(
      source,
      contains('if (!_screenActive || _streamPreviewTimer != null) return;'),
      reason: 'Hidden AI tabs must not schedule token-preview timers.',
    );
    expect(
      source,
      contains('_scheduleStreamPreview(generation);'),
      reason: 'Token deltas should flow through the visibility-aware preview gate.',
    );
    expect(
      source,
      contains('_activeStreamBuffer = rawStream;'),
      reason: 'Inference must keep collecting text while the preview is paused.',
    );
    expect(
      source,
      isNot(contains('_streamPreviewTimer ??= Timer(')),
      reason: 'Token callbacks must not directly create offstage repaint timers.',
    );
    expect(
      source,
      contains('if (!_screenActive || !_followResponse || _scrollScheduled) return;'),
      reason: 'Offstage streaming must not schedule scroll frames either.',
    );
    expect(
      source,
      contains('''// If a response completed while this retained tab was hidden, catch the
    // viewport up once on return.'''),
      reason: 'Returning to Brain must reveal a response that completed offstage.',
    );
  });
}
