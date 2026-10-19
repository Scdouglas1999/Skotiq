// The Solve tab: no result yet, a result against the target, the action
// controller's gating, and the 300 px layout.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/solve/night_solve_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../panel_test_support.dart';

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
    expect(find.text("8.7'"), findsOneWidget, reason: 'off target');
  });

  testWidgets('Solve & sync and Center go through the action controller',
      (tester) async {
    final api = RecordingActionApi();
    await pumpPanelTab(
      tester,
      const NightSolveTab(),
      overrides: panelOverrides(
        api: api,
        inputs: panelInputs(runState: SequenceExecutionState.running),
      ),
    );
    await tester.tap(find.byKey(_solveSync));
    await tester.pump();
    await tester.tap(find.byKey(_center));
    await tester.pump();
    expect(api.calls, ['solveAndSync', 'center']);
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
