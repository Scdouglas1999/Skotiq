part of '../database.dart';

extension _SkotiqDatabaseMigrationV52 on SkotiqDatabase {
  /// Version 52 (Pillars A & B — "Your Sky" / "First Light"): the personal sky
  /// atlas tables plus the difference-imaging transient log.
  ///
  /// Adds three Drift tables backing the atlas: `sky_tiles` (materialized
  /// HEALPix tiles + running totals + sidecar pointer), `sky_atlas_regions`
  /// (named groupings of tiles) and `sky_atlas_folds` (the append-only fold
  /// timeline that powers "scrub a region across time"); and one table backing
  /// First Light: `transient_detections` (one row per residual source the
  /// difference pipeline extracts against the deep atlas template).
  ///
  /// Each `createTable` is guarded by [_tableExists] — matching the v49 style —
  /// because the v2–v17 migration chain recreates tables from the CURRENT Drift
  /// schema (which already declares these), so a blind `createTable` would throw
  /// "table already exists" on upgrade paths that pass through such a step.
  /// `_createCustomIndexes` is re-run by the migration strategy after this hook,
  /// and the table-level `@TableIndex` declarations are materialized by
  /// `createTable`, so no extra index DDL is needed here.
  Future<void> _upgradeSchemaV52(Migrator m, int from) async {
    if (from < 52) {
      // skyAtlasRegions is referenced by skyTiles.regionId, so it must exist
      // first for the FK to resolve when skyTiles is created.
      if (!await _tableExists('sky_atlas_regions')) {
        await m.createTable(skyAtlasRegions);
      }
      if (!await _tableExists('sky_tiles')) {
        await m.createTable(skyTiles);
      }
      if (!await _tableExists('sky_atlas_folds')) {
        await m.createTable(skyAtlasFolds);
      }
      if (!await _tableExists('transient_detections')) {
        await m.createTable(transientDetections);
      }
    }
  }
}
