// Header, night strip and left-column view models.
part of '../night_control_contracts.dart';

// ---------------------------------------------------------------------------
// Header and timeline
// ---------------------------------------------------------------------------

/// Enabled state of one header control (Pause, Skip step, Start now...).
/// Which controls exist is decided by [NightHeaderVm.phase]; this only says
/// whether the shown one can be pressed.
@immutable
class NightControlVm {
  const NightControlVm.enabled()
      : enabled = true,
        disabledReason = null;

  const NightControlVm.disabled(NightText this.disabledReason)
      : enabled = false;

  final bool enabled;

  /// Shown in the tooltip and the semantics hint when [enabled] is false.
  final NightText? disabledReason;

  @override
  bool operator ==(Object other) =>
      other is NightControlVm &&
      other.enabled == enabled &&
      other.disabledReason == disabledReason;

  @override
  int get hashCode => Object.hash(enabled, disabledReason);
}

/// The 48 px header: run pill, plan, progress line, timeline and controls.
///
/// Board text "target 1 of 2 · step 7 of 12 · Ha 180 s · 44/60" comes from
/// the target/step/filter/frame fields; before a run, "2 targets · 12 steps ·
/// 7 h planned · dark in 1 h 12 m" from the counts, [plannedDuration] and the
/// timeline's dark time.
@immutable
class NightHeaderVm {
  const NightHeaderVm({
    required this.phase,
    this.pausedFor,
    this.runStartedAt,
    this.armedStartAt,
    this.planName,
    this.targetIndex,
    this.targetCount,
    this.stepIndex,
    this.stepCount,
    this.currentFilter,
    this.currentExposureSecs,
    this.framesDone,
    this.framesTotal,
    this.plannedDuration,
    this.pauseResume,
    this.skipStep,
    this.stop,
    this.startNow,
    this.startAtDark,
  });

  final NightRunPhase phase;

  /// The manual action holding the run, for "Paused for autofocus". Set
  /// only in [NightRunPhase.pausedForAction].
  final ManualActionId? pausedFor;

  /// When the run started; the widget ticks the "4 h 04 m" itself.
  final DateTime? runStartedAt;

  /// When an armed "Start at dark" fires.
  final DateTime? armedStartAt;

  final String? planName;

  /// 1-based position of the current target, and the plan's target count.
  final int? targetIndex;
  final int? targetCount;

  /// 1-based position of the current step, and the plan's step count.
  final int? stepIndex;
  final int? stepCount;

  final String? currentFilter;
  final double? currentExposureSecs;

  /// Frames finished and planned in the current step ("44/60").
  final int? framesDone;
  final int? framesTotal;

  /// The estimator's total for the plan. An estimate: render with "≈".
  final Duration? plannedDuration;

  /// Null when the control does not apply to [phase].
  final NightControlVm? pauseResume;
  final NightControlVm? skipStep;
  final NightControlVm? stop;
  final NightControlVm? startNow;
  final NightControlVm? startAtDark;

  @override
  bool operator ==(Object other) =>
      other is NightHeaderVm &&
      other.phase == phase &&
      other.pausedFor == pausedFor &&
      other.runStartedAt == runStartedAt &&
      other.armedStartAt == armedStartAt &&
      other.planName == planName &&
      other.targetIndex == targetIndex &&
      other.targetCount == targetCount &&
      other.stepIndex == stepIndex &&
      other.stepCount == stepCount &&
      other.currentFilter == currentFilter &&
      other.currentExposureSecs == currentExposureSecs &&
      other.framesDone == framesDone &&
      other.framesTotal == framesTotal &&
      other.plannedDuration == plannedDuration &&
      other.pauseResume == pauseResume &&
      other.skipStep == skipStep &&
      other.stop == stop &&
      other.startNow == startNow &&
      other.startAtDark == startAtDark;

  @override
  int get hashCode => Object.hash(
        phase,
        pausedFor,
        runStartedAt,
        armedStartAt,
        planName,
        targetIndex,
        targetCount,
        stepIndex,
        stepCount,
        currentFilter,
        currentExposureSecs,
        framesDone,
        framesTotal,
        plannedDuration,
        pauseResume,
        skipStep,
        stop,
        startNow,
        startAtDark,
      );
}

