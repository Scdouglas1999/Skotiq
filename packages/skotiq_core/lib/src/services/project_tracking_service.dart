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
List<FilterIntegration> acceptedLightsByFilter(Iterable<db.CapturedImage> frames) {
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

/// The sessions that imaged a target: every session holding one of its light
/// frames, and any session row that names the target.
///
/// A sequence run opens one session for all of its targets, so the session row
/// rarely names a target; the frames are what tie a night to a target.
Set<int> targetSessionIds(
  int targetId, {
  required Iterable<db.CapturedImage> frames,
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

bool _isAcceptedLight(db.CapturedImage frame) =>
    frame.frameType.toLowerCase() == 'light' && frame.isAccepted;

/// Multi-night progress of one target, from its frames and its goals.
class ProjectProgress {
  final db.Target target;

  /// Sessions that imaged the target ([targetSessionIds]).
  final int sessionCount;

  /// Accepted light frames of the target.
  final int acceptedFrames;

  /// Exposure of the accepted light frames, seconds.
  final double integratedSecs;

  /// [integratedSecs] by filter.
  final List<FilterIntegration> filters;

  /// The target's integration goals (frames x exposure, every filter), the
  /// goals the Plan project editor and the Scheduler write. Zero when none.
  final double goalIntegrationSecs;

  /// When the newest of the target's light frames was taken.
  final DateTime? lastImagedAt;

  const ProjectProgress({
    required this.target,
    required this.sessionCount,
    required this.acceptedFrames,
    required this.integratedSecs,
    required this.filters,
    required this.goalIntegrationSecs,
    required this.lastImagedAt,
  });

  double get completionFraction {
    if (goalIntegrationSecs <= 0) {
      return 0.0;
    }
    return (integratedSecs / goalIntegrationSecs).clamp(0.0, 1.0);
  }

  double get remainingSecs {
    if (goalIntegrationSecs <= 0) {
      return 0.0;
    }
    return (goalIntegrationSecs - integratedSecs).clamp(0.0, double.infinity);
  }

  bool get isTracked => goalIntegrationSecs > 0.0;
  bool get isCompleted => isTracked && integratedSecs >= goalIntegrationSecs;
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
    required List<db.Target> targets,
    required List<db.ImagingSession> sessions,
    required List<db.CapturedImage> frames,
    required List<IntegrationGoal> goals,
  }) {
    final framesByTarget = <int, List<db.CapturedImage>>{};
    for (final frame in frames) {
      final targetId = frame.targetId;
      if (targetId == null) continue;
      framesByTarget.putIfAbsent(targetId, () => []).add(frame);
    }
    final goalSecsByTarget = <int, double>{};
    for (final goal in goals) {
      goalSecsByTarget[goal.targetId] =
          (goalSecsByTarget[goal.targetId] ?? 0) +
          goal.frameCount * goal.exposureSeconds;
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
          goalIntegrationSecs: goalSecsByTarget[target.id] ?? 0.0,
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
