import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../backend/ffi_backend.dart';
import '../database/daos/sky_atlas_dao.dart';
import '../database/database.dart';
import '../database/tables/sky_atlas_tables.dart' show skyAtlasHealpixOrder;
import '../services/logging_service.dart';
import '../services/sky_atlas/sky_atlas_models.dart';
import '../services/sky_atlas/sky_atlas_service.dart';
import '../services/sky_atlas/sky_atlas_seam.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

/// Riverpod surface for Pillar A ("Your Sky") — the personal sky atlas.
///
/// [skyAtlasServiceProvider] builds the orchestrator from the atlas DAO + FFI
/// seam; the read providers ([skyAtlasCoverageProvider], [skyAtlasRegionsProvider],
/// [skyTileProvider]) expose the region list, growth/coverage, and a per-tile
/// PNG cutout fetch the atlas browser renders.
///
/// On a [NetworkBackend] companion the local atlas store is empty (the host owns
/// the imaging pipeline that folds frames in), so the region + coverage readers
/// branch to the host's `/api/atlas/*` routes — mirroring the First Light
/// remote path — and fall back to the local DAO/seam in host mode.

/// The sky-atlas orchestration service.
///
/// The [SkyAtlasService.targetResolver] is wired to the Targets DAO here so an
/// auto-fold of a captured image can ensure + name a region from the frame's
/// target (RA hours -> degrees). The core service stays DAO-agnostic; the
/// resolver is host-only and a slave never folds, so region creation is a
/// host-only write to the local atlas DB.
final skyAtlasServiceProvider = Provider<SkyAtlasService>((ref) {
  final targetsDao = ref.watch(targetsDaoProvider);
  return SkyAtlasService(
    dao: ref.watch(skyAtlasDaoProvider),
    seam: ref.watch(skyAtlasSeamProvider),
    logger: ref.watch(loggingServiceProvider),
    atlasRootResolver: defaultAtlasRoot,
    targetResolver: (targetId) async {
      final target = await targetsDao.getTargetById(targetId);
      if (target == null) return null;
      return AtlasTargetRef(
        name: target.name,
        raDeg: target.ra * 15.0,
        decDeg: target.dec,
      );
    },
  );
});

/// Authority-aware writer for the atlas's named-region metadata.
///
/// A desktop host writes its local atlas service; a companion writes through
/// the active NetworkBackend. A disconnected client fails explicitly instead
/// of populating its throwaway local database and pretending the host changed.
final skyAtlasRegionWriterProvider = Provider<SkyAtlasRegionWriter>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return SkyAtlasRegionWriter.remote(backend);
  }
  if (backend is FfiBackend) {
    return SkyAtlasRegionWriter.local(ref.watch(skyAtlasServiceProvider));
  }
  return const SkyAtlasRegionWriter.unavailable();
});

class SkyAtlasRegionWriter {
  final SkyAtlasService? _local;
  final NetworkBackend? _remote;

  const SkyAtlasRegionWriter.local(SkyAtlasService service)
    : _local = service,
      _remote = null;

  const SkyAtlasRegionWriter.remote(NetworkBackend backend)
    : _local = null,
      _remote = backend;

  const SkyAtlasRegionWriter.unavailable() : _local = null, _remote = null;

  Future<int> ensureRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    String kind = 'custom',
    int? targetId,
  }) {
    final remote = _remote;
    if (remote != null) {
      return remote.createAtlasRegion(
        name: name,
        centerRaDeg: centerRaDeg,
        centerDecDeg: centerDecDeg,
        radiusDeg: radiusDeg,
        kind: kind,
        targetId: targetId,
      );
    }
    final local = _local;
    if (local != null) {
      return local.ensureRegion(
        name: name,
        centerRaDeg: centerRaDeg,
        centerDecDeg: centerDecDeg,
        radiusDeg: radiusDeg,
        kind: kind,
        targetId: targetId,
      );
    }
    throw StateError('Connect to an imaging host before naming a sky region.');
  }
}

