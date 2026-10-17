part of '../database.dart';

extension _SkotiqDatabaseMigrationV56 on SkotiqDatabase {
  /// Version 56 — the shared trust substrate the collaborative features ride
  /// on. Purely additive: no destructive drops; every change is a new column or
  /// a new table.
  ///
  ///   * `calibration_tags` gains sharing/provenance columns — `shared_by`,
  ///     `shared_at`, `license`, `provenance_json`, `published_remote_id` — so a
  ///     locally-tagged master can record who shared it, when, under what
  ///     license, with what provenance, and (when the user published it) the hub
  ///     master id to retract by, for shared calibration libraries.
  ///   * `mosaic_panels` gains distribution columns — `assigned_rig_id`,
  ///     `assigned_user_id`, `claim_token`, `uploaded_master_id` — so a panel of
  ///     a collaborative mosaic can be claimed by a rig/user and tracked to the
  ///     uploaded panel master.
  ///   * `constellation_contributions` gains `session_id` — links a per-tile
  ///     swarm receipt to a live co-imaging session.
  ///   * New `co_imaging_sessions` table (+ its unique `(hub_key, session_id)`
  ///     index) — client-side membership of live co-imaging sessions.
  ///
  /// `calibration_tags` and `mosaic_panels` are raw-DDL tables (the dominant
  /// v27+ convention), so their new columns are retrofitted with guarded
  /// `ALTER TABLE ... ADD COLUMN` — the exact pattern of
  /// `_ensureIntegratedMastersV42Columns`. The fresh-install path adds the same
  /// columns directly in `_createCalibrationTagsTable` / `_createMosaicTables`,
  /// so both paths converge on the identical schema.
  ///
  /// `constellation_contributions` and `co_imaging_sessions` are Drift tables;
  /// the new `session_id` column is declared on the Drift class AND retrofitted
  /// here with a guarded ALTER, matching how v54 added `swarm_overlay_frames`.
  /// The `co_imaging_sessions` table is created via [_tableExists]-guarded
  /// `createTable` (the v52–v55 style — the v2–v17 chain recreates tables from
  /// the CURRENT Drift schema, which already declares it, so a blind
  /// `createTable` would throw on those upgrade paths). Its unique
  /// `(hub_key, session_id)` index is materialized explicitly (createTable does
  /// not always emit the `@TableIndex` on the migration path).
  Future<void> _upgradeSchemaV56(Migrator m, int from) async {
    if (from < 56) {
      // Calibration master sharing / provenance.
      if (!await _columnExists('calibration_tags', 'shared_by')) {
        await customStatement(
          'ALTER TABLE calibration_tags ADD COLUMN shared_by TEXT',
        );
      }
      if (!await _columnExists('calibration_tags', 'shared_at')) {
        await customStatement(
          'ALTER TABLE calibration_tags ADD COLUMN shared_at INTEGER',
        );
      }
      if (!await _columnExists('calibration_tags', 'license')) {
        await customStatement(
          'ALTER TABLE calibration_tags ADD COLUMN license TEXT',
        );
      }
      if (!await _columnExists('calibration_tags', 'provenance_json')) {
        await customStatement(
          'ALTER TABLE calibration_tags ADD COLUMN provenance_json TEXT',
        );
      }
      if (!await _columnExists('calibration_tags', 'published_remote_id')) {
        await customStatement(
          'ALTER TABLE calibration_tags ADD COLUMN published_remote_id TEXT',
        );
      }

      // Collaborative mosaic publish/role/status on the project itself, so
      // an owner's local project remembers the hub mosaic it published, its
      // collaborative role (owner|participant), and the hub-side lifecycle
      // (published|assembling|complete).
      if (!await _columnExists('mosaic_projects', 'hub_mosaic_id')) {
        await customStatement(
          'ALTER TABLE mosaic_projects ADD COLUMN hub_mosaic_id TEXT',
        );
      }
      if (!await _columnExists('mosaic_projects', 'collab_role')) {
        await customStatement(
          'ALTER TABLE mosaic_projects ADD COLUMN collab_role TEXT',
        );
      }
      if (!await _columnExists('mosaic_projects', 'collab_status')) {
        await customStatement(
          'ALTER TABLE mosaic_projects ADD COLUMN collab_status TEXT',
        );
      }
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_mosaic_projects_hub '
        'ON mosaic_projects (hub_mosaic_id)',
      );

      // Collaborative mosaic panel distribution.
      if (!await _columnExists('mosaic_panels', 'assigned_rig_id')) {
        await customStatement(
          'ALTER TABLE mosaic_panels ADD COLUMN assigned_rig_id TEXT',
        );
      }
      if (!await _columnExists('mosaic_panels', 'assigned_user_id')) {
        await customStatement(
          'ALTER TABLE mosaic_panels ADD COLUMN assigned_user_id TEXT',
        );
      }
      if (!await _columnExists('mosaic_panels', 'claim_token')) {
        await customStatement(
          'ALTER TABLE mosaic_panels ADD COLUMN claim_token TEXT',
        );
      }
      if (!await _columnExists('mosaic_panels', 'uploaded_master_id')) {
        await customStatement(
          'ALTER TABLE mosaic_panels ADD COLUMN uploaded_master_id INTEGER',
        );
      }

      // Co-imaging session link on the swarm contribution receipt.
      if (!await _columnExists('constellation_contributions', 'session_id')) {
        await customStatement(
          'ALTER TABLE constellation_contributions ADD COLUMN session_id TEXT',
        );
      }

      // Client-side co-imaging session membership table.
      if (!await _tableExists('co_imaging_sessions')) {
        await m.createTable(coImagingSessions);
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS '
          'idx_coimaging_sessions_key ON co_imaging_sessions '
          '(hub_key, session_id)',
        );
      }
    }
  }
}
