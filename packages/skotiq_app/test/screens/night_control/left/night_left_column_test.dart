// The whole plan column at the owner's size (272 x 758) on each board, at
// 1x and 1.3x text: it scrolls on its own and nothing overflows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/left/night_left_column.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';

import '../fixtures/night_fixtures.dart';
import 'night_widget_test_support.dart';

void main() {
  final boards = <String, NightBoard Function()>{
    'running': NightFixtures.running,
    'ready': NightFixtures.ready,
    'autofocus': NightFixtures.autofocus,
  };
  for (final MapEntry(key: name, value: board) in boards.entries) {
    for (final scale in const <double>[1, 1.3]) {
      testWidgets('$name board at 272x758, ${scale}x text', (tester) async {
        final harness = NightHarness(board: board());
        await harness.pump(
          tester,
          SizedBox(
            width: 272,
            height: 758,
            child: densityFor(
              NightControlMode.threeColumn,
              child: const NightLeftColumn(),
            ),
          ),
          size: const Size(272, 758),
          textScale: scale,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.descendant(
            of: find.byType(NightLeftColumn),
            matching: find.byType(Scrollable),
          ),
          findsOneWidget,
        );
        // Every section is there, top to bottom.
        final titles = <String>[
          'Target · M74',
          'Plan',
          'Steps',
          name == 'ready' ? 'The night' : 'Coming up',
        ];
        for (final title in titles) {
          expect(find.text(title), findsOneWidget, reason: title);
        }
      });
    }
  }

  testWidgets('in one column it sizes to its content', (tester) async {
    final harness = NightHarness(board: NightFixtures.running());
    await harness.pump(
      tester,
      SizedBox(
        width: 390,
        height: 844,
        child: SingleChildScrollView(
          child: densityFor(
            NightControlMode.singleColumn,
            child: const NightLeftColumn(),
          ),
        ),
      ),
      size: const Size(390, 844),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(NightLeftColumn)).height,
      greaterThan(758),
    );
  });
}
