/// The mount motion guard's state, as the app and linked clients see it.
///
/// The host's native guard watches the mount for motion Skotiq did not
/// command and for a reported position it can no longer trust. Both are
/// equipment safety faults: the run is paused and automatic moves are
/// refused until the operator recovers the mount.
library;

/// The host's guard answer is decoded strictly: a missing field is the host
/// answering something else, and a fault shown with made-up values would be
/// worse than an error.
String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('mount guard: "$key" is missing or not a string');
}

double _number(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  throw FormatException('mount guard: "$key" is missing or not a number');
}

double? _optionalNumber(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is num ? value.toDouble() : null;
}

bool _bool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('mount guard: "$key" is missing or not a bool');
}

DateTime _time(Map<String, dynamic> json, String key) {
  final value = DateTime.tryParse(_string(json, key));
  if (value != null) return value;
  throw FormatException('mount guard: "$key" is not a time');
}

/// The mount moved with no command from Skotiq.
class MountMotionFault {
  const MountMotionFault({
    required this.kind,
    required this.message,
    required this.detectedAt,
    required this.rateDegPerSec,
    required this.raHours,
    required this.decDegrees,
    required this.altitudeDegrees,
    required this.stillMoving,
    required this.stopAttempts,
    required this.runPaused,
  });

  /// `runaway`, `slewing` or `below_horizon`.
  final String kind;
  final String message;
  final DateTime detectedAt;
  final double rateDegPerSec;
  final double raHours;
  final double decDegrees;
  final double? altitudeDegrees;
  final bool stillMoving;

  /// What Skotiq sent to stop the mount, and how each command went.
  final List<String> stopAttempts;
  final bool runPaused;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'message': message,
    'detectedAt': detectedAt.toUtc().toIso8601String(),
    'rateDegPerSec': rateDegPerSec,
    'raHours': raHours,
    'decDegrees': decDegrees,
    'altitudeDegrees': altitudeDegrees,
    'stillMoving': stillMoving,
    'stopAttempts': stopAttempts,
    'runPaused': runPaused,
  };

  factory MountMotionFault.fromJson(Map<String, dynamic> json) =>
      MountMotionFault(
        kind: _string(json, 'kind'),
        message: _string(json, 'message'),
        detectedAt: _time(json, 'detectedAt'),
        rateDegPerSec: _number(json, 'rateDegPerSec'),
        raHours: _number(json, 'raHours'),
        decDegrees: _number(json, 'decDegrees'),
        altitudeDegrees: _optionalNumber(json, 'altitudeDegrees'),
        stillMoving: _bool(json, 'stillMoving'),
        stopAttempts: switch (json['stopAttempts']) {
          final List<dynamic> list => [for (final a in list) a.toString()],
          _ => throw const FormatException(
            'mount guard: "stopAttempts" is missing or not a list',
          ),
        },
        runPaused: _bool(json, 'runPaused'),
      );
}

/// Skotiq no longer trusts the mount's reported position.
class MountPositionUnknown {
  const MountPositionUnknown({
    required this.reason,
    required this.message,
    required this.flaggedAt,
    required this.runPaused,
  });

  final String reason;
  final String message;
  final DateTime flaggedAt;
  final bool runPaused;

  Map<String, dynamic> toJson() => {
    'reason': reason,
    'message': message,
    'flaggedAt': flaggedAt.toUtc().toIso8601String(),
    'runPaused': runPaused,
  };

  factory MountPositionUnknown.fromJson(Map<String, dynamic> json) =>
      MountPositionUnknown(
        reason: _string(json, 'reason'),
        message: _string(json, 'message'),
        flaggedAt: _time(json, 'flaggedAt'),
        runPaused: _bool(json, 'runPaused'),
      );
}

/// One mount with an open fault or an unknown position.
class MountGuardEntry {
  const MountGuardEntry({
    required this.deviceId,
    this.fault,
    this.positionUnknown,
    this.blockReason,
    this.autoRecovering = false,
  });

  final String deviceId;
  final MountMotionFault? fault;
  final MountPositionUnknown? positionUnknown;

  /// Why automatic slews, parks and homes are refused.
  final String? blockReason;
  final bool autoRecovering;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'fault': fault?.toJson(),
    'positionUnknown': positionUnknown?.toJson(),
    'blockReason': blockReason,
    'autoRecovering': autoRecovering,
  };

  factory MountGuardEntry.fromJson(Map<String, dynamic> json) {
    final fault = json['fault'];
    final lost = json['positionUnknown'];
    return MountGuardEntry(
      deviceId: _string(json, 'deviceId'),
      fault: fault is Map<String, dynamic>
          ? MountMotionFault.fromJson(fault)
          : null,
      positionUnknown: lost is Map<String, dynamic>
          ? MountPositionUnknown.fromJson(lost)
          : null,
      blockReason: json['blockReason'] as String?,
      autoRecovering: _bool(json, 'autoRecovering'),
    );
  }
}

/// A recovery plate solve, for the operator to accept or not.
class MountGuardSolveResult {
  const MountGuardSolveResult({
    required this.raHours,
    required this.decDegrees,
    required this.mountRaHours,
    required this.mountDecDegrees,
    required this.separationDegrees,
  });

  /// The solved position, J2000.
  final double raHours;
  final double decDegrees;

  /// Where the mount says it points.
  final double mountRaHours;
  final double mountDecDegrees;
  final double separationDegrees;

  Map<String, dynamic> toJson() => {
    'raHours': raHours,
    'decDegrees': decDegrees,
    'mountRaHours': mountRaHours,
    'mountDecDegrees': mountDecDegrees,
    'separationDegrees': separationDegrees,
  };

  factory MountGuardSolveResult.fromJson(Map<String, dynamic> json) =>
      MountGuardSolveResult(
        raHours: _number(json, 'raHours'),
        decDegrees: _number(json, 'decDegrees'),
        mountRaHours: _number(json, 'mountRaHours'),
        mountDecDegrees: _number(json, 'mountDecDegrees'),
        separationDegrees: _number(json, 'separationDegrees'),
      );
}
