import 'package:equatable/equatable.dart';

import 'project.dart';

/// Per-filter accrued-vs-goal line within a project target's progress.
///
/// Mirrors the semantics of `FilterProgress` (in
/// `models/scheduler/target_progress.dart`): integration is frame-count *
/// per-frame exposure, remaining frames clamp to zero on overshoot, and a goal
/// of zero frames is treated as inert (never "complete"). This is a pure
/// derivation model — it holds no database identity and is never persisted.
class FilterProgressLine extends Equatable {
  /// Filter name as stored on the integration goal (case-preserved). The
  /// goal-vs-captured match itself is case-insensitive across the scheduler
  /// stack — this field is purely for display/grouping.
  final String filter;

  /// Per-frame exposure in seconds.
  final double exposureSeconds;

  /// Total desired frame count for this filter.
  final int goalFrames;

  /// Frames already captured and accepted for this filter.
  final int capturedFrames;

  const FilterProgressLine({
    required this.filter,
    required this.exposureSeconds,
    required this.goalFrames,
    required this.capturedFrames,
  });

  /// Remaining frames, clamped to `[0, goalFrames]`. Overshooting a goal does
  /// not produce a negative remainder.
  int get remainingFrames => (goalFrames - capturedFrames).clamp(0, goalFrames);

  /// Integration time already on disk for this filter, in seconds.
  double get accruedSeconds => capturedFrames * exposureSeconds;

  /// Integration time required to meet the goal, in seconds.
  double get goalSeconds => goalFrames * exposureSeconds;

  /// True once the captured frame count meets or exceeds the goal. A zero
  /// goal is vacuously "complete at the frame level" only when captured >= 0,
  /// so guard with [goalFrames] at the call site if that matters; the
  /// time-based completeness used by [ProjectTargetProgress.isComplete]
  /// handles the inert-goal case explicitly.
  bool get isComplete => capturedFrames >= goalFrames;

  Map<String, dynamic> toJson() => {
    'filter': filter,
    'exposureSeconds': exposureSeconds,
    'goalFrames': goalFrames,
    'capturedFrames': capturedFrames,
    'remainingFrames': remainingFrames,
    'accruedSeconds': accruedSeconds,
    'goalSeconds': goalSeconds,
    'isComplete': isComplete,
  };

