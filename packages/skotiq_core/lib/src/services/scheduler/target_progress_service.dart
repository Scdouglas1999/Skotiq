import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../database/database.dart' as db;
import '../../models/scheduler/integration_goal.dart';
import '../../models/scheduler/target_progress.dart';
import 'integration_goal_service.dart';

typedef _Clock = DateTime Function();

/// Computes per-target capture progress and a "nights remaining" ETA.
///
/// Joins three sources:
///   * `integration_goals` (filter + per-frame exposure + desired frame
///     count) via [IntegrationGoalService].
///   * `captured_images` (accepted light frames) via raw SQL — counts and
///     `MAX(captured_at)` per target+filter, with no DAO layer in between
///     so the bulk path stays linear-time.
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
  /// Issues one query for the goals plus one aggregated capture query —
  /// fast even for targets with hundreds of frames.
  ///
  /// When [capturedImages] is supplied (remote companion path), aggregates
  /// are derived from the host-backed image list instead of local SQLite.
  Future<TargetProgress> forTarget({
    required int targetId,
    required String targetName,
    List<db.CapturedImage>? capturedImages,
  }) async {
    final goals = await _goalService.listForTarget(targetId);
    final aggregates = capturedImages != null
        ? _captureAggregatesFromImageList(
            capturedImages.where((i) => i.targetId == targetId).toList(),
          )
        : await _captureAggregatesForTarget(targetId);
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
    List<db.CapturedImage>? capturedImages,
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
    var totalCapturedSeconds = 0.0;

    for (final g in goals) {
      final captured =
          aggregates.framesByFilterLower[g.filter.toLowerCase()] ?? 0;
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
      totalCapturedSeconds += captured * g.exposureSeconds;
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
        milliseconds: (totalCapturedSeconds * 1000).round(),
      ),
      percentComplete: percentComplete,
      avgFramesPerNight: avgFramesPerNight,
      estimatedNightsRemaining: eta,
      lastImagedAt: aggregates.lastImagedAt,
    );
  }

  /// Build capture aggregates from an in-memory image list (host catalog).
  _CaptureAggregates _captureAggregatesFromImageList(
    List<db.CapturedImage> images,
  ) {
    final now = _now();
    final windowStart = _nightStart(
      now,
    ).subtract(const Duration(days: TargetProgress.etaWindowNights));

    final framesByFilterLower = <String, int>{};
    var totalCapturedAny = 0;
    DateTime? lastImagedAt;
    final distinctNights = <DateTime>{};
    var windowFrameCount = 0;

    for (final frame in images) {
      if (frame.frameType.toLowerCase() != 'light') continue;
      if (!frame.isAccepted) continue;

      final filter = frame.filter;
      if (filter == null || filter.isEmpty) continue;
      final key = filter.toLowerCase();
      framesByFilterLower[key] = (framesByFilterLower[key] ?? 0) + 1;
      totalCapturedAny += 1;

      final capturedAt = frame.capturedAt;
      if (lastImagedAt == null || capturedAt.isAfter(lastImagedAt)) {
        lastImagedAt = capturedAt;
      }

      if (!capturedAt.isBefore(windowStart)) {
        windowFrameCount += 1;
        distinctNights.add(_nightStart(capturedAt));
      }
    }

    return _CaptureAggregates(
      framesByFilterLower: framesByFilterLower,
      totalCapturedAny: totalCapturedAny,
      lastImagedAt: lastImagedAt,
      windowFrameCount: windowFrameCount,
      windowDistinctNights: distinctNights.length,
    );
  }

  /// Single-trip aggregate load: per-filter counts, last-captured, and the
  /// rolling-window stats needed for the ETA.
  Future<_CaptureAggregates> _captureAggregatesForTarget(int targetId) async {
    final now = _now();
    final windowStart = _nightStart(
      now,
    ).subtract(const Duration(days: TargetProgress.etaWindowNights));
    // Drift stores DateTimeColumn as Unix seconds (see e.g.
    // IntegrationGoalService which divides millis by 1000), so the
    // captured_at comparison and re-hydration both use seconds.
    final windowStartSec = windowStart.toUtc().millisecondsSinceEpoch ~/ 1000;

    // Per-filter accepted-light counts.
    final perFilterRows = await _db
        .customSelect(
          "SELECT LOWER(filter) AS filter_lower, COUNT(*) AS c "
          "FROM captured_images "
          "WHERE target_id = ? AND frame_type = 'light' AND is_accepted = 1 "
          "AND filter IS NOT NULL "
          "GROUP BY LOWER(filter)",
          variables: [Variable.withInt(targetId)],
        )
        .get();
    final framesByFilterLower = <String, int>{};
    var totalCapturedAny = 0;
    for (final row in perFilterRows) {
      final f = row.read<String>('filter_lower');
      final c = row.read<int>('c');
      framesByFilterLower[f] = c;
      totalCapturedAny += c;
    }

    // Most recent accepted light frame for the target. Stored as Unix
    // seconds by drift's DateTimeColumn (default mapping).
    final lastRow = await _db
        .customSelect(
          "SELECT MAX(captured_at) AS last_sec FROM captured_images "
          "WHERE target_id = ? AND frame_type = 'light' AND is_accepted = 1",
          variables: [Variable.withInt(targetId)],
        )
        .getSingleOrNull();
    DateTime? lastImagedAt;
    if (lastRow != null) {
      final lastSec = lastRow.data['last_sec'];
      if (lastSec is int) {
        lastImagedAt = DateTime.fromMillisecondsSinceEpoch(
          lastSec * 1000,
          isUtc: true,
        ).toLocal();
      }
    }

    // Frames in the rolling window — pulled as timestamps so we can bucket
    // them into local-noon nights in Dart (sqlite's date arithmetic does
    // not know the local-offset rule we want).
    final windowRows = await _db
        .customSelect(
          "SELECT captured_at AS ts FROM captured_images "
          "WHERE target_id = ? AND frame_type = 'light' AND is_accepted = 1 "
          "AND captured_at >= ?",
          variables: [
            Variable.withInt(targetId),
            Variable.withInt(windowStartSec),
          ],
        )
        .get();
    final distinctNights = <DateTime>{};
    for (final row in windowRows) {
      final ts = row.data['ts'];
      if (ts is! int) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(
        ts * 1000,
        isUtc: true,
      ).toLocal();
      distinctNights.add(_nightStart(dt));
    }

    return _CaptureAggregates(
      framesByFilterLower: framesByFilterLower,
      totalCapturedAny: totalCapturedAny,
      lastImagedAt: lastImagedAt,
      windowFrameCount: windowRows.length,
      windowDistinctNights: distinctNights.length,
    );
  }

  /// Returns the local-time instant of "noon" preceding [t]. A frame
  /// captured at 03:00 belongs to the night that started at noon the day
  /// before; a frame captured at 14:00 belongs to the night that started
  /// at noon the same day.
  ///
  /// We deliberately keep the result in the local timezone of [t] (no
  /// .toUtc()) so the bucketing matches the observer's wall clock.
  DateTime _nightStart(DateTime t) {
    final local = t.isUtc ? t.toLocal() : t;
    final noonToday = DateTime(local.year, local.month, local.day, 12);
    if (local.isBefore(noonToday)) {
      final yesterday = noonToday.subtract(const Duration(days: 1));
      return yesterday;
    }
    return noonToday;
  }
}

/// Internal carrier for the three queries that feed [TargetProgress].
class _CaptureAggregates {
  final Map<String, int> framesByFilterLower;
  final int totalCapturedAny;
  final DateTime? lastImagedAt;
  final int windowFrameCount;
  final int windowDistinctNights;

  const _CaptureAggregates({
    required this.framesByFilterLower,
    required this.totalCapturedAny,
    required this.lastImagedAt,
    required this.windowFrameCount,
    required this.windowDistinctNights,
  });
}
