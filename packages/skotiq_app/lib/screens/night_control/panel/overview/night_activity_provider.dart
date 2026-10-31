import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../actions/night_action_controller.dart';
import '../../data/plan/night_run_phase_provider.dart';
import '../../data/plan/plan_steps_provider.dart';
import '../../data/session/guide_series_provider.dart';
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
  String? detailKind,
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
  final centeringActive = switch (centering) {
    CenteringState.exposing ||
    CenteringState.solving ||
    CenteringState.slewing ||
    CenteringState.verifying =>
      true,
    _ => false,
  };
  if (centeringActive ||
      node is CenterNode ||
      detailKind == 'Center' ||
      manualAction == ManualActionId.center ||
      manualAction == ManualActionId.solve ||
      manualAction == ManualActionId.solveSync) {
    return NightActivityKind.center;
  }
  if (execution == SequenceExecutionState.recovering) {
    return NightActivityKind.recovery;
  }
  if (detailKind == 'Autofocus' || node is AutofocusNode) {
    return NightActivityKind.focus;
  }
  if (node is SlewNode ||
      node is ParkNode ||
      node is UnparkNode ||
      node is HomeMountNode ||
      detailKind == 'Slew') {
    return NightActivityKind.slew;
  }
  if (node is MeridianFlipNode ||
      detailKind == 'MeridianFlip' ||
      manualAction == ManualActionId.flip) {
    return NightActivityKind.flip;
  }
  if (exposing) return NightActivityKind.capture;
  if (settling ||
      detailKind == 'Dither' ||
      detailKind == 'Guiding' ||
      node is DitherNode ||
      node is StartGuidingNode ||
      node is StopGuidingNode ||
      manualAction == ManualActionId.dither) {
    return NightActivityKind.guide;
  }
  if (node is ExposureNode ||
      node is SmartExposureNode ||
      detailKind == 'Exposure' ||
      detailKind == 'SmartExposure') {
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
  final detailKind = percent != null && percent >= 100
      ? null
      : switch (structured) {
          ExposureInstructionProgressDetail() => 'Exposure',
          UnknownInstructionProgressDetail(:final kind) => kind,
          _ => null,
        };
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
    detailKind: detailKind,
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
  final raw = structured is UnknownInstructionProgressDetail
      ? structured.rawJson
      : const <String, Object?>{};
  double? number(String key) => switch (raw[key]) {
        final num value => value.toDouble(),
        _ => null,
      };
  MetricVm metric(String label, String? value) =>
      MetricVm(label: NightText(label), value: value);
  String? fixed(double? v, [String unit = '']) =>
      v != null && v.isFinite ? '${nightFixed(v, 1)}$unit' : null;
  final metrics = <MetricVm>[];
  double? fraction;
  String? detail;
  var titleKey =
      'nightActivity${kind.name[0].toUpperCase()}${kind.name.substring(1)}';
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
              : CoordinateFormat.ra(mount.ra!,
                  style: SexagesimalStyle.compactLetters,
                  seconds: SecondsPrecision.integerRounded,
                  wrapHours: true)),
      metric(
          'nightScopeDecJNow',
          mount.connectionState != DeviceConnectionState.connected ||
                  mount.dec == null
              ? null
              : CoordinateFormat.dec(mount.dec!,
                  style: SexagesimalStyle.compactLetters,
                  seconds: SecondsPrecision.integerRounded)),
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
          : number('attempt')?.toInt();
      final maximum = centerActive && center.maxIterations > 0
          ? center.maxIterations
          : number('max_attempts')?.toInt();
      metrics.addAll([
        metric('nightActivityAttempt',
            current == null ? null : '$current / ${maximum ?? "—"}'),
        metric(
            'nightScopeSolveOffTarget',
            fixed(
                centerActive
                    ? center.currentOffsetArcsec
                    : number('last_separation_arcsec'),
                '″')),
      ]);
      detail = centerActive ? center.message : null;
    }
    if (kind == NightActivityKind.flip) {
      detail = raw['phase'] is String
          ? raw['phase'] as String
          : progress.nodeProgressDetail[id];
      fraction = percent == null ? null : percent / 100;
    }
    if (flipping) fraction = ref.watch(flipProgressProvider) / 100;
    if (kind == NightActivityKind.slew && percent != null) {
      fraction = percent / 100;
    }
  } else if (kind == NightActivityKind.guide) {
    titleKey = phd2 == Phd2State.settling ? 'nightActivitySettling' : titleKey;
    final rms = ref.watch(nightGuideRmsProvider);
    final scale = ref.watch(nightGuideScaleProvider);
    metrics.addAll([
      metric('nightActivityRaRms', formatGuide(rms.ra, scale)),
      metric('nightActivityDecRms', formatGuide(rms.dec, scale)),
      metric('nightActivityTotalRms', formatGuide(rms.total, scale)),
      if (number('settle_pixels') != null)
        metric('nightActivitySettleThreshold',
            fixed(number('settle_pixels'), ' px')),
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
    if (number('remaining_secs') != null) {
      metrics.add(metric(
          'nightSessionStatRemaining', fixed(number('remaining_secs'), ' s')));
    }
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
    FlipStep.pausingGuider => 'nightActivityFlipPauseGuide',
    FlipStep.stoppingTracking => 'nightActivityFlipStopTracking',
    FlipStep.slewingToTarget => 'nightActivitySlew',
    FlipStep.verifyingPierSide => 'nightActivityFlipVerifySide',
    FlipStep.resumingTracking => 'nightActivityFlipResumeTracking',
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
