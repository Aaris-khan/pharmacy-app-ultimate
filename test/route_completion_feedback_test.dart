import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('completion feedback survives closing the source route', () {
    final design = File('lib/ui/design.dart').readAsStringSync();
    final editor = File('lib/ui/editor_screen.dart').readAsStringSync();
    final backup = File('lib/ui/backup_screen.dart').readAsStringSync();
    final supplier = File('lib/ui/supplier_editor.dart').readAsStringSync();
    final scanner = File('lib/ui/scanner_screen.dart').readAsStringSync();
    final review = File('lib/ui/medicine_review_screen.dart').readAsStringSync();

    expect(design, contains('void showSavedWithMessenger('));
    expect(
      editor,
      contains('final messenger = ScaffoldMessenger.maybeOf(context);'),
    );
    expect(editor, contains('showSavedWithMessenger(messenger, message);'));
    expect(
      backup,
      contains('final messenger = ScaffoldMessenger.maybeOf(context);'),
    );
    expect(backup, contains('showSavedWithMessenger('));
    expect(backup, contains('var completed = false;'));
    expect(backup, contains('completed = true;'));
    expect(backup, contains('if (!completed && mounted)'));
    expect(
      backup,
      contains('if (_sharing || _reading || _restoring) return;'),
    );
    expect(
      backup,
      contains('if (_reading || _sharing || _restoring) return;'),
    );
    expect(
      backup,
      contains('onPressed: _sharing || _reading || _restoring'),
    );
    expect(
      backup,
      contains('onPressed: _reading || _sharing || _restoring'),
    );
    expect(
      backup,
      contains('if (review == null || _restoring || _sharing || _reading || _restorePromptOpen) return;'),
    );

    // Cancelling the picker may preserve the currently reviewed backup. Once a
    // different file is actually selected, however, its predecessor must stop
    // being restorable before the replacement is parsed or compared.
    final pickerCancelGuard =
        backup.indexOf('if (!mounted || picked == null) return;');
    final replacementFile = backup.indexOf(
      '_pickedFile = picked;',
      pickerCancelGuard,
    );
    final retireOldReview = backup.indexOf(
      '_review = null;',
      replacementFile,
    );
    final reviewReplacement = backup.indexOf(
      'final review = await _reviewFile(picked);',
      retireOldReview,
    );
    expect(pickerCancelGuard, greaterThanOrEqualTo(0));
    expect(replacementFile, greaterThan(pickerCancelGuard));
    expect(retireOldReview, greaterThan(replacementFile));
    expect(reviewReplacement, greaterThan(retireOldReview));
    expect(
      supplier,
      contains('final messenger = ScaffoldMessenger.maybeOf(context);'),
    );
    expect(supplier, contains('showSavedWithMessenger('));
    expect(supplier, contains('if (!completed && mounted)'));
    expect(
      scanner,
      contains('if (mounted && !_closed && !_leaving) {'),
    );
    expect(
      scanner,
      isNot(contains('if (mounted && !_closed) setState(() => _capturing = false);')),
    );
    expect(review, contains('bool _leaving = false;'));
    expect(review, contains('void _finishReview()'));
    expect(
      review,
      contains('if (mounted && !_leaving) setState(() => _busy = false);'),
    );
    expect(
      RegExp(r'Navigator\.pop\(context, true\);').allMatches(review).length,
      1,
      reason: 'Medicine review completion must pop only through _finishReview.',
    );

    expect(
      editor,
      isNot(contains('Navigator.pop(context);\n        showSaved(')),
    );
    expect(
      backup,
      isNot(contains('Navigator.pop(context);\n        showSaved(')),
    );
    expect(
      supplier,
      isNot(contains('Navigator.pop(context, supplier.id);\n      showSaved(')),
    );
  });
}
