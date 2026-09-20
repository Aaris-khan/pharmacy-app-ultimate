import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/inventory.dart';
import '../lib/state/pharmacy_controller.dart';
import '../lib/ui/design.dart';
import '../lib/ui/search_screen.dart';
import 'domain_contract.dart';

void main() {
  testWidgets(
    'pasted medicine list stays out of the inline search editor',
    (tester) async {
      final first = stock(
        'bulk-one',
        name: 'Paracetamol',
        quantity: 10,
      );
      final second = stock(
        'bulk-two',
        name: 'Cefixime',
        quantity: 8,
      );
      final controller = PharmacyController(
        MemoryInventoryStorage(
          InventorySnapshot(
            records: {
              first.id: first,
              second.id: second,
            },
          ),
        ),
        clock: () => contractToday,
        backgroundSearch: false,
      );
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          home: SearchScreen(
            controller: controller,
            scope: SearchScope.all,
            database: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Paste list'));
      await tester.pumpAndSettle();
      final listInput = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextFormField),
      );
      expect(listInput, findsOneWidget);

      const pasted = 'Paracetamol\nzzzzzzzzzz';
      await tester.enterText(listInput, pasted);
      await tester.tap(find.text('Find medicines'));
      await tester.pumpAndSettle();

      final inlineField = tester.widget<TextField>(
        find.descendant(
          of: find.byType(SearchScreen),
          matching: find.byType(TextField),
        ),
      );
      expect(inlineField.controller!.text, isEmpty);
      expect(
        find.text('Pasted medicine list active · local inventory search'),
        findsOneWidget,
      );

      // Assert the actual bulk-search publication rather than inferring it from
      // a footer that lives below a lazy sliver viewport. The exact medicine
      // must survive while the unrelated pasted line contributes no weak fuzzy
      // result.
      final expectedCard = find.byWidgetPredicate(
        (widget) =>
            widget is MedicineCard && widget.record.id == first.id,
      );
      final unrelatedCard = find.byWidgetPredicate(
        (widget) =>
            widget is MedicineCard && widget.record.id == second.id,
      );
      expect(expectedCard, findsOneWidget);
      expect(unrelatedCard, findsNothing);

      // The count/footer is intentionally lazy. Scroll it into the viewport
      // before asserting presentation text so this remains a UI contract test,
      // not an accidental eager-sliver requirement.
      final count = find.text('1 stock entry');
      await tester.scrollUntilVisible(
        count,
        300,
        scrollable: find.byType(CustomScrollView),
      );
      await tester.pumpAndSettle();
      expect(count, findsOneWidget);
      expect(find.text('Load more'), findsNothing);

      await tester.tap(find.text('Paste list'));
      await tester.pumpAndSettle();
      final dialogEditor = tester.widget<EditableText>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(EditableText),
        ),
      );
      expect(dialogEditor.controller.text, pasted);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );
}
