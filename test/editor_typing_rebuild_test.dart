import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:aaris_pharmacy/ui/design.dart';
import 'package:aaris_pharmacy/ui/editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'medicine editor stops whole-screen rebuilds after becoming dirty',
    (tester) async {
      final controller = PharmacyController(
        MemoryInventoryStorage(InventorySnapshot()),
        clock: () => DateTime(2026, 9, 20, 10),
        backgroundSearch: false,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: pharmacyTheme(),
          home: EditorScreen(controller: controller),
        ),
      );
      await tester.pump();

      final title = find.text('Add medicine');
      final initialTitle = tester.widget<Text>(title);
      final nameField = find.byType(TextFormField).first;

      await tester.enterText(nameField, 'P');
      await tester.pump();

      final dirtyTitle = tester.widget<Text>(title);
      expect(
        dirtyTitle,
        isNot(same(initialTitle)),
        reason: 'The first edit must rebuild PopScope so discard protection activates.',
      );

      await tester.enterText(nameField, 'Paracetamol');
      await tester.pump();

      expect(
        tester.widget<Text>(title),
        same(dirtyTitle),
        reason:
            'Once dirty, field-local typing must not rebuild the entire medicine editor.',
      );

      // PharmacyController owns a civil-day timer. Dispose it inside the widget
      // test body (not only in addTearDown) so Flutter's pending-timer invariant
      // observes the same lifecycle shutdown the real app performs.
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
