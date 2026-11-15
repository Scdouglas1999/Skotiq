import '../../models/imaging/frame_type_record.dart';
import 'dart:math' as math;

import '../../database/database.dart' as db;
import '../../models/scheduler/integration_goal.dart';
import '../../models/scheduler/target_progress.dart';
import '../project_tracking_service.dart'
    show acceptedLightSeconds, acceptedLightsByFilter;
import 'integration_goal_service.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

typedef _Clock = DateTime Function();

/// Computes per-target capture progress and a "nights remaining" ETA.
///
/// Joins three sources:
///   * `integration_goals` (filter + per-frame exposure + desired frame
///     count) via [IntegrationGoalService].
///   * `captured_images` (accepted light frames): counts per filter, which
///     a goal counts by [goalFrameCount], the integration in every filter
///     ([acceptedLightSeconds], the figure Analytics and the Darkroom show),
///     and the last capture.
///   * Wall-clock `now` (injectable for tests) to compute the rolling
///     "frames per night" pace.
///
/// "Night" is a noon-to-noon local interval — a frame captured at 03:00
/// belongs to the night that started the prior noon. This matches how
/// imagers count sessions ("last night" vs "tonight"), not calendar days.
class TargetProgressService {
  final db.SkotiqDatabase _db;
  final IntegrationGoalService _goalService;
  final _Clock _now;

  TargetProgressService({
    required db.SkotiqDatabase database,
    required IntegrationGoalService goalService,
    DateTime Function()? clock,
  }) : _db = database,
       _goalService = goalService,
       _now = clock ?? DateTime.now;

  /// Compute progress for a single target.
  ///
  /// Reads the goals and the target's frames.
  ///
  /// When [capturedImages] is supplied (remote companion path), aggregates
  /// are derived from the host-backed image list instead of local SQLite.
  Future<TargetProgress> forTarget({
    required int targetId,
    required String targetName,
    List<db.DbCapturedImage>? capturedImages,
  }) async {
    final goals = await _goalService.listForTarget(targetId);
    final images = capturedImages != null
        ? capturedImages.where((i) => i.targetId == targetId).toList()
        : await _db.imagesDao.getImagesForTarget(targetId);
    final aggregates = _captureAggregates(images);
    return _assemble(
      targetId: targetId,
      targetName: targetName,
      goals: goals,
      aggregates: aggregates,
    );
  }

  /// Compute progress for many targets at once. Avoids the N+1 query
  /// pattern by issuing one goals-load and one aggregate-load per target;
  /// callers that need many should still prefer this entry point because
  /// the per-target queries run sequentially against the same connection.
  Future<Map<int, TargetProgress>> forTargets(
    List<({int id, String name})> targets, {
    List<db.DbCapturedImage>? capturedImages,
  }) async {
    final out = <int, TargetProgress>{};
    for (final t in targets) {
      out[t.id] = await forTarget(
        targetId: t.id,
        targetName: t.name,
        capturedImages: capturedImages,
      );
    }
    return out;
  }

  /// Build the [TargetProgress] aggregate from already-loaded inputs.
  TargetProgress _assemble({
    required int targetId,
    required String targetName,
    required List<IntegrationGoal> goals,
    required _CaptureAggregates aggregates,
  }) {
    final perFilter = <FilterProgress>[];
    var totalGoalFrames = 0;
    var totalCapturedFrames = 0;
    var totalGoalSeconds = 0.0;

    for (final g in goals) {
      final captured = goalFrameCount(g.filter, aggregates.framesByFilter);
      perFilter.add(
        FilterProgress(
          filter: g.filter,
          exposureSeconds: g.exposureSeconds,
          goalFrames: g.frameCount,
          capturedFrames: captured,
        ),
      );
      totalGoalFrames += g.frameCount;
      totalCapturedFrames += captured;
      totalGoalSeconds += g.frameCount * g.exposureSeconds;
    }

    final percentComplete = totalGoalFrames <= 0
        ? 0.0
        : math.min(1.0, totalCapturedFrames / totalGoalFrames);

    final avgFramesPerNight =
        aggregates.windowFrameCount > 0 && aggregates.windowDistinctNights > 0
        ? aggregates.windowFrameCount / aggregates.windowDistinctNights
        : 0.0;

    final remaining = totalGoalFrames - totalCapturedFrames;
    int? eta;
    if (aggregates.totalCapturedAny <= 0) {
      eta = null;
    } else if (remaining <= 0) {
      eta = null;
    } else if (avgFramesPerNight <= 0) {
      eta = null;
    } else {
      eta = (remaining / avgFramesPerNight).ceil();
    }

    return TargetProgress(
      targetId: targetId,
      targetName: targetName,
      perFilter: perFilter,
      totalGoalFrames: totalGoalFrames,
      totalCapturedFrames: totalCapturedFrames,
      totalIntegrationGoal: Duration(
        milliseconds: (totalGoalSeconds * 1000).round(),
      ),
      totalIntegrationCaptured: Duration(
        milliseconds: (aggregates.integratedSeconds * 1000).round(),
      ),
      percentComplete: percentComplete,
      avgFramesPerNight: avgFramesPerNight,
      estimatedNightsRemaining: eta,
      lastImagedAt: aggregates.lastImagedAt,
    );
  }

  /// Capture aggregates of one target's frames.
  _CaptureAggregates _captureAggregates(List<db.DbCapturedImage> images) {
    final now = _now();
    final windowStart = observingNightWindow(
      now,
    ).start.subtract(const Duration(days: TargetProgress.etaWindowNights));

    final framesByFilter = <String, int>{};
    var totalCapturedAny = 0;
    DateTime? lastImagedAt;
    final distinctNights = <DateTime>{};
    var windowFrameCount = 0;

    for (final frame in images) {
      if (!frame.isLight) continue;
      if (!frame.isAccepted) continue;

      final filter = frame.filter ?? '';
      framesByFilter[filter] = (framesByFilter[filter] ?? 0) + 1;
      totalCapturedAny += 1;

      final capturedAt = frame.capturedAt;
      if (lastImagedAt == null || capturedAt.isAfter(lastImagedAt)) {
        lastImagedAt = capturedAt;
      }

      if (!capturedAt.isBefore(windowStart)) {
        windowFrameCount += 1;
        distinctNights.add(observingNightOf(capturedAt));
      }
    }

    return _CaptureAggregates(
      framesByFilter: framesByFilter,
      integratedSeconds: acceptedLightSeconds(acceptedLightsByFilter(images)),
      totalCapturedAny: totalCapturedAny,
      lastImagedAt: lastImagedAt,
      windowFrameCount: windowFrameCount,
      windowDistinctNights: distinctNights.length,
    );
  }
}

/// Internal carrier for the three queries that feed [TargetProgress].
class _CaptureAggregates {
  /// Accepted light frames by filter as filed, `''` for none.
  final Map<String, int> framesByFilter;

  /// Accepted light seconds in every filter ([acceptedLightSeconds]).
  final double integratedSeconds;
  final int totalCapturedAny;
  final DateTime? lastImagedAt;
  final int windowFrameCount;
  final int windowDistinctNights;

  const _CaptureAggregates({
    required this.framesByFilter,
    required this.integratedSeconds,
    required this.totalCapturedAny,
    required this.lastImagedAt,
    required this.windowFrameCount,
    required this.windowDistinctNights,
  });
}
