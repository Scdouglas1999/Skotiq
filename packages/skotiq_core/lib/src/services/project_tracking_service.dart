import '../database/database.dart' as db;
import '../models/scheduler/integration_goal.dart';

/// Accepted light integration in one filter.
class FilterIntegration {
  const FilterIntegration({
    required this.filter,
    required this.frames,
    required this.seconds,
  });

  /// The filter as captured, "Unfiltered" when the frame names none.
  final String filter;
  final int frames;
  final double seconds;
}

/// Accepted light frames grouped by filter, sorted by filter name.
///
/// Filters are matched case-insensitively, as the scheduler matches goals, and
/// each group is named by its most common spelling (ties alphabetical), so
/// 'L' and 'l' are one row.
List<FilterIntegration> acceptedLightsByFilter(Iterable<db.DbCapturedImage> frames) {
  final buckets = <String, _FilterBucket>{};
  for (final frame in frames) {
    if (!_isAcceptedLight(frame)) continue;
    final label = (frame.filter == null || frame.filter!.isEmpty)
        ? 'Unfiltered'
        : frame.filter!;
    final bucket = buckets.putIfAbsent(label.toLowerCase(), _FilterBucket.new);
    bucket.frames++;
    bucket.seconds += frame.exposureDuration;
    bucket.labelCounts[label] = (bucket.labelCounts[label] ?? 0) + 1;
  }
  return [
    for (final bucket in buckets.values)
      FilterIntegration(
        filter: bucket.label,
        frames: bucket.frames,
        seconds: bucket.seconds,
      ),
  ]..sort((a, b) => a.filter.toLowerCase().compareTo(b.filter.toLowerCase()));
}

/// The accepted light integration a goal for [goalFilter] counts: the group
/// with that filter, matched case-insensitively; the unfiltered goal (empty
/// filter) counts the frames that name no filter.
FilterIntegration acceptedInGoalFilter(
  List<FilterIntegration> accepted,
  String goalFilter,
) {
  final key = _goalFilterKey(goalFilter);
  for (final f in accepted) {
    if (f.filter.toLowerCase() == key) return f;
  }
  return FilterIntegration(filter: goalFilter, frames: 0, seconds: 0);
}

/// What each of [goals] counts as done, in the order given.
///
/// Two goals can name the same filter at different exposures. They share that
/// filter's accepted time, which fills them in order and leaves any surplus on
/// the last, so a filter's time is counted once however many goals name it.
List<FilterIntegration> acceptedPerGoal(
  List<FilterIntegration> accepted,
  List<IntegrationGoal> goals,
) {
  final left = <String, ({double seconds, int frames})>{};
  final lastInFilter = <String, int>{};
  for (var i = 0; i < goals.length; i++) {
    lastInFilter[_goalFilterKey(goals[i].filter)] = i;
  }
  return [
    for (var i = 0; i < goals.length; i++)
      () {
        final goal = goals[i];
        final key = _goalFilterKey(goal.filter);
        final available = left[key] ??= () {
          final all = acceptedInGoalFilter(accepted, goal.filter);
          return (seconds: all.seconds, frames: all.frames);
        }();
        final wanted = goal.frameCount * goal.exposureSeconds;
        final takesRest =
            lastInFilter[key] == i || available.seconds <= wanted;
        final seconds = takesRest ? available.seconds : wanted;
        final frames = takesRest
            ? available.frames
            : (available.frames * seconds / available.seconds).round();
        left[key] = (
          seconds: available.seconds - seconds,
          frames: available.frames - frames,
        );
        return FilterIntegration(
          filter: goal.filter,
          frames: frames,
          seconds: seconds,
        );
      }(),
  ];
}

String _goalFilterKey(String goalFilter) =>
    goalFilter.trim().isEmpty ? 'unfiltered' : goalFilter.trim().toLowerCase();

/// The sessions that imaged a target: every session holding one of its light
/// frames, and any session row that names the target.
///
/// A sequence run opens one session for all of its targets, so the session row
/// rarely names a target; the frames are what tie a night to a target.
Set<int> targetSessionIds(
  int targetId, {
  required Iterable<db.DbCapturedImage> frames,
  required Iterable<db.ImagingSession> sessions,
}) => {
  for (final frame in frames)
    if (frame.targetId == targetId &&
        frame.frameType.toLowerCase() == 'light' &&
        frame.sessionId != null)
      frame.sessionId!,
  for (final session in sessions)
    if (session.targetId == targetId) session.id,
};

/// A target's integration goal, in seconds, and how much of it is done.
///
/// Progress is time: the goal is the target's per-filter integration goals
/// (frames x exposure), the ones Plan and the Scheduler write, and what is done
/// is the accepted light seconds in those filters, at whatever exposure they
/// were taken ([acceptedPerGoal]). Frame counts are shown beside it, never
/// instead of it. A target set up before those existed may carry only the old
/// single hours goal (`targets.goal_integration_secs`); with no per-filter
/// goal it still counts, as one goal over all filters, so a goal the user set
/// does not turn into "Not set".
class TargetGoal {
  const TargetGoal({
    required this.goalSecs,
    required this.doneSecs,
    required this.allFilters,
  });

  static const none = TargetGoal(goalSecs: 0, doneSecs: 0, allFilters: false);

  factory TargetGoal.of({
    required List<FilterIntegration> accepted,
    required List<IntegrationGoal> goals,
    required double oldTotalGoalSecs,
  }) {
    final perFilterGoalSecs = goals.fold(
      0.0,
      (sum, g) => sum + g.frameCount * g.exposureSeconds,
    );
    if (perFilterGoalSecs > 0) {
      return TargetGoal(
        goalSecs: perFilterGoalSecs,
        doneSecs: acceptedPerGoal(
          accepted,
          goals,
        ).fold(0.0, (sum, done) => sum + done.seconds),
        allFilters: false,
      );
    }
    if (oldTotalGoalSecs > 0) {
      return TargetGoal(
        goalSecs: oldTotalGoalSecs,
        doneSecs: accepted.fold(0.0, (sum, f) => sum + f.seconds),
        allFilters: true,
      );
    }
    return none;
  }

