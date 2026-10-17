import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/mosaic_project.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

/// Data-access object for the v45 `mosaic_projects` table (Mosaic M2) — the
/// durable record that makes a mosaic a first-class entity linking grid config →
/// per-panel targets → per-panel masters → the stitched output.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createMosaicTables]) rather than a drift `Table` class,
/// so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customInsert`/`customStatement` APIs — mirroring
/// [CampaignsDao] and [NarrowbandCompositesDao]. It is deliberately NOT a
/// `@DriftAccessor`.
///
/// SQLite errors propagate; reads map nullable columns to the model's nullable
/// fields.
class MosaicProjectsDao {
  MosaicProjectsDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, target_id, name, rows, cols, overlap_pct, position_angle_deg, '
      'status, output_master_id, created_at, updated_at, '
      // v56: collaborative publish/role/status.
      'hub_mosaic_id, collab_role, collab_status';

  /// Insert a mosaic project row and return its id. [createdAt]/[updatedAt]
  /// default to "now" (UTC seconds) when omitted.
  Future<int> create({
    int? targetId,
    required String name,
    required int rows,
    required int cols,
    double overlapPct = 15.0,
    double positionAngleDeg = 0.0,
    MosaicProjectStatus status = MosaicProjectStatus.planning,
    int? outputMasterId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final created = _toEpochSeconds(createdAt ?? DateTime.now());
    final updated = updatedAt == null ? created : _toEpochSeconds(updatedAt);
    return _db.customInsert(
      'INSERT INTO mosaic_projects('
      'target_id, name, rows, cols, overlap_pct, position_angle_deg, '
      'status, output_master_id, created_at, updated_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(targetId),
        Variable<String>(name),
        Variable<int>(rows),
        Variable<int>(cols),
        Variable<double>(overlapPct),
        Variable<double>(positionAngleDeg),
        Variable<String>(status.wire),
        Variable<int>(outputMasterId),
        Variable<int>(created),
        Variable<int>(updated),
      ],
    );
  }

  /// Fetch a project by id, or null when absent.
  Future<MosaicProject?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM mosaic_projects WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// All projects, newest first.
  Future<List<MosaicProject>> listAll() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM mosaic_projects '
          'ORDER BY created_at DESC, id DESC',
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Collaborative projects the unattended owner/participant poller still has
  /// work to drive: published to a hub (`hub_mosaic_id` set) and not yet
  /// `complete`. Scopes the poll sweep to the handful of in-flight collaborative
  /// mosaics rather than every local project. Newest first.
  Future<List<MosaicProject>> listActiveCollaborative() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM mosaic_projects '
          "WHERE hub_mosaic_id IS NOT NULL AND hub_mosaic_id != '' "
          "AND (collab_status IS NULL OR collab_status != 'complete') "
          'ORDER BY created_at DESC, id DESC',
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Fetch the local project linked to [hubMosaicId], or null when this
  /// device has not joined/published that hub mosaic. Used by the join flow to
  /// reuse an existing local mirror instead of creating a duplicate project.
  Future<MosaicProject?> getByHubMosaicId(String hubMosaicId) async {
    if (hubMosaicId.isEmpty) return null;
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM mosaic_projects WHERE hub_mosaic_id = ? '
          'ORDER BY id ASC LIMIT 1',
          variables: [Variable<String>(hubMosaicId)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// Projects with the given lifecycle [status], newest first.
  Future<List<MosaicProject>> listByStatus(MosaicProjectStatus status) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM mosaic_projects '
          'WHERE status = ? ORDER BY created_at DESC, id DESC',
          variables: [Variable<String>(status.wire)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Update a project's lifecycle [status] (and `updated_at`). Returns the
  /// number of rows changed.
  Future<int> updateStatus(
    int id,
    MosaicProjectStatus status, {
    DateTime? now,
  }) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return _db.customUpdate(
      'UPDATE mosaic_projects SET status = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable<String>(status.wire),
        Variable<int>(at),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Attach the stitched output's `integrated_masters.id` to the project and
  /// mark it [MosaicProjectStatus.complete] (and bump `updated_at`). Returns the
  /// number of rows changed.
  Future<int> setOutputMaster(int id, int outputMasterId, {DateTime? now}) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return _db.customUpdate(
      'UPDATE mosaic_projects SET output_master_id = ?, status = ?, '
      'updated_at = ? WHERE id = ?',
      variables: [
        Variable<int>(outputMasterId),
        Variable<String>(MosaicProjectStatus.complete.wire),
        Variable<int>(at),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Record that this project was published to the hub as a collaborative
  /// mosaic: persist the hub mosaic id, the collaborative [role]
  /// (`owner`|`participant`), and set `collab_status = 'published'`. Returns the
  /// number of rows changed.
  Future<int> setHubMosaic(
    int id,
    String hubMosaicId,
    String role, {
    DateTime? now,
  }) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return _db.customUpdate(
      'UPDATE mosaic_projects SET hub_mosaic_id = ?, collab_role = ?, '
      "collab_status = 'published', updated_at = ? WHERE id = ?",
      variables: [
        Variable<String>(hubMosaicId),
        Variable<String>(role),
        Variable<int>(at),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Update a published project's hub-side collaborative lifecycle
  /// (`published`|`assembling`|`complete`). Returns the number of rows changed.
  Future<int> setCollabStatus(int id, String collabStatus, {DateTime? now}) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return _db.customUpdate(
      'UPDATE mosaic_projects SET collab_status = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable<String>(collabStatus),
        Variable<int>(at),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Delete a project by id. `mosaic_panels` rows cascade
  /// (`ON DELETE CASCADE`). Returns the number of rows changed.
  Future<int> deleteProject(int id) {
    return _db.customUpdate(
      'DELETE FROM mosaic_projects WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
  }

  MosaicProject _map(QueryRow row) {
    return MosaicProject(
      id: row.read<int>('id'),
      targetId: row.readNullable<int>('target_id'),
      name: row.read<String>('name'),
      rows: row.read<int>('rows'),
      cols: row.read<int>('cols'),
      overlapPct: row.read<double>('overlap_pct'),
      positionAngleDeg: row.read<double>('position_angle_deg'),
      status: MosaicProjectStatus.fromWire(row.read<String>('status')),
      outputMasterId: row.readNullable<int>('output_master_id'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
      updatedAt: _fromEpochSeconds(row.read<int>('updated_at')),
      hubMosaicId: row.readNullable<String>('hub_mosaic_id'),
      collabRole: row.readNullable<String>('collab_role'),
      collabStatus: row.readNullable<String>('collab_status'),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [MosaicProjectsDao].
final mosaicProjectsDaoProvider = Provider<MosaicProjectsDao>((ref) {
  return MosaicProjectsDao(ref.watch(databaseProvider));
});