/// Where a target window stands against now.
enum TimelineWindowState { done, active, planned }

/// One target's slot on the night strip ("M74 → 03:40").
@immutable
class TimelineWindowVm {
  const TimelineWindowVm({
    required this.name,
    required this.start,
    required this.end,
    required this.estimated,
    required this.state,
  });

  final String name;
  final DateTime start;
  final DateTime end;

  /// True when the times come from the estimator ("≈"), false when both
  /// ends are recorded.
  final bool estimated;

  final TimelineWindowState state;

  @override
  bool operator ==(Object other) =>
      other is TimelineWindowVm &&
      other.name == name &&
      other.start == start &&
      other.end == end &&
      other.estimated == estimated &&
      other.state == state;

  @override
  int get hashCode => Object.hash(name, start, end, estimated, state);
}

/// The night strip. Null as a whole when there is no site or the sun does
/// not set tonight.
@immutable
class NightTimelineVm {
  const NightTimelineVm({
    required this.sunset,
    required this.sunrise,
    required this.now,
    this.astroDark,
    this.astroDawn,
    this.windows = const <TimelineWindowVm>[],
  });

  final DateTime sunset;
  final DateTime sunrise;
  final DateTime now;

  /// Null when the sun never gets 18° below the horizon tonight.
  final DateTime? astroDark;
  final DateTime? astroDawn;

  /// In plan order.
  final List<TimelineWindowVm> windows;

  @override
  bool operator ==(Object other) =>
      other is NightTimelineVm &&
      other.sunset == sunset &&
      other.sunrise == sunrise &&
      other.now == now &&
      other.astroDark == astroDark &&
      other.astroDawn == astroDawn &&
      listEquals(other.windows, windows);

  @override
  int get hashCode => Object.hash(
        sunset,
        sunrise,
        now,
        astroDark,
        astroDawn,
        Object.hashAll(windows),
      );
}

// ---------------------------------------------------------------------------
// Left column
// ---------------------------------------------------------------------------

/// One sample of a time series. A null [y] is a gap, never a zero.
@immutable
class SeriesPoint {
  const SeriesPoint(this.t, this.y, {this.accepted = true});

  final DateTime t;
  final double? y;

  /// False for a frame the grader rejected; the chart dots it in the error
  /// tone. Series that are not per frame leave it true.
  final bool accepted;

  @override
  bool operator ==(Object other) =>
      other is SeriesPoint &&
      other.t == t &&
      other.y == y &&
      other.accepted == accepted;

  @override
  int get hashCode => Object.hash(t, y, accepted);
}

/// The target card: name, coordinates, sky position and the altitude plot.
@immutable
class NightTargetVm {
  const NightTargetVm({
    required this.name,
    required this.raHours,
    required this.decDegrees,
    required this.horizonLimitDeg,
    this.nodeId,
    this.constellation,
    this.objectType,
    this.sizeArcmin,
    this.rotationDeg,
    this.altitudeDeg,
    this.hourAngleHours,
    this.airmass,
    this.altitudeCurve,
    this.moonAltitudeCurve,
    this.moonIlluminationPct,
    this.moonSet,
    this.transitAt,
    this.transitAltitudeDeg,
    this.belowLimitAt,
    this.flipAt,
  });

  final String name;

  /// The target header node, for "open in Sequencer".
  final String? nodeId;

  /// Catalog facts for "Psc · galaxy 9.9′"; each left out when unknown.
  final String? constellation;
  final String? objectType;
  final double? sizeArcmin;

  /// J2000.
  final double raHours;
  final double decDegrees;

  /// The plan's sky angle, when the target sets one.
  final double? rotationDeg;

  /// Null without a site.
  final double? altitudeDeg;

  /// Negative east of the meridian.
  final double? hourAngleHours;

  /// Null below the horizon, where airmass has no meaning.
  final double? airmass;

  /// The effective horizon the plot draws as its limit line.
  final double horizonLimitDeg;

