import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/mosaic_project.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

/// Data-access object for the v45 `mosaic_panels` table (Mosaic M2) — one row
/// per panel of a [MosaicProject], carrying its grid position, center RA/Dec,
/// per-panel capture target, per-panel integrated master, captured count, and
/// lifecycle status.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createMosaicTables]) rather than a drift `Table` class,
/// so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customInsert`/`customStatement` APIs — mirroring
/// [CampaignsDao] and [NarrowbandCompositesDao]. It is deliberately NOT a
/// `@DriftAccessor`.
///
/// `UNIQUE(project_id, panel_index)` makes `(project, panel)` the panel
/// identity; [upsert] keys on that pair so regenerating a project's panels
/// never duplicates rows. SQLite errors propagate.
class MosaicPanelsDao {
  MosaicPanelsDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, project_id, panel_index, center_ra, center_dec, target_id, '
      'integrated_master_id, captured_count, status, '
      // v56: distributed-capture claim + upload.
      'assigned_rig_id, assigned_user_id, claim_token, uploaded_master_id';

  /// Insert or update a panel keyed on `(project_id, panel_index)`.
  ///
  /// On a fresh insert the row is created with the supplied geometry/target and
  /// `captured_count = 0`, `status = 'pending'`. When a panel already exists for
  /// the pair, its geometry, per-panel `target_id`, and `integrated_master_id`
  /// are updated WITHOUT resetting the running `captured_count` or `status`
  /// (regenerating the grid must never lose capture progress). Returns the
  /// panel row id.
  Future<int> upsert({
    required int projectId,
    required int panelIndex,
    required double centerRa,
    required double centerDec,
    int? targetId,
    int? integratedMasterId,
  }) async {
    final existing = await _findRow(projectId, panelIndex);
    if (existing != null) {
      final id = existing.read<int>('id');
      await _db.customStatement(
        'UPDATE mosaic_panels SET center_ra = ?, center_dec = ?, '
        'target_id = ?, integrated_master_id = ? WHERE id = ?',
        [centerRa, centerDec, targetId, integratedMasterId, id],
      );
      return id;
    }
    return _db.customInsert(
      'INSERT INTO mosaic_panels('
      'project_id, panel_index, center_ra, center_dec, target_id, '
      'integrated_master_id, captured_count, status'
      ") VALUES (?, ?, ?, ?, ?, ?, 0, 'pending')",
      variables: [
        Variable<int>(projectId),
        Variable<int>(panelIndex),
        Variable<double>(centerRa),
        Variable<double>(centerDec),
        Variable<int>(targetId),
        Variable<int>(integratedMasterId),
      ],
    );
  }

