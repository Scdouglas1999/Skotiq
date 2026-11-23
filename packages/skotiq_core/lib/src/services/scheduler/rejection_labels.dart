/// The ONE place a scheduler hard-constraint rejection is turned into
/// operator-facing words.
///
/// The engine's decision record ([schedulerRejectionSummary]) and the queue
/// row's chip ([schedulerRejectionChipLabel]) render the same
/// [SchedulerRejectionKind] and differ only in length, never in meaning.
library;

import '../../models/scheduler/scheduler_rejection.dart';

/// Short chip text for a rejection — what the scheduler queue's STATUS pill
/// shows beside the full sentence.
///
/// Returns `'Rejected'` for [SchedulerRejectionKind.other]: the row already
/// prints the raw reason, so the chip stays short.
String schedulerRejectionChipLabel(SchedulerRejection rejection) {
  return switch (rejection.kind) {
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
  SchedulerRejection rejection, {
  required double minAltitudeDegrees,
}) {
  final altitude = rejection.altitudeDegrees;
  switch (rejection.kind) {
    case SchedulerRejectionKind.belowHorizon:
      return altitude == null
          ? 'below horizon'
          : 'below horizon (${altitude.toStringAsFixed(1)}°)';
    case SchedulerRejectionKind.tooLowForSite:
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
      return rejection.reason;
  }
}
