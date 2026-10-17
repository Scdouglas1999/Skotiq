/// The ONE place a scheduler hard-constraint rejection reason is turned into
/// operator-facing words.
///
/// The engine's `_summarizeRejection` and the queue row's `_statusLabel` are
/// two renderings of the same `reason.contains(...)` ladder. Two copies drift:
/// a target at +9.8 deg with a 30 deg site minimum reads "Below horizon" on the
/// chip while the sentence next to it says "altitude 9.8 deg below site minimum
/// 30.0 deg".
///
/// Both callers classify here. There is exactly one ladder; the two
/// renderings ([schedulerRejectionChipLabel] for the chip,
/// [schedulerRejectionSummary] for the decision record) differ only in length,
/// never in meaning. `scheduler_rejection_labels_test.dart` (core) and
/// `target_score_row_status_test.dart` (app) pin both ends, and the app test
/// also asserts the widget file grows no second ladder.
library;

/// Why a candidate failed a hard constraint, independent of wording.
enum SchedulerRejectionKind {
  /// Genuinely under the horizon (negative altitude).
  belowHorizon,

  /// Above the horizon, but under the configured site minimum altitude.
  tooLowForSite,

  /// Blocked by the user's custom horizon profile (trees, roof, hill).
  behindHorizonProfile,

  /// Too close to the Moon on the sky.
  moonSeparation,

  /// Moon is too bright (illumination fraction over the limit).
  moonIllumination,

  /// Some other Moon constraint.
  moon,

  /// Outside the target's allowed time window.
  outsideTimeWindow,

  /// A required filter is not available in the wheel.
  filterMissing,

  /// All integration goals are already met.
  goalsComplete,

  /// Anything the ladder does not recognise; render the raw reason.
  other,
}

/// First signed decimal number in [text] (e.g. the `9.8` of
/// `altitude 9.8° below site minimum 30.0°`), or null when there is none.
double? firstNumberIn(String text) {
  final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(text);
  if (match == null) return null;
  return double.tryParse(match.group(0)!);
}

/// Classify a single constraint-failure sentence.
///
/// [reason] is the engine's own per-constraint text, e.g.
/// `altitude 9.8° below site minimum 30.0°`.
SchedulerRejectionKind classifySchedulerRejection(String reason) {
  final r = reason.toLowerCase();
  if (r.contains('altitude') && r.contains('horizon profile')) {
    return SchedulerRejectionKind.behindHorizonProfile;
  }
  if (r.contains('horizon profile')) {
    return SchedulerRejectionKind.behindHorizonProfile;
  }
  if (r.contains('altitude') && r.contains('below')) {
    // "Below the horizon" and "too low to image" call for different operator
    // responses: one target is unreachable tonight, the other just needs time.
    // The sign of the reported altitude is what separates them.
    final altitude = firstNumberIn(r);
    if (altitude != null && altitude < 0) {
      return SchedulerRejectionKind.belowHorizon;
    }
    return SchedulerRejectionKind.tooLowForSite;
  }
  if (r.contains('moon separation')) {
    return SchedulerRejectionKind.moonSeparation;
  }
  if (r.contains('moon illumination')) {
    return SchedulerRejectionKind.moonIllumination;
  }
  if (r.contains('moon')) return SchedulerRejectionKind.moon;
  if (r.contains('time window')) {
    return SchedulerRejectionKind.outsideTimeWindow;
  }
  if (r.contains('filter')) return SchedulerRejectionKind.filterMissing;
  if (r.contains('goals complete')) return SchedulerRejectionKind.goalsComplete;
  return SchedulerRejectionKind.other;
}

/// Short chip text for a rejection — what the scheduler queue's STATUS pill
/// shows beside the full sentence.
///
/// Returns `'Rejected'` for [SchedulerRejectionKind.other]: the row already
/// prints the raw reason, so the chip stays short.
String schedulerRejectionChipLabel(String reason) {
  return switch (classifySchedulerRejection(reason)) {
    SchedulerRejectionKind.belowHorizon => 'Below horizon',
    SchedulerRejectionKind.tooLowForSite => 'Too low',
    SchedulerRejectionKind.behindHorizonProfile => 'Behind horizon',
    SchedulerRejectionKind.moonSeparation => 'Too close to moon',
    SchedulerRejectionKind.moonIllumination => 'Moon too bright',
    SchedulerRejectionKind.moon => 'Moon avoidance',
    SchedulerRejectionKind.outsideTimeWindow => 'Outside window',
    SchedulerRejectionKind.filterMissing => 'Filter missing',
    SchedulerRejectionKind.goalsComplete => 'Complete',
    SchedulerRejectionKind.other => 'Rejected',
  };
}

/// Longer operator-facing summary for the decision record's
/// `RejectedCandidate.primaryReason`. Keeps the numbers when it has them.
String schedulerRejectionSummary(
  String reason, {
  required double minAltitudeDegrees,
}) {
  final kind = classifySchedulerRejection(reason);
  switch (kind) {
    case SchedulerRejectionKind.belowHorizon:
      final altitude = firstNumberIn(reason);
      return altitude == null
          ? 'below horizon'
          : 'below horizon (${altitude.toStringAsFixed(1)}°)';
    case SchedulerRejectionKind.tooLowForSite:
      final altitude = firstNumberIn(reason);
      return altitude == null
          ? 'below site minimum altitude'
          : 'too low (${altitude.toStringAsFixed(1)}° < site minimum '
                '${minAltitudeDegrees.toStringAsFixed(1)}°)';
    case SchedulerRejectionKind.behindHorizonProfile:
      return 'behind custom horizon';
    case SchedulerRejectionKind.filterMissing:
      return 'required filter not in wheel';
    case SchedulerRejectionKind.goalsComplete:
      return 'all integration goals complete';
    case SchedulerRejectionKind.moonSeparation:
    case SchedulerRejectionKind.moonIllumination:
    case SchedulerRejectionKind.moon:
    case SchedulerRejectionKind.outsideTimeWindow:
    case SchedulerRejectionKind.other:
      // These already carry their own detail ("X% > Y%", the window bounds).
      return reason;
  }
}
