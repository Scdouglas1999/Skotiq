import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/database_provider.dart';
import '../database.dart';
import '../tables/sky_atlas_tables.dart';

part 'sky_atlas_dao.g.dart';

/// Data access for the personal sky atlas (Pillar A — "Your Sky").
///
/// Covers the three atlas tables: [SkyTiles] (materialized HEALPix tiles),
/// [SkyAtlasRegions] (named groupings) and [SkyAtlasFolds] (the append-only
/// fold timeline). The fold timeline is what makes "scrub a region across time"
/// possible — [listFoldsForRegionOverTime] replays a region's contributions in
/// chronological order.
@DriftAccessor(tables: [SkyTiles, SkyAtlasRegions, SkyAtlasFolds])
class SkyAtlasDao extends DatabaseAccessor<SkotiqDatabase>
    with _$SkyAtlasDaoMixin {
  SkyAtlasDao(super.db);

  // Regions

  /// All regions, newest first.
  Future<List<SkyAtlasRegionRow>> getAllRegions() {
    return (select(
      skyAtlasRegions,
    )..orderBy([(r) => OrderingTerm.desc(r.createdAt)])).get();
  }

  /// Reactive variant of [getAllRegions] for the atlas browser.
  Stream<List<SkyAtlasRegionRow>> watchAllRegions() {
    return (select(
      skyAtlasRegions,
    )..orderBy([(r) => OrderingTerm.desc(r.createdAt)])).watch();
  }

  Future<SkyAtlasRegionRow?> getRegion(int id) {
    return (select(
      skyAtlasRegions,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
  }

  /// Insert a region, returning its row id.
  Future<int> insertRegion(SkyAtlasRegionsCompanion region) {
    return into(skyAtlasRegions).insert(region);
  }

  /// Insert-or-update a region.
  ///
  /// IDENTITY (load-bearing for nightly re-folds): when a [targetId] is given
  /// the region is keyed on it, so each successive auto-fold of the same target
  /// reuses ONE region rather than creating a duplicate per night (and a later
  /// rename does not orphan the prior nights). When [targetId] is null (a custom
  /// / mosaic / polar region named by hand) we fall back to matching on the
  /// human [name]. The matched row's geometry + [targetId] are refreshed and its
  /// id returned; otherwise a new row is inserted. Denormalized rollups
  /// ([SkyAtlasRegions.tileCount] / [SkyAtlasRegions.integrationSeconds]) are
  /// left untouched here — they are maintained by [refreshRegionRollups].
  Future<int> upsertRegion({
    required String name,
    required String kind,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    int? targetId,
  }) {
    return transaction(() async {
      final existing = targetId != null
          ? await (select(skyAtlasRegions)
                  ..where((r) => r.targetId.equals(targetId))
                  ..limit(1))
                .getSingleOrNull()
          : await (select(skyAtlasRegions)
                  ..where((r) => r.name.equals(name))
                  ..limit(1))
                .getSingleOrNull();
      if (existing != null) {
        // Grow-only radius: a per-frame fold passes its own (small) cone, but a
        // mosaic/dithered target legitimately spans wider than one sub, so never
        // shrink an established region below the widest cone it has seen.
        final mergedRadius = radiusDeg > existing.radiusDeg
            ? radiusDeg
            : existing.radiusDeg;
        await (update(
          skyAtlasRegions,
        )..where((r) => r.id.equals(existing.id))).write(
          SkyAtlasRegionsCompanion(
            // Refresh the human name too (a target-keyed region follows a
            // target rename); geometry centre tracks the latest known centre.
            name: Value(name),
            kind: Value(kind),
            centerRaDeg: Value(centerRaDeg),
            centerDecDeg: Value(centerDecDeg),
            radiusDeg: Value(mergedRadius),
            targetId: Value(targetId),
          ),
        );
        return existing.id;
      }
      return into(skyAtlasRegions).insert(
        SkyAtlasRegionsCompanion.insert(
          name: name,
          kind: kind,
          centerRaDeg: centerRaDeg,
          centerDecDeg: centerDecDeg,
          radiusDeg: radiusDeg,
          targetId: Value(targetId),
        ),
      );
    });
  }

  /// Delete a region. Tiles that pointed at it are detached (their `region_id`
  /// is set null by the FK action) rather than removed, so the underlying atlas
  /// data survives.
  Future<int> deleteRegion(int id) {
    return (delete(skyAtlasRegions)..where((r) => r.id.equals(id))).go();
  }

  /// The region whose cone contains the point [raDeg]/[decDeg], or null when no
  /// region covers it.
  ///
  /// Uses the exact great-circle (angular) separation between the point and
  /// each region center, comparing against the region's [SkyAtlasRegions.radiusDeg].
  /// When several regions overlap the point, the tightest (smallest radius) wins
  /// — that is the most specific grouping for the point. RA/Dec are in degrees.
  Future<SkyAtlasRegionRow?> getRegionForPoint(
    double raDeg,
    double decDeg,
  ) async {
    final regions = await select(skyAtlasRegions).get();
    SkyAtlasRegionRow? best;
    for (final region in regions) {
      final sep = _angularSeparationDeg(
        raDeg,
        decDeg,
        region.centerRaDeg,
        region.centerDecDeg,
      );
      if (sep <= region.radiusDeg) {
        if (best == null || region.radiusDeg < best.radiusDeg) {
          best = region;
        }
      }
    }
    return best;
  }

  /// Recompute and store a region's denormalized rollups:
  /// [SkyAtlasRegions.tileCount] (tiles in the region) and
  /// [SkyAtlasRegions.integrationSeconds], the exposure of the distinct frames
  /// folded into any of its tiles (each frame counted once, not once per tile).
  Future<void> refreshRegionRollups(int regionId) async {
    final countExpr = skyTiles.id.count();
    final query = selectOnly(skyTiles)
      ..addColumns([countExpr])
      ..where(skyTiles.regionId.equals(regionId));
    final row = await query.getSingle();
    final count = row.read(countExpr) ?? 0;
    final totals = await regionTotals(regionId);
    await (update(skyAtlasRegions)..where((r) => r.id.equals(regionId))).write(
      SkyAtlasRegionsCompanion(
        tileCount: Value(count),
        integrationSeconds: Value(totals.seconds),
      ),
    );
  }

  /// Distinct-frame totals from the fold timeline. A frame is one
  /// (label, contributor) pair; its exposure is the largest seconds any of its
  /// tile rows recorded (every row of a frame records the frame's own
  /// exposure). [where] narrows the fold rows (an SQL predicate on `f`).
  Future<({int frames, double seconds})> _distinctFrameTotals(
    String where,
    List<Variable<Object>> variables,
  ) async {
    final row = await customSelect(
      'SELECT COUNT(*) AS frames, COALESCE(SUM(s), 0.0) AS seconds FROM ('
      'SELECT f.label, f.contributor, MAX(f.integration_seconds_added) AS s '
      'FROM sky_atlas_folds f WHERE f.frames_added > 0 AND ($where) '
      'GROUP BY f.label, f.contributor)',
      variables: variables,
      readsFrom: {skyAtlasFolds, skyTiles},
    ).getSingle();
    return (
      frames: row.read<int>('frames'),
      seconds: row.read<double>('seconds'),
    );
  }

  /// Distinct frames and their exposure across the whole atlas.
  Future<({int frames, double seconds})> atlasTotals() =>
      _distinctFrameTotals('1 = 1', const []);

  /// Distinct frames and their exposure for one tile.
  Future<({int frames, double seconds})> tileTotals(
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
  }) => _distinctFrameTotals('f.tile_id = ? AND f.healpix_order = ?', [
    Variable.withInt(tileId),
    Variable.withInt(healpixOrder),
  ]);

  /// Distinct frames and their exposure over the tiles of a region.
  Future<({int frames, double seconds})> regionTotals(int regionId) =>
      _distinctFrameTotals(
        'EXISTS (SELECT 1 FROM sky_tiles t WHERE t.tile_id = f.tile_id '
        'AND t.healpix_order = f.healpix_order AND t.region_id = ?)',
        [Variable.withInt(regionId)],
      );

  // Tiles

  /// All tiles, ordered by depth (most integration first) for coverage views.
  Future<List<SkyTileRow>> getAllTiles() {
    return (select(
      skyTiles,
    )..orderBy([(t) => OrderingTerm.desc(t.integrationSeconds)])).get();
  }

  /// Reactive variant of [getAllTiles].
  Stream<List<SkyTileRow>> watchAllTiles() {
    return (select(
      skyTiles,
    )..orderBy([(t) => OrderingTerm.desc(t.integrationSeconds)])).watch();
  }

  /// The tile for a HEALPix pixel at [healpixOrder] (default
  /// [skyAtlasHealpixOrder]), or null when it has not been folded yet.
  Future<SkyTileRow?> getTile(
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
  }) {
    return (select(skyTiles)
          ..where(
            (t) =>
                t.tileId.equals(tileId) & t.healpixOrder.equals(healpixOrder),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// Tiles whose center declination falls within `[minDecDeg, maxDecDeg]`.
  ///
  /// The cone selection that drives Contribute / Pull / Your-Sky rendering used
  /// to materialize EVERY tile ever imaged and filter the cone in Dart — cost
  /// scaling with atlas size, not the cone. This is the cheap spatial
  /// prefilter: pass the cone's Dec band (`center.dec ± radius`, clamped to
  /// `[-90, 90]`) and the read becomes an index range on
  /// `idx_sky_tiles_dec (center_dec_deg)`; the caller still does the exact
  /// great-circle in-cone test on this much smaller candidate set (RA wrap and
  /// the spherical-cap RA widening near the poles make a pure SQL cone unsafe).
  Future<List<SkyTileRow>> getTilesInDecBand(
    double minDecDeg,
    double maxDecDeg,
  ) {
    return (select(skyTiles)..where(
          (t) =>
              t.centerDecDeg.isBiggerOrEqualValue(minDecDeg) &
              t.centerDecDeg.isSmallerOrEqualValue(maxDecDeg),
        ))
        .get();
  }

  /// Tiles belonging to [regionId], deepest first.
  Future<List<SkyTileRow>> getTilesForRegion(int regionId) {
    return (select(skyTiles)
          ..where((t) => t.regionId.equals(regionId))
          ..orderBy([(t) => OrderingTerm.desc(t.integrationSeconds)]))
        .get();
  }

  /// Insert-or-update a tile keyed by its `(tileId, healpixOrder)` pixel
  /// identity, returning the tile row id.
  ///
  /// On first fold a row is created; subsequent folds replace the running
  /// totals + sidecar pointer for the same pixel. This mirrors the streaming
  /// accumulator's "one sidecar per pixel" model — the caller passes the
  /// post-fold totals it computed from the accumulator.
  Future<int> upsertTile({
    required int tileId,
    int healpixOrder = skyAtlasHealpixOrder,
    required int channels,
    required double centerRaDeg,
    required double centerDecDeg,
    required double coverageMean,
    required int totalFrames,
    required double integrationSeconds,
    required String sidecarPath,
    int? lastFoldSessionId,
    DateTime? lastFoldAt,
    int? regionId,
    int? swarmOverlayFrames,
    double? swarmOverlayIntegrationSeconds,
  }) {
    return transaction(() async {
      final existing = await getTile(tileId, healpixOrder: healpixOrder);
      if (existing != null) {
        await (update(skyTiles)..where((t) => t.id.equals(existing.id))).write(
          SkyTilesCompanion(
            channels: Value(channels),
            centerRaDeg: Value(centerRaDeg),
            centerDecDeg: Value(centerDecDeg),
            coverageMean: Value(coverageMean),
            totalFrames: Value(totalFrames),
            integrationSeconds: Value(integrationSeconds),
            sidecarPath: Value(sidecarPath),
            lastFoldSessionId: Value(lastFoldSessionId),
            lastFoldAt: Value(lastFoldAt),
            regionId: Value(regionId ?? existing.regionId),
            // Overlay totals are owned by the swarm merge path; a plain fold
            // passes null and must not clobber them, and vice versa.
            swarmOverlayFrames: swarmOverlayFrames == null
                ? const Value.absent()
                : Value(swarmOverlayFrames),
            swarmOverlayIntegrationSeconds:
                swarmOverlayIntegrationSeconds == null
                ? const Value.absent()
                : Value(swarmOverlayIntegrationSeconds),
          ),
        );
        return existing.id;
      }
      return into(skyTiles).insert(
        SkyTilesCompanion.insert(
          tileId: tileId,
          healpixOrder: healpixOrder,
          channels: channels,
          centerRaDeg: centerRaDeg,
          centerDecDeg: centerDecDeg,
          coverageMean: Value(coverageMean),
          totalFrames: Value(totalFrames),
          integrationSeconds: Value(integrationSeconds),
          sidecarPath: sidecarPath,
          lastFoldSessionId: Value(lastFoldSessionId),
          lastFoldAt: Value(lastFoldAt),
          regionId: Value(regionId),
          swarmOverlayFrames: swarmOverlayFrames == null
              ? const Value.absent()
              : Value(swarmOverlayFrames),
          swarmOverlayIntegrationSeconds: swarmOverlayIntegrationSeconds == null
              ? const Value.absent()
              : Value(swarmOverlayIntegrationSeconds),
        ),
      );
    });
  }

  /// Attach a tile to a region (or detach by passing null), keeping the tile's
  /// other state intact.
  Future<void> assignTileToRegion(int tileRowId, int? regionId) async {
    await (update(skyTiles)..where((t) => t.id.equals(tileRowId))).write(
      SkyTilesCompanion(regionId: Value(regionId)),
    );
  }

  // Folds (the time-scrub timeline)

  /// Append a fold record to the timeline, returning its row id.
  ///
  /// One row per fold of one tile; never updated after insert, so the timeline
  /// is an immutable record of how a tile (and its region) deepened over time.
  Future<int> recordFold({
    required int tileId,
    int healpixOrder = skyAtlasHealpixOrder,
    int? sessionId,
    required int framesAdded,
    required double weightAdded,
    required double integrationSecondsAdded,
    int rejected = 0,
    String contributor = '',
    required String label,
    DateTime? foldedAt,
  }) {
    return into(skyAtlasFolds).insert(
      SkyAtlasFoldsCompanion.insert(
        tileId: tileId,
        healpixOrder: healpixOrder,
        sessionId: Value(sessionId),
        framesAdded: framesAdded,
        weightAdded: weightAdded,
        integrationSecondsAdded: integrationSecondsAdded,
        rejected: Value(rejected),
        contributor: Value(contributor),
        label: label,
        foldedAt: foldedAt == null ? const Value.absent() : Value(foldedAt),
      ),
    );
  }

  /// The fold timeline for a single tile, oldest first — replays how that one
  /// pixel deepened over time.
  Future<List<SkyAtlasFoldRow>> listFoldsForTileOverTime(
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
  }) {
    return (select(skyAtlasFolds)
          ..where(
            (f) =>
                f.tileId.equals(tileId) & f.healpixOrder.equals(healpixOrder),
          )
          ..orderBy([
            (f) => OrderingTerm.asc(f.foldedAt),
            (f) => OrderingTerm.asc(f.id),
          ]))
        .get();
  }

  /// The fold timeline for every tile in [regionId], oldest first — the backing
  /// query for "scrub a region across time".
  ///
  /// Joins folds to the region's tiles on `(tileId, healpixOrder)` so a fold is
  /// only included when its pixel currently belongs to the region. Ordered by
  /// fold time (then id) so a UI scrubber walks the region's contributions in
  /// the exact order they happened.
  Future<List<SkyAtlasFoldRow>> listFoldsForRegionOverTime(int regionId) {
    final query =
        select(skyAtlasFolds).join([
            innerJoin(
              skyTiles,
              skyTiles.tileId.equalsExp(skyAtlasFolds.tileId) &
                  skyTiles.healpixOrder.equalsExp(skyAtlasFolds.healpixOrder),
            ),
          ])
          ..where(skyTiles.regionId.equals(regionId))
          ..orderBy([
            OrderingTerm.asc(skyAtlasFolds.foldedAt),
            OrderingTerm.asc(skyAtlasFolds.id),
          ]);
    return query.map((row) => row.readTable(skyAtlasFolds)).get();
  }

  /// Reactive variant of [listFoldsForRegionOverTime] for a live scrubber.
  Stream<List<SkyAtlasFoldRow>> watchFoldsForRegionOverTime(int regionId) {
    final query =
        select(skyAtlasFolds).join([
            innerJoin(
              skyTiles,
              skyTiles.tileId.equalsExp(skyAtlasFolds.tileId) &
                  skyTiles.healpixOrder.equalsExp(skyAtlasFolds.healpixOrder),
            ),
          ])
          ..where(skyTiles.regionId.equals(regionId))
          ..orderBy([
            OrderingTerm.asc(skyAtlasFolds.foldedAt),
            OrderingTerm.asc(skyAtlasFolds.id),
          ]);
    return query.watch().map(
      (rows) => rows
          .map((row) => row.readTable(skyAtlasFolds))
          .toList(growable: false),
    );
  }

  /// All folds contributed by [sessionId], oldest first.
  Future<List<SkyAtlasFoldRow>> listFoldsForSession(int sessionId) {
    return (select(skyAtlasFolds)
          ..where((f) => f.sessionId.equals(sessionId))
          ..orderBy([
            (f) => OrderingTerm.asc(f.foldedAt),
            (f) => OrderingTerm.asc(f.id),
          ]))
        .get();
  }

  /// Great-circle (angular) separation in degrees between two sky points.
  /// Uses the haversine form so it stays well-conditioned for the small
  /// separations region cones are typically queried at.
  static double _angularSeparationDeg(
    double ra1Deg,
    double dec1Deg,
    double ra2Deg,
    double dec2Deg,
  ) {
    const deg2rad = math.pi / 180.0;
    final dec1 = dec1Deg * deg2rad;
    final dec2 = dec2Deg * deg2rad;
    final dDec = (dec2Deg - dec1Deg) * deg2rad;
    final dRa = (ra2Deg - ra1Deg) * deg2rad;
    final sinDDec = math.sin(dDec / 2.0);
    final sinDRa = math.sin(dRa / 2.0);
    final a =
        sinDDec * sinDDec + math.cos(dec1) * math.cos(dec2) * sinDRa * sinDRa;
    final c = 2.0 * math.asin(math.min(1.0, math.sqrt(a)));
    return c / deg2rad;
  }
}

/// Riverpod provider for [SkyAtlasDao].
final skyAtlasDaoProvider = Provider<SkyAtlasDao>((ref) {
  return SkyAtlasDao(ref.watch(databaseProvider));
});
