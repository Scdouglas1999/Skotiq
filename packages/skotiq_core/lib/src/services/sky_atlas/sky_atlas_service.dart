import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../database/daos/sky_atlas_dao.dart';
import '../../database/database.dart';
import '../../database/tables/sky_atlas_tables.dart' show skyAtlasHealpixOrder;
import '../logging_service.dart';
import '../wcs/gnomonic_projection.dart';
import 'sky_atlas_models.dart';
import 'sky_atlas_seam.dart';
import '../../utils/skotiq_data_directory.dart';
part 'sky_atlas_service/atlas_models.dart';
part 'sky_atlas_service/internals.dart';

/// Orchestrates Pillar A ("Your Sky") — the personal sky atlas.
///
/// Folds plate-solved light frames into the fixed HEALPix tiling via the native
/// `api_sky_atlas` surface ([SkyAtlasSeam]) and mirrors every fold into the
/// Drift atlas tables ([SkyAtlasDao]): one [SkyTiles] row per touched tile
/// (running totals + sidecar pointer) and one [SkyAtlasFolds] row per fold (the
/// time-scrub timeline). Region grouping, coverage, growth, and shareable
/// cutouts are read straight back through the same seam.
///
/// The atlas state itself lives entirely on disk under [atlasRoot] (one `.nst`
/// accumulator per tile); the DB rows are the cheap index the UI renders from.
class SkyAtlasService {
  SkyAtlasService({
    required SkyAtlasDao dao,
    required SkyAtlasSeam seam,
    required LoggingService logger,
    required Future<String> Function() atlasRootResolver,
    Future<AtlasTargetRef?> Function(int targetId)? targetResolver,
    int order = skyAtlasHealpixOrder,
  }) : _dao = dao,
       _seam = seam,
       _logger = logger,
       _atlasRootResolver = atlasRootResolver,
       _targetResolver = targetResolver,
       _order = order;

  final SkyAtlasDao _dao;
  final SkyAtlasSeam _seam;
  final LoggingService _logger;
  final Future<String> Function() _atlasRootResolver;

  /// Resolves a target id to its name + sky coordinates so an auto-fold of a
  /// captured image can attach (and name) a region without the core package
  /// depending on the Targets DAO. Wired in `skyAtlasServiceProvider`; null on a
  /// slave (which never folds), so auto-region-creation is silently skipped.
  final Future<AtlasTargetRef?> Function(int targetId)? _targetResolver;

  final int _order;

  static const _logSource = 'SkyAtlasService';

  String? _cachedAtlasRoot;

  /// Serializes every writer that touches a base/overlay `.nst` sidecar so two
  /// folds (or a fold and a swarm merge) never interleave on the same tile file.
  /// In-process is sufficient: the host is the single atlas authority — remote
  /// companions mirror but do not fold.
  Future<void> _foldChain = Future<void>.value();

  /// Run [body] after the prior queued sidecar writer completes, restoring the
  /// chain even when [body] throws so one failed fold cannot wedge the queue.
  Future<T> _serialized<T>(Future<T> Function() body) {
    final prior = _foldChain;
    final completer = Completer<void>();
    _foldChain = completer.future;
    return prior.then((_) => body()).whenComplete(completer.complete);
  }

  /// The on-disk atlas root, resolved (and the directory created) lazily once.
  Future<String> atlasRoot() async {
    final cached = _cachedAtlasRoot;
    if (cached != null) return cached;
    final root = await _atlasRootResolver();
    _cachedAtlasRoot = root;
    return root;
  }

