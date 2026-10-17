import 'package:drift/drift.dart';

import 'imaging_sessions.dart';
import 'targets.dart';

/// Pillar A ("Your Sky") persistence — the personal sky atlas.
///
/// The atlas folds every plate-solved light frame into a fixed HEALPix tiling
/// (NESTED, order [skyAtlasHealpixOrder]) so the same patch of sky accumulates
/// across nights and equipment changes. Three tables back the feature:
///
///   * [SkyTiles] — one row per materialized HEALPix tile, carrying the running
///     totals and a pointer to the on-disk `.nst` streaming accumulator sidecar.
///   * [SkyAtlasRegions] — named, human-facing groupings of tiles (a target, a
///     mosaic, a custom box) used to drive the atlas browser and per-region
///     coverage rollups.
///   * [SkyAtlasFolds] — the append-only fold timeline that makes "scrub a
///     region across time" possible: each row records one fold of one tile at a
///     point in time, with the frames/weight/integration it added and the
///     session that contributed it.
///
/// Enum-ish columns ([SkyAtlasRegions.kind]) are stored as stable text so a
/// forward-compatible reader degrades gracefully, matching the convention in
/// `tables/narrator_events.dart`. FK columns are nullable where the referenced
/// row can legitimately disappear (a deleted session or target), so atlas
/// history survives the deletion of the thing that produced it.

/// HEALPix order the atlas tiling is built at. Must match
/// `sky_atlas.rs::ATLAS_HEALPIX_ORDER` (9) — see the constants table in
/// `docs/skotiq_5_0_contracts.md`. Persisted per-row on tiles/folds so a
/// future order change can be detected rather than silently mis-addressing
/// historical tiles.
const int skyAtlasHealpixOrder = 9;

/// One materialized HEALPix tile of the personal sky atlas.
///
/// `(tileId, healpixOrder)` is unique: a HEALPix NESTED pixel id is only
/// meaningful together with the order it was computed at, and the atlas folds
/// every contribution for the same pixel into the same row (and the same
/// on-disk accumulator at [sidecarPath]).
@DataClassName('SkyTileRow')
@TableIndex(
  name: 'idx_sky_tiles_pixel',
  unique: true,
  columns: {#tileId, #healpixOrder},
)
@TableIndex(name: 'idx_sky_tiles_region', columns: {#regionId})
class SkyTiles extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// HEALPix NESTED pixel id.
  IntColumn get tileId => integer()();

  /// HEALPix order the [tileId] was computed at (= [skyAtlasHealpixOrder] for
  /// tiles folded by this build).
  IntColumn get healpixOrder => integer()();

  /// Channel count of the accumulator (1 = mono, 3 = colour).
  IntColumn get channels => integer()();

  /// Tile-center sky coordinates, degrees, for spatial lookup without reopening
  /// the sidecar.
  RealColumn get centerRaDeg => real()();
  RealColumn get centerDecDeg => real()();

  /// Mean sum-count across the tile's pixels — a cheap "how deep is this tile"
  /// coverage proxy for the atlas browser.
  RealColumn get coverageMean => real().withDefault(const Constant(0))();

  /// Running totals across every fold into this tile.
  IntColumn get totalFrames => integer().withDefault(const Constant(0))();
  RealColumn get integrationSeconds => real().withDefault(const Constant(0))();

  /// Blended community ("swarm") depth pulled into the separate overlay sidecar
  /// for DISPLAY only — kept OUT of [totalFrames]/[integrationSeconds] so the
  /// own-light contribution math (and the "your contribution" bar) stays honest
  /// after a pull. `mergeSwarmDelta` writes these from the overlay tree; the
  /// Your Sky co-add view adds them on top of own-light for display.
  IntColumn get swarmOverlayFrames =>
      integer().withDefault(const Constant(0))();
  RealColumn get swarmOverlayIntegrationSeconds =>
      real().withDefault(const Constant(0))();

  /// Path to the on-disk `.nst` streaming accumulator sidecar.
  TextColumn get sidecarPath => text()();

  /// The session whose fold last touched this tile (null when that session was
  /// deleted, or the fold was sessionless).
  IntColumn get lastFoldSessionId => integer().nullable().references(
    ImagingSessions,
    #id,
    onDelete: KeyAction.setNull,
  )();
  DateTimeColumn get lastFoldAt => dateTime().nullable()();

  /// The region this tile belongs to, if any (null = orphan / not yet grouped).
  IntColumn get regionId => integer().nullable().references(
    SkyAtlasRegions,
    #id,
    onDelete: KeyAction.setNull,
  )();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// A named, human-facing grouping of atlas tiles.
@DataClassName('SkyAtlasRegionRow')
@TableIndex(name: 'idx_sky_atlas_regions_target', columns: {#targetId})
class SkyAtlasRegions extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get name => text()();

  /// `target` | `mosaic` | `custom` | `polar` (stored as stable text).
  TextColumn get kind => text()();

  /// Region center + cone radius, degrees.
  RealColumn get centerRaDeg => real()();
  RealColumn get centerDecDeg => real()();
  RealColumn get radiusDeg => real()();

  /// The target this region tracks, if it was created from one (null when the
  /// target was deleted, or the region is freestanding).
  IntColumn get targetId => integer().nullable().references(
    Targets,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// Denormalized rollups so the region list renders without scanning tiles.
  IntColumn get tileCount => integer().withDefault(const Constant(0))();
  RealColumn get integrationSeconds => real().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Append-only fold timeline — one row per fold of one tile at a point in time.
///
/// This is the table the "scrub a region across time" UI walks: ordering a
/// region's folds by [foldedAt] replays exactly how the tile (and therefore the
/// region) deepened night by night, and the [sessionId] links each contribution
/// back to the frames that produced it.
@DataClassName('SkyAtlasFoldRow')
@TableIndex(
  name: 'idx_sky_atlas_folds_tile_time',
  columns: {#tileId, #healpixOrder, #foldedAt},
)
@TableIndex(name: 'idx_sky_atlas_folds_session', columns: {#sessionId})
class SkyAtlasFolds extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// HEALPix NESTED pixel id + order the fold targeted (mirrors [SkyTiles] so
  /// the timeline is walkable without a join through the tile row).
  IntColumn get tileId => integer()();
  IntColumn get healpixOrder => integer()();

  /// The session that contributed this fold (null when sessionless, or when
  /// that session was later deleted).
  IntColumn get sessionId => integer().nullable().references(
    ImagingSessions,
    #id,
    onDelete: KeyAction.setNull,
  )();

  DateTimeColumn get foldedAt => dateTime().withDefault(currentDateAndTime)();

  /// What this fold added to the tile.
  IntColumn get framesAdded => integer()();
  RealColumn get weightAdded => real()();
  RealColumn get integrationSecondsAdded => real()();

  /// Frames rejected by the accumulator's clipping during this fold.
  IntColumn get rejected => integer().withDefault(const Constant(0))();

  /// Originating contributor — empty for local folds, a hub identity for
  /// constellation pulls.
  TextColumn get contributor => text().withDefault(const Constant(''))();

  /// Short human label for the fold (e.g. the session name or "swarm pull").
  TextColumn get label => text()();
}
