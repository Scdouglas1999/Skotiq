import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/stack_and_share_models.dart';
import '../../providers/database_provider.dart';
import '../../services/live_stacking_service.dart';
import '../database.dart';

/// Data-access object for the v38 `stacked_results` table — the persisted
/// provenance record for every stacked master the **Stack-and-Share Loop**
/// produces.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createStackedResultsTable]) rather than a Drift `Table`
/// class, so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customStatement` APIs — mirroring how [ImagesDao] accesses
/// the raw-DDL `thumbnail_path` column. It is deliberately *not* a Drift
/// `@DriftAccessor`, which would require the table to be Drift-declared.
///
/// SQLite errors propagate to the caller; reads map nullable columns to the
/// [StackAndShareResult] model's defaults.
class StackedResultsDao {
  StackedResultsDao(this._db);

  final SkotiqDatabase _db;

  /// Columns selected by every read, in a stable order. Kept in one place so
  /// the row-mapping in [_mapRow] stays in lock-step with the projection.
  static const String _columns =
      'id, session_id, target_id, target_name, width, height, '
      'frames_stacked, frames_attempted, integration_secs, '
      'avg_alignment_residual, avg_hfr, filter, is_color, channels, '
      'exported_image_path, created_at';

  /// Persists a completed [StackAndShareResult] and returns its new row id.
  ///
  /// The model's `id`, `stats` (other than the overlapping aggregate columns),
  /// and any non-persisted fields are intentionally not stored — the table
  /// records the share-ready provenance summary, not the full in-memory run
  /// state. The returned id is the SQLite `last_insert_rowid()`.
  Future<int> insertResult(StackAndShareResult result) {
    return _db.customInsert(
      'INSERT INTO stacked_results('
      'session_id, target_id, target_name, width, height, '
      'frames_stacked, frames_attempted, integration_secs, '
      'avg_alignment_residual, avg_hfr, filter, is_color, channels, '
      'exported_image_path, created_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(result.sessionId),
        Variable<int>(result.targetId),
        Variable<String>(result.targetName),
        Variable<int>(result.width),
        Variable<int>(result.height),
        Variable<int>(result.framesStacked),
        Variable<int>(result.framesAttempted),
        Variable<double>(result.integrationSecs),
        Variable<double>(result.avgAlignmentResidual),
        Variable<double>(result.avgHfr),
        Variable<String>(result.filter),
        Variable<int>(result.isColor ? 1 : 0),
        Variable<int>(result.channels),
        Variable<String>(result.exportedImagePath),
        Variable<int>(_toEpochSeconds(result.createdAt)),
      ],
    );
  }

  /// Returns the persisted stacked result with the given [id], or null when no
  /// row matches.
  ///
  /// Used by the Stack-and-Share result viewer to load a single stacked master
  /// by its database id. Returns null (rather than throwing) for a missing row
  /// so the provider layer can decide how to surface a stale id.
  Future<StackAndShareResult?> getResultById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM stacked_results WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _mapRow(rows.first);
  }

  /// Returns every stacked result for the given imaging session, newest first.
  Future<List<StackAndShareResult>> getResultsForSession(int sessionId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM stacked_results '
          'WHERE session_id = ? ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(sessionId)],
        )
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
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM stacked_results '
          'ORDER BY created_at DESC, id DESC LIMIT ?',
          variables: [Variable<int>(limit)],
        )
        .get();
    return rows.map(_mapRow).toList();
  }

  /// Stamps the exported share image path onto an existing stacked result.
  ///
  /// Returns the number of rows updated (0 if no row matches [id]) so callers
  /// can detect a stale id rather than silently assuming success.
  Future<int> updateExportedPath(int id, String path) {
    return _db.customUpdate(
      'UPDATE stacked_results SET exported_image_path = ? WHERE id = ?',
      variables: [Variable<String>(path), Variable<int>(id)],
      updateKind: UpdateKind.update,
    );
  }

  /// Deletes the stacked result with the given [id].
  ///
  /// Returns the number of rows deleted (0 if no row matched).
  Future<int> deleteResult(int id) {
    return _db.customUpdate(
      'DELETE FROM stacked_results WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
  }

  /// Maps a raw `stacked_results` row to a [StackAndShareResult].
  ///
  /// The table persists only the aggregate columns that overlap with
  /// [LiveStackingStats] (`frames_stacked`, `frames_attempted`,
  /// `avg_alignment_residual`); the reconstructed [LiveStackingStats] carries
  /// those and leaves the non-persisted fields at their defaults — an honest
  /// representation of what the table actually stores.
  StackAndShareResult _mapRow(QueryRow row) {
    final framesStacked = row.read<int>('frames_stacked');
    final framesAttempted = row.read<int>('frames_attempted');
    final avgAlignmentResidual =
        row.readNullable<double>('avg_alignment_residual') ?? 0.0;
    return StackAndShareResult(
      id: row.read<int>('id'),
      sessionId: row.readNullable<int>('session_id'),
      targetId: row.readNullable<int>('target_id'),
      targetName: row.readNullable<String>('target_name'),
      width: row.read<int>('width'),
      height: row.read<int>('height'),
      framesStacked: framesStacked,
      framesAttempted: framesAttempted,
      integrationSecs: row.read<double>('integration_secs'),
      avgAlignmentResidual: avgAlignmentResidual,
      avgHfr: row.readNullable<double>('avg_hfr'),
      filter: row.readNullable<String>('filter'),
      isColor: row.read<int>('is_color') != 0,
      channels: row.read<int>('channels'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
      exportedImagePath: row.readNullable<String>('exported_image_path'),
      stats: LiveStackingStats(
        stackedFrameCount: framesStacked,
        totalFramesAttempted: framesAttempted,
        avgAlignmentResidual: avgAlignmentResidual,
      ),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [StackedResultsDao].
///
/// Lives alongside the DAO (rather than in the central `database_provider.dart`)
/// to keep the Stack-and-Share Loop's persistence layer self-contained. Reads
/// the shared [databaseProvider] so it participates in the same lifecycle and
/// test overrides as every other DAO.
final stackedResultsDaoProvider = Provider<StackedResultsDao>((ref) {
  return StackedResultsDao(ref.watch(databaseProvider));
});
