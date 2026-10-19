// The Steps list: what each row prints, the running step kept in view, and
// "open in Sequencer" selecting the node and going there.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/left/night_left_column.dart';
import 'package:skotiq_app/screens/night_control/left/steps_section.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_core/skotiq_core.dart' show selectedNodeIdProvider;

import '../fixtures/night_fixtures.dart';
import 'night_widget_test_support.dart';

/// A long plan whose running step sits far down the list.
List<PlanStepVm> _longPlan({int count = 40, int active = 34}) => <PlanStepVm>[
      for (var i = 0; i < count; i++)
        PlanStepVm(
          nodeId: 'n$i',
          label: 'Step $i',
          status: i < active
              ? PlanStepStatus.done
              : i == active
                  ? PlanStepStatus.active
                  : PlanStepStatus.pending,
          when: i == active ? const StepWhenProgress(3, null) : null,
        ),
    ];

Future<NightHarness> _pumpColumn(
  WidgetTester tester, {
  required List<PlanStepVm> steps,
  NightControlMode mode = NightControlMode.threeColumn,
}) async {
  final harness = NightHarness(board: NightFixtures.running(), steps: steps);
  final column = densityFor(mode, child: const NightLeftColumn());
  await harness.pump(
    tester,
    mode == NightControlMode.singleColumn
        ? SizedBox(
            width: 272,
            height: 758,
            child: SingleChildScrollView(child: column),
          )
        : SizedBox(width: 272, height: 758, child: column),
    size: const Size(272, 758),
  );
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('recorded, running and planned times', (tester) async {
    final harness = NightHarness(board: NightFixtures.running());
    await harness.pump(
      tester,
      const SizedBox(width: 272, child: NightStepsSection()),
      size: const Size(272, 758),
    );
    expect(find.text('19:52'), findsOneWidget);
    expect(find.text('44/60'), findsOneWidget);
    expect(find.text('≈03:40'), findsOneWidget);
    expect(find.text('≈05:30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('before a run every time is the estimate', (tester) async {
    final harness = NightHarness(board: NightFixtures.ready());
    await harness.pump(
      tester,
      const SizedBox(width: 272, child: NightStepsSection()),
      size: const Size(272, 758),
    );
    expect(find.text('≈19:40'), findsOneWidget);
    expect(find.text('≈23:20'), findsOneWidget);
    expect(find.text('19:40'), findsNothing);
  });

  testWidgets('the running step is scrolled into view', (tester) async {
    await _pumpColumn(tester, steps: _longPlan());
    final viewport = tester.getRect(find.byType(NightLeftColumn));
    final row = tester.getRect(find.text('Step 34'));
    expect(viewport.top, lessThanOrEqualTo(row.top));
    expect(viewport.bottom, greaterThanOrEqualTo(row.bottom));
    expect(find.text('Target · M74').hitTestable(), findsNothing);
  });

  testWidgets('a running step already in view moves nothing', (tester) async {
    await _pumpColumn(tester, steps: _longPlan(active: 1));
    expect(find.text('Target · M74').hitTestable(), findsOneWidget);
  });

  testWidgets('in one column the page is not pulled to the step',
      (tester) async {
    await _pumpColumn(
      tester,
      steps: _longPlan(),
      mode: NightControlMode.singleColumn,
    );
    expect(
      find.descendant(
        of: find.byType(NightLeftColumn),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    expect(find.text('Target · M74').hitTestable(), findsOneWidget);
  });

  testWidgets('open in Sequencer selects the running step and goes there',
      (tester) async {
    final harness = NightHarness(board: NightFixtures.running());
    await harness.pump(
      tester,
      const SizedBox(width: 272, child: NightStepsSection()),
      size: const Size(272, 758),
    );
    await tester.tap(find.text('open in Sequencer'));
    await tester.pumpAndSettle();
    expect(harness.container.read(selectedNodeIdProvider), 'step-7');
    expect(
      harness.router.routerDelegate.currentConfiguration.uri.path,
      '/sequencer',
    );
  });

  testWidgets('a row opens its own step', (tester) async {
    final harness = NightHarness(board: NightFixtures.running());
    await harness.pump(
      tester,
      const SizedBox(width: 272, child: NightStepsSection()),
      size: const Size(272, 758),
    );
    await tester.tap(find.text('L 30 × 180 s'));
    await tester.pumpAndSettle();
    expect(harness.container.read(selectedNodeIdProvider), 'step-9');
    expect(find.text('sequencer'), findsOneWidget);
  });

  testWidgets('a step reads its state and time', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = NightHarness(board: NightFixtures.running());
    await harness.pump(
      tester,
      const SizedBox(width: 272, child: NightStepsSection()),
      size: const Size(272, 758),
    );
    expect(
      find.bySemanticsLabel('Ha 60 × 180 s, dither 3, running now, 44/60'),
      findsOneWidget,
    );
    handle.dispose();
  });
}
