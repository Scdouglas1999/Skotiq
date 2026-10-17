import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for the Pillar A ("Your Sky") personal sky-atlas surface.
///
/// Exposes the atlas region list + per-region detail, a co-added cutout image,
/// and the per-region fold timeline so a [NetworkBackend] mobile companion can
/// browse the host's atlas over REST. Reads go through [SkyAtlasService] (region
/// rows from the Drift DAO; coverage / cutout from the native bridge) — the same
/// service the desktop UI uses, so the host stays the single source of truth.
class AtlasHandlers {
  final ProviderContainer container;

  /// Upper bound for the cutout `outPixels` (square edge). The native co-adder
  /// allocates three `out_pixels²` f64 accumulation buffers plus two f32
  /// outputs, with no internal cap. At 4096 this working set is already roughly
  /// 512 MiB before tile buffers and image encoding; larger values are not a
  /// safe preview/API contract.
  static const int _maxCutoutPixels = 4096;

  AtlasHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);
  SkyAtlasService get _service => container.read(skyAtlasServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'AtlasHandlers');

  // GET /api/atlas/regions

  Future<Response> handleGetRegions(Request request) async {
    _logInfo('[API] GET /api/atlas/regions');
    final regions = await _service.regions();
    return jsonOk({
      'regions': regions.map(_regionToJson).toList(),
      'count': regions.length,
    });
  }

  // POST /api/atlas/regions

  Future<Response> handleCreateRegion(Request request) async {
    _logInfo('[API] POST /api/atlas/regions');
    final payload = await readJsonObject(request);
    final name = requireString(payload, 'name', maxLength: 200).trim();
    if (name.isEmpty) {
      throw BadRequestError(
        field: 'name',
        expected: 'non-empty string',
        message: 'name cannot be empty',
      );
    }
    final centerRaDeg = requireDouble(payload, 'centerRaDeg', min: 0, max: 360);
    final centerDecDeg = requireDouble(
      payload,
      'centerDecDeg',
      min: -90,
      max: 90,
    );
    final radiusDeg = requireDouble(payload, 'radiusDeg', max: 180);
    if (radiusDeg <= 0) {
      throw BadRequestError(
        field: 'radiusDeg',
        expected: 'number in (0, 180]',
        message: 'radiusDeg must be greater than zero and at most 180',
      );
    }
    final kind = optionalString(payload, 'kind')?.trim() ?? 'custom';
    if (kind != 'custom' && kind != 'target') {
      throw BadRequestError(
        field: 'kind',
        expected: 'custom or target',
        message: 'kind must be "custom" or "target"',
      );
    }
    final targetId = optionalInt(payload, 'targetId', min: 1);
    if (kind == 'target' && targetId == null) {
      throw BadRequestError(
        field: 'targetId',
        expected: 'positive integer for a target region',
        message: 'targetId is required when kind is "target"',
      );
    }

    final id = await _service.ensureRegion(
      name: name,
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      radiusDeg: radiusDeg,
      kind: kind,
      targetId: targetId,
    );
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.atlas,
      action: HostMutationAction.created,
      entityId: id.toString(),
    );
    return jsonOk({'id': id});
  }

  // GET /api/atlas/coverage
  //
  // Per-tile coverage rows (deepest first), the heat-overlay / gallery data the
  // companion's "Your Sky" browser renders and the "your contribution" bar sums.
  // The native coverage query runs on the host, so a remote client reads it here
  // instead of its (empty) local atlas store.

  Future<Response> handleGetCoverage(Request request) async {
    _logInfo('[API] GET /api/atlas/coverage');
    // Served from the SkyTiles DB index (same scalars, no `.nst` sidecar scan)
    // so a companion's coverage poll never thrashes the host's disk.
    final tiles = await _service.coverageFromIndex();
    return jsonOk({
      'tiles': tiles.map(_coverageToJson).toList(),
      'count': tiles.length,
    });
  }

  // GET /api/atlas/region/<id>

  Future<Response> handleGetRegion(Request request, String id) async {
    _logInfo('[API] GET /api/atlas/region/$id');
    final resolved = await _resolveRegion(id);
    if (resolved.error != null) return resolved.error!;
    final regionId = resolved.regionId!;
    final region = resolved.region!;

    // Live native coverage for the region cone augments the denormalized DB
    // rollups so the companion sees the true integration depth without a
    // second round-trip.
    final coverage = await _service.regionCoverage(
      centerRaDeg: region.centerRaDeg,
      centerDecDeg: region.centerDecDeg,
      radiusDeg: region.radiusDeg,
    );

    // The region's tiles (deepest first) so the companion's detail screen can
    // pick a preview tile + render the depth/provenance rollups without a
    // per-tile route. Additive to the same response — the contract is unchanged.
    final tiles = await _service.tilesForRegion(regionId);

    return jsonOk({
      'region': _regionToJson(region),
      'coverage': coverage,
      'tiles': tiles.map(_tileToJson).toList(),
    });
  }

  // GET /api/atlas/region/<id>/cutout
  //
  // Returns the co-added PNG of the region cone as image bytes. Optional query
  // params: outPixels (default 2048), interp (bilinear|catmullRom|lanczos3).

  Future<Response> handleGetRegionCutout(Request request, String id) async {
    _logInfo('[API] GET /api/atlas/region/$id/cutout');

    // Validate outPixels BEFORE resolving the region or allocating the co-add.
    // Absent → 2048. A supplied value must be a positive whole number within the
    // safe native range; a garbage value must not silently become 2048 and an
    // unbounded value must not drive a multi-gigabyte allocation. Emitted as the
    // unified error envelope so it decodes through the same client parser as the
    // other atlas errors.
    final qp = request.url.queryParameters;
    final outPixelsRaw = qp['outPixels'];
    final int outPixels;
    if (outPixelsRaw == null || outPixelsRaw.isEmpty) {
      outPixels = 2048;
    } else {
      final parsed = int.tryParse(outPixelsRaw);
      if (parsed == null || parsed < 1 || parsed > _maxCutoutPixels) {
        throw BadRequestError(
          field: 'outPixels',
          expected: 'integer in 1..$_maxCutoutPixels',
          message: 'outPixels must be a whole number in 1..$_maxCutoutPixels',
        );
      }
      outPixels = parsed;
    }

    final resolved = await _resolveRegion(id);
    if (resolved.error != null) return resolved.error!;
    final regionId = resolved.regionId!;
    final region = resolved.region!;

    final interp = _parseInterp(qp['interp']);

    final result = await _service.cutout(
      centerRaDeg: region.centerRaDeg,
      centerDecDeg: region.centerDecDeg,
      radiusDeg: region.radiusDeg,
      outPixels: outPixels,
      interp: interp,
    );

    final pngPath = result['pngPath'] as String?;
    if (pngPath == null || pngPath.trim().isEmpty) {
      return jsonError(
        code: 'cutout_failed',
        message: 'cutout did not produce a PNG for region $regionId',
        statusCode: 500,
      );
    }
    final file = File(pngPath);
    if (!await file.exists()) {
      return jsonError(
        code: 'cutout_missing',
        message: 'cutout PNG missing on disk for region $regionId',
        statusCode: 500,
      );
    }
    final bytes = await file.readAsBytes();
    return contentResponse(
      bytes,
      contentType: 'image/png',
      contentLength: bytes.length,
      headers: {
        'cache-control': 'no-cache',
        'x-covered-fraction':
            (result['coveredFraction'] as num?)?.toString() ?? '0',
        'x-tiles-used': (result['tilesUsed'] as num?)?.toString() ?? '0',
      },
    );
  }

  // GET /api/atlas/region/<id>/timeline

  Future<Response> handleGetRegionTimeline(Request request, String id) async {
    _logInfo('[API] GET /api/atlas/region/$id/timeline');
    final resolved = await _resolveRegion(id);
    if (resolved.error != null) return resolved.error!;
    final regionId = resolved.regionId!;
    final region = resolved.region!;

    final folds = await _service.regionTimeline(regionId);

    // The deepening growth curve for the cone (cumulative frames / seconds per
    // fold) — the companion plots this as the "your sky is getting deeper" line.
    final growth = await _service.growth(
      centerRaDeg: region.centerRaDeg,
      centerDecDeg: region.centerDecDeg,
      radiusDeg: region.radiusDeg,
    );

    return jsonOk({
      'regionId': regionId,
      'folds': folds.map(_foldToJson).toList(),
      'growth': growth,
    });
  }

  // Helpers

  Future<SkyAtlasRegionRow?> _findRegion(int regionId) async {
    final regions = await _service.regions();
    for (final region in regions) {
      if (region.id == regionId) return region;
    }
    return null;
  }

  /// Shared preamble for the three `/api/atlas/region/<id>/...` routes: parse
  /// [id] as an integer and resolve the region. Returns either the resolved
  /// `(regionId, region)` pair (with `error == null`) or a ready-made [error]
  /// [Response] carrying the envelope all three routes share:
  ///   * 400 `invalid_region_id` / 'region id must be an integer' for a
  ///     non-integer id, and
  ///   * 404 `region_not_found` / `region <id> not found` when no region
  ///     matches.
  Future<({int? regionId, SkyAtlasRegionRow? region, Response? error})>
  _resolveRegion(String id) async {
    final regionId = int.tryParse(id);
    if (regionId == null) {
      return (
        regionId: null,
        region: null,
        error: jsonError(
          code: 'invalid_region_id',
          message: 'region id must be an integer',
          statusCode: 400,
        ),
      );
    }
    final region = await _findRegion(regionId);
    if (region == null) {
      return (
        regionId: regionId,
        region: null,
        error: jsonError(
          code: 'region_not_found',
          message: 'region $regionId not found',
          statusCode: 404,
        ),
      );
    }
    return (regionId: regionId, region: region, error: null);
  }

  AtlasInterp _parseInterp(String? value) {
    final normalized = value?.trim().toLowerCase();
    for (final interp in AtlasInterp.values) {
      if (interp.wire.toLowerCase() == normalized) return interp;
    }
    return AtlasInterp.lanczos3;
  }

  /// Serialize a coverage row using the bridge-native key names
  /// [AtlasTileCoverage.fromJson] consumes (`centerRa` / `centerDec`), so the
  /// companion reconstructs rows with the same decoder the local path uses.
  Map<String, dynamic> _coverageToJson(AtlasTileCoverage tile) => {
    'tileId': tile.tileId,
    'centerRa': tile.centerRaDeg,
    'centerDec': tile.centerDecDeg,
    'coverageMean': tile.coverageMean,
    'totalFrames': tile.totalFrames,
    'integrationSeconds': tile.integrationSeconds,
    'lastFoldIso': tile.lastFoldIso,
    'channels': tile.channels,
  };

  /// Serialize a tile row for the companion's region detail. Carries the
  /// `(tileId, healpixOrder)` identity, centre + own-light totals, and the
  /// blended swarm-overlay depth so the slave renders the same rollups the host
  /// computes locally.
  Map<String, dynamic> _tileToJson(SkyTileRow tile) => {
    'id': tile.id,
    'tileId': tile.tileId,
    'healpixOrder': tile.healpixOrder,
    'channels': tile.channels,
    'centerRaDeg': tile.centerRaDeg,
    'centerDecDeg': tile.centerDecDeg,
    'coverageMean': tile.coverageMean,
    'totalFrames': tile.totalFrames,
    'integrationSeconds': tile.integrationSeconds,
    'swarmOverlayFrames': tile.swarmOverlayFrames,
    'swarmOverlayIntegrationSeconds': tile.swarmOverlayIntegrationSeconds,
    'regionId': tile.regionId,
  };

  Map<String, dynamic> _regionToJson(SkyAtlasRegionRow region) => {
    'id': region.id,
    'name': region.name,
    'kind': region.kind,
    'centerRaDeg': region.centerRaDeg,
    'centerDecDeg': region.centerDecDeg,
    'radiusDeg': region.radiusDeg,
    'targetId': region.targetId,
    'tileCount': region.tileCount,
    'integrationSeconds': region.integrationSeconds,
    'createdAt': region.createdAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> _foldToJson(SkyAtlasFoldRow fold) => {
    'id': fold.id,
    'tileId': fold.tileId,
    'healpixOrder': fold.healpixOrder,
    'sessionId': fold.sessionId,
    'foldedAt': fold.foldedAt.toUtc().toIso8601String(),
    'framesAdded': fold.framesAdded,
    'weightAdded': fold.weightAdded,
    'integrationSecondsAdded': fold.integrationSecondsAdded,
    'rejected': fold.rejected,
    'contributor': fold.contributor,
    'label': fold.label,
  };
}
