// The run phase and the header controls it decides: which run controls the
// header offers and, when one cannot be pressed, the reason it gives.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import 'plan_test_support.dart';

void main() {
  final evening = DateTime(2026, 10, 19, 18, 36);

  test('no plan loaded: not set up, and Start says why', () {
    final container = planContainer(now: evening);
    addTearDown(container.dispose);

    expect(container.read(nightRunPhaseProvider), NightRunPhase.notSetUp);
    final header = container.read(nightHeaderProvider);
    expect(header.planName, isNull);
    expect(header.startNow?.enabled, isFalse);
    expect(header.startNow?.disabledReason, const NightText('ncPlanNoPlan'));
    expect(header.pauseResume, isNull);
    expect(header.stop, isNull);
  });

  test('a plan with the camera disconnected is not set up', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      cameraConnected: false,
    );
    addTearDown(container.dispose);

    expect(container.read(nightRunPhaseProvider), NightRunPhase.notSetUp);
    expect(
      container.read(nightHeaderProvider).startNow?.disabledReason,
      const NightText('ncPlanConnectCamera'),
    );
  });

  test('a loaded plan and a camera: ready, with both starts offered', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
    );
    addTearDown(container.dispose);

    expect(container.read(nightRunPhaseProvider), NightRunPhase.ready);
    final header = container.read(nightHeaderProvider);
    expect(header.planName, 'M74 plan');
    expect(header.targetCount, 2);
    expect(header.stepCount, 3);
    expect(header.targetIndex, isNull, reason: 'no run, no current target');
    expect(header.startNow, const NightControlVm.enabled());
    expect(header.startAtDark, const NightControlVm.enabled());
    expect(header.plannedDuration, isNotNull);
  });

  test('Start at dark needs a site, and a dark still ahead', () {
    final noSite = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      site: false,
    );
    addTearDown(noSite.dispose);
    expect(
      noSite.read(nightHeaderProvider).startAtDark?.disabledReason,
      const NightText('ncPlanNoSite'),
    );
    expect(noSite.read(nightHeaderProvider).startNow?.enabled, isTrue);

    final dark = planContainer(
      now: DateTime(2026, 10, 19, 21),
      sequence: TwoTargetPlan().sequence,
    );
    addTearDown(dark.dispose);
    expect(
      dark.read(nightHeaderProvider).startAtDark?.disabledReason,
      const NightText('ncPlanAlreadyDark'),
    );
  });

  test('a remote viewer that cannot command gets disabled controls', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      canCommand: false,
    );
    addTearDown(container.dispose);

    final header = container.read(nightHeaderProvider);
    expect(header.phase, NightRunPhase.running);
    for (final control in [header.pauseResume, header.skipStep, header.stop]) {
      expect(control?.enabled, isFalse);
      expect(control?.disabledReason, const NightText('ncPlanCannotCommand'));
    }
  });

  test('a pause the operator made reads as paused by user', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.paused,
    );
    addTearDown(container.dispose);

    expect(container.read(nightRunPhaseProvider), NightRunPhase.pausedByUser);
    final header = container.read(nightHeaderProvider);
    expect(header.pausedFor, isNull);
    expect(header.pauseResume, const NightControlVm.enabled());
    expect(header.skipStep, const NightControlVm.enabled());
    expect(header.stop, const NightControlVm.enabled());
  });

  test('a pause the action controller made reads as paused for that action',
      () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.paused,
      action: const ManualActionState(
        phase: ManualActionPhase.running,
        active: ManualActionId.autofocus,
        startedRunPause: true,
      ),
    );
    addTearDown(container.dispose);

    expect(
      container.read(nightRunPhaseProvider),
      NightRunPhase.pausedForAction,
    );
    final header = container.read(nightHeaderProvider);
    expect(header.pausedFor, ManualActionId.autofocus);
    expect(
      header.pauseResume?.disabledReason,
      const NightText('ncPlanActionOwnsResume'),
    );
    expect(header.stop, const NightControlVm.enabled(),
        reason: 'Stop is never taken away from a paused run.');
  });

  test('an action running while the operator had paused is still their pause',
      () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.paused,
      action: const ManualActionState(
        phase: ManualActionPhase.running,
        active: ManualActionId.solveSync,
      ),
    );
    addTearDown(container.dispose);

    expect(container.read(nightRunPhaseProvider), NightRunPhase.pausedByUser);
  });

  test('a manual loop holds the run even though the operator started it', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.paused,
      action: const ManualActionState(
        phase: ManualActionPhase.running,
        active: ManualActionId.loop,
      ),
    );
    addTearDown(container.dispose);

    expect(
      container.read(nightRunPhaseProvider),
      NightRunPhase.pausedForAction,
    );
  });

  test('an armed start reads as armed and carries its time', () {
    final armedAt = DateTime(2026, 10, 19, 19, 48);
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      armedStartAt: armedAt,
    );
    addTearDown(container.dispose);

    final header = container.read(nightHeaderProvider);
    expect(header.phase, NightRunPhase.armed);
    expect(header.armedStartAt, armedAt);
    expect(header.startNow?.enabled, isTrue);
  });

  test('stopping, a failed stop and finalizing', () {
    for (final (state, stopEnabled) in [
      (SequenceExecutionState.stopping, true),
      (SequenceExecutionState.stopFailed, true),
      (SequenceExecutionState.finalizing, false),
    ]) {
      final container = planContainer(
        now: evening,
        sequence: TwoTargetPlan().sequence,
        execution: state,
      );
      addTearDown(container.dispose);

      final header = container.read(nightHeaderProvider);
      expect(header.phase, NightRunPhase.stopping, reason: '$state');
      expect(header.stop?.enabled, stopEnabled, reason: '$state');
      expect(header.startNow, isNull, reason: '$state');
    }
  });

  test('a completed run reads as finished and can start again', () {
    final container = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.completed,
    );
    addTearDown(container.dispose);

    expect(container.read(nightRunPhaseProvider), NightRunPhase.finished);
    expect(container.read(nightHeaderProvider).startNow?.enabled, isTrue);
  });
}
