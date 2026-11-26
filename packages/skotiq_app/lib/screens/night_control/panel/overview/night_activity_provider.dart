import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart' show CoordinateFormat;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../../../utils/guide_distance.dart';
import '../../../../services/night_actions/night_action_controller.dart';
import '../../data/plan/night_header_provider.dart' show nightRunEndingProvider;
import '../../data/plan/night_run_phase_provider.dart';
import '../../data/plan/plan_steps_provider.dart';
import '../../data/session/session_format.dart';
import '../guide/guide_metrics.dart';
import '../../night_control_contracts.dart';

enum NightActivityKind {
  ready,
  focus,
  slew,
  center,
  capture,
  guide,
  flip,
  waiting,
  paused,
  stopping,
  finished,
  failed,
  recovery,
}

class NightActivityVm {
  const NightActivityVm({
    required this.kind,
    required this.title,
    this.target,
    this.context,
    this.detail,
    this.progress,
    this.metrics = const [],
  });
  final NightActivityKind kind;
  final NightText title;
  final String? target;
  final NightText? context;
  final String? detail;
  final double? progress;
  final List<MetricVm> metrics;
}

/// Operation ownership takes precedence over device telemetry. In particular,
/// a background plate solve or ordinary guiding cannot replace an exposure.
NightActivityKind resolveNightActivity({
  required NightRunPhase phase,
  required SequenceExecutionState execution,
  SequenceNode? node,
  InstructionProgressDetail? detail,
  bool autofocusRunning = false,
  bool flipping = false,
  FlipStep? flipStep,
  CenteringState centering = CenteringState.idle,
  bool exposing = false,
  bool settling = false,
  ManualActionId? manualAction,
}) {
  if (phase == NightRunPhase.notSetUp ||
      phase == NightRunPhase.ready ||
      phase == NightRunPhase.armed) {
    return NightActivityKind.ready;
  }
  if (execution == SequenceExecutionState.failed ||
      execution == SequenceExecutionState.stopFailed ||
      execution == SequenceExecutionState.cleanupFailed) {
    return NightActivityKind.failed;
  }
  if (phase == NightRunPhase.finished) return NightActivityKind.finished;
  if (phase == NightRunPhase.stopping) return NightActivityKind.stopping;
  if (phase == NightRunPhase.pausedByUser) return NightActivityKind.paused;
  if (autofocusRunning || manualAction == ManualActionId.autofocus) {
    return NightActivityKind.focus;
  }
  if (flipping) {
    return switch (flipStep) {
      FlipStep.refocusing => NightActivityKind.focus,
      FlipStep.plateSolvingAndCentering => NightActivityKind.center,
      FlipStep.resumingGuider || FlipStep.settling => NightActivityKind.guide,
      _ => NightActivityKind.flip,
    };
  }
  final activity = node?.kind.activity;
  final centeringActive = switch (centering) {
    CenteringState.exposing ||
    CenteringState.solving ||
    CenteringState.slewing ||
    CenteringState.verifying =>
      true,
    _ => false,
  };
  if (centeringActive ||
      activity == NodeActivity.center ||
      detail is CenterInstructionProgressDetail ||
      manualAction == ManualActionId.center ||
      manualAction == ManualActionId.solve ||
      manualAction == ManualActionId.solveSync) {
    return NightActivityKind.center;
  }
  if (execution == SequenceExecutionState.recovering) {
    return NightActivityKind.recovery;
  }
  if (detail is AutofocusInstructionProgressDetail ||
      activity == NodeActivity.focus) {
    return NightActivityKind.focus;
  }
  if (activity == NodeActivity.slew) return NightActivityKind.slew;
  if (activity == NodeActivity.flip ||
      detail is MeridianFlipStepProgressDetail ||
      manualAction == ManualActionId.flip) {
    return NightActivityKind.flip;
  }
  if (exposing) return NightActivityKind.capture;
  if (settling ||
      activity == NodeActivity.guide ||
      manualAction == ManualActionId.dither) {
    return NightActivityKind.guide;
  }
  if (activity == NodeActivity.capture ||
      detail is ExposureInstructionProgressDetail ||
      detail is SmartExposureInstructionProgressDetail) {
    return NightActivityKind.capture;
  }
  return NightActivityKind.waiting;
}

