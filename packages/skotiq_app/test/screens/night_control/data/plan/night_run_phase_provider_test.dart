// The run phase and the header controls it decides: which run controls the
// header offers and, when one cannot be pressed, the reason it gives.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

  // A stopped or dawn-ended run settles idle; Tonight read "Ready · not
  // started" with 0 frames (qa-pair QP-22, reverify RV-11).
  test('a run that was stopped reads as finished until another plan loads', () {
    final plan = TwoTargetPlan().sequence;
    final container = planContainer(
      now: evening,
      sequence: plan,
      execution: SequenceExecutionState.running,
    );
    addTearDown(container.dispose);
    container.listen(lastEndedRunProvider, (_, __) {});
    expect(container.read(nightRunPhaseProvider), NightRunPhase.running);

    container.read(runRecordProvider.notifier).setLifecycle(SequenceExecutionState.idle);
    expect(container.read(nightRunPhaseProvider), NightRunPhase.finished);

    container.read(currentSequenceProvider.notifier).createSequence(
          name: 'Another plan',
        );
    expect(
        container.read(nightRunPhaseProvider), isNot(NightRunPhase.finished));
  });

  // A stopped one-tap night read "Not set up · No plan loaded" over the
  // frames it had just taken: the planner's plan left the editor when the
  // run ended, and with it everything that says a run happened.
  test('a one-tap run started from an empty editor reads as finished, with '
      'its plan, after it ends', () {
    final plan = TwoTargetPlan().sequence;
    for (final releaseFirst in [true, false]) {
      final container = planContainer(now: evening);
      addTearDown(container.dispose);
      container.listen(lastEndedRunProvider, (_, __) {});
      final editor = container.read(currentSequenceProvider.notifier);
      final execution = container.read(runRecordProvider.notifier);

      editor.takeOwnership(plan, ActivePlanOwner.smartNight);
      execution.setLifecycle(SequenceExecutionState.running);
      expect(container.read(nightRunPhaseProvider), NightRunPhase.running);

      // The executor hands the editor back as the run ends.
      if (releaseFirst) editor.releaseOwnership();
      execution.setLifecycle(SequenceExecutionState.idle);
      if (!releaseFirst) editor.releaseOwnership();

      final header = container.read(nightHeaderProvider);
      expect(header.phase, NightRunPhase.finished,
          reason: 'released first: $releaseFirst');
      expect(header.planName, plan.name);
      expect(header.startNow, const NightControlVm.enabled(),
          reason: 'the plan can be started again');
    }
  });

  // SY-36: the header read "Finished" in gray for a run the host and the
  // rig chip reported as failed.
  test('how a finished run ended: completed, failed, or ended otherwise', () {
    final plan = TwoTargetPlan().sequence;
    for (final (state, ending) in <(SequenceExecutionState, NightRunEnding)>[
      (SequenceExecutionState.completed, NightRunEnding.completed),
      (SequenceExecutionState.failed, NightRunEnding.failed),
      // The host's "cancelled" and "stopped" settle idle on a linked client.
      (SequenceExecutionState.idle, NightRunEnding.ended),
    ]) {
      final container = planContainer(
        now: evening,
        sequence: plan,
        execution: SequenceExecutionState.running,
      );
      addTearDown(container.dispose);
      container.listen(lastEndedRunProvider, (_, __) {});
      expect(container.read(nightHeaderProvider).ending, isNull,
          reason: 'a live run has not ended');

      container.read(runRecordProvider.notifier).setLifecycle(state);
      final header = container.read(nightHeaderProvider);
      expect(header.phase, NightRunPhase.finished, reason: '$state');
      expect(header.ending, ending, reason: '$state');
    }
  });

  test('a run the operator stopped reads as stopped; a dawn park does not', () {
    final plan = TwoTargetPlan().sequence;
    for (final (evidence, ending) in <(SequenceStopDecision?, NightRunEnding)>[
      (
        const SequenceStopDecision(SequenceStopAuthor.operatorPress),
        NightRunEnding.stopped,
      ),
      (
        const SequenceStopDecision(
          SequenceStopAuthor.system,
          origin: 'dawn_approaching',
          parked: true,
        ),
        NightRunEnding.ended,
      ),
      (null, NightRunEnding.ended),
    ]) {
      final container = planContainer(
        now: evening,
        sequence: plan,
        execution: SequenceExecutionState.running,
      );
      addTearDown(container.dispose);
      container.listen(lastEndedRunProvider, (_, __) {});
      container.read(runRecordProvider.notifier).setStopEvidence(evidence);
      container.read(runRecordProvider.notifier).setLifecycle(SequenceExecutionState.idle);
      expect(
        container.read(nightHeaderProvider).ending,
        ending,
        reason: '${evidence?.author}',
      );
    }
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

  test('an action under way with no run is named; during a run it is not', () {
    const autofocus = ManualActionState(
      phase: ManualActionPhase.running,
      active: ManualActionId.autofocus,
    );
    final idle = planContainer(now: evening, action: autofocus);
    addTearDown(idle.dispose);
    expect(idle.read(nightRunPhaseProvider), NightRunPhase.notSetUp);
    expect(idle.read(nightHeaderProvider).actionUnderWay,
        ManualActionId.autofocus);

    final running = planContainer(
      now: evening,
      sequence: TwoTargetPlan().sequence,
      execution: SequenceExecutionState.running,
      action: autofocus,
    );
    addTearDown(running.dispose);
    expect(running.read(nightHeaderProvider).actionUnderWay, isNull);

    final nothing = planContainer(now: evening);
    addTearDown(nothing.dispose);
    expect(nothing.read(nightHeaderProvider).actionUnderWay, isNull);
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
