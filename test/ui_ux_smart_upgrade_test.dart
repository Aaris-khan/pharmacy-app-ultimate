import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/inventory.dart';
import 'package:aaris_pharmacy/state/autopilot_supervisor.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/editor_screen.dart';
import 'package:aaris_pharmacy/ui/home_screen.dart';
import 'package:aaris_pharmacy/ui/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Home header add affordance opens medicine editor', (
    tester,
  ) async {
    final controller = PharmacyController(
      MemoryInventoryStorage(),
      backgroundSearch: false,
    );
    await controller.initialize();
    final autopilot = AarisAutopilotSupervisor(
      controller,
      startImmediately: false,
    );
    autopilot.setLifecycleActive(false);

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: HomeScreen(
          controller: controller,
          autopilot: autopilot,
          onOpenWorkQueue: () {},
        ),
      ),
    );
    await tester.pump();

    final quickAdd = find.byWidgetPredicate(
      (widget) =>
          widget is GlassIconButton &&
          widget.tooltip == 'Add medicine' &&
          widget.icon == Icons.add_rounded,
    );
    expect(quickAdd, findsOneWidget);

    await tester.tap(quickAdd);
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsOneWidget);
    expect(find.text('Add medicine'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    autopilot.dispose();
    controller.dispose();
  });

  testWidgets('Search quick actions stay readable at large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final controller = PharmacyController(
      MemoryInventoryStorage(),
      backgroundSearch: false,
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: pharmacyTheme(),
        home: SearchScreen(
          controller: controller,
          scope: SearchScope.all,
          database: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scan = find.text('Scan');
    final voice = find.text('Voice');
    final paste = find.text('Paste list');

    expect(scan, findsOneWidget);
    expect(voice, findsOneWidget);
    expect(paste, findsOneWidget);
    expect(tester.getCenter(scan).dy, lessThan(tester.getCenter(voice).dy));
    expect(tester.getCenter(voice).dy, lessThan(tester.getCenter(paste).dy));
    expect(find.textContaining('Scope ·'), findsOneWidget);
    expect(find.textContaining('Searching:'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });
}
