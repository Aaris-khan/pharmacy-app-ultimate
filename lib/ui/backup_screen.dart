import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/backup.dart';
import '../services/backup_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _service = BackupService();
  final _input = TextEditingController();
  BackupReview? _review;
  bool _sharing = false;
  bool _reading = false;
  bool _restoring = false;
  String _error = '';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await _service.share(widget.controller.createBackup());
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _pick() async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final text = await _service.pickBackupText();
      if (text != null && mounted) {
        _input.text = text;
        await _reviewInput();
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _error =
              'File selection is available in the Android app. Paste backup JSON here on this device.',
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    _input.text = data?.text ?? '';
    setState(() {
      _review = null;
      _error = '';
    });
  }

  Future<void> _reviewInput() async {
    if (_restoring || (_reading && _input.text.isEmpty)) return;
    final input = _input.text;
    setState(() {
      _reading = true;
      _error = '';
      _review = null;
    });
    try {
      final parsed = await widget.controller.reviewBackup(input);
      if (!mounted || _input.text != input) return;

      // The impact preview must describe the exact live snapshot bound to this
      // review. If a concurrent stock write lands in the tiny hand-off window,
      // fail closed and ask for a fresh review instead of showing stale counts.
      final current = widget.controller.snapshot;
      if (parsed.currentRevision != current.revision) {
        setState(
          () => _error =
              'Inventory changed while this backup was being reviewed. Review it again to see the current impact.',
        );
        return;
      }
      final impact = BackupImpact.compare(
        backup: parsed.backup,
        currentRecords: current.records,
        currentSales: current.sales,
        currentSettings: current.settings,
        currentSoldValue: current.soldValue,
        currentUnknownSold: current.unknownSold,
      );
      setState(
        () => _review = BackupReview(
          backup: parsed.backup,
          currentRevision: parsed.currentRevision,
          impact: impact,
        ),
      );
    } catch (error) {
      if (mounted && _input.text == input) {
        setState(
          () => _error = error.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state):\s*'),
            '',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Widget _impactRow(IconData icon, String text, {Color color = ink}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Future<void> _restore() async {
    final review = _review;
    if (review == null || _restoring) return;
    final impact = review.impact;
    var phrase = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Restore this backup?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The reviewed backup becomes the active inventory. Current stock missing from it moves to Removed stock instead of being silently destroyed.',
                ),
                if (impact.activeEntriesMovingToRemoved > 0) ...[
                  const SizedBox(height: 14),
                  Text(
                    '${impact.activeEntriesMovingToRemoved} current active ${impact.activeEntriesMovingToRemoved == 1 ? 'entry moves' : 'entries move'} to Removed stock.',
                    style: const TextStyle(
                      color: amber,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (impact.removedSaleEvents > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${impact.removedSaleEvents} current sale ${impact.removedSaleEvents == 1 ? 'event is' : 'events are'} not in this backup and will be replaced.',
                    style: const TextStyle(
                      color: amber,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (review.legacyFormat) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'This is an older backup format. Its pharmacy facts were validated, but it predates the content-integrity seal used by current backups.',
                    style: TextStyle(color: amber, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Export your current backup first if you may need it later.',
                  style: TextStyle(color: amber, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                TextField(
                  onChanged: (value) => setState(() => phrase = value),
                  decoration: const InputDecoration(
                    labelText: 'Type RESTORE',
                    hintText: 'RESTORE',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: phrase == 'RESTORE'
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Restore backup'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _restoring = true);
    try {
      await widget.controller.restoreBackup(review);
      if (mounted) {
        Navigator.pop(context);
        showSaved(context, 'Backup restored. All live views are updated.');
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Backup & Restore')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
      children: [
        const ScreenIntro(
          title: 'Keep a safe copy',
          message:
              'Save a full backup, or review a saved file before restoring it.',
          icon: Icons.shield_outlined,
        ),
        Surface(
          color: ink,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.shield_outlined, color: primarySoft, size: 30),
              const SizedBox(height: 14),
              const Text(
                'Keep your pharmacy portable',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Export medicines, removed stock, warning settings and aggregate sales. The file never contains an AI API key.',
                style: TextStyle(color: inverseMuted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: primarySoft,
                  foregroundColor: ink,
                ),
                onPressed: _sharing ? null : () => unawaited(_share()),
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(_sharing ? 'Preparing…' : 'Export full backup'),
              ),
            ],
          ),
        ),
        const SectionHeading('Restore a backup'),
        FlowSteps(
          const ['Choose file', 'Review', 'Restore'],
          current: _review == null ? 0 : 1,
        ),
        const Text(
          'Choose your Aaris backup file, or paste its contents. Review the summary before you restore.',
          style: TextStyle(color: muted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: _reading ? null : () => unawaited(_pick()),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Choose backup file'),
            ),
            OutlinedButton.icon(
              onPressed: _reading ? null : () => unawaited(_paste()),
              icon: const Icon(Icons.content_paste_rounded),
              label: const Text('Paste'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _input,
          minLines: 5,
          maxLines: 10,
          maxLength: maxBackupCharacters,
          onChanged: (_) => setState(() {
            _review = null;
            _error = '';
          }),
          decoration: const InputDecoration(
            hintText: 'Aaris Pharmacy backup JSON',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _reading || _input.text.trim().isEmpty
              ? null
              : () => unawaited(_reviewInput()),
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(_reading ? 'Checking backup…' : 'Review backup'),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Surface(
              color: errorSoft,
              child: Text(_error, style: const TextStyle(color: red)),
            ),
          ),
        if (_review != null) ...[
          const SectionHeading('Backup summary'),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _review!.integrityVerified
                          ? Icons.verified_user_outlined
                          : Icons.history_rounded,
                      color: _review!.integrityVerified ? primary : amber,
                      size: 20,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        _review!.integrityVerified
                            ? 'Integrity verified'
                            : 'Legacy backup · validated without an integrity seal',
                        style: TextStyle(
                          color: _review!.integrityVerified ? primary : amber,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  '${_review!.activeMedicines} active stock entries',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text('${_review!.removedMedicines} removed entries'),
                Text('${_review!.sales} aggregate sale events'),
                Text(
                  'Warnings: ${_review!.backup.settings.shortDays} days · ${_review!.backup.settings.months} months',
                ),
                const SizedBox(height: 8),
                Text(
                  'Created ${_review!.backup.createdAt.toLocal().toString().split('.').first}',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SectionHeading('Restore impact'),
          Surface(
            child: Builder(
              builder: (context) {
                final impact = _review!.impact;
                if (!impact.hasMaterialChange) {
                  return _impactRow(
                    Icons.check_circle_outline_rounded,
                    'No material stock, sales, warning or sold-total difference was found against the reviewed live snapshot.',
                    color: primary,
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (impact.newStockEntries > 0)
                      _impactRow(
                        Icons.add_box_outlined,
                        '${impact.newStockEntries} new stock ${impact.newStockEntries == 1 ? 'entry' : 'entries'} will be added.',
                      ),
                    if (impact.changedStockEntries > 0)
                      _impactRow(
                        Icons.edit_note_rounded,
                        '${impact.changedStockEntries} existing stock ${impact.changedStockEntries == 1 ? 'entry has' : 'entries have'} different saved facts in this backup.',
                      ),
                    if (impact.reactivatedStockEntries > 0)
                      _impactRow(
                        Icons.restore_from_trash_outlined,
                        '${impact.reactivatedStockEntries} removed stock ${impact.reactivatedStockEntries == 1 ? 'entry returns' : 'entries return'} to active stock.',
                      ),
                    if (impact.activeEntriesMovingToRemoved > 0)
                      _impactRow(
                        Icons.inventory_2_outlined,
                        '${impact.activeEntriesMovingToRemoved} current active ${impact.activeEntriesMovingToRemoved == 1 ? 'entry moves' : 'entries move'} to Removed stock because it is not in this backup.',
                        color: amber,
                      ),
                    if (impact.newSaleEvents > 0 ||
                        impact.changedSaleEvents > 0 ||
                        impact.removedSaleEvents > 0)
                      _impactRow(
                        Icons.receipt_long_outlined,
                        'Sale history: ${impact.newSaleEvents} new · ${impact.changedSaleEvents} changed · ${impact.removedSaleEvents} removed.',
                        color: impact.removedSaleEvents > 0 ? amber : ink,
                      ),
                    if (impact.warningSettingsChange)
                      _impactRow(
                        Icons.notifications_active_outlined,
                        'Expiry warning windows will change to ${_review!.backup.settings.shortDays} days and ${_review!.backup.settings.months} months.',
                      ),
                    if (impact.soldTotalsChange)
                      _impactRow(
                        Icons.calculate_outlined,
                        'Saved sold-stock totals will be restored from this backup.',
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _restoring ? null : () => unawaited(_restore()),
            icon: const Icon(Icons.restore_rounded),
            label: Text(_restoring ? 'Restoring…' : 'Restore reviewed backup'),
          ),
        ],
      ],
    ),
  );
}
