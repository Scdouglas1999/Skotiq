/// Recovery Mode — Dart mirror of the Rust [`RecoveryContext`].
///
/// Deserialised from JSON delivered over the bridge's
/// `api_sequencer_get_current_recovery_json` API for cold-start snapshots
/// (history dialog open after restart). Live recovery state arrives via
/// the typed `SequencerEvent.RecoveryStarted/Progress/Completed/GaveUp`
/// events — see `recovery_provider.dart` for the
/// bridge that turns those into [RecoveryStatus] instances.
library;

import 'package:equatable/equatable.dart';

/// Sub-phase of an in-flight recovery loop. Mirrors the Rust
/// `RecoveryPhase` enum field-by-field; the wire keys match the Rust
/// `Debug` formatting so the Dart side never needs `switch`-with-default.
enum RecoveryPhase {
  /// Waiting between retry attempts; countdown ticking.
  waiting,

  /// Currently re-executing the failed operation.
  attempting,

  /// Recovery succeeded — executor will resume the sequence.
  recovered,

  /// Recovery exhausted attempts / time / was aborted by the user.
  gaveUp,
}

/// Stable string keys for each [RecoveryPhase] — used by JSON
/// deserialisation. Matches the Rust `Debug` output (which is also the
/// serialised string for serde_json on a unit variant).
String _phaseWireKey(RecoveryPhase p) {
  switch (p) {
    case RecoveryPhase.waiting:
      return 'Waiting';
    case RecoveryPhase.attempting:
      return 'Attempting';
    case RecoveryPhase.recovered:
      return 'Recovered';
    case RecoveryPhase.gaveUp:
      return 'GaveUp';
  }
}

RecoveryPhase _phaseFromWire(dynamic raw) {
  // Rust serde emits unit variants as JSON strings. Anything else is a
  // protocol contract violation: throwing keeps a mis-shaped payload from
  // resolving to a default phase the recovery UI would then report as real.
  final s = raw is String ? raw : raw.toString();
  switch (s) {
    case 'Waiting':
      return RecoveryPhase.waiting;
    case 'Attempting':
      return RecoveryPhase.attempting;
    case 'Recovered':
      return RecoveryPhase.recovered;
    case 'GaveUp':
      return RecoveryPhase.gaveUp;
    default:
      throw FormatException('Unknown RecoveryPhase wire value: $s');
  }
}

/// Stable string keys for the [RecoveryCause] discriminant. Matches the
/// Rust `serde` representation for unit variants. The [RecoveryCause.custom]
/// variant carries a payload string.
class RecoveryCause extends Equatable {
  /// Discriminant key. Matches the Rust enum variant name verbatim.
  final String kind;

  /// Custom payload — populated only when [kind] == 'Custom'.
  final String? customLabel;

  const RecoveryCause._(this.kind, this.customLabel);

  factory RecoveryCause.guideStarLost() =>
      const RecoveryCause._('GuideStarLost', null);
  factory RecoveryCause.slewFailed() =>
      const RecoveryCause._('SlewFailed', null);
  factory RecoveryCause.plateSolveFailed() =>
      const RecoveryCause._('PlateSolveFailed', null);
  factory RecoveryCause.weatherUnsafe() =>
      const RecoveryCause._('WeatherUnsafe', null);
  factory RecoveryCause.mountTrackingLost() =>
      const RecoveryCause._('MountTrackingLost', null);
  factory RecoveryCause.focusDriftCritical() =>
      const RecoveryCause._('FocusDriftCritical', null);
  factory RecoveryCause.consecutiveRejectsExceeded() =>
      const RecoveryCause._('ConsecutiveRejectsExceeded', null);
  factory RecoveryCause.deviceDisconnected() =>
      const RecoveryCause._('DeviceDisconnected', null);
  factory RecoveryCause.custom(String label) =>
      RecoveryCause._('Custom', label);

  /// Human-readable label. Mirrors `RecoveryCause::display_label` on the
  /// Rust side so the dashboard banner shows the same string the
  /// post-session report records.
  String get displayLabel {
    switch (kind) {
      case 'GuideStarLost':
        return 'Guide star lost';
      case 'SlewFailed':
        return 'Slew failed';
      case 'PlateSolveFailed':
        return 'Plate-solve failed';
      case 'WeatherUnsafe':
        return 'Weather unsafe';
      case 'MountTrackingLost':
        return 'Mount tracking lost';
      case 'FocusDriftCritical':
        return 'Critical focus drift';
      case 'ConsecutiveRejectsExceeded':
        return 'Consecutive rejects';
      case 'DeviceDisconnected':
        return 'Device disconnected';
      case 'Custom':
        return customLabel ?? 'Custom recovery';
      default:
        // Unknown variant — named as unknown rather than silently
        // reported as "Recovering".
        return 'Unknown ($kind)';
    }
  }

