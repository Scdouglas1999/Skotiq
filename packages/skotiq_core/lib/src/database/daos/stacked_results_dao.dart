import 'package:drift/drift.dart';

import '../../models/imaging/stack_and_share_models.dart';
import '../../services/live_stacking_service.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'stacked_results_dao.g.dart';

/// Reads and writes for `stacked_results`: the persisted provenance record for
/// every stacked master the Stack-and-Share Loop produces.
///
/// SQLite errors propagate to the caller; reads map nullable columns to the
/// [StackAndShareResult] model's defaults.
@DriftAccessor(include: {'../schema/post_session.drift'})
class StackedResultsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$StackedResultsDaoMixin {
  StackedResultsDao(super.db);

  /// Persists a completed [StackAndShareResult] and returns its new row id.
  ///
  /// The model's `id`, `stats` (other than the overlapping aggregate columns),
  /// and any non-persisted fields are intentionally not stored — the table
  /// records the share-ready provenance summary, not the full in-memory run
  /// state. The returned id is the SQLite `last_insert_rowid()`.
  Future<int> insertResult(StackAndShareResult result) {
    return into(stackedResults).insert(
      StackedResultsCompanion.insert(
        sessionId: Value(result.sessionId),
        targetId: Value(result.targetId),
        targetName: Value(result.targetName),
        width: result.width,
        height: result.height,
        framesStacked: result.framesStacked,
        framesAttempted: result.framesAttempted,
        integrationSecs: result.integrationSecs,
        avgAlignmentResidual: Value(result.avgAlignmentResidual),
        avgHfr: Value(result.avgHfr),
        filter: Value(result.filter),
        isColor: Value(result.isColor ? 1 : 0),
        channels: Value(result.channels),
        exportedImagePath: Value(result.exportedImagePath),
        createdAt: toEpochSeconds(result.createdAt),
      ),
    );
  }

  /// Returns the persisted stacked result with the given [id], or null when no
  /// row matches.
  ///
  /// Used by the Stack-and-Share result viewer to load a single stacked master
  /// by its database id. Returns null (rather than throwing) for a missing row
  /// so the provider layer can decide how to surface a stale id.
  Future<StackAndShareResult?> getResultById(int id) async {
    final row = await (select(
      stackedResults,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  /// Returns every stacked result for the given imaging session, newest first.
  Future<List<StackAndShareResult>> getResultsForSession(int sessionId) async {
    final rows =
        await (select(stackedResults)
              ..where((r) => r.sessionId.equals(sessionId))
              ..orderBy(_newestFirst))
            .get();
    return rows.map(_mapRow).toList();
  }

  /// Returns the most recent stacked results across all sessions, newest first.
  ///
  /// [limit] caps the number of rows returned (must be positive); callers use
  /// this to populate the "recent stacks" gallery without loading the entire
  /// history.
  Future<List<StackAndShareResult>> getRecentResults({int limit = 20}) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be a positive integer');
    }
    final rows =
        await (select(stackedResults)
              ..orderBy(_newestFirst)
              ..limit(limit))
            .get();
    return rows.map(_mapRow).toList();
  }

  /// Stamps the exported share image path onto an existing stacked result.
  ///
  /// Returns the number of rows updated (0 if no row matches [id]) so callers
  /// can detect a stale id rather than silently assuming success.
  Future<int> updateExportedPath(int id, String path) {
    return (update(stackedResults)..where((r) => r.id.equals(id))).write(
      StackedResultsCompanion(exportedImagePath: Value(path)),
    );
  }

  /// Deletes the stacked result with the given [id].
  ///
  /// Returns the number of rows deleted (0 if no row matched).
  Future<int> deleteResult(int id) =>
      (delete(stackedResults)..where((r) => r.id.equals(id))).go();

  static final List<OrderingTerm Function(StackedResults)> _newestFirst = [
    (r) => OrderingTerm.desc(r.createdAt),
    (r) => OrderingTerm.desc(r.id),
  ];

  /// Maps a `stacked_results` row to a [StackAndShareResult].
  ///
  /// The table persists only the aggregate columns that overlap with
  /// [LiveStackingStats] (`frames_stacked`, `frames_attempted`,
  /// `avg_alignment_residual`); the reconstructed [LiveStackingStats] carries
  /// those and leaves the non-persisted fields at their defaults — an honest
  /// representation of what the table actually stores.
  StackAndShareResult _mapRow(StackedResultRow row) {
    final avgAlignmentResidual = row.avgAlignmentResidual ?? 0.0;
    return StackAndShareResult(
      id: row.id,
      sessionId: row.sessionId,
      targetId: row.targetId,
      targetName: row.targetName,
      width: row.width,
      height: row.height,
      framesStacked: row.framesStacked,
      framesAttempted: row.framesAttempted,
      integrationSecs: row.integrationSecs,
      avgAlignmentResidual: avgAlignmentResidual,
      avgHfr: row.avgHfr,
      filter: row.filter,
      isColor: row.isColor != 0,
      channels: row.channels,
      createdAt: fromEpochSeconds(row.createdAt),
      exportedImagePath: row.exportedImagePath,
      stats: LiveStackingStats(
        stackedFrameCount: row.framesStacked,
        totalFramesAttempted: row.framesAttempted,
        avgAlignmentResidual: avgAlignmentResidual,
      ),
    );
  }
}