/// Per-tile coverage rows (deepest first) for the heat overlay / gallery.
/// Remote (companion) mode reads the host's coverage over REST, refreshed when
/// a backend event arrives (a fold is exactly what changes coverage); host mode
/// queries the native bridge directly.
final skyAtlasCoverageProvider = StreamProvider<List<AtlasTileCoverage>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _remoteAtlasSnapshotStream<AtlasTileCoverage>(
      ref,
      backend,
      backend.getAtlasCoverage,
      AtlasTileCoverage.fromJson,
    );
  }
  // Host coverage poll reads the SkyTiles DB index (same scalars, zero sidecar
  // I/O) rather than the native full-scan of every `.nst` sidecar.
  return Stream.fromFuture(
    ref.watch(skyAtlasServiceProvider).coverageFromIndex(),
  );
});

/// Reactive list of persisted atlas regions for the browser. Remote (companion)
/// mode reads the host's regions over REST (event-refreshed); host mode watches
/// the local atlas DB live.
final skyAtlasRegionsProvider = StreamProvider<List<SkyAtlasRegionRow>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _remoteAtlasSnapshotStream<SkyAtlasRegionRow>(
      ref,
      backend,
      backend.getAtlasRegions,
      skyAtlasRegionFromWireJson,
    );
  }
  return ref.watch(skyAtlasServiceProvider).watchRegions();
});

/// Reconstruct a [SkyAtlasRegionRow] from the wire JSON the appliance's
/// `/api/atlas/regions` endpoint emits (see `AtlasHandlers._regionToJson`).
/// Mirrors the DB row so the remote browser renders identically to the local
/// one; `createdAt` is the ISO-8601 string the handler serializes (not the
/// epoch-millis the Drift default serializer would expect), so it is parsed
/// here explicitly.
SkyAtlasRegionRow skyAtlasRegionFromWireJson(Map<String, dynamic> json) {
  return SkyAtlasRegionRow(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String,
    kind: json['kind'] as String,
    centerRaDeg: (json['centerRaDeg'] as num).toDouble(),
    centerDecDeg: (json['centerDecDeg'] as num).toDouble(),
    radiusDeg: (json['radiusDeg'] as num).toDouble(),
    targetId: (json['targetId'] as num?)?.toInt(),
    tileCount: (json['tileCount'] as num?)?.toInt() ?? 0,
    integrationSeconds: (json['integrationSeconds'] as num?)?.toDouble() ?? 0.0,
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// REST snapshot stream for a remote atlas read: fetch once, then re-fetch
/// (debounced) whenever a backend event arrives. Keeps the last good snapshot on
/// a transient fetch failure rather than flashing empty — the same shape the
/// remote First Light feed uses (`_remoteFirstLightStream`).
Stream<List<T>> _remoteAtlasSnapshotStream<T>(
  Ref ref,
  NetworkBackend backend,
  Future<List<Map<String, dynamic>>> Function() fetch,
  T Function(Map<String, dynamic>) fromJson,
) {
  final controller = StreamController<List<T>>();
  final logger = ref.read(loggingServiceProvider);
  Timer? debounce;
  var emittedOnce = false;

  Future<void> refetch() async {
    try {
      final raw = await fetch();
      final rows = raw.map(fromJson).toList(growable: false);
      if (!controller.isClosed) {
        controller.add(rows);
        emittedOnce = true;
      }
    } catch (e) {
      // After a prior good snapshot this is transient (reconnect / host busy):
      // keep the last snapshot rather than flashing empty. But if the very
      // first fetch fails the StreamProvider would hang in loading forever, so
      // surface the error to drive the view's error + Retry state.
      if (!emittedOnce) {
        if (!controller.isClosed) controller.addError(e);
        return;
      }
      logger.debug(
        'Remote atlas snapshot refetch failed; keeping last good snapshot: $e',
        source: 'SkyAtlasProvider',
      );
    }
  }

  refetch();
  final sub = backend.eventStream.listen((_) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 750), refetch);
  });
  ref.onDispose(() {
    debounce?.cancel();
    unawaited(sub.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
}

/// Query key for [skyTileProvider]: a tile id plus an optional time-scrub
/// anchor. Value-equal so the same query reuses one cached cutout future.
class SkyTileQuery {
  final int tileId;
  final DateTime? asOf;

  const SkyTileQuery(this.tileId, {this.asOf});

  @override
  bool operator ==(Object other) =>
      other is SkyTileQuery && other.tileId == tileId && other.asOf == asOf;

  @override
  int get hashCode => Object.hash(tileId, asOf);
}

/// Render (and cache) a finalized tile to a PNG, returning its on-disk path.
/// Optionally time-scrubbed via [SkyTileQuery.asOf].
final skyTileProvider = FutureProvider.family<String, SkyTileQuery>((
  ref,
  query,
) {
  return ref
      .watch(skyAtlasServiceProvider)
      .finalizeTilePng(query.tileId, asOf: query.asOf);
});

// Region detail — backend-aware families
//
// Hoisted here (out of `region_detail_screen.dart`) so the region-detail screen
// renders on a slave instead of reading an empty local atlas DB. Each family
// branches on the active backend: a [NetworkBackend] companion reads the host's
// already-advertised `/api/atlas/region/<id>[/timeline]` routes; a host reads
// the local DAO/seam.

/// One region's row by id. Remote: from the host region-detail payload; host:
/// the local DAO.
final atlasRegionProvider = FutureProvider.family<SkyAtlasRegionRow?, int>((
  ref,
  regionId,
) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final json = await backend.getAtlasRegion(regionId);
    final region = json['region'];
    if (region is! Map<String, dynamic>) return null;
    return skyAtlasRegionFromWireJson(region);
  }
  return ref.watch(skyAtlasServiceProvider).getRegion(regionId);
});

