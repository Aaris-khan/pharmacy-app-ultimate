import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('standalone management routes protect the bottom system inset', () {
    const routes = <String, String>{
      'lib/ui/backup_screen.dart': 'Backup & Restore',
      'lib/ui/medicine_review_screen.dart': 'Confirm medicine',
      'lib/ui/profile_screen.dart': 'Activity & Undo',
      'lib/ui/removed_stock_screen.dart': 'Removed stock',
      'lib/ui/stats_screen.dart': 'Sold Medicine Tracker',
      'lib/ui/version_history_screen.dart': 'Version history',
    };

    for (final entry in routes.entries) {
      final source = File(entry.key).readAsStringSync();
      final escapedTitle = RegExp.escape(entry.value);
      final bodySafety = RegExp(
        "appBar:\\s*AppBar\\(title:\\s*const Text\\('$escapedTitle'\\)\\),"
        "\\s*body:\\s*SafeArea\\(\\s*top:\\s*false,",
        multiLine: true,
      );

      expect(
        source,
        matches(bodySafety),
        reason:
            '${entry.value} is a standalone route and must keep its body above '
            'the Android bottom navigation/gesture inset.',
      );
    }
  });

  test('dynamic app-bar management routes do not reapply the top inset', () {
    const routes = <String>[
      'lib/ui/editor_screen.dart',
      'lib/ui/search_screen.dart',
      'lib/ui/supplier_editor.dart',
    ];

    final topInsetSafety = RegExp(
      r'body:\s*SafeArea\(\s*top:\s*false',
      multiLine: true,
    );

    for (final path in routes) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        matches(topInsetSafety),
        reason:
            '$path is laid out below an AppBar, so its body must not add the '
            'status-bar inset a second time.',
      );
    }
  });
}
