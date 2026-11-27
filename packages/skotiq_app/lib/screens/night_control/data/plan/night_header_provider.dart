// The header: run pill, plan, the progress line and the run's controls
// (runTransportProvider). The controls only report their enabled state and
// why not; the header widget wires them to SequenceActionService and to the
// action controller.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../tonight_night.dart';
import '../../../../services/run_dashboard_providers.dart';
import '../../night_control_contracts.dart';
import '../../../../services/run_control/run_control.dart';
import 'night_plan_inputs.dart';
import 'plan_steps_provider.dart';
import '../../../../services/night_session/night_now.dart';

final nightHeaderProvider = Provider<NightHeaderVm>((ref) {
  final phase = ref.watch(nightRunPhaseProvider);
  final tree = ref.watch(nightPlanTreeProvider);
  final timing = ref.watch(nightPlanTimingProvider);
  final clock = ref.watch(clockProvider);
  final action = ref.watch(runActionStateProvider);
  final transport = ref.watch(runTransportProvider);

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
    runStartedAt: started == null ? null : clock.wallClockOf(started),
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
    pauseResume: transport.pauseResume,
    skipStep: transport.skip,
    stop: transport.stop,
    startNow: transport.start,
    startAtDark: transport.startLater(
      (gate) => _startAtDarkControl(ref, gate),
    ),
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

/// "Start at dark" needs a dark to start at, still ahead of now.
RunControl _startAtDarkControl(Ref ref, RunControl otherwise) {
  final night = ref.watch(tonightNightProvider);
  if (night == null) {
    return RunControl.disabled(NightText(
      ref.watch(appObserverLocationProvider) == null
          ? 'ncPlanNoSite'
          : 'ncPlanNoDarkTonight',
    ));
  }
  final now = ref.watch(clockProvider).wallClockOf(ref.watch(nightNowProvider));
  if (!now.isBefore(night.astroDark)) {
    return const RunControl.disabled(NightText('ncPlanAlreadyDark'));
  }
  return otherwise;
}
