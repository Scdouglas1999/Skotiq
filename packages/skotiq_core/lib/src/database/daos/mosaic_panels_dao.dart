import 'package:drift/drift.dart';

import '../../models/imaging/mosaic_project.dart';
import '../database.dart';

part 'mosaic_panels_dao.g.dart';

/// Reads and writes for `mosaic_panels`: one row per panel of a
/// [MosaicProject], carrying its grid position, center RA/Dec, per-panel
/// capture target, per-panel integrated master, captured count, and lifecycle
/// status.
///
/// `UNIQUE(project_id, panel_index)` makes `(project, panel)` the panel
/// identity; [upsert] keys on that pair so regenerating a project's panels
/// never duplicates rows. SQLite errors propagate.
@DriftAccessor(include: {'../schema/mosaic.drift'})
class MosaicPanelsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$MosaicPanelsDaoMixin {
  MosaicPanelsDao(super.db);

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
    final placement = MosaicPanelsCompanion(
      centerRa: Value(centerRa),
      centerDec: Value(centerDec),
      targetId: Value(targetId),
      integratedMasterId: Value(integratedMasterId),
    );
    if (existing != null) {
      await _write(existing.id, placement);
      return existing.id;
    }
    return into(mosaicPanels).insert(
      placement.copyWith(
        projectId: Value(projectId),
        panelIndex: Value(panelIndex),
        capturedCount: const Value(0),
        status: Value(MosaicPanelStatus.pending.wire),
      ),
    );
  }

  /// All panels for a project, ordered by `panel_index`.
  Future<List<MosaicProjectPanel>> getForProject(int projectId) async {
    final rows =
        await (select(mosaicPanels)
              ..where((p) => p.projectId.equals(projectId))
              ..orderBy([(p) => OrderingTerm.asc(p.panelIndex)]))
            .get();
    return rows.map(_map).toList();
  }

  /// The single panel for a `(project, panel_index)` pair, or null when absent.
  Future<MosaicProjectPanel?> getByIndex(int projectId, int panelIndex) async {
    final row = await _findRow(projectId, panelIndex);
    return row == null ? null : _map(row);
  }

  Future<MosaicProjectPanel?> getById(int id) async {
    final row = await (select(
      mosaicPanels,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// Attach the per-panel master's `integrated_masters.id` to a panel and mark
  /// it [MosaicPanelStatus.integrated]. Returns the number of rows changed.
  Future<int> setMaster(int panelId, int integratedMasterId) => _write(
    panelId,
    MosaicPanelsCompanion(
      integratedMasterId: Value(integratedMasterId),
      status: Value(MosaicPanelStatus.integrated.wire),
    ),
  );

  /// Clear a panel's `integrated_master_id` link WITHOUT touching its status —
  /// used when a re-integration of the panel failed, so the panel no longer
  /// points at a stale/superseded master. The caller sets the terminal status
  /// (e.g. [MosaicPanelStatus.failed]) separately. Returns rows changed.
  Future<int> clearMaster(int panelId) => _write(
    panelId,
    const MosaicPanelsCompanion(integratedMasterId: Value(null)),
  );

  /// Persist a hub panel claim onto a panel: the hub-issued [claimToken]
  /// baton and the authoritative [accountId] / [rigId] the panel is assigned to.
  /// Returns the number of rows changed.
  Future<int> setClaim(
    int panelId, {
    required String claimToken,
    String? rigId,
    String? accountId,
  }) => _write(
    panelId,
    MosaicPanelsCompanion(
      claimToken: Value(claimToken),
      assignedRigId: Value(rigId),
      assignedUserId: Value(accountId),
    ),
  );

  /// Drop a hub panel claim from a panel: clears the claim baton
  /// and the assignment it granted, so local state stops advertising a hold the
  /// hub has already given back to the pool. Returns rows changed.
  Future<int> clearClaim(int panelId) => _write(
    panelId,
    const MosaicPanelsCompanion(
      claimToken: Value(null),
      assignedRigId: Value(null),
      assignedUserId: Value(null),
    ),
  );

  /// Record the local `integrated_masters.id` of the panel master uploaded to
  /// the hub for this panel. Returns the number of rows changed.
  Future<int> setUploaded(int panelId, int uploadedMasterId) => _write(
    panelId,
    MosaicPanelsCompanion(uploadedMasterId: Value(uploadedMasterId)),
  );

  /// Update a panel's lifecycle [status]. Returns the number of rows changed.
  Future<int> updateStatus(int panelId, MosaicPanelStatus status) =>
      _write(panelId, MosaicPanelsCompanion(status: Value(status.wire)));

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
    return _write(
      panelId,
      MosaicPanelsCompanion.custom(
        capturedCount: mosaicPanels.capturedCount + Variable(delta),
      ),
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
    return _write(panelId, MosaicPanelsCompanion(capturedCount: Value(count)));
  }

  Future<MosaicPanelRow?> _findRow(int projectId, int panelIndex) {
    return (select(mosaicPanels)
          ..where(
            (p) =>
                p.projectId.equals(projectId) & p.panelIndex.equals(panelIndex),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<int> _write(int panelId, Insertable<MosaicPanelRow> changes) =>
      (update(mosaicPanels)..where((p) => p.id.equals(panelId))).write(changes);

  MosaicProjectPanel _map(MosaicPanelRow row) {
    return MosaicProjectPanel(
      id: row.id,
      projectId: row.projectId,
      panelIndex: row.panelIndex,
      centerRa: row.centerRa,
      centerDec: row.centerDec,
      targetId: row.targetId,
      integratedMasterId: row.integratedMasterId,
      capturedCount: row.capturedCount,
      status: MosaicPanelStatus.fromWire(row.status),
      assignedRigId: row.assignedRigId,
      assignedUserId: row.assignedUserId,
      claimToken: row.claimToken,
      uploadedMasterId: row.uploadedMasterId,
    );
  }
}
