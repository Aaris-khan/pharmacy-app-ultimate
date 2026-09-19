import 'package:flutter/material.dart';

import '../state/pharmacy_controller.dart';

/// Rebuilds only when the authoritative inventory snapshot or civil day changes.
///
/// [PharmacyController] also emits short-lived UI notifications for work such as
/// AI preparation progress. Read-only inventory surfaces do not depend on those
/// signals and should not repaint large lists or metric grids for them.
///
/// Like the app's other retained-tab listeners, this detaches while its route is
/// inactive and catches up from the current controller state when reactivated.
class InventorySnapshotBuilder extends StatefulWidget {
  const InventorySnapshotBuilder({
    super.key,
    required this.controller,
    required this.builder,
    this.child,
  });

  final PharmacyController controller;
  final TransitionBuilder builder;
  final Widget? child;

  @override
  State<InventorySnapshotBuilder> createState() =>
      _InventorySnapshotBuilderState();
}

class _InventorySnapshotBuilderState extends State<InventorySnapshotBuilder> {
  late Object _snapshot;
  late DateTime _day;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _capture();
  }

  void _capture() {
    _snapshot = widget.controller.snapshot;
    _day = widget.controller.today;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active == _listening) return;

    _listening = active;
    if (active) {
      _capture();
      widget.controller.addListener(_changed);
    } else {
      widget.controller.removeListener(_changed);
    }
  }

  @override
  void didUpdateWidget(covariant InventorySnapshotBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    if (_listening) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _capture();
  }

  void _changed() {
    if (!mounted) return;
    final snapshot = widget.controller.snapshot;
    final day = widget.controller.today;
    if (identical(snapshot, _snapshot) && day == _day) return;

    _snapshot = snapshot;
    _day = day;
    setState(() {});
  }

  @override
  void dispose() {
    if (_listening) widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.child);
}
