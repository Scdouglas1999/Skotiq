import 'dart:convert';

import 'package:equatable/equatable.dart';

/// Kinds of hard constraints applied to a target.
///
/// The scheduler refuses to select a target whose hard constraints are
/// violated at the current evaluation time, regardless of score.
enum TargetConstraintKind {
  /// A wall-clock time window during which imaging is permitted.
  /// Example: image NGC 7000 only between 22:00 and 02:00 local time.
  timeWindow,

  /// A maximum moon illumination fraction (0..1) above which the target
  /// is skipped. Example: image M42 only when moon < 0.30 illuminated.
  moonIlluminationMax,

  /// A minimum angular separation (degrees) between the target and the moon,
  /// below which the target is skipped.
  ///
  /// Illumination alone is the wrong axis on its own: it rejects a target
  /// 150° away from a 90% moon (harmless) and accepts one 10° from a 40% moon
  /// (ruined). Separation is what NINA and SGP both gate on, and the rest of
  /// this app already speaks it — the planner filter bar, the recommendation
  /// cards, and the scheduler's own moon score factor.
  moonSeparationMin,

  /// A reference to a horizon profile id; the target is rejected if its
  /// current altitude is below the profile's value at the target's azimuth.
  customHorizon,

  /// A forced priority window — during this absolute UTC range, the
  /// scheduler MUST switch to the target (hysteresis bypassed) and the
  /// target's score gets a configurable additive boost so it dominates the
  /// runner-up. Unlike [timeWindow] this is NOT a hard constraint outside
  /// the window: the target remains fully eligible when no scheduled
  /// window is active.
  scheduledWindow,
}

/// Inclusive-exclusive local time window expressed as hh:mm.
///
/// startMinutes and endMinutes are minutes-since-midnight in local time
/// (0..1440). If endMinutes < startMinutes the window crosses midnight
/// (e.g. start=22:00, end=02:00 => window is 22:00–02:00 next day).
class TargetTimeWindow extends Equatable {
  final int startMinutes;
  final int endMinutes;

  const TargetTimeWindow({
    required this.startMinutes,
    required this.endMinutes,
  });

  /// Returns true if [localTime] (HH:MM in local clock) falls inside the
  /// window. Wrap-around (midnight-crossing) windows are handled.
  bool containsLocal(DateTime localTime) {
    final mins = localTime.hour * 60 + localTime.minute;
    if (endMinutes >= startMinutes) {
      return mins >= startMinutes && mins < endMinutes;
    }
    return mins >= startMinutes || mins < endMinutes;
  }

  Map<String, dynamic> toJson() => {
    'start_minutes': startMinutes,
    'end_minutes': endMinutes,
  };

  static TargetTimeWindow fromJson(Map<String, dynamic> json) {
    return TargetTimeWindow(
      startMinutes: json['start_minutes'] as int,
      endMinutes: json['end_minutes'] as int,
    );
  }

  @override
  List<Object?> get props => [startMinutes, endMinutes];
}

/// Absolute UTC time range with a priority-boost amount, used by
/// [TargetConstraintKind.scheduledWindow]. While the current time falls
/// inside [startUtc, endUtc), the scheduler:
///   * adds [priorityBoost] (clamped to [0, 1]) to the target's score; and
///   * bypasses the hysteresis ratio so the target wins this tick
///     regardless of what it was chasing before.
class ScheduledWindow extends Equatable {
  /// Inclusive UTC start instant.
  final DateTime startUtc;

  /// Exclusive UTC end instant.
  final DateTime endUtc;

  /// Additive boost applied to the target's total score while the window
  /// is active. Clamped to [0, 1]; the engine clamps the resulting total
  /// to [0, sumOfWeights + 1].
  final double priorityBoost;

  const ScheduledWindow({
    required this.startUtc,
    required this.endUtc,
    this.priorityBoost = 0.5,
  });

  /// Whether [nowUtc] falls inside `[startUtc, endUtc)`.
  bool containsUtc(DateTime nowUtc) {
    final n = nowUtc.toUtc();
    return !n.isBefore(startUtc.toUtc()) && n.isBefore(endUtc.toUtc());
  }

  Map<String, dynamic> toJson() => {
    'start_utc_ms': startUtc.toUtc().millisecondsSinceEpoch,
    'end_utc_ms': endUtc.toUtc().millisecondsSinceEpoch,
    'priority_boost': priorityBoost,
  };

  static ScheduledWindow fromJson(Map<String, dynamic> json) {
    return ScheduledWindow(
      startUtc: DateTime.fromMillisecondsSinceEpoch(
        json['start_utc_ms'] as int,
        isUtc: true,
      ),
      endUtc: DateTime.fromMillisecondsSinceEpoch(
        json['end_utc_ms'] as int,
        isUtc: true,
      ),
      priorityBoost: (json['priority_boost'] as num).toDouble(),
    );
  }

  @override
  List<Object?> get props => [startUtc, endUtc, priorityBoost];
}

/// A single hard constraint attached to a target.
///
/// Only the field matching [kind] should be populated; the others are null.
/// Serialized to the database as JSON in the `payload_json` column so we
/// can add more constraint kinds without a schema change.
class TargetConstraint extends Equatable {
  /// Database row id; null for transient instances not yet persisted.
  final int? id;

  /// FK to targets.id.
  final int targetId;

  final TargetConstraintKind kind;

  final TargetTimeWindow? timeWindow;

  final double? moonIlluminationMax;