  /// Tolerant decoder for [toJson]. Only the four base fields are read back;
  /// the derived totals are recomputed from them.
  static FilterProgressLine fromJson(Map<String, dynamic> json) {
    return FilterProgressLine(
      filter: json['filter'] as String? ?? '',
      exposureSeconds: (json['exposureSeconds'] as num?)?.toDouble() ?? 0.0,
      goalFrames: json['goalFrames'] as int? ?? 0,
      capturedFrames: json['capturedFrames'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props => [
    filter,
    exposureSeconds,
    goalFrames,
    capturedFrames,
  ];
}

/// Accrued-vs-remaining imaging progress for a single target inside a project.
///
/// Aggregates the target's per-filter [FilterProgressLine]s into integration
/// totals and a clamped completion fraction. Pure derivation — no persistence.
class ProjectTargetProgress extends Equatable {
  /// FK to `targets.id`.
  final int targetId;

  final String targetName;

  /// Right ascension in decimal hours (matches `targets.ra`).
  final double raHours;

  /// Declination in degrees (matches `targets.dec`).
  final double decDegrees;

  /// Per-filter progress lines, in scheduler order (priority DESC, filter ASC).
  final List<FilterProgressLine> filters;

  const ProjectTargetProgress({
    required this.targetId,
    required this.targetName,
    required this.raHours,
    required this.decDegrees,
    required this.filters,
  });

  /// Integration seconds already on disk, summed across filters.
  double get accruedSeconds =>
      filters.fold(0.0, (sum, f) => sum + f.accruedSeconds);

  /// Integration seconds required to satisfy every filter goal.
  double get goalSeconds => filters.fold(0.0, (sum, f) => sum + f.goalSeconds);

  /// Outstanding integration seconds, clamped to zero on overshoot.
  double get remainingSeconds {
    final r = goalSeconds - accruedSeconds;
    return r < 0.0 ? 0.0 : r;
  }

  /// Completion fraction in `[0.0, 1.0]`. Returns 0.0 when there is no goal
  /// (nothing to be a fraction of) and clamps to 1.0 on overshoot.
  double get percentComplete {
    if (goalSeconds <= 0.0) return 0.0;
    final ratio = accruedSeconds / goalSeconds;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  /// True only when there is a real goal and nothing remains. A zero goal is
  /// never "complete" — it signals an unconfigured target, not a finished one.
  bool get isComplete => remainingSeconds <= 0.0 && goalSeconds > 0.0;

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'raHours': raHours,
    'decDegrees': decDegrees,
    'filters': filters.map((f) => f.toJson()).toList(),
    'accruedSeconds': accruedSeconds,
    'goalSeconds': goalSeconds,
    'remainingSeconds': remainingSeconds,
    'percentComplete': percentComplete,
    'isComplete': isComplete,
  };

  /// Tolerant decoder for [toJson]. Reads the base fields and the per-filter
  /// lines; all aggregates are recomputed from those.
  static ProjectTargetProgress fromJson(Map<String, dynamic> json) {
    final rawFilters = json['filters'];
    final filters = rawFilters is List
        ? rawFilters
              .whereType<Map>()
              .map(
                (m) => FilterProgressLine.fromJson(m.cast<String, dynamic>()),
              )
              .toList()
        : const <FilterProgressLine>[];
    return ProjectTargetProgress(
      targetId: json['targetId'] as int? ?? 0,
      targetName: json['targetName'] as String? ?? '',
      raHours: (json['raHours'] as num?)?.toDouble() ?? 0.0,
      decDegrees: (json['decDegrees'] as num?)?.toDouble() ?? 0.0,
      filters: filters,
    );
  }

  @override
  List<Object?> get props => [
    targetId,
    targetName,
    raHours,
    decDegrees,
    filters,
  ];
}

/// Roll-up of every target's progress within one [Project].
///
/// Binds directly to the project detail UI: it exposes target counts, project
/// integration totals, an overall completion fraction, and the subset of
/// targets still needing data. Pure derivation — no persistence.
///
/// Named `CampaignProgress` (a project *is* a multi-night campaign) to avoid
/// colliding with the unrelated, pre-existing analytics
/// `project_tracking_service.dart::ProjectProgress`. Keeping a distinct name
/// lets the barrel export this planning roll-up under its own symbol rather
/// than hiding it.
class CampaignProgress extends Equatable {
  final Project project;

  /// Per-target progress, one entry per attached target.
  final List<ProjectTargetProgress> targets;

  const CampaignProgress({required this.project, required this.targets});

  int get totalTargets => targets.length;

  int get completeTargets => targets.where((t) => t.isComplete).length;

  /// Integration seconds on disk across all targets in the project.
  double get totalAccruedSeconds =>
      targets.fold(0.0, (sum, t) => sum + t.accruedSeconds);

  /// Integration seconds required across all targets in the project.
  double get totalGoalSeconds =>
      targets.fold(0.0, (sum, t) => sum + t.goalSeconds);

  /// Outstanding integration seconds across the whole project, clamped to
  /// zero on overshoot.
  double get totalRemainingSeconds {
    final r = totalGoalSeconds - totalAccruedSeconds;
    return r < 0.0 ? 0.0 : r;
  }

  /// Project-wide completion fraction in `[0.0, 1.0]`, weighted by each
  /// target's goal size (i.e. accrued seconds / goal seconds across the
  /// project). 0.0 when the project has no goals.
  double get totalPercentComplete {
    final goal = totalGoalSeconds;
    if (goal <= 0.0) return 0.0;
    final ratio = totalAccruedSeconds / goal;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  /// Targets that still need data (anything not [ProjectTargetProgress.isComplete],
  /// which includes targets with no configured goals).
  List<ProjectTargetProgress> get incompleteTargets =>
      targets.where((t) => !t.isComplete).toList(growable: false);

  Map<String, dynamic> toJson() => {
    'project': project.toJson(),
    'targets': targets.map((t) => t.toJson()).toList(),
    'totalTargets': totalTargets,
    'completeTargets': completeTargets,
    'totalAccruedSeconds': totalAccruedSeconds,
    'totalGoalSeconds': totalGoalSeconds,
    'totalRemainingSeconds': totalRemainingSeconds,
    'totalPercentComplete': totalPercentComplete,
  };

  /// Tolerant decoder for [toJson] (host -> slave roll-up mirror).
  static CampaignProgress fromJson(Map<String, dynamic> json) {
    final rawProject = json['project'];
    final rawTargets = json['targets'];
    return CampaignProgress(
      project: rawProject is Map
          ? Project.fromJson(rawProject.cast<String, dynamic>())
          : Project(
              name: 'Untitled project',
              createdAt: DateTime.fromMillisecondsSinceEpoch(0),
              updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
      targets: rawTargets is List
          ? rawTargets
                .whereType<Map>()
                .map(
                  (m) =>
                      ProjectTargetProgress.fromJson(m.cast<String, dynamic>()),
                )
                .toList()
          : const <ProjectTargetProgress>[],
    );
  }

  @override
  List<Object?> get props => [project, targets];
}