  /// Seconds the goal asks for; 0 when the target has none.
  final double goalSecs;

  /// Accepted seconds counted toward it.
  final double doneSecs;

  /// True when the goal is the old single total over every filter.
  final bool allFilters;

  bool get isSet => goalSecs > 0;

  double get completionFraction =>
      isSet ? (doneSecs / goalSecs).clamp(0.0, 1.0) : 0.0;

  double get remainingSecs =>
      isSet ? (goalSecs - doneSecs).clamp(0.0, double.infinity) : 0.0;

  bool get isComplete => isSet && doneSecs >= goalSecs;
}

bool _isAcceptedLight(db.DbCapturedImage frame) =>
    frame.frameType.toLowerCase() == 'light' && frame.isAccepted;

/// Multi-night progress of one target, from its frames and its goals.
class ProjectProgress {
  final db.DbTarget target;

  /// Sessions that imaged the target ([targetSessionIds]).
  final int sessionCount;

  /// Accepted light frames of the target.
  final int acceptedFrames;

  /// Exposure of the accepted light frames, seconds.
  final double integratedSecs;

  /// [integratedSecs] by filter.
  final List<FilterIntegration> filters;

  /// The target's goal ([TargetGoal]).
  final TargetGoal goal;

  /// When the newest of the target's light frames was taken.
  final DateTime? lastImagedAt;

  const ProjectProgress({
    required this.target,
    required this.sessionCount,
    required this.acceptedFrames,
    required this.integratedSecs,
    required this.filters,
    required this.goal,
    required this.lastImagedAt,
  });

  double get goalIntegrationSecs => goal.goalSecs;
  double get completionFraction => goal.completionFraction;
  double get remainingSecs => goal.remainingSecs;
  bool get isTracked => goal.isSet;
  bool get isCompleted => goal.isComplete;
  bool get hasAnyProgress => integratedSecs > 0.0 || acceptedFrames > 0;
}

/// Summarizes multi-night target progress from captured frames and goals.
///
/// The numbers are the ones the campaign rollup and the Darkroom show for the
/// same target: accepted light frames linked to the target, the sessions
/// those frames were taken in, and the target's integration goals.
class ProjectTrackingService {
  const ProjectTrackingService();

  List<ProjectProgress> summarize({
    required List<db.DbTarget> targets,
    required List<db.ImagingSession> sessions,
    required List<db.DbCapturedImage> frames,
    required List<IntegrationGoal> goals,
  }) {
    final framesByTarget = <int, List<db.DbCapturedImage>>{};
    for (final frame in frames) {
      final targetId = frame.targetId;
      if (targetId == null) continue;
      framesByTarget.putIfAbsent(targetId, () => []).add(frame);
    }
    final goalsByTarget = <int, List<IntegrationGoal>>{};
    for (final goal in goals) {
      goalsByTarget.putIfAbsent(goal.targetId, () => []).add(goal);
    }

    final progress = <ProjectProgress>[];
    for (final target in targets) {
      final targetFrames = framesByTarget[target.id] ?? const [];
      final filters = acceptedLightsByFilter(targetFrames);
      DateTime? lastImagedAt;
      for (final frame in targetFrames) {
        if (frame.frameType.toLowerCase() != 'light') continue;
        if (lastImagedAt == null || frame.capturedAt.isAfter(lastImagedAt)) {
          lastImagedAt = frame.capturedAt;
        }
      }
      progress.add(
        ProjectProgress(
          target: target,
          sessionCount: targetSessionIds(
            target.id,
            frames: targetFrames,
            sessions: sessions,
          ).length,
          acceptedFrames: filters.fold(0, (sum, f) => sum + f.frames),
          integratedSecs: filters.fold(0.0, (sum, f) => sum + f.seconds),
          filters: filters,
          goal: TargetGoal.of(
            accepted: filters,
            goals: goalsByTarget[target.id] ?? const [],
            oldTotalGoalSecs: target.goalIntegrationSecs,
          ),
          lastImagedAt: lastImagedAt,
        ),
      );
    }

    progress.sort((a, b) {
      final aPriority = a.isTracked ? 0 : (a.hasAnyProgress ? 1 : 2);
      final bPriority = b.isTracked ? 0 : (b.hasAnyProgress ? 1 : 2);
      if (aPriority != bPriority) {
        return aPriority.compareTo(bPriority);
      }
      if (a.isTracked && b.isTracked) {
        final completionOrder = a.completionFraction.compareTo(
          b.completionFraction,
        );
        if (completionOrder != 0) {
          return completionOrder;
        }
      }
      final aLast = a.lastImagedAt?.millisecondsSinceEpoch ?? 0;
      final bLast = b.lastImagedAt?.millisecondsSinceEpoch ?? 0;
      if (aLast != bLast) {
        return bLast.compareTo(aLast);
      }
      return a.target.name.toLowerCase().compareTo(b.target.name.toLowerCase());
    });

    return progress;
  }
}

class _FilterBucket {
  int frames = 0;
  double seconds = 0.0;
  final Map<String, int> labelCounts = <String, int>{};

  String get label {
    String? best;
    var bestCount = -1;
    final keys = labelCounts.keys.toList()..sort();
    for (final key in keys) {
      final count = labelCounts[key]!;
      if (count > bestCount) {
        bestCount = count;
        best = key;
      }
    }
    return best ?? 'Unfiltered';
  }
}