  /// Degrees; payload for [TargetConstraintKind.moonSeparationMin].
  final double? moonSeparationMinDeg;

  /// Reference to HorizonProfiles.id (resolved against the same database).
  final int? customHorizonId;

  /// Payload for [TargetConstraintKind.scheduledWindow].
  final ScheduledWindow? scheduledWindow;

  /// If false, the constraint exists but is not evaluated. Useful for
  /// preserving operator state across nights without deleting rows.
  final bool enabled;

  const TargetConstraint({
    this.id,
    required this.targetId,
    required this.kind,
    this.timeWindow,
    this.moonIlluminationMax,
    this.moonSeparationMinDeg,
    this.customHorizonId,
    this.scheduledWindow,
    this.enabled = true,
  });

  TargetConstraint copyWith({
    int? id,
    int? targetId,
    TargetConstraintKind? kind,
    TargetTimeWindow? timeWindow,
    double? moonIlluminationMax,
    double? moonSeparationMinDeg,
    int? customHorizonId,
    ScheduledWindow? scheduledWindow,
    bool? enabled,
  }) {
    return TargetConstraint(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      kind: kind ?? this.kind,
      timeWindow: timeWindow ?? this.timeWindow,
      moonIlluminationMax: moonIlluminationMax ?? this.moonIlluminationMax,
      moonSeparationMinDeg: moonSeparationMinDeg ?? this.moonSeparationMinDeg,
      customHorizonId: customHorizonId ?? this.customHorizonId,
      scheduledWindow: scheduledWindow ?? this.scheduledWindow,
      enabled: enabled ?? this.enabled,
    );
  }

  /// Serialize the kind-specific payload to a JSON string for storage in
  /// the `payload_json` column.
  String encodePayload() {
    switch (kind) {
      case TargetConstraintKind.timeWindow:
        if (timeWindow == null) {
          throw StateError('timeWindow constraint missing timeWindow value');
        }
        return jsonEncode(timeWindow!.toJson());
      case TargetConstraintKind.moonIlluminationMax:
        if (moonIlluminationMax == null) {
          throw StateError(
            'moonIlluminationMax constraint missing moonIlluminationMax value',
          );
        }
        return jsonEncode({'max': moonIlluminationMax});
      case TargetConstraintKind.moonSeparationMin:
        if (moonSeparationMinDeg == null) {
          throw StateError(
            'moonSeparationMin constraint missing moonSeparationMinDeg value',
          );
        }
        return jsonEncode({'min_deg': moonSeparationMinDeg});
      case TargetConstraintKind.customHorizon:
        if (customHorizonId == null) {
          throw StateError(
            'customHorizon constraint missing customHorizonId value',
          );
        }
        return jsonEncode({'profile_id': customHorizonId});
      case TargetConstraintKind.scheduledWindow:
        if (scheduledWindow == null) {
          throw StateError(
            'scheduledWindow constraint missing scheduledWindow value',
          );
        }
        return jsonEncode(scheduledWindow!.toJson());
    }
  }

  /// Reconstruct a constraint from a database row.
  static TargetConstraint fromRow({
    required int id,
    required int targetId,
    required String kindName,
    required String payloadJson,
    required bool enabled,
  }) {
    final kind = TargetConstraintKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => throw StateError('Unknown constraint kind: $kindName'),
    );
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
    switch (kind) {
      case TargetConstraintKind.timeWindow:
        return TargetConstraint(
          id: id,
          targetId: targetId,
          kind: kind,
          timeWindow: TargetTimeWindow.fromJson(payload),
          enabled: enabled,
        );
      case TargetConstraintKind.moonIlluminationMax:
        return TargetConstraint(
          id: id,
          targetId: targetId,
          kind: kind,
          moonIlluminationMax: (payload['max'] as num).toDouble(),
          enabled: enabled,
        );
      case TargetConstraintKind.moonSeparationMin:
        return TargetConstraint(
          id: id,
          targetId: targetId,
          kind: kind,
          moonSeparationMinDeg: (payload['min_deg'] as num).toDouble(),
          enabled: enabled,
        );
      case TargetConstraintKind.customHorizon:
        return TargetConstraint(
          id: id,
          targetId: targetId,
          kind: kind,
          customHorizonId: payload['profile_id'] as int,
          enabled: enabled,
        );
      case TargetConstraintKind.scheduledWindow:
        return TargetConstraint(
          id: id,
          targetId: targetId,
          kind: kind,
          scheduledWindow: ScheduledWindow.fromJson(payload),
          enabled: enabled,
        );
    }
  }

  /// Wire serialization (host -> slave mirror): emits the same raw column
  /// shape the `target_constraints` table stores, so the slave can rebuild
  /// the constraint with [fromRow]. Used by `/api/target-constraints`.
  Map<String, dynamic> toJson() => {
    'id': id,
    'targetId': targetId,
    'kind': kind.name,
    'payloadJson': encodePayload(),
    'enabled': enabled,
  };

  /// Tolerant decoder for the wire payload above.
  static TargetConstraint fromJson(Map<String, dynamic> json) {
    return TargetConstraint.fromRow(
      id: json['id'] as int? ?? 0,
      targetId: json['targetId'] as int? ?? 0,
      kindName: json['kind'] as String? ?? '',
      payloadJson: json['payloadJson'] as String? ?? '{}',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  @override
  List<Object?> get props => [
    id,
    targetId,
    kind,
    timeWindow,
    moonIlluminationMax,
    moonSeparationMinDeg,
    customHorizonId,
    scheduledWindow,
    enabled,
  ];
}
