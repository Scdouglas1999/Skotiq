import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/guide_rms_history.dart';

part 'guide_rms_history_dao.g.dart';

/// Data access object for [GuideRmsHistory].
///
/// Append-only log of per-session guiding RMS samples used by the Smart
/// Night exposure planner. The planner computes a weighted average of the
/// last N rows for the current mount, so [recentForMount] is the hot
/// query — backed by `idx_guide_rms_mount_recent` (created in
/// `database.dart::_createCustomIndexes`) for O(log n) lookup.
@DriftAccessor(tables: [GuideRmsHistory])
class GuideRmsHistoryDao extends DatabaseAccessor<SkotiqDatabase>
    with _$GuideRmsHistoryDaoMixin {
  GuideRmsHistoryDao(super.db);

  /// Insert a new guide-RMS sample and return its auto-incremented id.
  ///
  /// Caller is responsible for filling the companion. We do not synthesize
  /// `recordedAt` here so the writer can attribute the row to the actual
  /// end-of-session time rather than the wall-clock time of the insert
  /// (these may differ when a long session is post-processed).
  Future<int> insertSample(GuideRmsHistoryCompanion entry) {
    return into(guideRmsHistory).insert(entry);
  }

  /// Return the most recent [limit] samples for the given mount in
  /// descending `recordedAt` order.
  ///
  /// Default [limit] of 20 matches the planner's weighted-average window.
  /// Backed by `idx_guide_rms_mount_recent` so the SQLite optimizer can
  /// satisfy the WHERE + ORDER BY with an index range scan.
  Future<List<GuideRmsHistoryEntry>> recentForMount(
    String mountId, {
    int limit = 20,
  }) {
    return (select(guideRmsHistory)
          ..where((t) => t.mountId.equals(mountId))
          ..orderBy([(t) => OrderingTerm.desc(t.recordedAt)])
          ..limit(limit))
        .get();
  }

  /// Delete rows whose `recordedAt` is strictly before [cutoff].
  ///
  /// Intended for periodic housekeeping; the planner's window is bounded
  /// by [recentForMount]'s limit, so older rows are dead weight.
  Future<void> deleteOlderThan(DateTime cutoff) {
    return (delete(
      guideRmsHistory,
    )..where((t) => t.recordedAt.isSmallerThanValue(cutoff))).go();
  }

  /// Time-bucketed paginated listing for the remote read API.
  /// [sinceMs] and [untilMs] are inclusive epoch-millisecond bounds; null
  /// means "unbounded on that side". Newest-first ordering matches the
  /// existing [recentForMount] convention. Caller MUST validate / clamp
  /// [limit] and [offset].
  Future<List<GuideRmsHistoryEntry>> listPaginated({
    String? mountId,
    int? sinceMs,
    int? untilMs,
    int limit = 200,
    int offset = 0,
  }) {
    var query = select(guideRmsHistory)
      ..orderBy([(t) => OrderingTerm.desc(t.recordedAt)])
      ..limit(limit, offset: offset);
    final trimmedMountId = mountId?.trim();
    if (trimmedMountId != null && trimmedMountId.isNotEmpty) {
      query = query..where((t) => t.mountId.equals(trimmedMountId));
    }
    if (sinceMs != null) {
      final since = DateTime.fromMillisecondsSinceEpoch(sinceMs);
      query = query..where((t) => t.recordedAt.isBiggerOrEqualValue(since));
    }
    if (untilMs != null) {
      final until = DateTime.fromMillisecondsSinceEpoch(untilMs);
      query = query..where((t) => t.recordedAt.isSmallerOrEqualValue(until));
    }
    return query.get();
  }

  /// Row count for the same filter set [listPaginated] uses.
  Future<int> countFiltered({
    String? mountId,
    int? sinceMs,
    int? untilMs,
  }) async {
    final countExpr = guideRmsHistory.id.count();
    final query = selectOnly(guideRmsHistory)..addColumns([countExpr]);
    final trimmedMountId = mountId?.trim();
    if (trimmedMountId != null && trimmedMountId.isNotEmpty) {
      query.where(guideRmsHistory.mountId.equals(trimmedMountId));
    }
    if (sinceMs != null) {
      final since = DateTime.fromMillisecondsSinceEpoch(sinceMs);
      query.where(guideRmsHistory.recordedAt.isBiggerOrEqualValue(since));
    }
    if (untilMs != null) {
      final until = DateTime.fromMillisecondsSinceEpoch(untilMs);
      query.where(guideRmsHistory.recordedAt.isSmallerOrEqualValue(until));
    }
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }
}