  /// Snake-case wire key used by analytics / persisted history. Mirrors
  /// `RecoveryCause::wire_key`.
  String get wireKey {
    switch (kind) {
      case 'GuideStarLost':
        return 'guide_star_lost';
      case 'SlewFailed':
        return 'slew_failed';
      case 'PlateSolveFailed':
        return 'plate_solve_failed';
      case 'WeatherUnsafe':
        return 'weather_unsafe';
      case 'MountTrackingLost':
        return 'mount_tracking_lost';
      case 'FocusDriftCritical':
        return 'focus_drift_critical';
      case 'ConsecutiveRejectsExceeded':
        return 'consecutive_rejects_exceeded';
      case 'DeviceDisconnected':
        return 'device_disconnected';
      case 'Custom':
        return 'custom';
      default:
        return kind.toLowerCase();
    }
  }

  /// Parses the cause out of the JSON shape that `serde` emits. Unit
  /// variants are bare strings; the `Custom` variant is `{"Custom":"..."}`.
  factory RecoveryCause.fromJson(dynamic raw) {
    if (raw is String) {
      return RecoveryCause._(raw, null);
    }
    if (raw is Map<String, dynamic>) {
      if (raw.containsKey('Custom')) {
        final payload = raw['Custom'];
        return RecoveryCause._('Custom', payload?.toString());
      }
      if (raw.length == 1) {
        final key = raw.keys.first;
        return RecoveryCause._(key, null);
      }
    }
    throw FormatException('Unknown RecoveryCause wire value: $raw');
  }

  /// Inverse of [RecoveryCause.fromJson] — emits the same serde wire shape:
  /// a bare string for unit variants, `{"Custom": "..."}` for the custom
  /// variant.
  dynamic toJson() =>
      kind == 'Custom' ? <String, dynamic>{'Custom': customLabel} : kind;

  @override
  List<Object?> get props => [kind, customLabel];
}

/// Snapshot of an in-flight recovery loop. Cloned cheaply for the
/// dashboard banner so the UI can render the cause + attempt + countdown
/// without reaching back into the Rust executor on every redraw.
class RecoveryStatus extends Equatable {
  /// UTC timestamp when the loop entered the `Recovering` state.
  final DateTime startedAt;

  /// What triggered the loop.
  final RecoveryCause cause;

  /// UTC timestamp of the most recent attempt. `null` before the first.
  final DateTime? lastAttemptAt;

  /// 1-based attempt counter.
  final int attemptCount;

  /// Hard cap on the number of attempts.
  final int maxAttempts;

  /// Seconds between attempts while in `Waiting`.
  final double retryIntervalSecs;

  /// Total time budget (seconds).
  final double maxDurationSecs;

  /// Current sub-phase.
  final RecoveryPhase phase;

  /// Most recent failure message, if any.
  final String? lastError;

  const RecoveryStatus({
    required this.startedAt,
    required this.cause,
    required this.lastAttemptAt,
    required this.attemptCount,
    required this.maxAttempts,
    required this.retryIntervalSecs,
    required this.maxDurationSecs,
    required this.phase,
    required this.lastError,
  });

  /// Seconds elapsed since `startedAt`.
  double elapsedSecs(DateTime now) {
    final delta = now.toUtc().difference(startedAt.toUtc());
    return delta.inMilliseconds.toDouble() / 1000.0;
  }

  /// Seconds remaining in the budget. Negative once exhausted.
  double remainingSecs(DateTime now) => maxDurationSecs - elapsedSecs(now);

  /// Seconds until the next auto-retry. 0 means "fire now" (the wait has
  /// elapsed or this is the first attempt); always 0 outside `Waiting`.
  double nextAttemptInSecs(DateTime now) {
    if (phase != RecoveryPhase.waiting) return 0.0;
    final last = lastAttemptAt;
    if (last == null) return 0.0;
    final elapsedMs = now.toUtc().difference(last.toUtc()).inMilliseconds;
    final elapsed = elapsedMs <= 0 ? 0.0 : elapsedMs / 1000.0;
    final remaining = retryIntervalSecs - elapsed;
    return remaining < 0.0 ? 0.0 : remaining;
  }