  /// Fold a session's solved frames into the atlas and persist the result.
  ///
  /// Invertible-WCS frames are sent to the native fold in one batch; the
  /// per-tile post-fold state the bridge returns is upserted into [SkyTiles] and
  /// a [SkyAtlasFolds] timeline row is appended per touched tile. Frames with a
  /// degenerate WCS are dropped before the call (the native side would reject
  /// the whole batch otherwise) and noted in the log. Returns the decoded
  /// summary; an empty frame list short-circuits to [AtlasFoldSummary.empty].
  Future<AtlasFoldSummary> foldSession({
    required int sessionId,
    required List<SolvedFrameRef> frames,
    AtlasInterp interp = AtlasInterp.lanczos3,
    String label = '',
    String contributor = '',
    int? targetId,
    String? regionName,
    double? targetRaDeg,
    double? targetDecDeg,
    double regionRadiusDeg = 0.25,
  }) async {
    final usable = frames.where((f) => f.hasInvertibleWcs).toList();
    final dropped = frames.length - usable.length;
    if (dropped > 0) {
      _logger.warning(
        'foldSession($sessionId): dropped $dropped '
        'frame${dropped == 1 ? '' : 's'} with a '
        'degenerate WCS before folding.',
        source: _logSource,
      );
    }
    if (usable.isEmpty) {
      return AtlasFoldSummary.empty;
    }

    final root = await atlasRoot();
    final foldLabel = label.trim().isEmpty
        ? DateTime.now().toUtc().toIso8601String()
        : label.trim();

    final args = <String, dynamic>{
      'action': 'fold',
      'atlasRoot': root,
      'order': _order,
      'contributor': contributor,
      'interp': interp.wire,
      'label': foldLabel,
      'frames': usable.map((f) => f.toFoldFrameJson()).toList(),
    };

    final summary = await _serialized(() async {
      final result = await _seam.dispatch(args);
      final folded = AtlasFoldSummary.fromJson(result);
      await _persistFold(
        summary: folded,
        sessionId: sessionId,
        label: foldLabel,
        contributor: contributor,
        root: root,
        targetId: targetId,
        regionName: regionName,
        targetRaDeg: targetRaDeg,
        targetDecDeg: targetDecDeg,
        regionRadiusDeg: regionRadiusDeg,
      );
      return folded;
    });

    _logger.info(
      'foldSession($sessionId): folded ${summary.totalFramesFolded} '
      'frame${summary.totalFramesFolded == 1 ? '' : 's'} across '
      '${summary.tilesTouched.length} '
      'tile${summary.tilesTouched.length == 1 ? '' : 's'}; '
      '${summary.framesSkippedNoCoverage} off-sky.',
      source: _logSource,
    );
    return summary;
  }

  /// Fold a single solved frame — the per-capture hook the imaging/live-stacking
  /// path calls as each light is solved. Thin wrapper over [foldSession].
  Future<AtlasFoldSummary> foldFrame({
    required int? sessionId,
    required SolvedFrameRef frame,
    AtlasInterp interp = AtlasInterp.lanczos3,
    String label = '',
    String contributor = '',
    int? targetId,
    String? regionName,
    double? targetRaDeg,
    double? targetDecDeg,
    double regionRadiusDeg = 0.25,
  }) {
    return foldSession(
      sessionId: sessionId ?? 0,
      frames: [frame],
      interp: interp,
      label: label,
      contributor: contributor,
      targetId: targetId,
      regionName: regionName,
      targetRaDeg: targetRaDeg,
      targetDecDeg: targetDecDeg,
      regionRadiusDeg: regionRadiusDeg,
    );
  }

