import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile, supplier and stats hubs serialize interactive entry', () {
    final profile = File('lib/ui/profile_screen.dart').readAsStringSync();
    final suppliers = File('lib/ui/supplier_screen.dart').readAsStringSync();
    final stats = File('lib/ui/stats_screen.dart').readAsStringSync();
    final attention = File('lib/ui/attention_screen.dart').readAsStringSync();
    final removed = File('lib/ui/removed_stock_screen.dart').readAsStringSync();
    final review = File('lib/ui/medicine_review_screen.dart').readAsStringSync();

    expect(
      profile,
      contains('class _ProfileScreenState extends State<ProfileScreen>'),
    );
    expect(profile, contains('bool _actionInProgress = false;'));
    expect(
      profile,
      contains(
        'Future<void> _runExclusiveAction(Future<void> Function() action) async',
      ),
    );
    expect(profile, contains('if (_actionInProgress || !mounted) return;'));
    expect(profile, contains('onTap: _actionInProgress'));
    expect(profile, contains('class _ActivityScreenState extends State<ActivityScreen>'));
    expect(profile, contains('bool _undoing = false;'));
    expect(profile, contains('if (_undoing || !controller.canUndo'));

    expect(
      suppliers,
      contains('class _SupplierScreenState extends State<SupplierScreen>'),
    );
    expect(suppliers, contains('bool _routeOpening = false;'));
    expect(
      suppliers,
      contains(
        'bool get _interactionLocked => _returning || _routeOpening;',
      ),
    );
    expect(suppliers, contains('final VoidCallback? onTap;'));
    expect(
      suppliers,
      contains('final live = widget.controller.snapshot.records[medicine.id];'),
    );

    expect(
      stats,
      contains('class _StatsScreenState extends State<StatsScreen>'),
    );
    expect(stats, contains('bool _routeOpening = false;'));
    expect(
      stats,
      contains(
        'onTap: _routeOpening ? null : () => unawaited(_openTracker())',
      ),
    );

    expect(attention, contains('Future<void> _openSuppliers() async'));
    expect(
      attention,
      contains('onPressed: _opening\n                                      ? null'),
    );

    expect(removed, contains('bool _restoring = false;'));
    expect(
      removed,
      contains(
        'Future<void> _runRestoreFlow(Future<void> Function() action) async',
      ),
    );
    expect(removed, contains('if (_restoring || !mounted) return;'));
    expect(removed, contains('final VoidCallback? onRestore;'));

    expect(
      review,
      contains(
        'Future<void> _openSavedMatch(\n    Medicine record,\n    MedicineScanDraft scanDraft,',
      ),
    );
    expect(
      review,
      contains(
        'onTap: _leaving || _busy\n              ? null\n              : () => unawaited(_openSavedMatch(record, scanDraft))',
      ),
    );
  });
}
