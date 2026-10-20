// "Coming up" while a run is live (next dither, autofocus cadence, flip,
// target switch, dawn) and "The night" before one (sunset, dark, moon, flip,
// dawn). A row whose facts cannot be read is left out, never sent half empty.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../tonight_night.dart';
import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';
import 'night_target_provider.dart';
import 'night_timeline_provider.dart';
import 'plan_steps_provider.dart';

final nightUpcomingProvider = Provider<List<UpcomingItemVm>>((ref) {
  final phase = ref.watch(nightRunPhaseProvider);
  final night = ref.watch(tonightNightProvider);
  final clock = ref.watch(clockProvider);
  final now = clock.toNightClock(ref.watch(nightNowProvider));
  final flipAt = ref.watch(nightTargetProvider.select((t) => t?.flipAt));

  UpcomingItemVm at(UpcomingKind kind, DateTime when) =>
      UpcomingItemVm(kind: kind, at: when, passed: !now.isBefore(when));

  final flip = flipAt == null
      ? null
      : UpcomingItemVm(
          kind: UpcomingKind.meridianFlip,
          at: flipAt,
          tone: MetricTone.warning,
        );

  if (!phase.isRunLive) {
    if (night == null) return flip == null ? const [] : [flip];
    final timed = <UpcomingItemVm>[
      at(UpcomingKind.sunset, night.sunset),
      at(UpcomingKind.astroDark, night.astroDark),
      if (flip != null) flip,
      at(UpcomingKind.astroDawn, night.astroDawn),
    ];
    final moonPct = night.moonIlluminationPercent;
    final moonSet = ref.watch(nightTargetProvider.select((t) => t?.moonSet)) ??
        _moonSetTonight(night);
    if (moonPct != null) {
      timed.add(
        UpcomingItemVm(
          kind: UpcomingKind.moon,
          at: moonSet,
          passed: moonSet != null && !now.isBefore(moonSet),
          moonIlluminationPct: moonPct,
        ),
      );
    }
    // In time order; a moon that does not set tonight sits after dark.
    int rank(UpcomingItemVm item) =>
        item.kind == UpcomingKind.moon && item.at == null
            ? night.astroDark.microsecondsSinceEpoch + 1
            : item.at!.microsecondsSinceEpoch;
    timed.sort((a, b) => rank(a).compareTo(rank(b)));
    return timed;
  }

  final items = <UpcomingItemVm>[];
  final tree = ref.watch(nightPlanTreeProvider);

  final dither = _nextDither(ref, tree);
  if (dither != null) items.add(dither);
  final autofocus = _autofocusCadence(tree);
  if (autofocus != null) items.add(autofocus);

  final timed = <UpcomingItemVm>[
    if (flip != null) flip,
    if (_nextTarget(ref) case final next?)
      UpcomingItemVm(
        kind: UpcomingKind.targetSwitch,
        at: clock.toNightClock(next.start),
        subject: next.target.displayName,
      ),
    if (night != null && now.isBefore(night.astroDawn))
      at(UpcomingKind.astroDawn, night.astroDawn),
  ]..sort((a, b) => a.at!.compareTo(b.at!));
  return [...items, ...timed];
});

DateTime? _moonSetTonight(TonightNight night) {
  final set = night.moonSet;
  if (set == null || set.isBefore(night.sunset) || set.isAfter(night.sunrise)) {
    return null;
  }
  return set;
}

/// "Dither after #45": the running exposure step dithers every N frames.
///
/// The frame number continues this session's frame count. Falls back to a
/// dither-interval trigger's cadence when the step itself has none. Null when
/// neither is configured, or the step has no dither left in it (the executor
/// never dithers after a burst's last frame).
UpcomingItemVm? _nextDither(Ref ref, NightPlanTree? tree) {
  final active = ref.watch(nightActiveStepProvider)?.node;
  if (active is ExposureNode && active.frameType == FrameType.light) {
    final every = active.ditherEvery;
    if (every != null && every > 0) {
      final frames = nightNodeFrames(
        active.id,
        tally: ref.watch(nodeExposureTallyProvider),
        progress: ref.watch(sequenceProgressProvider),
      );
      if (frames == null) return null;
      final next = (frames.captured ~/ every + 1) * every;
      if (next >= active.count) return null;
      final sessionFrames = ref.watch(recentSessionFramesProvider).length;
      return UpcomingItemVm(
        kind: UpcomingKind.dither,
        afterFrame: sessionFrames + (next - frames.captured),
      );
    }
  }
  final trigger = tree?.entries
      .map((e) => e.node)
      .whereType<RecoveryNode>()
      .where((n) => n.triggerType == TriggerType.ditherInterval)
      .firstOrNull;
  if (trigger == null || trigger.triggerEveryNFrames <= 0) return null;
  return UpcomingItemVm(
    kind: UpcomingKind.dither,
    everyFrames: trigger.triggerEveryNFrames,
  );
}

/// "Autofocus 6 frames or Δ1 °C", from the plan's autofocus triggers.
UpcomingItemVm? _autofocusCadence(NightPlanTree? tree) {
  if (tree == null) return null;
  int? everyFrames;
  double? tempDelta;
  for (final node
      in tree.entries.map((e) => e.node).whereType<RecoveryNode>()) {
    switch (node.triggerType) {
      case TriggerType.autofocusInterval when node.triggerEveryNFrames > 0:
        everyFrames ??= node.triggerEveryNFrames;
      case TriggerType.temperatureShift
          when node.recoveryAction == RecoveryActionType.autofocus:
        final threshold = node.triggerThreshold;
        if (threshold != null && threshold > 0) tempDelta ??= threshold;
      default:
        break;
    }
  }
  if (everyFrames == null && tempDelta == null) return null;
  return UpcomingItemVm(
    kind: UpcomingKind.autofocus,
    everyFrames: everyFrames,
    tempDeltaC: tempDelta,
  );
}

/// The first target window still to come.
NightTargetWindow? _nextTarget(Ref ref) {
  final windows = ref.watch(nightTargetWindowsProvider);
  final active = windows.indexWhere(
    (w) => w.state == TimelineWindowState.active,
  );
  for (var i = active + 1; i < windows.length; i++) {
    if (windows[i].state == TimelineWindowState.planned) return windows[i];
  }
  return null;
}