/// A region's tiles (deepest first). Remote has no per-tile route, so the host's
/// region-detail payload carries a `tiles` array (added additively to
/// `GET /api/atlas/region/<id>`); host reads the local DAO.
final atlasRegionTilesProvider = FutureProvider.family<List<SkyTileRow>, int>((
  ref,
  regionId,
) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final json = await backend.getAtlasRegion(regionId);
    final raw = json['tiles'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(skyTileRowFromWireJson)
        .toList(growable: false);
  }
  return ref.watch(skyAtlasServiceProvider).tilesForRegion(regionId);
});

/// A region's fold timeline (oldest first). Remote: decode the host timeline
/// payload's `folds` array; host: watch the local DAO live.
final atlasRegionTimelineProvider =
    StreamProvider.family<List<SkyAtlasFoldRow>, int>((ref, regionId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _remoteAtlasSnapshotStream<SkyAtlasFoldRow>(
          ref,
          backend,
          () async {
            final json = await backend.getAtlasRegionTimeline(regionId);
            final raw = json['folds'];
            if (raw is! List) return const [];
            return raw.whereType<Map<String, dynamic>>().toList(
              growable: false,
            );
          },
          skyAtlasFoldRowFromWireJson,
        );
      }
      return ref.watch(skyAtlasServiceProvider).watchRegionTimeline(regionId);
    });

/// A region's deepening growth curve (cumulative integration vs. night).
///
/// Host: the native bridge `growth` action over the region cone. Remote: the
/// `growth` block the host already ships inside the
/// `/api/atlas/region/<id>/timeline` payload (no extra round-trip, no new
/// route) — so the curve plots identically on a slave companion.
final atlasRegionGrowthProvider = FutureProvider.family<AtlasGrowthCurve, int>((
  ref,
  regionId,
) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final json = await backend.getAtlasRegionTimeline(regionId);
    final growth = json['growth'];
    if (growth is! Map<String, dynamic>) return AtlasGrowthCurve.empty;
    return AtlasGrowthCurve.fromJson(growth);
  }
  final region = await ref.watch(skyAtlasServiceProvider).getRegion(regionId);
  if (region == null) return AtlasGrowthCurve.empty;
  final raw = await ref
      .watch(skyAtlasServiceProvider)
      .growth(
        centerRaDeg: region.centerRaDeg,
        centerDecDeg: region.centerDecDeg,
        radiusDeg: region.radiusDeg,
      );
  return AtlasGrowthCurve.fromJson(raw);
});