  /// Fold an already-persisted, plate-solved captured-image row into the atlas.
  ///
  /// This is the auto-fold entry point the solve-persist hook calls: it gates on
  /// the row being a light frame with a usable solve, builds the [SolvedFrameRef]
  /// from the stored WCS (CD matrix + SIP when present, else scale+rotation), and
  /// folds it under the image's session label. Returns null (folding nothing)
  /// when the row is not a foldable light or lacks an invertible WCS — never
  /// throws for those expected cases. [imageWidth]/[imageHeight] are the frame's
  /// pixel dimensions (the FITS dims), needed for the reference pixel.
  Future<AtlasFoldSummary?> autoFoldCapturedImage({
    required CapturedImage image,
    required int imageWidth,
    required int imageHeight,
    SolvedWcsDistortion distortion = const SolvedWcsDistortion(),
    AtlasInterp interp = AtlasInterp.lanczos3,
  }) async {
    if (image.frameType.toLowerCase() != 'light') return null;
    if (!image.isPlateSolved ||
        image.solvedRa == null ||
        image.solvedDec == null) {
      return null;
    }
    if (image.filePath.trim().isEmpty) return null;
    if (imageWidth <= 0 || imageHeight <= 0) return null;

    final solvedWcs = SolvedWcs(
      raHours: image.solvedRa!,
      decDegrees: image.solvedDec!,
      rotationDeg: image.solvedRotation ?? 0.0,
      pixelScaleArcsec: image.solvedPixelScale ?? 0.0,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      cd1_1: distortion.cd1_1,
      cd1_2: distortion.cd1_2,
      cd2_1: distortion.cd2_1,
      cd2_2: distortion.cd2_2,
      aOrder: distortion.aOrder,
      bOrder: distortion.bOrder,
      aCoeffs: distortion.aCoeffs,
      bCoeffs: distortion.bCoeffs,
      apOrder: distortion.apOrder,
      bpOrder: distortion.bpOrder,
      apCoeffs: distortion.apCoeffs,
      bpCoeffs: distortion.bpCoeffs,
    );
    // A solve with neither a CD matrix nor a positive pixel scale cannot yield
    // an invertible geometry; skip rather than feeding the native fold garbage.
    if (!solvedWcs.hasCdMatrix && solvedWcs.pixelScaleArcsec <= 0) return null;

    final frame = SolvedFrameRef.fromSolvedWcs(
      framePath: image.filePath,
      wcs: solvedWcs,
      exposureSec: image.exposureDuration,
    );
    if (!frame.hasInvertibleWcs) return null;

    // Region attach (Pillar A reachability): a captured-image solve carries a
    // [targetId], so resolve the target's name + sky coordinates and pass them
    // through so `_persistFold` ensures/updates ONE region for the target and
    // links every touched tile to it — making the whole region UX reachable
    // without any manual step. The resolver is host-only (null on a slave, which
    // never folds), and a resolve failure degrades to a plain fold.
    int? regionTargetId;
    String? regionName;
    double? regionRaDeg;
    double? regionDecDeg;
    if (image.targetId != null && _targetResolver != null) {
      try {
        final ref = await _targetResolver(image.targetId!);
        if (ref != null && ref.name.trim().isNotEmpty) {
          regionTargetId = image.targetId;
          regionName = ref.name.trim();
          regionRaDeg = ref.raDeg;
          regionDecDeg = ref.decDeg;
        }
      } catch (e) {
        _logger.warning(
          'autoFoldCapturedImage: target resolve failed for '
          'targetId=${image.targetId} ($e); folding without a region.',
          source: _logSource,
        );
      }
    }
    // Region radius: half the frame's diagonal field of view, floored at 0.25°
    // so a single sub still describes a sensible cone.
    final widthDeg = imageWidth * solvedWcs.pixelScaleArcsec / 3600.0;
    final heightDeg = imageHeight * solvedWcs.pixelScaleArcsec / 3600.0;
    final diagDeg = math.sqrt(widthDeg * widthDeg + heightDeg * heightDeg);
    final regionRadiusDeg = math.max(diagDeg / 2.0, 0.25);

    return foldSession(
      sessionId: image.sessionId ?? 0,
      frames: [frame],
      interp: interp,
      label: _foldLabelFor(image),
      targetId: regionTargetId,
      regionName: regionName,
      targetRaDeg: regionRaDeg,
      targetDecDeg: regionDecDeg,
      regionRadiusDeg: regionRadiusDeg,
    );
  }

  /// Render a finalized tile to a PNG under the atlas cache and return its path.
  /// [asOf] requests a time-scrubbed render (only honoured by the native side
  /// when every fold is at/before the anchor; otherwise it raises).
  Future<String> finalizeTilePng(int tileId, {DateTime? asOf}) async {
    final root = await atlasRoot();
    final outPath = p.join(_cacheDir(root), 'tile_$tileId.png');
    final args = <String, dynamic>{
      'action': 'tilePng',
      'atlasRoot': root,
      'order': _order,
      'tileId': tileId,
      'outPath': outPath,
      if (asOf != null) 'asOfIso': asOf.toUtc().toIso8601String(),
    };
    final result = await _seam.dispatch(args);
    return result['outPath'] as String? ?? outPath;
  }

