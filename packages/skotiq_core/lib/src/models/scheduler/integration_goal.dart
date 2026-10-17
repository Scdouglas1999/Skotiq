import 'package:equatable/equatable.dart';

/// User-defined "I want N frames in filter F at exposure E for this target".
///
/// The scheduler uses remainingFrames = frameCount - already-captured
/// (rows in `captured_images` matching target_id and filter) when scoring.
class IntegrationGoal extends Equatable {
  /// Database row id; null for transient instances not yet persisted.
  final int? id;

  /// FK to targets.id (drift `Targets` table).
  final int targetId;

  /// Filter name (case-preserved). Matches `captured_images.filter`.
  final String filter;

  /// Per-frame exposure in seconds.
  final double exposureSeconds;

  /// Total desired frame count.
  final int frameCount;

  /// Tiebreaker among filters (higher = preferred).
  final int priority;

  final DateTime createdAt;

  const IntegrationGoal({
    this.id,
    required this.targetId,
    required this.filter,
    required this.exposureSeconds,
    required this.frameCount,
    this.priority = 5,
    required this.createdAt,
  });

  IntegrationGoal copyWith({
    int? id,
    int? targetId,
    String? filter,
    double? exposureSeconds,
    int? frameCount,
    int? priority,
    DateTime? createdAt,
  }) {
    return IntegrationGoal(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      filter: filter ?? this.filter,
      exposureSeconds: exposureSeconds ?? this.exposureSeconds,
      frameCount: frameCount ?? this.frameCount,
      priority: priority ?? this.priority,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Wire serialization for the host -> slave mirror. The slave's
  /// `IntegrationGoalService` fetches goals over `/api/integration-goals`
  /// when running as a remote client, since the goals live in the host DB.
  Map<String, dynamic> toJson() => {
    'id': id,
    'targetId': targetId,
    'filter': filter,
    'exposureSeconds': exposureSeconds,
    'frameCount': frameCount,
    'priority': priority,
    'createdAtUnix': createdAt.toUtc().millisecondsSinceEpoch ~/ 1000,
  };

  /// Tolerant decoder for the wire payload above (missing fields default).
  static IntegrationGoal fromJson(Map<String, dynamic> json) {
    final createdUnix = json['createdAtUnix'];
    return IntegrationGoal(
      id: json['id'] as int?,
      targetId: json['targetId'] as int? ?? 0,
      filter: json['filter'] as String? ?? '',
      exposureSeconds: (json['exposureSeconds'] as num?)?.toDouble() ?? 0.0,
      frameCount: json['frameCount'] as int? ?? 0,
      priority: json['priority'] as int? ?? 5,
      createdAt: createdUnix is int
          ? DateTime.fromMillisecondsSinceEpoch(createdUnix * 1000, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  @override
  List<Object?> get props => [
    id,
    targetId,
    filter,
    exposureSeconds,
    frameCount,
    priority,
    createdAt,
  ];
}

/// Pairing of a goal with the count already captured for target+filter.
class IntegrationGoalProgress extends Equatable {
  final IntegrationGoal goal;
  final int capturedCount;

  const IntegrationGoalProgress({
    required this.goal,
    required this.capturedCount,
  });

  int get remainingFrames {
    final r = goal.frameCount - capturedCount;
    return r < 0 ? 0 : r;
  }

  /// Fraction of the goal still needed (0..1). 0 means complete.
  double get remainingFraction {
    if (goal.frameCount <= 0) return 0.0;
    return remainingFrames / goal.frameCount;
  }

  bool get isComplete => remainingFrames == 0;

  @override
  List<Object?> get props => [goal, capturedCount];
}
