import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'scan search keeps an explicit manual recovery path beside catalog results',
    () {
      final source = File('lib/ui/search_screen.dart').readAsStringSync();

      expect(
        source,
        contains(r"'Scope · ${scopeTitle(widget.scope, settings)}"),
      );
      expect(
        source,
        contains(
          'if (_scan != null &&\n'
          '                    widget.database &&\n'
          '                    !_catalogLoading)',
        ),
      );
      expect(
        source,
        isNot(
          contains(
            '!_catalogLoading &&\n'
            '                    _catalogHits.isEmpty',
          ),
        ),
      );
    },
  );

  test('destructive inventory confirmations are visually explicit', () {
    final source = File('lib/ui/editor_screen.dart').readAsStringSync();

    expect(source, contains('bool destructive = false'));
    expect(source, contains('backgroundColor: red'));
    expect(source, contains('foregroundColor: Colors.white'));
    expect(
      RegExp(r'destructive:\s*true').allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('global inventory removal keeps its final action visibly destructive', () {
    final source = File('lib/ui/profile_screen.dart').readAsStringSync();

    expect(source, contains("backgroundColor: red"));
    expect(source, contains("child: const Text('Remove all')"));
  });

  test('management navigation describes the screen the user actually opens', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains("label: 'Insights'"));
    expect(source, contains('Icons.insights_outlined'));
    expect(source, isNot(contains("label: 'Calculator'")));
  });

  test('snapshot uses on-hand inventory value instead of summing unit costs', () {
    final source = File('lib/ui/stats_screen.dart').readAsStringSync();

    expect(source, contains("label: 'Inventory value'"));
    expect(source, contains('inventory.onHandValue'));
    expect(
      source,
      isNot(contains('_money(inventory.totalEnteredAmountPaise)')),
    );
  });

  test('medicine editor exposes the stock facts its model already persists', () {
    final source = File('lib/ui/editor_screen.dart').readAsStringSync();

    expect(source, contains("'Stock quantity'"));
    expect(source, contains("label: 'Medicine form'"));
    expect(source, contains("'Unit cost (₹)'"));
    expect(source, contains('DropdownButtonFormField<String>'));
    expect(source, contains('bool _matchesOriginalRecord()'));
    expect(
      source,
      contains('floatingLabelBehavior: FloatingLabelBehavior.always'),
      reason: 'Saved values must not hide their field meaning.',
    );
  });

  test('filled app form fields keep their labels after entry', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(
      source,
      contains('floatingLabelBehavior: FloatingLabelBehavior.auto'),
    );
    expect(
      source,
      isNot(contains('floatingLabelBehavior: FloatingLabelBehavior.never')),
    );
  });

  test('raised action labels honor text scaling instead of shrinking text', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class RaisedActionButton');
    final end = source.indexOf('BoxDecoration depthDecoration', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final actionSource = source.substring(start, end);

    expect(actionSource, contains('ConstrainedBox('));
    expect(actionSource, contains('maxLines: 2'));
    expect(actionSource, isNot(contains('FittedBox(')));
  });

  test('filled date fields keep MFG/EXP meaning visible', () {
    final source = File('lib/ui/date_field.dart').readAsStringSync();

    expect(
      source,
      contains('floatingLabelBehavior: FloatingLabelBehavior.always'),
    );
  });
  test('expiry precision controls grow with accessibility text', () {
    final source = File('lib/ui/editor_screen.dart').readAsStringSync();
    final start = source.indexOf('Widget _expiryMode');
    final end = source.indexOf('@override\n  Widget build', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final modeSource = source.substring(start, end);

    expect(modeSource, contains('ConstrainedBox('));
    expect(modeSource, contains('maxLines: 2'));
    expect(modeSource, isNot(contains('FittedBox(')));
  });

  test('today work cards keep actionable text readable', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();
    final start = source.indexOf('class _HomeWorkRow');
    final end = source.indexOf('class _OverviewTile', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final taskSource = source.substring(start, end);

    expect(RegExp(r'maxLines:\s*2').allMatches(taskSource).length, 2);
    expect(taskSource, isNot(contains('maxLines: 1')));
  });

  test('bottom navigation adapts instead of crushing labels on small screens', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains('navigationWidth < 380'));
    expect(source, contains('navigationLabelHeight > 15'));
    expect(
      source,
      contains('NavigationDestinationLabelBehavior.onlyShowSelected'),
    );
    expect(source, contains('height: navigationHeight'));
  });

  test('saved medicine matches keep enough identity visible before selection', () {
    final source =
        File('lib/ui/medicine_review_screen.dart').readAsStringSync();
    final start = source.indexOf('Widget _matchCard(');
    expect(start, greaterThanOrEqualTo(0));
    final matchSource = source.substring(start);

    expect(matchSource, contains('maxLines: 2'));
    expect(
      matchSource,
      contains('crossAxisAlignment: CrossAxisAlignment.start'),
    );
  });

  test('medicine cards do not force manufacturer identity to one line', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class MedicineCard');
    final end = source.indexOf('class _ExpiryBorder', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final cardSource = source.substring(start, end);

    expect(cardSource, contains('record.manufacturer'));
    expect(
      RegExp(
        r'record\.manufacturer,[\s\S]{0,180}maxLines:\s*2',
      ).hasMatch(cardSource),
      isTrue,
    );
  });


  test('bottom navigation height grows with accessibility text', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains('(navigationLabelHeight - 11)'));
    expect(source, contains('.clamp(0.0, 24.0)'));
    expect(
      source,
      isNot(contains('navigationLabelHeight > 16 ? 80.0 : 72.0')),
    );
  });

  test('custom warning settings cannot save without an explicit edit', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();

    expect(
      source,
      contains(
        'bool get _hasChanges => _shortDaysChanged || _monthsChanged;',
      ),
    );
    expect(source, contains('onPressed: _hasChanges'));
    expect(
      RegExp(r'_error = null').allMatches(source).length,
      greaterThanOrEqualTo(4),
    );
    expect(source, contains('textInputAction: TextInputAction.next'));
    expect(source, contains('textInputAction: TextInputAction.done'));
  });

  test('management confirmations stay scrollable on short or large-text screens', () {
    const minimumScrollableDialogs = <String, int>{
      'lib/ui/editor_screen.dart': 1,
      'lib/ui/profile_screen.dart': 3,
      'lib/ui/removed_stock_screen.dart': 1,
      'lib/ui/supplier_screen.dart': 1,
    };

    for (final entry in minimumScrollableDialogs.entries) {
      final source = File(entry.key).readAsStringSync();
      expect(
        RegExp(r'scrollable:\s*true').allMatches(source).length,
        greaterThanOrEqualTo(entry.value),
        reason: '${entry.key} must keep confirmation content reachable.',
      );
    }
  });


  test('long management confirmations stay reachable across high-risk flows', () {
    const minimumScrollableDialogs = <String, int>{
      'lib/ui/brain_screen.dart': 5,
      'lib/ui/medicine_review_screen.dart': 2,
      'lib/ui/search_screen.dart': 1,
      'lib/ui/supplier_editor.dart': 2,
      'lib/ui/local_models_panel.dart': 1,
      'lib/ui/medicine_intake_panel.dart': 1,
      'lib/ui/version_history_screen.dart': 1,
    };

    for (final entry in minimumScrollableDialogs.entries) {
      final source = File(entry.key).readAsStringSync();
      expect(
        RegExp(r'scrollable:\s*true').allMatches(source).length,
        greaterThanOrEqualTo(entry.value),
        reason:
            '${entry.key} must keep long confirmation content reachable on '
            'short screens and with accessibility text scaling.',
      );
    }
  });

  test('destructive management actions are visually distinct before commit', () {
    final brain = File('lib/ui/brain_screen.dart').readAsStringSync();
    final intake = File('lib/ui/medicine_intake_panel.dart').readAsStringSync();
    final supplier = File('lib/ui/supplier_editor.dart').readAsStringSync();

    expect(
      RegExp(
        r"backgroundColor:\s*red,[\s\S]{0,180}child:\s*const Text\('Remove'\)",
      ).hasMatch(brain),
      isTrue,
    );
    expect(
      RegExp(
        r"TextButton\.styleFrom\(foregroundColor:\s*red\)[\s\S]{0,180}child:\s*const Text\('Remove'\)",
      ).hasMatch(intake),
      isTrue,
    );
    expect(
      RegExp(
        r"backgroundColor:\s*red,[\s\S]{0,180}child:\s*const Text\('Discard'\)",
      ).hasMatch(supplier),
      isTrue,
    );
  });

  test('pasted-list search cannot submit an empty accidental request', () {
    final source = File('lib/ui/search_screen.dart').readAsStringSync();

    expect(source, contains('builder: (ctx) => StatefulBuilder('));
    expect(source, contains('scrollable: true'));
    expect(source, contains('autofocus: true'));
    expect(source, contains('onChanged: (value) => draft = value'));
    expect(
      source,
      contains("'Paste at least one medicine name before searching.'"),
    );
    expect(source, contains('Navigator.pop(ctx, clean)'));
    expect(source, contains('textInputAction: TextInputAction.newline'));
  });

  test('supplier custom-field validation feedback clears while correcting', () {
    final source = File('lib/ui/supplier_editor.dart').readAsStringSync();

    expect(
      source,
      contains("if (error.isNotEmpty) setDialogState(() => error = '');"),
    );
  });


  test('stock cards surface operational quantity and unit cost at a glance', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class MedicineCard');
    final end = source.indexOf('class _ExpiryBorder', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final cardSource = source.substring(start, end);

    expect(cardSource, contains(r"'Qty ${record.quantity}'"));
    expect(
      cardSource,
      contains(r"'Cost ${money(record.unitPricePaise!)}'"),
    );
    expect(
      cardSource,
      contains(r"'${record.quantity} units in stock'"),
    );
  });

  test('latest user feedback drops stale snackbar queues', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final feedback = source.substring(source.indexOf('void showError'));

    expect(
      RegExp(r'clearSnackBars\(\)').allMatches(feedback).length,
      greaterThanOrEqualTo(2),
    );
    expect(feedback, isNot(contains('removeCurrentSnackBar()')));
  });

  test('supplier fields release the keyboard when the user taps away', () {
    final source = File('lib/ui/supplier_editor.dart').readAsStringSync();

    expect(
      RegExp(r'onTapOutside:\s*\(_\)').allMatches(source).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('wide screens keep primary navigation compact and reachable', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains('constraints: const BoxConstraints(maxWidth: 720)'));
    expect(source, contains('alignment: Alignment.bottomCenter'));
    expect(source, contains('Icons.home_outlined'));
    expect(source, contains('selectedIcon: Icons.home_rounded'));
    expect(source, contains('Icons.psychology_outlined'));
    expect(source, contains('Icons.psychology_rounded'));
    expect(source, contains('HapticFeedback.selectionClick()'));
    expect(source, contains('final reduceMotion ='));
    expect(source, contains('animationDuration: reduceMotion'));
    expect(source, contains('? Duration.zero'));
    expect(source, contains('const Duration(milliseconds: 260)'));
    final design = File('lib/ui/design.dart').readAsStringSync();
    expect(design, contains('size: selected ? 27 : 24'));
  });

  test('home keeps empty-state actions focused and status icons meaningful', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();

    expect(source, contains('if (!projection.isEmpty)'));
    expect(source, contains('action: emptyInventory'));
    expect(source, contains('icon: Icons.sell_rounded'));
  });

  test('scoped search carries the active query into whole-inventory search', () {
    final source = File('lib/ui/search_screen.dart').readAsStringSync();

    expect(source, contains("this.initialQuery = ''"));
    expect(source, contains('this.initialBulkQuery'));
    expect(source, contains('initialQuery: _bulkQuery == null'));
    expect(source, contains('? _query.text'));
    expect(source, contains('initialBulkQuery: _bulkQuery'));
    expect(source, contains("message: 'Import stock'"));
    expect(source, isNot(contains("message: 'Add / Import medicines'")));
  });

  test('high-risk supplier return and backup restore actions are explicit', () {
    final supplier = File('lib/ui/supplier_screen.dart').readAsStringSync();
    final backup = File('lib/ui/backup_screen.dart').readAsStringSync();

    expect(
      RegExp(
        r"backgroundColor:\s*red,[\s\S]{0,220}child:\s*const Text\('Mark returned'\)",
      ).hasMatch(supplier),
      isTrue,
    );
    expect(
      RegExp(
        r"backgroundColor:\s*red,[\s\S]{0,260}child:\s*const Text\('Restore backup'\)",
      ).hasMatch(backup),
      isTrue,
    );
  });


  test('medicine capture chooser keeps every source reachable', () {
    final source = File('lib/ui/medicine_capture.dart').readAsStringSync();
    final start = source.indexOf('showModalBottomSheet<String>');
    final end = source.indexOf('if (choice == null', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final chooser = source.substring(start, end);
    expect(chooser, contains('useSafeArea: true'));
    expect(chooser, contains('isScrollControlled: true'));
    expect(chooser, contains('showDragHandle: true'));
    expect(chooser, contains('SingleChildScrollView('));
  });

  test('today work beacon keeps priority and next action readable', () {
    final source = File('lib/ui/autopilot_beacon.dart').readAsStringSync();

    expect(
      RegExp(r'maxLines:\s*2').allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
    expect(source, isNot(contains('maxLines: 1')));
  });



  test('long selection sheets can expand on compact or large-text layouts', () {
    final order = File('lib/ui/order_screen.dart').readAsStringSync();
    final ai = File('lib/ui/ai_screen.dart').readAsStringSync();

    final orderStart = order.indexOf('showModalBottomSheet<String>');
    expect(orderStart, greaterThanOrEqualTo(0));
    final orderSheet = order.substring(orderStart, order.indexOf('if (selected == null', orderStart));
    expect(orderSheet, contains('isScrollControlled: true'));
    expect(orderSheet, contains('showDragHandle: true'));

    final aiStart = ai.indexOf('showModalBottomSheet<AiHubQuickAction>');
    expect(aiStart, greaterThanOrEqualTo(0));
    final aiSheet = ai.substring(aiStart, ai.indexOf('if (action != null', aiStart));
    expect(aiSheet, contains('isScrollControlled: true'));
    expect(aiSheet, contains('showDragHandle: true'));
  });

  test('active AI route remains readable instead of being forced to one line', () {
    final source = File('lib/ui/ai_screen.dart').readAsStringSync();
    final label = source.indexOf('Aaris Brain · On-device');
    expect(label, greaterThanOrEqualTo(0));
    final start = source.lastIndexOf('child: Text(', label);
    final end = source.indexOf('else if (_configuration.key.isNotEmpty)', label);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final routeBanner = source.substring(start, end);
    expect(routeBanner, contains('maxLines: 2'));
    expect(routeBanner, isNot(contains('maxLines: 1')));
  });


  test('shared touch surfaces compress subtly and respect reduced motion', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class TactileInkWell');
    final end = source.indexOf('class GlassIconButton', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final tactile = source.substring(start, end);
    expect(tactile, contains('AnimatedScale('));
    expect(tactile, contains('onHighlightChanged: enabled ? _setPressed : null'));
    expect(tactile, contains('disableAnimations'));
    expect(tactile, contains('pressedScale'));
    expect(
      RegExp(r'TactileInkWell\(').allMatches(source).length,
      greaterThanOrEqualTo(4),
    );
  });

  test('stock quick actions use per-action width before stacking', () {
    final source = File('lib/ui/search_screen.dart').readAsStringSync();
    final start = source.indexOf('Widget responsiveActionStrip');
    final end = source.indexOf('final body = CustomScrollView', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final strip = source.substring(start, end);
    expect(strip, contains('final gapWidth = spacing * (actions.length - 1)'));
    expect(strip, contains('(constraints.maxWidth - gapWidth) / actions.length'));
    expect(strip, contains('cellWidth < 96'));
    expect(strip, isNot(contains('constraints.maxWidth < 360')));
  });

  test('dashboard overview cards use the shared tactile interaction', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();
    final start = source.indexOf('class _OverviewTile');
    final end = source.indexOf('class _WarningSelector', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final overview = source.substring(start, end);
    expect(overview, contains('TactileInkWell('));
    expect(overview, contains('pressedScale: .985'));
  });


  test('primary action opacity respects the platform reduced-motion setting', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class RaisedActionButton');
    final end = source.indexOf('BoxDecoration depthDecoration', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final actionSource = source.substring(start, end);
    expect(actionSource, contains('disableAnimations'));
    expect(actionSource, contains('duration: reduceMotion'));
    expect(actionSource, contains('? Duration.zero'));
  });

  test('home dashboard combines meaningful motion with tactile surfaces', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();
    final workStart = source.indexOf('class _HomeWorkRow');
    final overviewStart = source.indexOf('class _OverviewTile', workStart);
    final selectorStart = source.indexOf('class _WarningSelector', overviewStart);
    final scanStart = source.indexOf('class _ScanBanner', selectorStart);

    expect(workStart, greaterThanOrEqualTo(0));
    expect(overviewStart, greaterThan(workStart));
    expect(selectorStart, greaterThan(overviewStart));
    expect(scanStart, greaterThan(selectorStart));

    final work = source.substring(workStart, overviewStart);
    final overview = source.substring(overviewStart, selectorStart);
    final scan = source.substring(scanStart);

    expect(work, contains('TactileInkWell('));
    expect(work, contains('pressedScale: .99'));
    expect(overview, contains('AnimatedSwitcher('));
    expect(overview, contains('disableAnimations'));
    expect(overview, contains('ValueKey<int>(count)'));
    expect(scan, contains('TactileInkWell('));
    expect(scan, contains('pressedScale: .985'));
  });

  test('remaining high-frequency cards share tactile interaction semantics', () {
    for (final path in <String>[
      'lib/ui/ai_screen.dart',
      'lib/ui/autopilot_beacon.dart',
      'lib/ui/local_models_panel.dart',
      'lib/ui/medicine_review_screen.dart',
      'lib/ui/supplier_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('TactileInkWell('), reason: path);
      expect(RegExp(r'\bInkWell\(').hasMatch(source), isFalse, reason: path);
    }

    final ai = File('lib/ui/ai_screen.dart').readAsStringSync();
    final quickStart = ai.indexOf('class _AiQuickActionChip');
    final quickEnd = ai.indexOf('class _AiConnectionsSheet', quickStart);
    expect(quickStart, greaterThanOrEqualTo(0));
    expect(quickEnd, greaterThan(quickStart));
    final quick = ai.substring(quickStart, quickEnd);
    expect(quick, contains('disableAnimations'));
    expect(quick, contains('duration: reduceMotion'));
    expect(quick, contains('? Duration.zero'));
  });

  test('high-frequency management cards share tactile press feedback', () {
    final editor = File('lib/ui/editor_screen.dart').readAsStringSync();
    final attention = File('lib/ui/attention_screen.dart').readAsStringSync();
    final stats = File('lib/ui/stats_screen.dart').readAsStringSync();
    final search = File('lib/ui/search_screen.dart').readAsStringSync();

    final supplierStart = editor.indexOf('Widget _supplierField()');
    final supplierEnd = editor.indexOf('bool _samePersistedFacts', supplierStart);
    final expiryStart = editor.indexOf('Widget _expiryMode', supplierEnd);
    final expiryEnd = editor.indexOf('@override\n  Widget build', expiryStart);
    expect(supplierStart, greaterThanOrEqualTo(0));
    expect(supplierEnd, greaterThan(supplierStart));
    expect(expiryStart, greaterThan(supplierEnd));
    expect(expiryEnd, greaterThan(expiryStart));
    expect(
      editor.substring(supplierStart, supplierEnd),
      contains('TactileInkWell('),
    );
    expect(
      editor.substring(expiryStart, expiryEnd),
      contains('TactileInkWell('),
    );

    final taskStart = attention.indexOf('class _AttentionCard');
    expect(taskStart, greaterThanOrEqualTo(0));
    expect(attention.substring(taskStart), contains('TactileInkWell('));

    final metricStart = stats.indexOf('class _SnapshotCard');
    expect(metricStart, greaterThanOrEqualTo(0));
    expect(stats.substring(metricStart), contains('TactileInkWell('));

    final catalogStart = search.indexOf('class _CatalogCandidateCard');
    expect(catalogStart, greaterThanOrEqualTo(0));
    expect(search.substring(catalogStart), contains('TactileInkWell('));
  });



  test('retained home tab detaches the today-work listener while offstage', () {
    final source = File('lib/ui/home_screen.dart').readAsStringSync();
    final start = source.indexOf('class _TodayWorkPreview');
    final end = source.indexOf('class _ReadyTodayWork', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final preview = source.substring(start, end);
    expect(preview, contains('ActiveListenableBuilder('));
    expect(preview, contains('listenable: autopilot.workQueue'));
    expect(preview, contains('rebuildToken: () => autopilot.workQueue.value'));
    expect(
      preview,
      isNot(contains('ValueListenableBuilder<AarisAutopilotWorkQueue>')),
    );
  });

  test('snapshot value changes use motion-safe continuity', () {
    final source = File('lib/ui/stats_screen.dart').readAsStringSync();
    final start = source.indexOf('class _SnapshotCard');
    final end = source.indexOf('class _SoldMedicineTrackerScreen', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final card = source.substring(start, end);
    expect(card, contains('AnimatedSwitcher('));
    expect(card, contains('disableAnimations'));
    expect(card, contains('ValueKey<String>(metric.value)'));
    expect(card, contains('Tween<double>(begin: .96, end: 1)'));
  });


  test('shared tactile controls can label the complete touch target', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class TactileInkWell');
    final end = source.indexOf('class GlassIconButton', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final tactile = source.substring(start, end);
    expect(tactile, contains('final String? tooltip;'));
    expect(tactile, contains('widget.tooltip?.trim()'));
    expect(
      tactile,
      contains('return Tooltip(message: tooltip, child: control);'),
    );
  });

  test('AI custom icon controls label their full tactile targets', () {
    final source = File('lib/ui/ai_screen.dart').readAsStringSync();

    final headerStart = source.indexOf('class _AiHubHeader');
    final headerEnd = source.indexOf('class _AiChatMessage', headerStart);
    expect(headerStart, greaterThanOrEqualTo(0));
    expect(headerEnd, greaterThan(headerStart));
    final header = source.substring(headerStart, headerEnd);
    expect(
      header,
      contains(
        "tooltip: configured ? 'AI settings · Connected' : 'AI settings'",
      ),
    );

    final composerStart = source.indexOf('class _AiComposer');
    final composerEnd = source.indexOf('class _AiQuickActions', composerStart);
    expect(composerStart, greaterThanOrEqualTo(0));
    expect(composerEnd, greaterThan(composerStart));
    final composer = source.substring(composerStart, composerEnd);
    expect(
      composer,
      contains("tooltip: busy ? 'AI is working' : 'Run command'"),
    );
    expect(
      composer,
      isNot(
        contains(
          "message: 'Run command',\n"
          '                        child: Icon(',
        ),
      ),
    );
  });

  test('composite tappable surfaces expose one atomic screen-reader action', () {
    final design = File('lib/ui/design.dart').readAsStringSync();
    final medicineStart = design.indexOf('class MedicineCard');
    final medicineEnd = design.indexOf('class _ExpiryBorder', medicineStart);
    expect(medicineStart, greaterThanOrEqualTo(0));
    expect(medicineEnd, greaterThan(medicineStart));
    final medicine = design.substring(medicineStart, medicineEnd);
    expect(medicine, contains('onTap: onTap'));
    expect(medicine, contains('excludeSemantics: true'));

    final stats = File('lib/ui/stats_screen.dart').readAsStringSync();
    final snapshotStart = stats.indexOf('class _SnapshotCard');
    final snapshotEnd = stats.indexOf(
      'class _SoldMedicineTrackerScreen',
      snapshotStart,
    );
    expect(snapshotStart, greaterThanOrEqualTo(0));
    expect(snapshotEnd, greaterThan(snapshotStart));
    final snapshot = stats.substring(snapshotStart, snapshotEnd);
    expect(snapshot, contains('onTap: metric.onTap'));
    expect(snapshot, contains('excludeSemantics: metric.onTap != null'));

    final beacon = File('lib/ui/autopilot_beacon.dart').readAsStringSync();
    expect(beacon, contains('onTap: onOpenWorkQueue'));
    expect(beacon, contains('excludeSemantics: true'));
  });

  test('system bars follow the pharmacy surface contract', () {
    final design = File('lib/ui/design.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(design, contains('const pharmacySystemUiOverlayStyle'));
    expect(design, contains('statusBarColor: Colors.transparent'));
    expect(design, contains('systemNavigationBarColor: canvas'));
    expect(
      design,
      contains('systemOverlayStyle: pharmacySystemUiOverlayStyle'),
    );
    expect(
      main,
      contains(
        'SystemChrome.setSystemUIOverlayStyle(pharmacySystemUiOverlayStyle);',
      ),
    );
  });


  test(
    'primary navigation animates destination glyphs and returns home on system back',
    () {
      final source = File('lib/app.dart').readAsStringSync();

      expect(source, contains('Icons.home_outlined'));
      expect(source, contains('Icons.home_rounded'));
      expect(source, isNot(contains('Icons.dashboard_outlined')));
      expect(
        RegExp(r'_AnimatedNavigationIcon\(').allMatches(source).length,
        greaterThanOrEqualTo(6),
      );

      expect(source, contains('final shell = Scaffold('));
      expect(source, contains('return PopScope('));
      expect(source, contains('canPop: tab == 0'));
      expect(source, contains('if (!didPop && tab != 0) _selectTab(0);'));

      final start = source.indexOf('class _AnimatedNavigationIcon');
      expect(start, greaterThanOrEqualTo(0));
      final icon = source.substring(start);
      expect(icon, contains('final currentIcon = selected ? selectedIcon : icon;'));
      expect(icon, contains('AnimatedSwitcher('));
      expect(
        icon,
        contains(
          'duration: reduceMotion\n'
          '          ? Duration.zero\n'
          '          : const Duration(milliseconds: 180)',
        ),
      );
      expect(icon, contains('Tween<double>(begin: .92, end: 1)'));
      expect(icon, contains('ValueKey(('));
      expect(icon, contains('currentIcon.codePoint'));
      expect(icon, contains('child: Icon(currentIcon)'));
    },
  );

  test('Aaris Brain names the current Insights destination in navigation replies', () {
    final source = File('lib/ui/brain_screen.dart').readAsStringSync();
    final start = source.indexOf('String _sectionReply(AppSection section)');
    expect(start, greaterThanOrEqualTo(0));
    final reply = source.substring(start);

    expect(reply, contains("AppSection.ai => 'Aaris Brain is already open.'"));
    expect(reply, contains("AppSection.calculator => 'Insights opened.'"));
    expect(reply, isNot(contains("AppSection.calculator => 'Calculator opened.'")));
  });

  test('shared tactile controls emit one non-blocking haptic pulse', () {
    final source = File('lib/ui/design.dart').readAsStringSync();
    final start = source.indexOf('class _TactileInkWellState');
    final end = source.indexOf('class GlassIconButton', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final tactile = source.substring(start, end);

    expect(source, contains("import 'dart:async';"));
    expect(source, contains('final bool hapticFeedback;'));
    expect(source, contains('this.hapticFeedback = true'));
    expect(tactile, contains('unawaited(HapticFeedback.selectionClick())'));
    expect(tactile, contains('onTap: enabled ? _handleTap : null'));
  });

  test('scanner chrome and success feedback stay legible and motion-safe', () {
    final design = File('lib/ui/design.dart').readAsStringSync();
    final scanner = File('lib/ui/scanner_view.dart').readAsStringSync();
    final scannerLogic = File('lib/ui/scanner_screen.dart').readAsStringSync();

    final darkStyleStart = design.indexOf(
      'const pharmacyDarkSystemUiOverlayStyle',
    );
    final darkStyleEnd = design.indexOf(');', darkStyleStart);
    expect(darkStyleStart, greaterThanOrEqualTo(0));
    expect(darkStyleEnd, greaterThan(darkStyleStart));
    final darkStyle = design.substring(darkStyleStart, darkStyleEnd);

    expect(darkStyle, contains('statusBarIconBrightness: Brightness.light'));
    expect(darkStyle, contains('systemNavigationBarColor: ink'));
    expect(
      darkStyle,
      contains('systemNavigationBarIconBrightness: Brightness.light'),
    );
    expect(
      scanner,
      contains('systemOverlayStyle: pharmacyDarkSystemUiOverlayStyle'),
    );
    expect(scanner, contains('AnimatedContainer('));
    expect(scanner, contains('AnimatedSwitcher('));
    expect(scanner, contains('liveRegion: true'));
    expect(scanner, contains('background:'));
    expect(scanner, contains('? successSoft'));
    expect(scanner, contains('?.disableAnimations ??'));
    expect(scanner, contains('? green'));
    expect(scanner, contains('const Duration(milliseconds: 220)'));
    expect(scannerLogic, contains('HapticFeedback.mediumImpact()'));
    expect(scannerLogic, contains('HapticFeedback.lightImpact()'));
  });

}
