part of '../database.dart';

extension _SkotiqDatabaseMigrationV54 on SkotiqDatabase {
  /// Version 54 (Living Sky — Wave 0, "stop data corruption"): the durable
  /// substrate the Constellation idempotency + atlas fold-integrity fixes ride
  /// on. Purely additive — no destructive drops.
  ///
  ///   * New `constellation_contributions` table — per-(hub, tile) federation
  ///     receipts: the contribution high-water (true-delta export anchor +
  ///     remote receipt id), the pulled-tile high-water (re-pull idempotency)
  ///     and the joined-target rehydration row.
  ///   * `sky_tiles` gains `swarm_overlay_frames` / `swarm_overlay_integration_seconds`
  ///     — blended community depth kept OUT of the own-light totals so the
  ///     contribution bar stays honest after a pull.
  ///   * `captured_images` gains `atlas_folded_at` — the dedup marker the solve
  ///     hook stamps after a successful fold so a re-solved frame cannot
  ///     double-fold.
  ///
  /// Every step is guarded by [_tableExists] / [_columnExists] — matching the
  /// v52/v53 style — because the v2–v17 migration chain recreates tables from
  /// the CURRENT Drift schema (which already declares these), so a blind
  /// `createTable` / `ADD COLUMN` would throw on upgrade paths that pass through
  /// such a step. The table-level `@TableIndex` (the unique
  /// `(hubKey, tileId, healpixOrder)` key) is materialized by `createTable`, and
  /// `_createCustomIndexes` is re-run by the migration strategy afterwards, so
  /// no extra index DDL is needed here.
  ///
  /// Drift stores `DateTime` as an INTEGER (epoch), so `atlas_folded_at` is
  /// declared `INTEGER` in the raw ALTER below.
  Future<void> _upgradeSchemaV54(Migrator m, int from) async {
    if (from < 54) {
      if (!await _tableExists('constellation_contributions')) {
        await m.createTable(constellationContributions);
        // `createTable` does not always materialize the table's `@TableIndex`
        // on the migration path, so create the unique key explicitly (IF NOT
        // EXISTS keeps it idempotent against a createAll that already made it).
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS '
          'idx_constellation_contributions_key ON constellation_contributions '
          '(hub_key, tile_id, healpix_order)',
        );
      }

      if (!await _columnExists('sky_tiles', 'swarm_overlay_frames')) {
        await customStatement(
          'ALTER TABLE sky_tiles ADD COLUMN swarm_overlay_frames '
          'INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!await _columnExists(
        'sky_tiles',
        'swarm_overlay_integration_seconds',
      )) {
        await customStatement(
          'ALTER TABLE sky_tiles ADD COLUMN swarm_overlay_integration_seconds '
          'REAL NOT NULL DEFAULT 0',
        );
      }

      if (!await _columnExists('captured_images', 'atlas_folded_at')) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN atlas_folded_at INTEGER',
        );
      }
    }
  }
}
