import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('completion feedback survives closing the source route', () {
    final design = File('lib/ui/design.dart').readAsStringSync();
    final editor = File('lib/ui/editor_screen.dart').readAsStringSync();
    final backup = File('lib/ui/backup_screen.dart').readAsStringSync();
    final supplier = File('lib/ui/supplier_editor.dart').readAsStringSync();

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
    expect(
      supplier,
      contains('final messenger = ScaffoldMessenger.maybeOf(context);'),
    );
    expect(supplier, contains('showSavedWithMessenger('));
    expect(supplier, contains('if (!completed && mounted)'));

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
