part of '../sky_atlas_service.dart';

extension _SkyAtlasInternals on SkyAtlasService {
  /// A stable, sortable ISO date label for a captured image's fold, derived from
  /// its capture time (UTC) so the time-scrub timeline orders by acquisition.
  String _foldLabelFor(CapturedImage image) {
    return image.capturedAt.toUtc().toIso8601String();
  }

  /// Provenance for the overlay sidecar at [overlayPath] (geometry/coverage only,
  /// used to seed a base index row for a never-imaged-locally pulled tile).
  Future<TileProvenanceView> _overlayTileInfo(int tileId) async {
    final root = await atlasRoot();
    final result = await _seam.dispatch({
      'action': 'info',
      'atlasRoot': _overlayRoot(root),
      'order': _order,
      'tileId': tileId,
    });
    return TileProvenanceView.fromJson(tileId, result);
  }

  Future<void> _persistFold({
    required AtlasFoldSummary summary,
    required int sessionId,
    required String label,
    required String contributor,
    required String root,
    int? targetId,
    String? regionName,
    double? targetRaDeg,
    double? targetDecDeg,
    double regionRadiusDeg = 0.25,
  }) async {
    final foldedAt = DateTime.now();
    final tilesDir = _tilesDir(root);
    final linkedSession = sessionId > 0 ? sessionId : null;

    // Region attach (Pillar A): when this fold came from a known target, ensure
    // ONE region for it (idempotent on targetId — nightly re-folds reuse the
    // same region) BEFORE the per-tile loop, then link every touched tile to it
    // in the same upsert. ensureRegion refreshes rollups; we refresh once more
    // after the loop so the new tile membership is reflected.
    int? regionId;
    if (targetId != null &&
        regionName != null &&
        regionName.trim().isNotEmpty &&
        targetRaDeg != null &&
        targetDecDeg != null) {
      regionId = await ensureRegion(
        name: regionName.trim(),
        centerRaDeg: targetRaDeg,
        centerDecDeg: targetDecDeg,
        radiusDeg: math.max(regionRadiusDeg, 0.25),
        kind: 'target',
        targetId: targetId,
      );
    }

    for (final tile in summary.tiles) {
      // Phantom guard: a cone that overlaps a tile's footprint but contributes
      // no accepted frames (e.g. an over-coverage edge tile) reports framesAdded
      // == 0. Upserting it would seed an empty 0-frame SkyTiles row + a dangling
      // sidecarPath to a never-written `.nst`, and recordFold would inject a
      // "+0 frames" entry into the timeline. Skip those entirely.
      if (tile.framesAdded <= 0) continue;
      final sidecarPath = p.join(tilesDir, '${tile.tileId}.nst');
      await _dao.upsertTile(
        tileId: tile.tileId,
        healpixOrder: _order,
        channels: tile.channels,
        centerRaDeg: tile.centerRaDeg,
        centerDecDeg: tile.centerDecDeg,
        coverageMean: tile.coverageMean,
        totalFrames: tile.totalFrames,
        integrationSeconds: tile.integrationSeconds,
        sidecarPath: sidecarPath,
        lastFoldSessionId: linkedSession,
        lastFoldAt: foldedAt,
        regionId: regionId,
      );
      await _dao.recordFold(
        tileId: tile.tileId,
        healpixOrder: _order,
        sessionId: linkedSession,
        framesAdded: tile.framesAdded,
        weightAdded: tile.weightAdded,
        integrationSecondsAdded: _integrationDeltaFor(tile),
        rejected: tile.rejected,
        contributor: contributor,
        label: label,
        foldedAt: foldedAt,
      );
    }

    // The tiles just gained this region's id; recompute the denormalized
    // tileCount / integrationSeconds rollups so the region card + detail render
    // the true depth immediately.
    if (regionId != null) {
      await _dao.refreshRegionRollups(regionId);
    }
  }

  /// Delete one cache file, swallowing the race where it vanished mid-sweep so
  /// one unlucky file cannot sink the whole pass. Returns whether it was removed.
  Future<bool> _deleteCacheFile(File file) async {
    try {
      if (!file.existsSync()) return false;
      await file.delete();
      return true;
    } on FileSystemException catch (e) {
      _logger.warning(
        'sweepCache: could not delete ${file.path}: ${e.message}',
        source: SkyAtlasService._logSource,
      );
      return false;
    }
  }

  /// Per-fold integration delta. The bridge's per-tile summary reports the
  /// post-fold cumulative `integrationSeconds`; the timeline wants the increment
  /// this fold added. We derive it from the prior tile total when available,
  /// falling back to the cumulative value for a tile's very first fold.
  double _integrationDeltaFor(AtlasFoldTile tile) {
    // The native running total includes this fold; for the first fold of a tile
    // that equals the increment. For subsequent folds we do not have the prior
    // total in the summary, so we attribute the proportional share by frame
    // count when frames are known, else the full cumulative (first-fold case).
    if (tile.totalFrames <= 0 || tile.framesAdded >= tile.totalFrames) {
      return tile.integrationSeconds;
    }
    final perFrame = tile.integrationSeconds / tile.totalFrames;
    return perFrame * tile.framesAdded;
  }

  String _tilesDir(String root) => p.join(root, 'tiles', '$_order');

  /// The swarm OVERLAY sidecar directory. A SEPARATE tree from the own-light
  /// base ([_tilesDir]) that [exportDelta] never reads, so pulled community
  /// depth can never re-upload as the user's contribution. It mirrors the base
  /// `tiles/<order>` layout under a `swarm_overlay` root so the native
  /// `open_atlas` read path (`info`) resolves an overlay sidecar when handed
  /// `<root>/swarm_overlay` as its atlas root.
  String _overlayDir(String root) =>
      p.join(_overlayRoot(root), 'tiles', '$_order');

  /// The atlas root the overlay tree presents to the native `open_atlas`.
  String _overlayRoot(String root) => p.join(root, 'swarm_overlay');

  String _cacheDir(String root) => p.join(root, 'cache');
}
