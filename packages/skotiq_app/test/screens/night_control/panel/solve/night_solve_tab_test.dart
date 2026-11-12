// The Solve tab: no result yet, a result against the target, the action
// controller's gating, and the 300 px layout.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/solve/solve_sections.dart';
import 'package:skotiq_app/screens/night_control/panel/solve/night_solve_tab.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

import '../scope_panel_test_support.dart';

PlateSolveResult _solved({double ra = 24.17, double dec = 15.78}) =>
    PlateSolveResult(
      success: true,
      ra: ra,
      dec: dec,
      pixelScale: 0.77,
      rotation: 0.4,
      fieldWidth: 1.0,
      fieldHeight: 0.75,
      solveTimeSecs: 2.1,
      cd11: 0,
      cd12: 0,
      cd21: 0,
      cd22: 0,
      sipAOrder: 0,
      sipBOrder: 0,
      sipACoeffs: Float64List(0),
      sipBCoeffs: Float64List(0),
      sipApOrder: 0,
      sipBpOrder: 0,
      sipApCoeffs: Float64List(0),
      sipBpCoeffs: Float64List(0),
    );

const _solve = ValueKey<String>('nightSolve.solve');
const _solveSync = ValueKey<String>('nightSolve.solveSync');
const _center = ValueKey<String>('nightSolve.center');
const _setUpSolver = ValueKey<String>('nightSolve.setUpSolver');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('with no solve yet every value is a dash', (tester) async {
    await pumpPanelTab(tester, const NightSolveTab(),
        overrides: panelOverrides());
    expectCleanLayout(tester);
    expect(find.text('No solve yet this session'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    expect(find.text('0.0°'), findsNothing);
    expect(find.text('No solves yet'), findsOneWidget);
    expect(
      find.text('Solve a frame to compare the camera angle with the target.'),
      findsOneWidget,
    );
    // No frame on screen: Solve says why.
    expect(isEnabled(tester, _solve), isFalse);
    expect(tooltipOf(tester, _solve), 'Take a frame first');
  });

  testWidgets('a solve shows its numbers and the distance to the target',
      (tester) async {
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: [
        ...panelOverrides(),
        plateSolveStateProvider
            .overrideWith((ref) => PlateSolveState(lastResult: _solved())),
        // The target is 0.01 h (9') east of the solve in RA.
        nightCenterTargetProvider.overrideWithValue(
          const NightCenterTarget(
            name: 'M74',
            raHours: 24.17 / 15 + 0.01,
            decDegrees: 15.78,
          ),
        ),
      ],
    );
    expectCleanLayout(tester);
    expect(find.text('Solved · 2.1 s'), findsOneWidget);
    expect(find.text('0.77"/px'), findsOneWidget);
    expect(find.text("60'×45'"), findsOneWidget);
    // In arcseconds, the unit every off-target reading uses.
    expect(find.text('520"'), findsOneWidget, reason: 'off target');
  });

  testWidgets('Solve, Solve & sync and Center go through the action controller',
      (tester) async {
    final api = RecordingActionApi();
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: panelOverrides(
        api: api,
        inputs: panelInputs(
          runState: SequenceExecutionState.running,
          hasFrame: true,
        ),
      ),
    );
    await tester.tap(find.byKey(_solve));
    await tester.pump();
    await tester.tap(find.byKey(_solveSync));
    await tester.pump();
    await tester.tap(find.byKey(_center));
    await tester.pump();
    expect(api.calls, ['solve', 'solveAndSync', 'center']);
  });

  testWidgets('the centering note quotes the config Center runs',
      (tester) async {
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: [
        ...panelOverrides(),
        nightCenteringConfigProvider.overrideWithValue(
          const CenteringConfig(maxIterations: 7, toleranceArcsec: 12),
        ),
      ],
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pump();
    expect(find.textContaining('Center button: within 12" · 7 attempts'),
        findsOneWidget);
    expect(find.textContaining("Plan's Center step"), findsNothing);
  });

  // SY-19: during a run whose Center step centers within 5", the tab said
  // "Center within 30"", the Center button's tolerance, as if it were the
  // run's.
  testWidgets(
      'a plan with a Center step quotes that step, apart from the button',
      (tester) async {
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: [
        ...panelOverrides(),
        nightCenteringConfigProvider.overrideWithValue(
          const CenteringConfig(maxIterations: 5, toleranceArcsec: 30),
        ),
        nightPlanCenterNodeProvider.overrideWithValue(
          CenterNode(id: 'center', accuracyArcsec: 5, maxAttempts: 5),
        ),
      ],
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pump();
    expect(find.text('Plan\'s Center step: within 5" · 5 attempts'),
        findsOneWidget);
    expect(find.textContaining('Center button: within 30" · 5 attempts'),
        findsOneWidget);
  });

  test('the plan Center step is the running one, else the first in the plan',
      () {
    final sequence = Sequence.create(
      name: 'Run',
      rootNodeId: 'root',
      nodes: {
        'root': InstructionSetNode(
          id: 'root',
          name: 'Run',
          childIds: const ['slew', 'first', 'second'],
        ),
        'slew': SlewNode(id: 'slew', parentId: 'root', orderIndex: 0),
        'first': CenterNode(
          id: 'first',
          parentId: 'root',
          orderIndex: 1,
          accuracyArcsec: 5,
        ),
        'second': CenterNode(
          id: 'second',
          parentId: 'root',
          orderIndex: 2,
          accuracyArcsec: 8,
        ),
      },
    );
    final tree = buildNightPlanTree(sequence);

    ProviderContainer container(NightPlanTree? tree, NightPlanEntry? active) {
      final c = ProviderContainer(overrides: [
        nightPlanTreeProvider.overrideWithValue(tree),
        nightActiveStepProvider.overrideWithValue(active),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    expect(
        container(tree, null).read(nightPlanCenterNodeProvider)?.id, 'first');
    final second = tree.steps.firstWhere((s) => s.node.id == 'second');
    expect(container(tree, second).read(nightPlanCenterNodeProvider)?.id,
        'second');
    expect(container(null, null).read(nightPlanCenterNodeProvider), isNull);
  });

  testWidgets(
      'with no plate solver the tab says so and offers to set one up in '
      'place of Solve & sync', (tester) async {
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: panelOverrides(
        inputs: panelInputs(hasFrame: true, solverMissing: true),
      ),
    );
    expect(find.text('No plate solver set up'), findsOneWidget);
    expect(find.byKey(_solveSync), findsNothing);
    expect(find.byKey(_setUpSolver), findsOneWidget);
    expect(isEnabled(tester, _solve), isFalse);
    expect(tooltipOf(tester, _solve), 'No plate solver is set up');
    expect(tooltipOf(tester, _center), 'No plate solver is set up');
    expectCleanLayout(tester);
  });

  testWidgets('a busy controller disables its actions with the reason',
      (tester) async {
    const busy = ManualActionState(
      phase: ManualActionPhase.running,
      active: ManualActionId.autofocus,
    );
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: panelOverrides(
        action: busy,
        inputs: panelInputs(action: busy),
      ),
    );
    expect(isEnabled(tester, _solveSync), isFalse);
    expect(tooltipOf(tester, _solveSync), 'Autofocus is running');
    expect(tooltipOf(tester, _solve), 'Autofocus is running');
  });

  testWidgets('lays out at 1.3x text without overflow', (tester) async {
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: [
        ...panelOverrides(),
        plateSolveStateProvider
            .overrideWith((ref) => PlateSolveState(lastResult: _solved())),
      ],
      textScale: 1.3,
    );
    expectCleanLayout(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pump();
    expectCleanLayout(tester);
  });
}