final nightActivityProvider = Provider<NightActivityVm>((ref) {
  final phase = ref.watch(nightRunPhaseProvider);
  final execution = ref.watch(sequenceExecutionStateProvider);
  final activeNode = ref.watch(nightActiveStepProvider)?.node;
  final progress = ref.watch(sequenceProgressProvider);
  bool ended(String? id) => switch (progress.nodeStatuses[id]) {
        NodeStatus.success ||
        NodeStatus.failure ||
        NodeStatus.skipped ||
        NodeStatus.cancelled =>
          true,
        _ => false,
      };
  final node = ended(activeNode?.id) ? null : activeNode;
  final id = progress.currentNodeId;
  final structured =
      ended(id) ? null : progress.nodeProgressStructuredDetail[id];
  final percent = progress.nodeProgressPercent[id];
  // A completed sub-operation must not keep its panel when capture resumes.
  final current = percent != null && percent >= 100 ? null : structured;
  final camera = ref.watch(cameraStateProvider);
  final mount = ref.watch(mountStateProvider);
  final center = ref.watch(centeringStatusProvider);
  final flipping = ref.watch(isFlipInProgressProvider);
  final flipStep = ref.watch(flipCurrentStepProvider);
  final phd2 = ref.watch(phd2StateProvider);
  final kind = resolveNightActivity(
    phase: phase,
    execution: execution,
    node: node,
    detail: current,
    autofocusRunning: ref.watch(autofocusOverlayProvider).isRunning,
    flipping: flipping,
    flipStep: flipStep,
    centering: center.state,
    exposing: camera.isExposing,
    settling: phd2 == Phd2State.settling,
    manualAction: phase == NightRunPhase.pausedForAction
        ? ref.watch(nightActionStateProvider).active
        : null,
  );
  final centerActive = switch (center.state) {
    CenteringState.exposing ||
    CenteringState.solving ||
    CenteringState.slewing ||
    CenteringState.verifying =>
      true,
    _ => false,
  };
  final centerReport =
      structured is CenterInstructionProgressDetail ? structured : null;
  MetricVm metric(String label, String? value) =>
      MetricVm(label: NightText(label), value: value);
  String? fixed(double? v, [String unit = '']) =>
      v != null && v.isFinite ? '${nightFixed(v, 1)}$unit' : null;
  final metrics = <MetricVm>[];
  double? fraction;
  String? detail;
  var titleKey =
      'nightActivity${kind.name[0].toUpperCase()}${kind.name.substring(1)}';
  // "Sequence finished" under a header pill that says "Stopped": the card
  // says how the run ended, as the pill does.
  if (kind == NightActivityKind.finished) {
    titleKey = switch (ref.watch(nightRunEndingProvider)) {
      NightRunEnding.completed => 'nightActivityCompleted',
      NightRunEnding.stopped => 'nightActivityStopped',
      NightRunEnding.failed => 'nightActivityFailed',
      NightRunEnding.ended || null => 'nightActivityEnded',
    };
  }
  if (kind == NightActivityKind.capture) {
    final exposure = ref.watch(exposureProgressProvider);
    final wheel = ref.watch(filterWheelStateProvider);
    if (camera.isExposing || exposure.isDownloading) {
      fraction = exposure.isDownloading ? null : exposure.percent / 100;
      titleKey = exposure.isDownloading ? 'nightActivityDownloading' : titleKey;
    } else {
      titleKey = 'nightActivityBetweenFrames';
    }
    metrics.addAll([
      metric('nightScopeSolveFilter',
          progress.currentFilter ?? wheel.currentFilterName),
      metric(
          'nightScopeSolveExposure',
          fixed(
              structured is ExposureInstructionProgressDetail
                  ? structured.durationSecs
                  : node is ExposureNode
                      ? node.durationSecs
                      // A Smart Exposure step (what Image tonight builds)
                      // takes the length of the filter plan it is on.
                      : node is SmartExposureNode
                          ? _smartPlanSecs(node, structured)
                          : null,
              ' s')),
      metric('nightPanelGain', camera.gain?.toString()),
      metric('nightPanelOffset', camera.offset?.toString()),
      metric(
          'nightPanelSensor',
          camera.temperature == null
              ? null
              : nightCelsius(camera.temperature!)),
      metric(
          'nightActivityFrames',
          progress.totalExposures > 0
              ? '${progress.completedExposures} / ${progress.totalExposures}'
              : '${progress.completedExposures}'),
      if (camera.isExposing)
        metric('nightSessionStatRemaining', fixed(exposure.remaining, ' s')),
    ]);
  } else if (kind == NightActivityKind.slew ||
      kind == NightActivityKind.flip ||
      kind == NightActivityKind.center) {
    metrics.addAll([
      metric(
          'nightScopeRaJNow',
          mount.connectionState != DeviceConnectionState.connected ||
                  mount.ra == null
              ? null
              : CoordinateFormat.raDense(mount.ra!)),
      metric(
          'nightScopeDecJNow',
          mount.connectionState != DeviceConnectionState.connected ||
                  mount.dec == null
              ? null
              : CoordinateFormat.decDense(mount.dec!)),
      metric(
          'nightActivityAltitude',
          fixed(
              mount.connectionState == DeviceConnectionState.connected
                  ? mount.altitude
                  : null,
              '°')),
      metric(
          'nightActivityAzimuth',
          fixed(
              mount.connectionState == DeviceConnectionState.connected
                  ? mount.azimuth
                  : null,
              '°')),
    ]);
    if (kind == NightActivityKind.center) {
      titleKey = mount.isSlewing || center.state == CenteringState.slewing
          ? 'nightActivityCenterSlew'
          : camera.isExposing || center.state == CenteringState.exposing
              ? 'nightActivityCenterExposure'
              : center.state == CenteringState.verifying
                  ? 'nightActivityVerifying'
                  : 'nightActivityCenter';
      final current = centerActive && center.currentIteration > 0
          ? center.currentIteration
          : centerReport?.attempt;
      final maximum = centerActive && center.maxIterations > 0
          ? center.maxIterations
          : centerReport?.maxAttempts;
      metrics.addAll([
        metric('nightActivityAttempt',
            current == null ? null : '$current / ${maximum ?? "—"}'),
        metric(
            'nightScopeSolveOffTarget',
            fixed(
                centerActive
                    ? center.currentOffsetArcsec
                    : centerReport?.lastSeparationArcsec,
                '″')),
      ]);
      detail = centerActive ? center.message : null;
    }
    if (kind == NightActivityKind.flip) {
      detail = progress.nodeProgressDetail[id];
      fraction = percent == null ? null : percent / 100;
    }
    if (flipping) fraction = ref.watch(flipProgressProvider) / 100;
    if (kind == NightActivityKind.slew && percent != null) {
      fraction = percent / 100;
    }
  } else if (kind == NightActivityKind.guide) {
    titleKey = phd2 == Phd2State.settling ? 'nightActivitySettling' : titleKey;
    final rms = ref.watch(nightGuideRmsProvider);
    final scale = ref.watch(guideScaleProvider);
    metrics.addAll([
      metric('nightActivityRaRms', formatGuide(rms.ra, scale)),
      metric('nightActivityDecRms', formatGuide(rms.dec, scale)),
      metric('nightActivityTotalRms', formatGuide(rms.total, scale)),
    ]);
  } else if (kind == NightActivityKind.recovery) {
    final recovery = ref.watch(currentRecoveryProvider);
    detail = recovery?.lastError ?? progress.message;
    if (recovery != null) {
      metrics.add(metric('nightActivityAttempt',
          '${recovery.attemptCount} / ${recovery.maxAttempts}'));
    }
  } else if (kind == NightActivityKind.waiting) {
    detail = progress.nodeProgressDetail[id] ?? progress.currentNodeName;
  } else if (kind == NightActivityKind.failed ||
      kind == NightActivityKind.paused ||
      kind == NightActivityKind.stopping) {
    detail = progress.message;
  }
  final flipOperation = flipping &&
      switch (kind) {
        NightActivityKind.flip ||
        NightActivityKind.focus ||
        NightActivityKind.center ||
        NightActivityKind.guide =>
          true,
        _ => false,
      };
  final stageKey = switch (flipStep) {
    FlipStep.enablingTracking ||
    FlipStep.confirmingTracking =>
      'nightActivityFlip',
    FlipStep.pausingGuider => 'nightActivityFlipPauseGuide',
    FlipStep.slewingToTarget => 'nightActivitySlew',
    FlipStep.verifyingPierSide => 'nightActivityFlipVerifySide',
    FlipStep.plateSolvingAndCentering => titleKey,
    FlipStep.refocusing => 'nightActivityFocus',
    FlipStep.resumingGuider => 'nightActivityGuide',
    FlipStep.settling => 'nightActivitySettling',
    null => 'nightActivityFlip',
  };
  return NightActivityVm(
    kind: kind,
    title: NightText(flipOperation ? stageKey : titleKey),
    context: flipOperation && stageKey != 'nightActivityFlip'
        ? const NightText('nightActivityFlip')
        : null,
    target: phase.isRunLive ? progress.currentTarget : null,
    detail: detail,
    progress: fraction?.isFinite == true ? fraction!.clamp(0, 1) : null,
    metrics: metrics,
  );
});

/// The sub-exposure length of the filter plan [node] is taking: the plan the
/// run reports when it does, else the plan for the filter in the wheel.
double? _smartPlanSecs(SmartExposureNode node, Object? structured) {
  if (structured is SmartExposureInstructionProgressDetail &&
      structured.planIndex >= 0 &&
      structured.planIndex < node.plans.length) {
    return node.plans[structured.planIndex].durationSecs;
  }
  if (node.plans.length == 1) return node.plans.single.durationSecs;
  return null;
}
