// The Plan block: integration against the estimate, the end time, and the
// per-filter rows, during a run and before one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/left/plan_section.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';

import '../fixtures/night_fixtures.dart';
import 'night_widget_test_support.dart';

Future<void> _pump(WidgetTester tester, NightBoard board) async {
  final harness = NightHarness(board: board);
  await harness.pump(
    tester,
    const SizedBox(width: 272, child: NightPlanSection()),
    size: const Size(272, 758),
  );
}

void main() {
  testWidgets('running: integrated against the estimate, ETA', (tester) async {
    await _pump(tester, NightFixtures.running());
    expect(find.text('5 h 10 m / ≈7 h · ETA ≈05:30'), findsOneWidget);
    expect(find.text('43/60'), findsOneWidget);
    expect(find.text('2h09'), findsOneWidget);
    expect(find.text('0h36'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready: nothing captured, the plan\'s end', (tester) async {
    await _pump(tester, NightFixtures.ready());
    expect(find.text('0 / ≈7 h · ends ≈05:30'), findsOneWidget);
    expect(find.text('0/60'), findsNWidgets(2));
    expect(find.text('—'), findsNWidgets(5));
  });

  testWidgets('each row reads as one sentence', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, NightFixtures.running());
    expect(
      find.bySemanticsLabel(
        'Ha: 43 of 60 frames, 2 h 09 m captured, exposing now',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('an open-ended plan: no planned count, no estimate',
      (tester) async {
    final harness = NightHarness(
      board: NightFixtures.running(),
      plan: const NightPlanVm(
        rows: <PlanFilterRowVm>[
          PlanFilterRowVm(
            filter: 'L',
            framesDone: 3,
            integrated: Duration(minutes: 9),
            isCurrent: true,
          ),
        ],
        integrated: Duration(minutes: 9),
      ),
    );
    await harness.pump(
      tester,
      const SizedBox(width: 272, child: NightPlanSection()),
      size: const Size(272, 758),
    );
    expect(find.text('9 m'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('≈'), findsNothing);
  });

  testWidgets('no plan says so', (tester) async {
    final harness = NightHarness(board: NightFixtures.ready(), noPlan: true);
    await harness.pump(
      tester,
      const SizedBox(width: 272, child: NightPlanSection()),
      size: const Size(272, 758),
    );
    expect(find.text('No plan loaded'), findsOneWidget);
  });
}
