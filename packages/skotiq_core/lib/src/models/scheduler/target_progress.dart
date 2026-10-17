import 'package:equatable/equatable.dart';

/// Per-filter capture progress for one target.
///
/// Pairs an integration goal (filter + per-frame exposure + desired frame
/// count) with the number of frames already on disk for that target+filter.
/// Used by [TargetProgress] to drive aggregate stats and UI progress bars.
class FilterProgress extends Equatable {
  /// Filter name as stored on the integration goal (case-preserved). The
  /// goal-vs-captured filter match itself is case-insensitive — see
  /// `IntegrationGoalService.capturedFrameCount`.
  final String filter;

  /// Per-frame exposure in seconds for the goal.
  final double exposureSeconds;

  /// Total desired frame count for this filter.
  final int goalFrames;

  /// Number of frames already captured and accepted for this filter.
  final int capturedFrames;

  const FilterProgress({
    required this.filter,
    required this.exposureSeconds,
    required this.goalFrames,
    required this.capturedFrames,
  });

  /// Remaining frames clamped to zero — overshooting a goal does not yield
  /// a negative remainder.
  int get remainingFrames {
    final r = goalFrames - capturedFrames;
    return r < 0 ? 0 : r;
  }

  /// Completion ratio in `[0.0, 1.0]`. Returns 0.0 when the goal is zero
  /// (i.e. an inert goal row) and 1.0 when capture meets or exceeds the
  /// goal.
  double get percentComplete {
    if (goalFrames <= 0) return 0.0;
    final ratio = capturedFrames / goalFrames;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  /// Integration time already on disk for this filter, in seconds.
  Duration get integrationCaptured =>
      Duration(milliseconds: (capturedFrames * exposureSeconds * 1000).round());

  /// Total integration time required to meet the goal, in seconds.
  Duration get integrationGoal =>
      Duration(milliseconds: (goalFrames * exposureSeconds * 1000).round());

  Map<String, dynamic> toJson() => {
    'filter': filter,
    'exposureSeconds': exposureSeconds,
    'goalFrames': goalFrames,
    'capturedFrames': capturedFrames,
    'remainingFrames': remainingFrames,
    'percentComplete': percentComplete,
  };

  @override
  List<Object?> get props => [
    filter,
    exposureSeconds,
    goalFrames,
    capturedFrames,
  ];
}

/// Aggregate imaging progress + ETA for a single target.
///
/// Combines all of a target's integration goals into a single snapshot:
///   * total goal vs captured frames (sum across filters)
///   * total integration goal vs integration captured (sum of frames*exposure)
///   * percent complete (frame-based, weighted by goal sizes per filter)
///   * a rolling "frames per night" measured from the last
///     [TargetProgress.etaWindowNights] of activity
///   * an `estimatedNightsRemaining` projection at the current pace
///
/// `null`-able fields encode "no signal" rather than masking with zeros:
///   * `estimatedNightsRemaining == null` when no frames have ever been
///     captured (no pace to project from) OR when the target is fully
///     complete (nothing left to project).
///   * `lastImagedAt == null` when no frames have ever been captured.
class TargetProgress extends Equatable {
  /// Rolling window over which the "frames per night" pace is averaged.
  /// Chosen as 7 nights so a single bad-weather week does not pull the
  /// average to zero permanently — the next clear night re-seeds it.
  static const int etaWindowNights = 7;

  final int targetId;
  final String targetName;

  /// Per-filter rows in the order returned by `IntegrationGoalService`
  /// (priority DESC, filter ASC).
  final List<FilterProgress> perFilter;

  final int totalGoalFrames;
  final int totalCapturedFrames;
  final Duration totalIntegrationGoal;
  final Duration totalIntegrationCaptured;

  /// `[0.0, 1.0]` — frame-based completion summed across filters. 0.0 when
  /// no goals exist; 1.0 when all captured >= all goals.
  final double percentComplete;

  /// Average frames per clear night in the rolling window. 0.0 when no
  /// frames captured in the window.
  final double avgFramesPerNight;

  /// `ceil(remainingFrames / avgFramesPerNight)`. Null when no captured
  /// frames exist (nothing to extrapolate from) or when 100% complete
  /// (nothing remaining).
  final int? estimatedNightsRemaining;

  /// `MAX(captured_at)` for the target — most recent accepted light frame.
  /// Null when nothing has been captured.
  final DateTime? lastImagedAt;

  const TargetProgress({
    required this.targetId,
    required this.targetName,
    required this.perFilter,
    required this.totalGoalFrames,
    required this.totalCapturedFrames,
    required this.totalIntegrationGoal,
    required this.totalIntegrationCaptured,
    required this.percentComplete,
    required this.avgFramesPerNight,
    required this.estimatedNightsRemaining,
    required this.lastImagedAt,
  });

  /// True when the operator has not configured any integration goals for
  /// this target. The UI can show a "set goals to track progress" prompt.
  bool get hasGoals => perFilter.isNotEmpty;

  /// True when at least one frame has been captured.
  bool get hasCaptures => totalCapturedFrames > 0;

  /// True when every filter goal is met (and at least one goal exists).
  bool get isComplete => hasGoals && totalCapturedFrames >= totalGoalFrames;

  int get totalRemainingFrames {
    final r = totalGoalFrames - totalCapturedFrames;
    return r < 0 ? 0 : r;
  }

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'perFilter': perFilter.map((f) => f.toJson()).toList(),
    'totalGoalFrames': totalGoalFrames,
    'totalCapturedFrames': totalCapturedFrames,
    'totalRemainingFrames': totalRemainingFrames,
    'totalIntegrationGoalSeconds': totalIntegrationGoal.inSeconds,
    'totalIntegrationCapturedSeconds': totalIntegrationCaptured.inSeconds,
    'percentComplete': percentComplete,
    'avgFramesPerNight': avgFramesPerNight,
    'estimatedNightsRemaining': estimatedNightsRemaining,
    'lastImagedAt': lastImagedAt?.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    targetId,
    targetName,
    perFilter,
    totalGoalFrames,
    totalCapturedFrames,
    totalIntegrationGoal,
    totalIntegrationCaptured,
    percentComplete,
    avgFramesPerNight,
    estimatedNightsRemaining,
    lastImagedAt,
  ];
}
