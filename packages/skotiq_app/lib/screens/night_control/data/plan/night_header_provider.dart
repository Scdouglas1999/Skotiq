// The header: run pill, plan, the progress line and which run controls can
// be pressed. The controls only report their enabled state and why not; the
// header widget (P4) wires them to SequenceActionService and to the action
// controller (P2).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../../dashboard/widgets/tonight/tonight_night.dart';
import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';
import 'plan_steps_provider.dart';

const _enabled = NightControlVm.enabled();

NightControlVm _off(String key) => NightControlVm.disabled(NightText(key));

final nightHeaderProvider = Provider<NightHeaderVm>((ref) {
  final phase = ref.watch(nightRunPhaseProvider);
  final execution = ref.watch(sequenceExecutionStateProvider);
  final tree = ref.watch(nightPlanTreeProvider);
  final timing = ref.watch(nightPlanTimingProvider);
  final clock = ref.watch(clockProvider);
  final canCommand = ref.watch(backendCanCommandProvider);
  final action = ref.watch(nightPlanActionStateSeamProvider);

  // Every control needs a backend that can carry the command: a remote
  // viewer whose host went away must not offer to pause a run.
  NightControlVm gated(bool allowed, String reasonKey) {
    if (!allowed) return _off(reasonKey);
    return canCommand ? _enabled : _off('ncPlanCannotCommand');
  }

  NightControlVm? pauseResume;
  NightControlVm? skipStep;
  NightControlVm? stop;
  NightControlVm? startNow;
  NightControlVm? startAtDark;

  final liveReason = execution == SequenceExecutionState.recovering
      ? 'ncPlanRecovering'
      : 'ncPlanStopping';
  switch (phase) {
    case NightRunPhase.running:
      pauseResume = gated(execution.canPause, liveReason);
      skipStep = gated(execution.canSkip, liveReason);
      stop = gated(execution.canStop, liveReason);
    case NightRunPhase.pausedByUser:
      pauseResume = gated(execution.canResume, liveReason);
      skipStep = gated(execution.canSkip, liveReason);
      stop = gated(execution.canStop, liveReason);
    case NightRunPhase.pausedForAction:
      // The action controller resumes what it paused; a second resume from
      // the header would race it. Stop stays available.
      pauseResume = _off('ncPlanActionOwnsResume');
      skipStep = _off('ncPlanActionInProgress');
      stop = gated(execution.canStop, liveReason);
    case NightRunPhase.stopping:
      pauseResume = _off('ncPlanStopping');
      skipStep = _off('ncPlanStopping');
      // A failed stop or cleanup offers Stop again; finalizing has nothing
      // left to stop.
      stop = gated(execution.canStop, 'ncPlanFinalizing');
    case NightRunPhase.armed:
      startNow = gated(execution.canStart, 'ncPlanStopping');
      // Shown as the armed time with Cancel; cancelling is always possible.
      startAtDark = _enabled;
    case NightRunPhase.ready ||
          NightRunPhase.finished ||
          NightRunPhase.notSetUp:
      final notReady = _notReadyReason(
        tree,
        cameraConnected: ref.watch(nightCameraConnectedProvider),
      );
      startNow = notReady != null
          ? _off(notReady)
          : gated(execution.canStart, 'ncPlanStopping');
      startAtDark = notReady != null
          ? _off(notReady)
          : _startAtDarkControl(
              ref, gated(execution.canStart, 'ncPlanStopping'));
  }

  final live = phase.isRunLive;
  final progress = live ? ref.watch(sequenceProgressProvider) : null;
  final activeStep = ref.watch(nightActiveStepProvider);
  final activeTarget =
      live ? ref.watch(runDashboardActiveTargetProvider) : null;
  final targetIndex = activeTarget == null || tree == null
      ? -1
      : tree.targets.indexWhere((t) => t.id == activeTarget.id);
  final stepIndex =
      activeStep == null || tree == null ? -1 : tree.steps.indexOf(activeStep);
  final activeNode = activeStep?.node;
  final frames = activeStep == null || progress == null
      ? null
      : nightNodeFrames(
          activeStep.node.id,
          tally: ref.watch(nodeExposureTallyProvider),
          progress: progress,
        );

  final started =
      live ? ref.watch(sessionStateProvider.select((s) => s.startTime)) : null;

  return NightHeaderVm(
    phase: phase,
    pausedFor: phase == NightRunPhase.pausedForAction ? action.active : null,
    runStartedAt: started == null ? null : clock.toNightClock(started),
    armedStartAt: phase == NightRunPhase.armed
        ? ref.watch(nightPlanArmedStartSeamProvider)
        : null,
    planName: tree?.sequence.name,
    targetIndex: targetIndex >= 0 ? targetIndex + 1 : null,
    targetCount: tree?.targets.length,
    stepIndex: stepIndex >= 0 ? stepIndex + 1 : null,
    stepCount: tree?.steps.length,
    currentFilter: _nonEmpty(progress?.currentFilter) ??
        (activeNode is ExposureNode ? _nonEmpty(activeNode.filter) : null),
    currentExposureSecs:
        activeNode is ExposureNode ? activeNode.durationSecs : null,
    framesDone: frames?.captured,
    framesTotal: frames == null
        ? null
        : frames.planned ??
            (activeNode == null ? null : nightPlannedFrames(activeNode)),
    plannedDuration:
        timing == null || tree == null || tree.openEnded ? null : timing.total,
    pauseResume: pauseResume,
    skipStep: skipStep,
    stop: stop,
    startNow: startNow,
    startAtDark: startAtDark,
  );
});

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// Why a plan cannot start at all, or null when it can.
String? _notReadyReason(NightPlanTree? tree, {required bool cameraConnected}) {
  if (tree == null) return 'ncPlanNoPlan';
  if (!tree.launchable) return 'ncPlanNothingToRun';
  if (!cameraConnected) return 'ncPlanConnectCamera';
  return null;
}

/// "Start at dark" needs a dark to start at, still ahead of now.
NightControlVm _startAtDarkControl(Ref ref, NightControlVm otherwise) {
  final night = ref.watch(tonightNightProvider);
  if (night == null) {
    return _off(
      ref.watch(appObserverLocationProvider) == null
          ? 'ncPlanNoSite'
          : 'ncPlanNoDarkTonight',
    );
  }
  final now =
      ref.watch(clockProvider).toNightClock(ref.watch(nightNowProvider));
  if (!now.isBefore(night.astroDark)) return _off('ncPlanAlreadyDark');
  return otherwise;
}