  /// Co-add a cone of the atlas into a shareable cutout (FITS + PNG) and return
  /// the result map (`fitsPath`, `pngPath`, coverage stats). The cutout is
  /// written under the atlas cache, keyed by the cone geometry.
  Future<Map<String, dynamic>> cutout({
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    int channels = 1,
    int outPixels = 2048,
    AtlasInterp interp = AtlasInterp.lanczos3,
    bool withPng = true,
    bool includeSwarm = false,
  }) async {
    final root = await atlasRoot();
    final stem =
        'cutout_${centerRaDeg.toStringAsFixed(3)}_'
        '${centerDecDeg.toStringAsFixed(3)}_${radiusDeg.toStringAsFixed(3)}';
    final fitsPath = p.join(_cacheDir(root), '$stem.fits');
    final pngPath = p.join(_cacheDir(root), '$stem.png');
    final args = <String, dynamic>{
      'atlasRoot': root,
      'order': _order,
      'centerRa': centerRaDeg,
      'centerDec': centerDecDeg,
      'radiusDeg': radiusDeg,
      'channels': channels,
      'outPixels': outPixels,
      'interp': interp.wire,
      'fitsPath': fitsPath,
      if (withPng) 'pngPath': pngPath,
      // VIEW co-add: composite the swarm overlay on top of own-light for DISPLAY
      // only. Never set by the contribute/export path — exportDelta never reads
      // the overlay tree at all, so a community photon cannot leak into a push.
      'includeOverlay': includeSwarm,
    };
    return _seam.queryCutout(args);
  }

  /// Per-tile coverage rows for the heat overlay / gallery, deepest first —
  /// served from the [SkyTiles] DB index instead of scanning the on-disk `.nst`
  /// sidecars.
  ///
  /// Every scalar the heat overlay / contribution bar reads
  /// (`coverageMean`/`totalFrames`/`integrationSeconds`/`channels`/centre) is
  /// mirrored into the [SkyTiles] index row on each fold, so this indexed read
  /// returns the SAME numbers as the native [coverage] full-scan while opening
  /// zero sidecars. The rows are already ordered deepest-first by the DAO
  /// ([SkyAtlasDao.getAllTiles]), matching [coverage]'s sort.
  ///
  /// `lastFoldIso` is taken from the indexed `lastFoldAt` timestamp (the native
  /// path surfaces the last fold's free-text label instead); both are display
  /// hints only and never feed a computation.
  ///
  /// [includeSwarm] is accepted for call-site parity with [coverage] but, like
  /// the native coverage scan (whose `CoverageArgs` ignores the overlay flag),
  /// has no effect: coverage always reports own-light depth. The swarm overlay
  /// composites only into the per-pixel cutout/tilePng render path.
  Future<List<AtlasTileCoverage>> coverageFromIndex({
    bool includeSwarm = false,
  }) async {
    final rows = await _dao.getAllTiles();
    return rows
        .map(
          (t) => AtlasTileCoverage(
            tileId: t.tileId,
            centerRaDeg: t.centerRaDeg,
            centerDecDeg: t.centerDecDeg,
            coverageMean: t.coverageMean,
            totalFrames: t.totalFrames,
            integrationSeconds: t.integrationSeconds,
            lastFoldIso: t.lastFoldAt?.toUtc().toIso8601String(),
            channels: t.channels,
          ),
        )
        .toList(growable: false);
  }

  /// Local atlas tiles whose centre falls within [radiusDeg] of the cone centre
  /// — the spatial selector behind Constellation Contribute / Pull and Your-Sky
  /// cone reads.
  ///
  /// Reads the [SkyTiles] DB index so the cost scales with the cone, not the
  /// atlas: a Dec-band range scan on `idx_sky_tiles_dec`
  /// ([SkyAtlasDao.getTilesInDecBand], band `centerDec ± radius` clamped to
  /// `[-90, 90]`) narrows to a small candidate set, then the exact great-circle
  /// test runs on those candidates. The SQL band cannot be the final answer —
  /// RA wrap and the cap's RA widening near the poles make a pure-SQL cone
  /// unsafe.
  ///
  /// When the DB index has no tiles in the band (a wiring that has only ever
  /// folded through the native seam, or a brand-new atlas) it falls back to the
  /// [coverage] scan rather than selecting nothing.
  Future<List<AtlasTileCoverage>> tilesInCone({
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
  }) async {
    final minDec = math.max(-90.0, centerDecDeg - radiusDeg);
    final maxDec = math.min(90.0, centerDecDeg + radiusDeg);
    final band = await _dao.getTilesInDecBand(minDec, maxDec);
    final candidates = band.isNotEmpty
        ? band.map(_coverageFromTileRow).toList(growable: false)
        : await coverage();
    return candidates
        .where(
          (t) =>
              _coneSeparationDeg(
                centerRaDeg,
                centerDecDeg,
                t.centerRaDeg,
                t.centerDecDeg,
              ) <=
              radiusDeg,
        )
        .toList(growable: false);
  }

