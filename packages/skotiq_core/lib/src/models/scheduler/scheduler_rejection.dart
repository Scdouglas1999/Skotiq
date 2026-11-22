import 'package:equatable/equatable.dart';

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

  /// Some other Moon constraint. The engine never writes it; a sentence from
  /// an older host that only names the Moon reads as this.
  moon,

  /// Outside the target's allowed time window.
  outsideTimeWindow,

  /// A required filter is not available in the wheel.
  filterMissing,

  /// All integration goals are already met.
  goalsComplete,

  /// Anything else (the sky is still too bright); render the raw reason.
  other;

  /// Whether the target rising later tonight can clear this rejection: it is
  /// too low, under the horizon or behind the horizon profile, or the reason
  /// is not one of the named kinds (a sky still too bright). Rising does not
  /// clear the moon, a missing filter, a time window or met goals.
  bool get curedByRising => switch (this) {
    belowHorizon || tooLowForSite || behindHorizonProfile || other => true,
    moonSeparation ||
    moonIllumination ||
    moon ||
    outsideTimeWindow ||
    filterMissing ||
    goalsComplete => false,
  };
}

/// One failed hard constraint: what failed, the sentence the queue row shows,
/// and the altitude the sentence printed when it is about altitude.
class SchedulerRejection extends Equatable {
  final SchedulerRejectionKind kind;

  /// The engine's sentence, e.g. `altitude 9.8° below site minimum 30.0°`.
  final String reason;

  /// The target's altitude as [reason] prints it (one decimal), for the
  /// altitude kinds the engine writes; null otherwise.
  final double? altitudeDegrees;

  const SchedulerRejection({
    required this.kind,
    required this.reason,
    this.altitudeDegrees,
  });

  /// The target is under the site's minimum altitude. [printedAltitude] is
  /// the altitude as the sentence prints it: its sign is what separates
  /// "below the horizon" from "too low", so -0.04 deg (printed -0.0) is too
  /// low.
  factory SchedulerRejection.belowFloor({
    required double printedAltitude,
    required String reason,
  }) => SchedulerRejection(
    kind: printedAltitude < 0
        ? SchedulerRejectionKind.belowHorizon
        : SchedulerRejectionKind.tooLowForSite,
    reason: reason,
    altitudeDegrees: printedAltitude,
  );

  /// Reads a bare sentence from a host that sent no kind, by the words the
  /// engine has always written.
  factory SchedulerRejection.fromSentence(String reason) {
    final r = reason.toLowerCase();
    SchedulerRejection kind(SchedulerRejectionKind kind) =>
        SchedulerRejection(kind: kind, reason: reason);
    if (r.contains('horizon profile')) {
      return kind(SchedulerRejectionKind.behindHorizonProfile);
    }
    if (r.contains('altitude') && r.contains('below')) {
      final altitude = _firstNumberIn(r);
      if (altitude == null) {
        return kind(SchedulerRejectionKind.tooLowForSite);
      }
      return SchedulerRejection.belowFloor(
        printedAltitude: altitude,
        reason: reason,
      );
    }
    if (r.contains('moon separation')) {
      return kind(SchedulerRejectionKind.moonSeparation);
    }
    if (r.contains('moon illumination')) {
      return kind(SchedulerRejectionKind.moonIllumination);
    }
    if (r.contains('moon')) return kind(SchedulerRejectionKind.moon);
    if (r.contains('time window')) {
      return kind(SchedulerRejectionKind.outsideTimeWindow);
    }
    if (r.contains('filter')) return kind(SchedulerRejectionKind.filterMissing);
    if (r.contains('goals complete')) {
      return kind(SchedulerRejectionKind.goalsComplete);
    }
    return kind(SchedulerRejectionKind.other);
  }

  factory SchedulerRejection.fromJson(Map<String, dynamic> j) {
    final reason = j['reason'] as String;
    final kind = SchedulerRejectionKind.values
        .where((k) => k.name == j['kind'])
        .firstOrNull;
    if (kind == null) return SchedulerRejection.fromSentence(reason);
    return SchedulerRejection(
      kind: kind,
      reason: reason,
      altitudeDegrees: (j['altitudeDegrees'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'reason': reason,
    if (altitudeDegrees != null) 'altitudeDegrees': altitudeDegrees,
  };

  @override
  List<Object?> get props => [kind, reason, altitudeDegrees];
}

double? _firstNumberIn(String text) {
  final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(text);
  if (match == null) return null;
  return double.tryParse(match.group(0)!);
}
