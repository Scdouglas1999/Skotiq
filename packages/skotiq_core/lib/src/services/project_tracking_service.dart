import '../database/database.dart' as db;

/// Aggregated progress for a target imaged across multiple nights.
class ProjectProgress {
  final db.Target target;
  final int sessionCount;
  final int successfulExposures;
  final double integratedSecs;
  final DateTime? lastSessionAt;

  const ProjectProgress({
    required this.target,
    required this.sessionCount,
    required this.successfulExposures,
    required this.integratedSecs,
    required this.lastSessionAt,
  });

  double get goalIntegrationSecs => target.goalIntegrationSecs;

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
  bool get hasAnyProgress => integratedSecs > 0.0 || successfulExposures > 0;
}

/// Summarizes multi-night target progress from targets and session history.
class ProjectTrackingService {
  const ProjectTrackingService();

  List<ProjectProgress> summarize({
    required List<db.Target> targets,
    required List<db.ImagingSession> sessions,
  }) {
    final sessionsByTarget = <int, List<db.ImagingSession>>{};
    for (final session in sessions) {
      final targetId = session.targetId;
      if (targetId == null) {
        continue;
      }
      sessionsByTarget
          .putIfAbsent(targetId, () => <db.ImagingSession>[])
          .add(session);
    }

    final progress = <ProjectProgress>[];
    for (final target in targets) {
      final targetSessions =
          sessionsByTarget[target.id] ?? const <db.ImagingSession>[];
      final integratedSecs = targetSessions.fold<double>(
        0.0,
        (sum, session) => sum + session.totalIntegrationSecs,
      );
      final successfulExposures = targetSessions.fold<int>(
        0,
        (sum, session) => sum + session.successfulExposures,
      );

      DateTime? lastSessionAt;
      for (final session in targetSessions) {
        final candidate = session.endTime ?? session.startTime;
        if (lastSessionAt == null || candidate.isAfter(lastSessionAt)) {
          lastSessionAt = candidate;
        }
      }

      progress.add(
        ProjectProgress(
          target: target,
          sessionCount: targetSessions.length,
          successfulExposures: successfulExposures,
          integratedSecs: integratedSecs,
          lastSessionAt: lastSessionAt,
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
      final aLast = a.lastSessionAt?.millisecondsSinceEpoch ?? 0;
      final bLast = b.lastSessionAt?.millisecondsSinceEpoch ?? 0;
      if (aLast != bLast) {
        return bLast.compareTo(aLast);
      }
      return a.target.name.toLowerCase().compareTo(b.target.name.toLowerCase());
    });

    return progress;
  }
}