  /// Adapt a [SkyTileRow] (DB index) into the [AtlasTileCoverage] shape the cone
  /// callers already consume, so the index-backed path is a drop-in for the
  /// native-scan result.
  static AtlasTileCoverage _coverageFromTileRow(SkyTileRow row) =>
      AtlasTileCoverage(
        tileId: row.tileId,
        centerRaDeg: row.centerRaDeg,
        centerDecDeg: row.centerDecDeg,
        coverageMean: row.coverageMean,
        totalFrames: row.totalFrames,
        integrationSeconds: row.integrationSeconds,
        lastFoldIso: row.lastFoldAt?.toUtc().toIso8601String(),
        channels: row.channels,
      );

  /// Great-circle separation (deg) via the haversine formula — robust at the
  /// small angles cone selection queries at.
  static double _coneSeparationDeg(
    double ra1Deg,
    double dec1Deg,
    double ra2Deg,
    double dec2Deg,
  ) {
    const deg2rad = math.pi / 180.0;
    final dRa = (ra2Deg - ra1Deg) * deg2rad;
    final dDec = (dec2Deg - dec1Deg) * deg2rad;
    final lat1 = dec1Deg * deg2rad;
    final lat2 = dec2Deg * deg2rad;
    final a =
        math.sin(dDec / 2) * math.sin(dDec / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dRa / 2) * math.sin(dRa / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return c / deg2rad;
  }

  /// Per-tile coverage rows for the heat overlay / gallery, deepest first, by
  /// the native full-scan of the on-disk `.nst` sidecars.
  ///
  /// Prefer [coverageFromIndex] for the hot heat-overlay/contribution poll: it
  /// returns the same scalars from the [SkyTiles] index without any sidecar I/O.
  /// This native path is retained for callers that genuinely need a
  /// disk-of-record read (e.g. a sidecar/DB consistency check).
  ///
  /// [includeSwarm] composites the pulled community overlay depth for DISPLAY
  /// only (threaded as `includeOverlay`); it never affects the export path.
  Future<List<AtlasTileCoverage>> coverage({bool includeSwarm = false}) async {
    final root = await atlasRoot();
    final result = await _seam.dispatch({
      'action': 'coverage',
      'atlasRoot': root,
      'order': _order,
      'includeOverlay': includeSwarm,
    });
    final tiles =
        (result['tiles'] as List? ?? const [])
            .map((e) => AtlasTileCoverage.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort(
            (a, b) => b.integrationSeconds.compareTo(a.integrationSeconds),
          );
    return tiles;
  }

  /// Provenance for one tile (contributors + fold log).
  Future<TileProvenanceView> tileInfo(int tileId) async {
    final root = await atlasRoot();
    final result = await _seam.dispatch({
      'action': 'info',
      'atlasRoot': root,
      'order': _order,
      'tileId': tileId,
    });
    return TileProvenanceView.fromJson(tileId, result);
  }

  /// Export the accumulator state for the LOCAL folds since [since] to a `.nst`
  /// delta under the atlas cache (the federation contribution payload).
  ///
  /// Returns the delta path together with the post-anchor own-light tally the
  /// native side carved out ([AtlasDeltaExport.framesInDelta] /
  /// [AtlasDeltaExport.integrationSeconds]) — these are the TRUE delta the
  /// high-water contribute flow ships, never the whole accumulator and never
  /// pulled (foreign) community depth. The native side rejects a tile that mixes
  /// pre-anchor own folds with new own folds (an inseparable pixel-exact delta).
  Future<AtlasDeltaExport> exportDelta(
    int tileId, {
    required DateTime since,
  }) async {
    final root = await atlasRoot();
    final outPath = p.join(_cacheDir(root), 'delta_$tileId.nst');
    final result = await _seam.dispatch({
      'action': 'exportDelta',
      'atlasRoot': root,
      'order': _order,
      'tileId': tileId,
      'sinceIso': since.toUtc().toIso8601String(),
      'outPath': outPath,
    });
    return AtlasDeltaExport(
      path: result['outPath'] as String? ?? outPath,
      framesInDelta: (result['framesInDelta'] as num?)?.toInt() ?? 0,
      integrationSeconds:
          (result['integrationSeconds'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// The deepening growth curve for a region cone (raw bridge result map).
  Future<Map<String, dynamic>> growth({
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
  }) async {
    final root = await atlasRoot();
    return _seam.growth({
      'atlasRoot': root,
      'order': _order,
      'centerRa': centerRaDeg,
      'centerDec': centerDecDeg,
      'radiusDeg': radiusDeg,
    });
  }

  /// Native coverage summary for a region cone (raw bridge result map).
  Future<Map<String, dynamic>> regionCoverage({
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
  }) async {
    final root = await atlasRoot();
    return _seam.regionInfo({
      'atlasRoot': root,
      'order': _order,
      'centerRa': centerRaDeg,
      'centerDec': centerDecDeg,
      'radiusDeg': radiusDeg,
    });
  }

  // Regions

  /// All persisted regions (newest first).
  Future<List<SkyAtlasRegionRow>> regions() => _dao.getAllRegions();

  /// One region by row id (null when absent).
  Future<SkyAtlasRegionRow?> getRegion(int id) => _dao.getRegion(id);

  /// The tightest region whose cone covers the given sky point (null when none).
  /// Backs the Constellation "open this deepened field in Your Sky" deep link
  /// after a Pull & Blend. RA/Dec in degrees.
  Future<SkyAtlasRegionRow?> getRegionForPoint(double raDeg, double decDeg) =>
      _dao.getRegionForPoint(raDeg, decDeg);

  /// The tiles belonging to a region, deepest first (host-local read; the slave
  /// reads the same rows off the region-detail wire payload).
  Future<List<SkyTileRow>> tilesForRegion(int regionId) =>
      _dao.getTilesForRegion(regionId);

  /// Co-add a region's cone into a shareable cutout and return its on-disk
  /// paths — the host-side seam behind the RegionDetail "Export / Use as
  /// reference frame" affordance. The PNG path backs Share/Export; the FITS path
  /// is the photometric co-add a follow-up session can stack against as a
  /// reference frame ([LiveStackingService.startFromFile]). Returns null when
  /// the region is unknown or the engine produced no co-add (e.g. zero folds).
  Future<RegionCutoutExport?> exportRegionCutout(int regionId) async {
    final region = await _dao.getRegion(regionId);
    if (region == null) return null;
    final result = await cutout(
      centerRaDeg: region.centerRaDeg,
      centerDecDeg: region.centerDecDeg,
      radiusDeg: region.radiusDeg,
    );
    final fitsPath = (result['fitsPath'] as String?)?.trim();
    final pngPath = (result['pngPath'] as String?)?.trim();
    if (fitsPath == null || fitsPath.isEmpty) return null;
    return RegionCutoutExport(
      regionName: region.name,
      fitsPath: fitsPath,
      pngPath: (pngPath == null || pngPath.isEmpty) ? null : pngPath,
    );
  }

  /// Reactive region list for the atlas browser.
  Stream<List<SkyAtlasRegionRow>> watchRegions() => _dao.watchAllRegions();

  /// Insert-or-update a named region and refresh its denormalized rollups.
  /// Returns the region row id.
  Future<int> ensureRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    String kind = 'custom',
    int? targetId,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Region name cannot be empty');
    }
    if (!centerRaDeg.isFinite || centerRaDeg < 0 || centerRaDeg > 360) {
      throw RangeError.range(centerRaDeg, 0, 360, 'centerRaDeg');
    }
    if (!centerDecDeg.isFinite || centerDecDeg < -90 || centerDecDeg > 90) {
      throw RangeError.range(centerDecDeg, -90, 90, 'centerDecDeg');
    }
    if (!radiusDeg.isFinite || radiusDeg <= 0 || radiusDeg > 180) {
      throw RangeError.range(radiusDeg, 0, 180, 'radiusDeg');
    }
    if (targetId != null && targetId <= 0) {
      throw RangeError.value(targetId, 'targetId', 'Must be positive');
    }
    final id = await _dao.upsertRegion(
      name: normalizedName,
      kind: kind,
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      radiusDeg: radiusDeg,
      targetId: targetId,
    );
    await _dao.refreshRegionRollups(id);
    return id;
  }

  /// The fold timeline for a region, oldest first — backs the time scrubber.
  Future<List<SkyAtlasFoldRow>> regionTimeline(int regionId) =>
      _dao.listFoldsForRegionOverTime(regionId);

  /// Reactive region timeline for a live scrubber.
  Stream<List<SkyAtlasFoldRow>> watchRegionTimeline(int regionId) =>
      _dao.watchFoldsForRegionOverTime(regionId);

  // Internals

  /// Blend a pulled community `.nst` accumulator into the swarm OVERLAY tree so
  /// its depth can surface in "Your Sky" — without ever touching the user's
  /// contributable base tile.
  ///
  /// The overlay is a SEPARATE sidecar tree (`swarm_overlay/<order>/<tileId>.nst`)
  /// that [exportDelta] never reads, so pulled community photons can never be
  /// re-shipped as the user's own contribution. Each pull is a fresh full-tile
  /// community snapshot, so the merge is REPLACE-not-add: the existing overlay
  /// sidecar is removed first and the snapshot merged into an empty accumulator,
  /// leaving the overlay equal to exactly one copy of the current community
  /// depth (N pulls == 1 pull). The base [SkyTiles] index row keeps its
  /// own-light `totalFrames`/`integrationSeconds`; the blended community depth is
  /// written to the dedicated overlay columns so the contribution bar stays
  /// honest after a pull.
  ///
  /// Returns the overlay's (community) frame total for the tile.
  Future<int> mergeSwarmDelta({
    required int tileId,
    required String deltaPath,
    double trust = 1.0,
  }) {
    return _serialized(() async {
      final root = await atlasRoot();
      final basePath = p.join(_tilesDir(root), '$tileId.nst');
      final overlayPath = p.join(_overlayDir(root), '$tileId.nst');

      // REPLACE-not-add: drop any prior overlay so the merge folds the freshly
      // pulled community snapshot into a zeroed accumulator — the overlay always
      // equals exactly one copy of the current community depth.
      final overlayFile = File(overlayPath);
      if (overlayFile.existsSync()) {
        try {
          overlayFile.deleteSync();
        } on FileSystemException catch (e) {
          _logger.warning(
            'mergeSwarmDelta(tile $tileId): could not clear prior overlay '
            '($e); blend may double-count this pull.',
            source: _logSource,
          );
        }
      }

      final result = await _seam.mergeDelta({
        'basePath': overlayPath,
        'deltaPath': deltaPath,
        'trust': trust,
        'subtract': false,
        'outPath': overlayPath,
      });
      final overlayFrames = (result['totalFramesAfter'] as num?)?.toInt() ?? 0;
      final overlaySeconds =
          (result['integrationSecondsAfter'] as num?)?.toDouble() ?? 0.0;
      final contributors = (result['contributorsAfter'] as num?)?.toInt() ?? 0;

      // Refresh ONLY the overlay columns on the base index row; own-light
      // totals + the base sidecar pointer are preserved. If the user has never
      // imaged this tile there is no base row yet, so we seed one from the
      // overlay's geometry (centre/channels via tileInfo on the overlay), but
      // still with zero own-light totals.
      try {
        final existing = await _dao.getTile(tileId, healpixOrder: _order);
        if (existing != null) {
          await _dao.upsertTile(
            tileId: tileId,
            healpixOrder: _order,
            channels: existing.channels,
            centerRaDeg: existing.centerRaDeg,
            centerDecDeg: existing.centerDecDeg,
            coverageMean: existing.coverageMean,
            totalFrames: existing.totalFrames,
            integrationSeconds: existing.integrationSeconds,
            sidecarPath: existing.sidecarPath,
            lastFoldSessionId: existing.lastFoldSessionId,
            lastFoldAt: existing.lastFoldAt,
            regionId: existing.regionId,
            swarmOverlayFrames: overlayFrames,
            swarmOverlayIntegrationSeconds: overlaySeconds,
          );
        } else {
          final info = await _overlayTileInfo(tileId);
          await _dao.upsertTile(
            tileId: tileId,
            healpixOrder: _order,
            channels: info.channels,
            centerRaDeg: info.centerRaDeg,
            centerDecDeg: info.centerDecDeg,
            coverageMean: info.coverageMean,
            // No own-light yet — keep base totals at zero so the contribution
            // bar reads "nothing to contribute" until the user images here.
            totalFrames: 0,
            integrationSeconds: 0,
            sidecarPath: basePath,
            lastFoldSessionId: null,
            lastFoldAt: null,
            swarmOverlayFrames: overlayFrames,
            swarmOverlayIntegrationSeconds: overlaySeconds,
          );
        }
      } catch (e) {
        _logger.warning(
          'mergeSwarmDelta(tile $tileId): overlay index refresh failed: $e '
          '(overlay persisted, $contributors '
          'contributor${contributors == 1 ? '' : 's'}).',
          source: _logSource,
        );
      }
      return overlayFrames;
    });
  }

  /// Default age budget for the cutout/delta cache sweep — a cutout the user
  /// browsed two weeks ago is cheap to regenerate on demand from the durable
  /// `.nst` accumulators, so it need not occupy disk indefinitely.
  static const _defaultCacheMaxAge = Duration(days: 14);

  /// Reclaim the cutout/delta cache (`<atlasRoot>/cache`). Unlike the durable
  /// tile accumulators, everything here is a derived artefact the engine can
  /// rebuild on demand: `tile_<id>.png` renders, `cutout_*.fits`/`.png`
  /// co-adds, and spent `delta_<id>.nst` federation payloads. Left unmanaged it
  /// grows without bound (a 2048² PNG+FITS pair per distinct region browse),
  /// silently filling a long-running host or a constrained appliance.
  ///
  /// Two-pass LRU mirroring the swarm-blob sweep: first evict anything older
  /// than [maxAge], then — if [maxBytes] is set and the survivors still overflow
  /// it — evict oldest-first by mtime until the working set fits. Returns the
  /// number of files reclaimed. Cheap to call on startup / the maintenance
  /// schedule; a vanished file mid-sweep is swallowed so one race cannot sink
  /// the pass.
  Future<int> sweepCache({
    Duration maxAge = _defaultCacheMaxAge,
    int? maxBytes,
  }) async {
    final root = await atlasRoot();
    final dir = Directory(_cacheDir(root));
    if (!dir.existsSync()) return 0;

    final now = DateTime.now();
    final cutoff = now.subtract(maxAge);

    final entries = <({File file, DateTime modified, int size})>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (ext != '.png' && ext != '.fits' && ext != '.nst') continue;
      final stat = await entity.stat();
      entries.add((file: entity, modified: stat.modified, size: stat.size));
    }

    var deleted = 0;
    var reclaimedBytes = 0;
    final survivors = <({File file, DateTime modified, int size})>[];

    for (final entry in entries) {
      if (entry.modified.isBefore(cutoff)) {
        if (await _deleteCacheFile(entry.file)) {
          deleted++;
          reclaimedBytes += entry.size;
        }
      } else {
        survivors.add(entry);
      }
    }

    if (maxBytes != null) {
      var remainingBytes = survivors.fold<int>(0, (s, e) => s + e.size);
      if (remainingBytes > maxBytes) {
        survivors.sort((a, b) => a.modified.compareTo(b.modified));
        for (final entry in survivors) {
          if (remainingBytes <= maxBytes) break;
          if (await _deleteCacheFile(entry.file)) {
            deleted++;
            reclaimedBytes += entry.size;
            remainingBytes -= entry.size;
          }
        }
      }
    }

    if (deleted > 0) {
      _logger.info(
        'sweepCache: reclaimed $deleted cache '
        'file${deleted == 1 ? '' : 's'} ($reclaimedBytes bytes).',
        source: _logSource,
      );
    }
    return deleted;
  }

  /// Delete a spent federation delta after a successful contribution upload, so
  /// the `delta_<tileId>.nst` payload does not linger in the cache until the
  /// next [sweepCache]. A vanished/locked file is swallowed (best-effort).
  Future<bool> deleteExportedDelta(int tileId) async {
    final root = await atlasRoot();
    return _deleteCacheFile(File(p.join(_cacheDir(root), 'delta_$tileId.nst')));
  }
}

/// Default atlas root: `<app support>/sky_atlas`. The native fold creates the
/// per-tile sidecar directories on demand, so we only need the root to exist.
Future<String> defaultAtlasRoot() async {
  final support = await resolveSkotiqDataDirectory();
  return p.join(support.path, 'sky_atlas');
}