/// Native per-tile provenance ([TileProvenanceView]: coverage mean, contributor
/// list, per-fold log) for a region's DEEPEST tile — the provenance trail the
/// region-detail panel renders.
///
/// Host: the native bridge `info` action on the deepest tile. Remote: there is
/// no per-tile info route, so the view is reconstructed from data already on
/// the wire — the deepest tile's `coverageMean` from the region payload's
/// `tiles`, plus the per-fold log + contributor list from the region timeline's
/// `folds` — yielding the same [TileProvenanceView] shape on a slave companion.
final atlasRegionProvenanceProvider =
    FutureProvider.family<TileProvenanceView?, int>((ref, regionId) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        final detail = await backend.getAtlasRegion(regionId);
        final tilesRaw = detail['tiles'];
        if (tilesRaw is! List || tilesRaw.isEmpty) return null;
        final tiles = tilesRaw
            .whereType<Map<String, dynamic>>()
            .map(skyTileRowFromWireJson)
            .toList(growable: false);
        if (tiles.isEmpty) return null;
        final deepest = tiles.reduce(
          (a, b) => a.integrationSeconds >= b.integrationSeconds ? a : b,
        );
        final timeline = await backend.getAtlasRegionTimeline(regionId);
        final foldsRaw = timeline['folds'];
        final folds = foldsRaw is List
            ? foldsRaw
                  .whereType<Map<String, dynamic>>()
                  .map(skyAtlasFoldRowFromWireJson)
                  .where((f) => f.tileId == deepest.tileId)
                  .toList(growable: false)
            : const <SkyAtlasFoldRow>[];
        final contributors = <String>{
          for (final f in folds)
            if (f.contributor.trim().isNotEmpty) f.contributor.trim(),
        }.toList(growable: false);
        return TileProvenanceView(
          tileId: deepest.tileId,
          centerRaDeg: deepest.centerRaDeg,
          centerDecDeg: deepest.centerDecDeg,
          channels: deepest.channels,
          coverageMean: deepest.coverageMean,
          totalFrames: deepest.totalFrames,
          totalIntegrationSeconds: deepest.integrationSeconds,
          contributors: contributors,
          folds: [
            for (final f in folds)
              TileFoldView(
                framesAdded: f.framesAdded,
                weightAdded: f.weightAdded,
                integrationSecondsAdded: f.integrationSecondsAdded,
                rejected: f.rejected,
                label: f.label,
                contributor: f.contributor,
              ),
          ],
        );
      }
      final service = ref.watch(skyAtlasServiceProvider);
      final tiles = await service.tilesForRegion(regionId);
      if (tiles.isEmpty) return null;
      // tilesForRegion is deepest-first, so the head is the deepest tile.
      return service.tileInfo(tiles.first.tileId);
    });

/// The portable co-added region cutout PNG. Remote: fetch host cutout bytes for
/// `Image.memory`; host: render via the native cutout into a local cache file.
/// Carries NO `asOf` — the cutout always renders at the LATEST depth; the
/// time-scrub drives only the honestly-filtered frame list / growth panels.
final atlasRegionCutoutProvider =
    FutureProvider.family<AtlasRegionCutoutImage, int>((ref, regionId) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        final bytes = await backend.getAtlasRegionCutout(regionId);
        return AtlasRegionCutoutImage.bytes(bytes);
      }
      final region = await ref
          .watch(skyAtlasServiceProvider)
          .getRegion(regionId);
      if (region == null) {
        throw StateError('region $regionId not found');
      }
      final result = await ref
          .watch(skyAtlasServiceProvider)
          .cutout(
            centerRaDeg: region.centerRaDeg,
            centerDecDeg: region.centerDecDeg,
            radiusDeg: region.radiusDeg,
          );
      final pngPath = result['pngPath'] as String?;
      if (pngPath == null || pngPath.trim().isEmpty) {
        throw StateError('cutout produced no PNG for region $regionId');
      }
      return AtlasRegionCutoutImage.file(pngPath);
    });

