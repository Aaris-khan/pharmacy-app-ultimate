import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/ui/design.dart';

void main() {
  testWidgets(
    'ActiveListenableBuilder stays idle while hidden and catches up on resume',
    (tester) async {
      final value = ValueNotifier<int>(0);
      addTearDown(value.dispose);
      var builds = 0;

      Widget host(bool active) => MaterialApp(
        home: TickerMode(
          enabled: active,
          child: ActiveListenableBuilder(
            listenable: value,
            builder: (context, child) {
              builds++;
              return Center(child: Text('value:${value.value}'));
            },
          ),
        ),
      );

      await tester.pumpWidget(host(true));
      expect(find.text('value:0'), findsOneWidget);
      final initialBuilds = builds;

      value.value = 1;
      await tester.pump();
      expect(find.text('value:1'), findsOneWidget);
      expect(builds, initialBuilds + 1);

      await tester.pumpWidget(host(false));
      expect(find.text('value:1'), findsOneWidget);
      final hiddenBuilds = builds;

      value.value = 2;
      await tester.pump();
      expect(builds, hiddenBuilds);
      expect(find.text('value:1'), findsOneWidget);

      await tester.pumpWidget(host(true));
      expect(find.text('value:2'), findsOneWidget);
      expect(builds, greaterThan(hiddenBuilds));
    },
  );
}
