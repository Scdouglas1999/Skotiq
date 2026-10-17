part of '../database.dart';

extension _SkotiqDatabaseMigrationV55 on SkotiqDatabase {
  /// Version 55: turns the hot full-scans into index seeks and gives the
  /// maintenance sweeps a durable resume point. Purely additive — no drops;
  /// every change makes reads faster, never different.
  ///
  ///   * New `living_sky_retention` table — per-scope "where did the last
  ///     prune get to" markers (transient age-out, cutout/delta cache sweep,
  ///     swarm-blob sweep) so a maintenance pass is incremental instead of
  ///     re-scanning all history.
  ///   * INDEXES that turn the documented full-scans into seeks:
  ///       - `idx_transient_detections_dismissed (dismissed, tile_id)` — the
  ///         per-frame dismissed-suppression lookup, now scoped to the covered
  ///         tiles instead of scanning the whole all-time dismissed set.
  ///       - `idx_transient_detections_confirmed (reviewed, dismissed, detected_at)`
  ///         — the `reviewed && !dismissed` Confirmed feed, newest-first.
  ///       - `idx_sky_tiles_dec (center_dec_deg)` — the Dec-band cone prefilter
  ///         backing Contribute / Pull / Your-Sky cone selection at scale.
  ///       - `idx_sky_atlas_folds_contributor (contributor, tile_id, healpix_order)`
  ///         — export-delta excluding foreign (swarm) folds without scanning a
  ///         tile's whole fold history.
  ///
  /// Guarded by [_tableExists] to match the v52–v54 style (the v2–v17 chain
  /// recreates tables from the CURRENT Drift schema, which already declares
  /// these, so a blind `createTable` would throw on those paths). The indexes
  /// are created with `IF NOT EXISTS` here AND are re-asserted by
  /// `_createCustomIndexes` (re-run by the migration strategy after this hook),
  /// so creating them in either place is idempotent. The new table's unique
  /// `@TableIndex` on `scope` is materialized explicitly below for the same
  /// reason as v54's contribution-key index (createTable does not always emit
  /// the table index on the migration path).
  Future<void> _upgradeSchemaV55(Migrator m, int from) async {
    if (from < 55) {
      if (!await _tableExists('living_sky_retention')) {
        await m.createTable(livingSkyRetention);
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS '
          'idx_living_sky_retention_scope ON living_sky_retention (scope)',
        );
      }

      await _createLivingSkyWave3Indexes();
    }
  }

  /// The Wave 3 scale indexes — created here on the upgrade path and re-asserted
  /// by `_createCustomIndexes` on fresh installs. Idempotent (`IF NOT EXISTS`).
  Future<void> _createLivingSkyWave3Indexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transient_detections_dismissed '
      'ON transient_detections (dismissed, tile_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transient_detections_confirmed '
      'ON transient_detections (reviewed, dismissed, detected_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sky_tiles_dec '
      'ON sky_tiles (center_dec_deg)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sky_atlas_folds_contributor '
      'ON sky_atlas_folds (contributor, tile_id, healpix_order)',
    );
  }
}
