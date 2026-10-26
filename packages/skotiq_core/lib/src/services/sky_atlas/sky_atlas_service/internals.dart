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

  /// Mirror a native fold into the DB: one timeline row per (frame, tile)
  /// with that frame's own exposure, then each touched tile's index row with
  /// totals recounted from the timeline (distinct frames, each frame's exposure
  /// once) and its coverage depth advanced by what this fold added.
  Future<void> _persistFold({
    required AtlasFoldSummary summary,
    required List<_PendingFold> items,
    required String root,
  }) async {
    final foldedAt = DateTime.now();
    final tilesDir = _tilesDir(root);

    // Region attach: ensure ONE region per target (idempotent on targetId) so
    // nightly re-folds reuse it, before the tiles are linked to it.
    final regionByFrame = <int, int>{};
    for (var i = 0; i < items.length; i++) {
      final r = items[i].region;
      if (r.targetId == null ||
          r.name == null ||
          r.name!.trim().isEmpty ||
          r.raDeg == null ||
          r.decDeg == null) {
        continue;
      }
      regionByFrame[i] = await ensureRegion(
        name: r.name!.trim(),
        centerRaDeg: r.raDeg!,
        centerDecDeg: r.decDeg!,
        radiusDeg: math.max(r.radiusDeg, 0.25),
        kind: 'target',
        targetId: r.targetId,
      );
    }

    final frameFolds = summary.frameFolds.isNotEmpty
        ? summary.frameFolds
        : [
            // A bridge without per-frame records: one frame per call.
            for (final t in summary.tiles)
              if (t.framesAdded > 0)
                AtlasFrameTileFold(
                  frameIndex: 0,
                  label: items.first.label,
                  tileId: t.tileId,
                  weightAdded: t.weightAdded,
                  integrationSecondsAdded: t.integrationSecondsAdded > 0
                      ? t.integrationSecondsAdded
                      : items.first.frame.exposureSec,
                  coverageAdded: t.coverageAdded,
                  rejected: t.rejected,
                ),
          ];

    final regionByTile = <int, int>{};
    final sessionByTile = <int, int?>{};
    for (final f in frameFolds) {
      final item = items[f.frameIndex.clamp(0, items.length - 1)];
      final session = item.sessionId > 0 ? item.sessionId : null;
      sessionByTile[f.tileId] = session;
      final region = regionByFrame[f.frameIndex];
      if (region != null) regionByTile[f.tileId] = region;
      await _dao.recordFold(
        tileId: f.tileId,
        healpixOrder: _order,
        sessionId: session,
        framesAdded: 1,
        weightAdded: f.weightAdded,
        integrationSecondsAdded: f.integrationSecondsAdded,
        rejected: f.rejected,
        contributor: item.contributor,
        label: f.label.isEmpty ? item.label : f.label,
        foldedAt: foldedAt,
      );
    }

    for (final tile in summary.tiles) {
      if (tile.framesAdded <= 0) continue;
      final existing = await _dao.getTile(tile.tileId, healpixOrder: _order);
      final totals = await _dao.tileTotals(tile.tileId, healpixOrder: _order);
      await _dao.upsertTile(
        tileId: tile.tileId,
        healpixOrder: _order,
        channels: tile.channels,
        centerRaDeg: tile.centerRaDeg,
        centerDecDeg: tile.centerDecDeg,
        // Depth summed over filter layers; never below the folded layer's.
        coverageMean: math.max(
          (existing == null ? 0.0 : existing.coverageMean) + tile.coverageAdded,
          tile.coverageMean,
        ),
        totalFrames: totals.frames,
        integrationSeconds: totals.seconds,
        sidecarPath: p.join(tilesDir, '${tile.tileId}.skt'),
        lastFoldSessionId: sessionByTile[tile.tileId],
        lastFoldAt: foldedAt,
        regionId: regionByTile[tile.tileId],
      );
    }

    for (final regionId in regionByFrame.values.toSet()) {
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

/// Region a fold should ensure and link its tiles to (all fields set), or none.
class _RegionRequest {
  const _RegionRequest({
    this.targetId,
    this.name,
    this.raDeg,
    this.decDeg,
    this.radiusDeg = 0.25,
  });

  final int? targetId;
  final String? name;
  final double? raDeg;
  final double? decDeg;
  final double radiusDeg;
}

/// One frame waiting for (or inside) a native fold call.
class _PendingFold {
  _PendingFold({
    required this.frame,
    required this.sessionId,
    required this.layer,
    required this.region,
    required this.interp,
    required this.contributor,
  });

  final SolvedFrameRef frame;

  /// The frame's fold-log label (its capture time); every queued frame
  /// carries one.
  String get label => frame.label!;
  final int sessionId;
  final String? layer;
  final _RegionRequest region;
  final AtlasInterp interp;
  final String contributor;
  final Completer<AtlasFoldSummary?> completer = Completer<AtlasFoldSummary?>();
}
