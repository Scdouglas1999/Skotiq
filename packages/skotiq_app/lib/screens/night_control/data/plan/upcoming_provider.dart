// "Coming up" while a run is live and "The night" before one (sunset, dark,
// moon, flip, dawn). A row whose facts cannot be read is left out, never sent
// half empty.
//
// During a run, every row is something the app knows will happen and either
// when or after which frame: the next dither and autofocus from the plan's
// cadence (or, for autofocus, the operator's interval setting every run
// gets), the flip, the next target, the current target dropping below the
// altitude limit, the moon setting, the plan's estimated end and dawn.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../session/session_events_provider.dart';
import '../tonight_night.dart';
import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';
import 'night_target_provider.dart';
import 'night_timeline_provider.dart';
import 'plan_progress_provider.dart';
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
  final autofocus = _nextAutofocus(ref, tree);
  if (autofocus != null) items.add(autofocus);

  bool ahead(DateTime? when) =>
      when != null &&
      now.isBefore(when) &&
      (night == null || when.isBefore(night.astroDawn));

  final target = ref.watch(nightTargetProvider);
  final belowLimit = target?.belowLimitAt;
  final moonSet =
      target?.moonSet ?? (night == null ? null : _moonSetTonight(night));
  final moonPct = night?.moonIlluminationPercent;
  final planEnd = ref.watch(nightPlanProgressProvider.select((p) => p?.eta));

  final nextTarget = _nextTarget(ref);
  final switchAt =
      nextTarget == null ? null : clock.toNightClock(nextTarget.start);
  // The current target sinking matters only while the run is still on it.
  final lowMatters = belowLimit != null &&
      (switchAt == null || belowLimit.isBefore(switchAt)) &&
      (planEnd == null || belowLimit.isBefore(planEnd));

  final timed = <UpcomingItemVm>[
    if (flip != null) flip,
    if (nextTarget != null)
      UpcomingItemVm(
        kind: UpcomingKind.targetSwitch,
        at: switchAt,
        subject: nextTarget.target.displayName,
      ),
    if (target != null && lowMatters && ahead(belowLimit))
      UpcomingItemVm(
        kind: UpcomingKind.targetLow,
        at: belowLimit,
        subject: target.name,
        limitDeg: target.horizonLimitDeg,
      ),
    if (moonPct != null && ahead(moonSet))
      UpcomingItemVm(
        kind: UpcomingKind.moon,
        at: moonSet,
        moonIlluminationPct: moonPct,
      ),
    if (ahead(planEnd)) UpcomingItemVm(kind: UpcomingKind.planEnd, at: planEnd),
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
  // A Smart Exposure dithers on each filter's own cadence; the filter
  // exposing now says which one. The cadence counts inside one burst, and
  // the executor never dithers after a burst's last frame, so it only ever
  // fires when a burst is longer than it: rotating filters one frame at a
  // time, a plan's "dither every 2" never dithers.
  if (active is SmartExposureNode) {
    final filter = ref.watch(sequenceProgressProvider).currentFilter;
    final plan = active.plans.where((p) => p.filterName == filter).firstOrNull;
    final every = plan?.ditherEvery;
    if (plan != null && every != null && every > 0) {
      final burst = active.loopUntilStopped
          ? 1
          : active.rotateFilters || plan.depthGoal != null
              ? active.batchSize
              : plan.count;
      if (burst > every) {
        return UpcomingItemVm(kind: UpcomingKind.dither, everyFrames: every);
      }
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

/// "Autofocus after #12 or 1 °C change".
///
/// The cadence is the plan's autofocus triggers, else the operator's
/// interval setting, which every run started from this app gets as its
/// standard autofocus trigger. The executor refocuses once that many frames
/// have been taken since the last autofocus, so the frame it follows is the
/// session's frame count at the last autofocus this app saw, plus the
/// interval.
UpcomingItemVm? _nextAutofocus(Ref ref, NightPlanTree? tree) {
  final cadence = _autofocusCadence(tree);
  var everyFrames = cadence?.everyFrames;
  if (everyFrames == null) {
    final setting = ref.watch(
      sequencerDefaultsProvider.select((d) => d.autofocusIntervalFrames),
    );
    if (setting > 0) everyFrames = setting;
  }
  final tempDelta = cadence?.tempDeltaC;
  if (everyFrames == null && tempDelta == null) return null;

  int? afterFrame;
  if (everyFrames != null) {
    final frames = ref.watch(recentSessionFramesProvider);
    final lastRun = ref.watch(
      nightSessionEventsProvider.select(
        (e) => e.autofocusRuns.isEmpty ? null : e.autofocusRuns.last.at,
      ),
    );
    final atLastRun = lastRun == null
        ? 0
        : frames.where((f) => !f.capturedAt.isAfter(lastRun)).length;
    final next = atLastRun + everyFrames;
    // Past it with no autofocus seen (one this app missed, a restart): the
    // frame is not known, the cadence is.
    if (next > frames.length) afterFrame = next;
  }
  return UpcomingItemVm(
    kind: UpcomingKind.autofocus,
    afterFrame: afterFrame,
    everyFrames: afterFrame == null ? everyFrames : null,
    tempDeltaC: tempDelta,
  );
}

/// The plan's own autofocus triggers: every N frames, a temperature change.
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