  /// Convenience: true while the dashboard countdown is meaningful.
  bool get isWaiting => phase == RecoveryPhase.waiting;
  bool get isAttempting => phase == RecoveryPhase.attempting;
  bool get isRecovered => phase == RecoveryPhase.recovered;
  bool get isGaveUp => phase == RecoveryPhase.gaveUp;

  /// Deserialise from the JSON wire format. The Rust side serialises with
  /// `serde_json` so the shape is direct field-for-field.
  factory RecoveryStatus.fromJson(Map<String, dynamic> json) {
    DateTime parseDt(dynamic raw) {
      if (raw is String) return DateTime.parse(raw);
      throw FormatException('Expected ISO-8601 string for timestamp, got $raw');
    }

    return RecoveryStatus(
      startedAt: parseDt(json['started_at']),
      cause: RecoveryCause.fromJson(json['cause']),
      lastAttemptAt: json['last_attempt_at'] == null
          ? null
          : parseDt(json['last_attempt_at']),
      attemptCount: (json['attempt_count'] as num).toInt(),
      maxAttempts: (json['max_attempts'] as num).toInt(),
      retryIntervalSecs: (json['retry_interval_secs'] as num).toDouble(),
      maxDurationSecs: (json['max_duration_secs'] as num).toDouble(),
      phase: _phaseFromWire(json['phase']),
      lastError: json['last_error'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'started_at': startedAt.toUtc().toIso8601String(),
    'cause': cause.toJson(),
    'last_attempt_at': lastAttemptAt?.toUtc().toIso8601String(),
    'attempt_count': attemptCount,
    'max_attempts': maxAttempts,
    'retry_interval_secs': retryIntervalSecs,
    'max_duration_secs': maxDurationSecs,
    'phase': _phaseWireKey(phase),
    'last_error': lastError,
  };

  @override
  List<Object?> get props => [
    startedAt,
    cause,
    lastAttemptAt,
    attemptCount,
    maxAttempts,
    retryIntervalSecs,
    maxDurationSecs,
    phase,
    lastError,
  ];
}

/// Persisted record of a completed recovery loop. Populated from the Rust
/// `RecoveryHistoryEntry`; rendered by the post-session report dialog.
class RecoveryHistoryEntry extends Equatable {
  final DateTime startedAt;
  final DateTime endedAt;
  final RecoveryCause cause;
  final int attempts;
  final bool recovered;
  final bool abortedByUser;
  final String? lastError;

  const RecoveryHistoryEntry({
    required this.startedAt,
    required this.endedAt,
    required this.cause,
    required this.attempts,
    required this.recovered,
    required this.abortedByUser,
    required this.lastError,
  });

  Duration get duration => endedAt.difference(startedAt);
  double get durationSecs => duration.inMilliseconds.toDouble() / 1000.0;

  factory RecoveryHistoryEntry.fromJson(Map<String, dynamic> json) {
    DateTime parseDt(dynamic raw) => DateTime.parse(raw as String);
    return RecoveryHistoryEntry(
      startedAt: parseDt(json['started_at']),
      endedAt: parseDt(json['ended_at']),
      cause: RecoveryCause.fromJson(json['cause']),
      attempts: (json['attempts'] as num).toInt(),
      recovered: json['recovered'] as bool,
      abortedByUser: json['aborted_by_user'] as bool,
      lastError: json['last_error'] as String?,
    );
  }

  /// Round-trips with [RecoveryHistoryEntry.fromJson]. Used to persist the
  /// per-session recovery history into `session_diagnostics` so a historical
  /// run report can rebuild this list without the live provider.
  Map<String, dynamic> toJson() => {
    'started_at': startedAt.toIso8601String(),
    'ended_at': endedAt.toIso8601String(),
    'cause': cause.toJson(),
    'attempts': attempts,
    'recovered': recovered,
    'aborted_by_user': abortedByUser,
    'last_error': lastError,
  };

  @override
  List<Object?> get props => [
    startedAt,
    endedAt,
    cause,
    attempts,
    recovered,
    abortedByUser,
    lastError,
  ];
}