  /// All panels for a project, ordered by `panel_index`.
  Future<List<MosaicProjectPanel>> getForProject(int projectId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM mosaic_panels '
          'WHERE project_id = ? ORDER BY panel_index ASC',
          variables: [Variable<int>(projectId)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// The single panel for a `(project, panel_index)` pair, or null when absent.
  Future<MosaicProjectPanel?> getByIndex(int projectId, int panelIndex) async {
    final row = await _findRow(projectId, panelIndex);
    return row == null ? null : _map(row);
  }

  /// Fetch a panel by its row id, or null when absent.
  Future<MosaicProjectPanel?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM mosaic_panels WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// Attach the per-panel master's `integrated_masters.id` to a panel and mark
  /// it [MosaicPanelStatus.integrated]. Returns the number of rows changed.
  Future<int> setMaster(int panelId, int integratedMasterId) {
    return _db.customUpdate(
      'UPDATE mosaic_panels SET integrated_master_id = ?, status = ? '
      'WHERE id = ?',
      variables: [
        Variable<int>(integratedMasterId),
        Variable<String>(MosaicPanelStatus.integrated.wire),
        Variable<int>(panelId),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Clear a panel's `integrated_master_id` link WITHOUT touching its status —
  /// used when a re-integration of the panel failed, so the panel no longer
  /// points at a stale/superseded master. The caller sets the terminal status
  /// (e.g. [MosaicPanelStatus.failed]) separately. Returns rows changed.
  Future<int> clearMaster(int panelId) {
    return _db.customUpdate(
      'UPDATE mosaic_panels SET integrated_master_id = NULL WHERE id = ?',
      variables: [Variable<int>(panelId)],
      updateKind: UpdateKind.update,
    );
  }

  /// Persist a hub panel claim onto a panel: the hub-issued [claimToken]
  /// baton and the authoritative [accountId] / [rigId] the panel is assigned to.
  /// Returns the number of rows changed.
  Future<int> setClaim(
    int panelId, {
    required String claimToken,
    String? rigId,
    String? accountId,
  }) {
    return _db.customUpdate(
      'UPDATE mosaic_panels SET claim_token = ?, assigned_rig_id = ?, '
      'assigned_user_id = ? WHERE id = ?',
      variables: [
        Variable<String>(claimToken),
        Variable<String>(rigId),
        Variable<String>(accountId),
        Variable<int>(panelId),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Drop a hub panel claim from a panel: clears the claim baton
  /// and the assignment it granted, so local state stops advertising a hold the
  /// hub has already given back to the pool. Returns rows changed.
  Future<int> clearClaim(int panelId) {
    return _db.customUpdate(
      'UPDATE mosaic_panels SET claim_token = NULL, assigned_rig_id = NULL, '
      'assigned_user_id = NULL WHERE id = ?',
      variables: [Variable<int>(panelId)],
      updateKind: UpdateKind.update,
    );
  }

  /// Record the local `integrated_masters.id` of the panel master uploaded to
  /// the hub for this panel. Returns the number of rows changed.
  Future<int> setUploaded(int panelId, int uploadedMasterId) {
    return _db.customUpdate(
      'UPDATE mosaic_panels SET uploaded_master_id = ? WHERE id = ?',
      variables: [Variable<int>(uploadedMasterId), Variable<int>(panelId)],
      updateKind: UpdateKind.update,
    );
  }

  /// Update a panel's lifecycle [status]. Returns the number of rows changed.
  Future<int> updateStatus(int panelId, MosaicPanelStatus status) {
    return _db.customUpdate(
      'UPDATE mosaic_panels SET status = ? WHERE id = ?',
      variables: [Variable<String>(status.wire), Variable<int>(panelId)],
      updateKind: UpdateKind.update,
    );
  }

  /// Add [delta] accepted frames to a panel's running `captured_count`.
  /// Returns the number of rows changed, or 0 when [delta] <= 0 (a rejected /
  /// no-op frame must never advance the counter).
  ///
  /// Prefer [setCaptured] for the integration path: the per-panel integration
  /// always re-folds the *whole* accepted population, so an idempotent
  /// assignment (not `+=`) is correct there — see [setCaptured]. This
  /// accumulating form is retained for callers that genuinely credit a single
  /// freshly-captured frame (e.g. a live capture tick), where each call is a
  /// distinct new frame.
  Future<int> incrementCaptured(int panelId, {int delta = 1}) {
    if (delta <= 0) return Future.value(0);
    return _db.customUpdate(
      'UPDATE mosaic_panels SET captured_count = captured_count + ? '
      'WHERE id = ?',
      variables: [Variable<int>(delta), Variable<int>(panelId)],
      updateKind: UpdateKind.update,
    );
  }

  /// SET a panel's `captured_count` to the [count] freshly-accepted frames that
  /// fed its latest integration.
  ///
  /// This is an idempotent assignment, NOT an accumulation: re-integrating a
  /// panel (e.g. after grabbing more subs, or a re-run with the SAME subs) must
  /// land the count at the current accepted population, never double it. The
  /// per-panel integration always folds the *whole* accepted set for the panel's
  /// target, so the accepted count IS the running total — `+=` would inflate it
  /// on every re-run. Returns the number of rows changed, or 0 when [count] < 0
  /// (a negative population is nonsense and must never touch the counter).
  Future<int> setCaptured(int panelId, int count) {
    if (count < 0) return Future.value(0);
    return _db.customUpdate(
      'UPDATE mosaic_panels SET captured_count = ? WHERE id = ?',
      variables: [Variable<int>(count), Variable<int>(panelId)],
      updateKind: UpdateKind.update,
    );
  }

  Future<QueryRow?> _findRow(int projectId, int panelIndex) {
    return _db
        .customSelect(
          'SELECT $_columns FROM mosaic_panels '
          'WHERE project_id = ? AND panel_index = ? LIMIT 1',
          variables: [Variable<int>(projectId), Variable<int>(panelIndex)],
        )
        .getSingleOrNull();
  }

  MosaicProjectPanel _map(QueryRow row) {
    return MosaicProjectPanel(
      id: row.read<int>('id'),
      projectId: row.read<int>('project_id'),
      panelIndex: row.read<int>('panel_index'),
      centerRa: row.read<double>('center_ra'),
      centerDec: row.read<double>('center_dec'),
      targetId: row.readNullable<int>('target_id'),
      integratedMasterId: row.readNullable<int>('integrated_master_id'),
      capturedCount: row.read<int>('captured_count'),
      status: MosaicPanelStatus.fromWire(row.read<String>('status')),
      assignedRigId: row.readNullable<String>('assigned_rig_id'),
      assignedUserId: row.readNullable<String>('assigned_user_id'),
      claimToken: row.readNullable<String>('claim_token'),
      uploadedMasterId: row.readNullable<int>('uploaded_master_id'),
    );
  }
}

/// Riverpod provider for [MosaicPanelsDao].
final mosaicPanelsDaoProvider = Provider<MosaicPanelsDao>((ref) {
  return MosaicPanelsDao(ref.watch(databaseProvider));
});