  /// Altitude in degrees across the night. Null hides the curve.
  final List<SeriesPoint>? altitudeCurve;
  final List<SeriesPoint>? moonAltitudeCurve;

  final double? moonIlluminationPct;
  final DateTime? moonSet;
  final DateTime? transitAt;
  final double? transitAltitudeDeg;

  /// When the target drops below [horizonLimitDeg] tonight.
  final DateTime? belowLimitAt;

  /// The next meridian flip, when one is armed.
  final DateTime? flipAt;

  @override
  bool operator ==(Object other) =>
      other is NightTargetVm &&
      other.name == name &&
      other.nodeId == nodeId &&
      other.constellation == constellation &&
      other.objectType == objectType &&
      other.sizeArcmin == sizeArcmin &&
      other.raHours == raHours &&
      other.decDegrees == decDegrees &&
      other.rotationDeg == rotationDeg &&
      other.altitudeDeg == altitudeDeg &&
      other.hourAngleHours == hourAngleHours &&
      other.airmass == airmass &&
      other.horizonLimitDeg == horizonLimitDeg &&
      _nullableListEquals(other.altitudeCurve, altitudeCurve) &&
      _nullableListEquals(other.moonAltitudeCurve, moonAltitudeCurve) &&
      other.moonIlluminationPct == moonIlluminationPct &&
      other.moonSet == moonSet &&
      other.transitAt == transitAt &&
      other.transitAltitudeDeg == transitAltitudeDeg &&
      other.belowLimitAt == belowLimitAt &&
      other.flipAt == flipAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        name,
        nodeId,
        constellation,
        objectType,
        sizeArcmin,
        raHours,
        decDegrees,
        rotationDeg,
        altitudeDeg,
        hourAngleHours,
        airmass,
        horizonLimitDeg,
        _nullableListHash(altitudeCurve),
        _nullableListHash(moonAltitudeCurve),
        moonIlluminationPct,
        moonSet,
        transitAt,
        transitAltitudeDeg,
        belowLimitAt,
        flipAt,
      ]);
}

/// One filter's row in the Plan section ("Ha  43/60  2h09").
@immutable
class PlanFilterRowVm {
  const PlanFilterRowVm({
    required this.filter,
    required this.framesDone,
    required this.integrated,
    required this.isCurrent,
    this.framesPlanned,
  });

  final String filter;
  final int framesDone;

  /// Null for an open-ended step (loop until a time or a condition).
  final int? framesPlanned;

  /// Exposure time already captured in this filter.
  final Duration integrated;

  /// The filter the run is exposing now.
  final bool isCurrent;

  /// 0 to 1, or null when [framesPlanned] is unknown.
  double? get fraction {
    final planned = framesPlanned;
    if (planned == null || planned <= 0) return null;
    return (framesDone / planned).clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is PlanFilterRowVm &&
      other.filter == filter &&
      other.framesDone == framesDone &&
      other.framesPlanned == framesPlanned &&
      other.integrated == integrated &&
      other.isCurrent == isCurrent;

  @override
  int get hashCode =>
      Object.hash(filter, framesDone, framesPlanned, integrated, isCurrent);
}

/// The Plan section: "5 h 10 m / 7 h · ETA 05:30" and the filter rows.
@immutable
class NightPlanVm {
  const NightPlanVm({
    required this.rows,
    required this.integrated,
    this.planned,
    this.eta,
  });

  final List<PlanFilterRowVm> rows;
  final Duration integrated;

  /// Estimator output; null when the plan has open-ended steps.
  final Duration? planned;

  /// Estimated end of the run ("≈").
  final DateTime? eta;

  @override
  bool operator ==(Object other) =>
      other is NightPlanVm &&
      listEquals(other.rows, rows) &&
      other.integrated == integrated &&
      other.planned == planned &&
      other.eta == eta;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(rows), integrated, planned, eta);
}

/// What the Steps list prints on the right of a step.
sealed class StepWhen {
  const StepWhen();
}

/// When the step finished, from this session's events.
final class StepWhenActual extends StepWhen {
  const StepWhenActual(this.at);
  final DateTime at;

  @override
  bool operator ==(Object other) => other is StepWhenActual && other.at == at;

