// The header: run pill, plan, the progress line and which run controls can
// be pressed. The controls only report their enabled state and why not; the
// header widget wires them to SequenceActionService and to the action
// controller.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../tonight_night.dart';
import '../../../../services/run_dashboard_providers.dart';
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
        hasHost: !ref.watch(
            backendProvider.select((b) => b.hostPlace == HostPlace.none)),
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

  if (ref.watch(isFlipInProgressProvider)) {
    if (startNow != null) startNow = _off('nightActBusyFlip');
    if (startAtDark != null && phase != NightRunPhase.armed) {
      startAtDark = _off('nightActBusyFlip');
    }
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
    actionUnderWay: live || phase == NightRunPhase.armed
        ? null
        : action.isBusy
            ? action.active
            // An autofocus started elsewhere (the Imaging screen).
            : ref.watch(autofocusOverlayProvider.select((a) => a.isRunning))
                ? ManualActionId.autofocus
                : null,
    runStartedAt: started == null ? null : clock.toNightClock(started),
    armedStartAt: phase == NightRunPhase.armed
        ? ref.watch(nightPlanArmedStartSeamProvider)
        : null,
    planName: tree?.sequence.name,
    targetIndex: targetIndex >= 0 ? targetIndex + 1 : null,
    targetCount: tree?.targets.length,
    stepIndex: stepIndex >= 0 ? stepIndex + 1 : null,
    stepCount: tree?.steps.length,
    // A frame held for a meridian flip is a wait too: two minutes with no
    // exposure and nothing on the header said why.
    waitingFor: switch ((
      progress?.nodeLatestReport[activeTarget?.id],
      progress?.nodeLatestReport[progress.currentNodeId],
    )) {
      (TargetWaitingProgressDetail(), _) =>
        progress!.nodeProgressDetail[activeTarget!.id],
      (_, FlipHoldProgressDetail()) => kFlipWaitShort,
      _ => null,
    },
    // A calibration step reads as what it is for ("Dark 55 s", "Flat Ha
    // 2 s"), not as the wheel's filter alone.
    currentFilter: switch (activeNode) {
      ExposureNode(:final frameType, :final filter)
          when frameType != FrameType.light &&
              frameType != FrameType.snapshot =>
        frameType.caption(_nonEmpty(progress?.currentFilter) ?? filter),
      // A plan the phone does not hold (the end-of-night darks) names its
      // frame type when the step starts.
      null when progress?.currentFrameType?.coverOnLabel != null =>
        progress!.currentFrameType!.coverOnLabel,
      _ => _nonEmpty(progress?.currentFilter) ??
          (activeNode is ExposureNode ? _nonEmpty(activeNode.filter) : null),
    },
    currentExposureSecs:
        activeNode is ExposureNode ? activeNode.durationSecs : null,
    framesDone: frames?.captured,
    framesTotal: frames == null
        ? null
        : frames.planned ??
            (activeNode == null ? null : nightPlannedFrames(activeNode)),
    plannedDuration:
        timing == null || tree == null || tree.openEnded || timing.openEnded
            ? null
            : timing.total,
    restoredFrames:
        live ? null : ref.watch(restoredCheckpointProvider)?.completedExposures,
    pauseResume: pauseResume,
    skipStep: skipStep,
    stop: stop,
    startNow: startNow,
    startAtDark: startAtDark,
    ending: ref.watch(nightRunEndingProvider),
  );
});

/// How the last run ended, once it has (null before then); the header pill
/// and the Overview card both say it.
final nightRunEndingProvider = Provider<NightRunEnding?>((ref) {
  if (ref.watch(nightRunPhaseProvider) != NightRunPhase.finished) return null;
  return switch (ref.watch(sequenceExecutionStateProvider)) {
    SequenceExecutionState.completed => NightRunEnding.completed,
    SequenceExecutionState.failed => NightRunEnding.failed,
    _ => ref.watch(sequenceStopEvidenceProvider)?.author ==
            SequenceStopAuthor.operatorPress
        ? NightRunEnding.stopped
        : NightRunEnding.ended,
  };
});

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// Why a plan cannot start at all, or null when it can.
String? _notReadyReason(
  NightPlanTree? tree, {
  required bool hasHost,
  required bool cameraConnected,
}) {
  if (tree == null) return 'ncPlanNoPlan';
  if (!tree.launchable) return 'ncPlanNothingToRun';
  // No imaging computer means no camera to connect: say what to do first.
  if (!hasHost) return 'ncPlanLinkComputer';
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
