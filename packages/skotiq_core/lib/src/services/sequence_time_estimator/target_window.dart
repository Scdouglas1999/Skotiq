part of '../sequence_time_estimator.dart';

/// When a target's imaging starts and stops tonight, as the runtime decides
/// it: [start] is when the wait on its start condition ends, [end] when its
/// end condition (or the dawn park) stops it. A null [end] is a target with
/// nothing that ends it inside the next day.
class _TargetSpan {
  const _TargetSpan(this.start, this.end);

  final DateTime start;
  final DateTime? end;
}

/// How far ahead the solver looks for a trigger to change. A run never
/// outlasts a day; a condition that stays false that long never fires.
const Duration _kTriggerHorizon = Duration(hours: 24);

/// The coarse scan step, then the precision the crossing is refined to.
const Duration _kTriggerScanStep = Duration(minutes: 2);
const Duration _kTriggerPrecision = Duration(seconds: 15);

extension _SequenceTimeEstimatorTargetWindow on SequenceTimeEstimator {
  /// The start and end conditions the runtime evaluates for [node]: the
  /// explicit ones, or, when one is absent, the legacy fields translated the
  /// way `legacy_to_triggers` in `target_trigger.rs` does.
  (TargetTrigger?, TargetTrigger?) _runtimeTriggers(TargetHeaderNode node) {
    TargetTrigger? combine(
      List<TargetTrigger> terms,
      TargetTrigger Function(List<TargetTrigger>) join,
    ) => switch (terms.length) {
      0 => null,
      1 => terms.single,
      _ => join(terms),
    };

    int unix(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

    final start =
        node.startWhen ??
        combine([
          if (node.startAfter != null) TimeAfterTrigger(unix(node.startAfter!)),
          if (node.minAltitude != null) AltitudeAboveTrigger(node.minAltitude!),
        ], AndTrigger.new);
    final end =
        node.endWhen ??
        combine([
          if (node.endBefore != null) TimeAfterTrigger(unix(node.endBefore!)),
          if (node.maxAltitude != null) AltitudeAboveTrigger(node.maxAltitude!),
        ], OrTrigger.new);
    return (start, end);
  }

  /// Whether [trigger] holds for [node] at [at], computed as the runtime's
  /// `TargetTrigger::is_satisfied` does: geometric altitude of the header's
  /// coordinates and the hour angle normalized to -12..+12 h.
  bool _triggerHolds(
    TargetTrigger trigger,
    TargetHeaderNode node,
    DateTime at,
    _LocationContext site,
  ) {
    final lst = AstronomyCalculations.localSiderealTime(at, site.longitude);
    final (altitude, _) = AstronomyCalculations.equatorialToHorizontal(
      raDeg: node.raHours * 15.0,
      decDeg: node.decDegrees,
      latitudeDeg: site.latitude,
      lstHours: lst,
    );
    var hourAngle = lst - node.raHours;
    while (hourAngle < -12) {
      hourAngle += 24;
    }
    while (hourAngle > 12) {
      hourAngle -= 24;
    }
    return evaluateTargetTrigger(
      trigger,
      altitudeDeg: altitude,
      hourAngleHours: hourAngle,
      nowUnix: at.millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// The first instant at or after [from] when [trigger] holds, within
  /// [_kTriggerHorizon]; null when it does not hold in that time.
  DateTime? _firstHolding(
    TargetTrigger trigger,
    TargetHeaderNode node,
    DateTime from,
    _LocationContext site,
  ) {
    bool holds(DateTime t) => _triggerHolds(trigger, node, t, site);
    if (holds(from)) return from;
    final limit = from.add(_kTriggerHorizon);
    var before = from;
    var t = from.add(_kTriggerScanStep);
    while (!t.isAfter(limit)) {
      if (holds(t)) {
        // Narrow the crossing between the last false and first true sample.
        var after = t;
        while (after.difference(before) > _kTriggerPrecision) {
          final mid = before.add(after.difference(before) ~/ 2);
          if (holds(mid)) {
            after = mid;
          } else {
            before = mid;
          }
        }
        return after;
      }
      before = t;
      t = t.add(_kTriggerScanStep);
    }
    return null;
  }

  /// When [node] images tonight if the run reaches it at [arrival]; null
  /// when the runtime skips it: its end condition already holds, its start
  /// condition never comes, or the dawn park ends the run first.
  ///
  /// Without a site the conditions cannot be evaluated, so only their fixed
  /// times bound the target (the estimate before this existed).
  _TargetSpan? _targetSpan(
    TargetHeaderNode node,
    DateTime arrival,
    _LocationContext? site,
  ) {
    final runEndsBy = site?.runEndsBy;
    if (site == null) {
      final startAfter = _effectiveStartAfter(node);
      final start = startAfter != null && arrival.isBefore(startAfter)
          ? startAfter
          : arrival;
      return _TargetSpan(start, _effectiveEndBefore(node));
    }

    final (startWhen, endWhen) = _runtimeTriggers(node);
    if (endWhen != null && _triggerHolds(endWhen, node, arrival, site)) {
      return null;
    }
    final start = startWhen == null
        ? arrival
        : _firstHolding(startWhen, node, arrival, site);
    if (start == null) return null;
    if (runEndsBy != null && !start.isBefore(runEndsBy)) return null;

    final end = endWhen == null
        ? null
        : _firstHolding(endWhen, node, start, site);
    if (end != null && !end.isAfter(start)) return null;
    return _TargetSpan(start, _minDate(end, runEndsBy));
  }
}