/// A portable region cutout: either a host-local PNG file path (FFI backend) or
/// in-memory PNG bytes fetched over the wire (network backend). The UI renders
/// `Image.file` or `Image.memory` accordingly — the host-local path is never
/// shipped across the wire.
class AtlasRegionCutoutImage {
  /// Local PNG path when rendered on the host; null on a slave.
  final String? filePath;

  /// PNG bytes when fetched from the host; null on the host.
  final Uint8List? bytes;

  const AtlasRegionCutoutImage._({this.filePath, this.bytes});

  factory AtlasRegionCutoutImage.file(String path) =>
      AtlasRegionCutoutImage._(filePath: path);

  factory AtlasRegionCutoutImage.bytes(Uint8List bytes) =>
      AtlasRegionCutoutImage._(bytes: bytes);
}

/// Reconstruct a [SkyTileRow] from the host region-detail `tiles` wire JSON
/// (see `AtlasHandlers._tileToJson`). Only the fields the detail screen reads
/// are populated; the rest take sensible defaults.
SkyTileRow skyTileRowFromWireJson(Map<String, dynamic> json) {
  return SkyTileRow(
    id: (json['id'] as num?)?.toInt() ?? 0,
    tileId: (json['tileId'] as num).toInt(),
    healpixOrder:
        (json['healpixOrder'] as num?)?.toInt() ?? skyAtlasHealpixOrder,
    channels: (json['channels'] as num?)?.toInt() ?? 1,
    centerRaDeg: (json['centerRaDeg'] as num?)?.toDouble() ?? 0.0,
    centerDecDeg: (json['centerDecDeg'] as num?)?.toDouble() ?? 0.0,
    coverageMean: (json['coverageMean'] as num?)?.toDouble() ?? 0.0,
    totalFrames: (json['totalFrames'] as num?)?.toInt() ?? 0,
    integrationSeconds: (json['integrationSeconds'] as num?)?.toDouble() ?? 0.0,
    swarmOverlayFrames: (json['swarmOverlayFrames'] as num?)?.toInt() ?? 0,
    swarmOverlayIntegrationSeconds:
        (json['swarmOverlayIntegrationSeconds'] as num?)?.toDouble() ?? 0.0,
    sidecarPath: '',
    regionId: (json['regionId'] as num?)?.toInt(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// Reconstruct a [SkyAtlasFoldRow] from the host timeline wire JSON (mirrors
/// `AtlasHandlers._foldToJson`). `foldedAt` is the ISO-8601 string the handler
/// emits (not the Drift epoch-millis), so it is parsed explicitly.
SkyAtlasFoldRow skyAtlasFoldRowFromWireJson(Map<String, dynamic> json) {
  return SkyAtlasFoldRow(
    id: (json['id'] as num?)?.toInt() ?? 0,
    tileId: (json['tileId'] as num).toInt(),
    healpixOrder:
        (json['healpixOrder'] as num?)?.toInt() ?? skyAtlasHealpixOrder,
    sessionId: (json['sessionId'] as num?)?.toInt(),
    foldedAt:
        DateTime.tryParse(json['foldedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    framesAdded: (json['framesAdded'] as num?)?.toInt() ?? 0,
    weightAdded: (json['weightAdded'] as num?)?.toDouble() ?? 0.0,
    integrationSecondsAdded:
        (json['integrationSecondsAdded'] as num?)?.toDouble() ?? 0.0,
    rejected: (json['rejected'] as num?)?.toInt() ?? 0,
    contributor: json['contributor'] as String? ?? '',
    label: json['label'] as String? ?? '',
  );
}
