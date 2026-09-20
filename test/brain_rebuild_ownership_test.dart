import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Brain command state stays off the rendered AI hub rebuild path', () {
    final source = File('lib/ui/brain_screen.dart').readAsStringSync();

    expect(
      source,
      contains('Widget build(BuildContext context) => AiScreen('),
      reason: 'AiScreen owns the rendered AI interaction state.',
    );
    expect(
      source,
      contains('void _updateCommandState(VoidCallback update)'),
      reason: 'Brain command/session state should mutate without dirtying AiScreen.',
    );
    expect(
      source,
      isNot(contains('setState(')),
      reason:
          'BrainScreen command/session fields do not participate in build(); '
          'parent setState would rebuild the full AI hub without changing pixels.',
    );
  });
}