  @override
  int get hashCode => at.hashCode;
}

/// The estimator's start time; rendered with "≈".
final class StepWhenPlanned extends StepWhen {
  const StepWhenPlanned(this.at);
  final DateTime at;

  @override
  bool operator ==(Object other) => other is StepWhenPlanned && other.at == at;

  @override
  int get hashCode => at.hashCode;
}

/// The running step's frame count ("44/60"). [total] is null when open-ended.
final class StepWhenProgress extends StepWhen {
  const StepWhenProgress(this.done, this.total);
  final int done;
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is StepWhenProgress && other.done == done && other.total == total;

  @override
  int get hashCode => Object.hash(done, total);
}

enum PlanStepStatus { done, active, pending, failed, skipped }

/// One row of the Steps list. The tree is flattened; [depth] is the nesting
/// below the root, for an optional indent.
@immutable
class PlanStepVm {
  const PlanStepVm({
    required this.nodeId,
    required this.label,
    required this.status,
    this.depth = 0,
    this.when,
  });

  /// The sequence node, for "open in Sequencer" (`selectedNodeIdProvider`).
  final String nodeId;

  /// The step as the plan names it ("Ha 60 × 180 s, dither 3").
  final String label;

  final PlanStepStatus status;
  final int depth;

  /// Null when neither an estimate nor a recorded time exists.
  final StepWhen? when;

  @override
  bool operator ==(Object other) =>
      other is PlanStepVm &&
      other.nodeId == nodeId &&
      other.label == label &&
      other.status == status &&
      other.depth == depth &&
      other.when == when;

  @override
  int get hashCode => Object.hash(nodeId, label, status, depth, when);
}

/// The kinds of rows in "Coming up" (during a run) and "The night" (before).
enum UpcomingKind {
  dither,
  autofocus,
  meridianFlip,
  targetSwitch,

  /// The current target drops below the altitude limit.
  targetLow,
  sunset,
  astroDark,
  moon,

  /// The plan's estimated end.
  planEnd,
  astroDawn,
}

/// One row of "Coming up" / "The night". The widget builds the sentence from
/// [kind] and the typed fields; a row whose facts cannot be read is left out
/// by the provider rather than sent half empty.
@immutable
class UpcomingItemVm {
  const UpcomingItemVm({
    required this.kind,
    this.at,
    this.passed = false,
    this.subject,
    this.afterFrame,
    this.everyFrames,
    this.tempDeltaC,
    this.every,
    this.moonIlluminationPct,
    this.limitDeg,
    this.tone = MetricTone.neutral,
  });

  final UpcomingKind kind;

  /// When it happens. For dither and autofocus it is usually unknown.
  final DateTime? at;

  /// True for "Sunset 18:18 · passed".
  final bool passed;

  /// The next target for [UpcomingKind.targetSwitch], the current one for
  /// [UpcomingKind.targetLow].
  final String? subject;

  /// "Dither after #45": the frame number it follows.
  final int? afterFrame;

  /// "Autofocus 6 frames or Δ1 °C": the trigger's frame interval,
  /// temperature change and time interval, each when configured.
  final int? everyFrames;
  final double? tempDeltaC;
  final Duration? every;

  /// For [UpcomingKind.moon].
  final double? moonIlluminationPct;

  /// The altitude limit, for [UpcomingKind.targetLow].
  final double? limitDeg;

  /// The meridian flip row is [MetricTone.warning] on the boards.
  final MetricTone tone;

  @override
  bool operator ==(Object other) =>
      other is UpcomingItemVm &&
      other.kind == kind &&
      other.at == at &&
      other.passed == passed &&
      other.subject == subject &&
      other.afterFrame == afterFrame &&
      other.everyFrames == everyFrames &&
      other.tempDeltaC == tempDeltaC &&
      other.every == every &&
      other.moonIlluminationPct == moonIlluminationPct &&
      other.limitDeg == limitDeg &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(
        kind,
        at,
        passed,
        subject,
        afterFrame,
        everyFrames,
        tempDeltaC,
        every,
        moonIlluminationPct,
        limitDeg,
        tone,
      );
}
