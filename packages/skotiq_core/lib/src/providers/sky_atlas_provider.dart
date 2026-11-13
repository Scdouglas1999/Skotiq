import 'package:skotiq_astro/format.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import 'database_provider.dart';
import '../database/daos/sky_atlas_dao.dart';
import '../database/database.dart';
import '../database/tables/sky_atlas_tables.dart' show skyAtlasHealpixOrder;
import '../models/backend/host_mutation_event.dart';
import '../services/notification_service.dart'
    show NotificationEvent;
import '../services/sky_atlas/sky_atlas_models.dart';
import '../services/sky_atlas/sky_atlas_service.dart';
import '../settings/store_settings.dart';
import 'backend_provider.dart';
import 'host_mutation_event_provider.dart';
import 'host_role.dart';
import 'remote_snapshot_stream.dart';
import 'science_provider.dart' show scienceSettingsProvider;
import '../database/daos/settings_dao.dart';
import '../models/backend/backend_types.dart';
import 'logging_service_provider.dart';
import 'notification_service_provider.dart';
import 'sky_atlas/sky_atlas_seam_provider.dart';

/// Riverpod surface for Pillar A ("Your Sky") — the personal sky atlas.
///
/// [skyAtlasServiceProvider] builds the orchestrator from the atlas DAO + FFI
/// seam; the read providers ([skyAtlasCoverageProvider], [skyAtlasRegionsProvider],
/// [skyTileProvider]) expose the region list, growth/coverage, and a per-tile
/// PNG cutout fetch the atlas browser renders.
///
/// On a companion the local atlas store is empty (the host owns
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
    autoFoldEnabled: () async {
      final value = await ref
          .read(settingsDaoProvider)
          .getSetting(StoreSettings.scienceSkyAtlas.key);
      return StoreSettings.scienceSkyAtlas.decode(value?.trim(), false);
    },
    targetResolver: (targetId) async {
      final target = await targetsDao.getTargetById(targetId);
      if (target == null) return null;
      return AtlasTargetRef(
        name: target.name,
        raDeg: target.ra * 15.0,
        decDeg: target.dec,
      );
    },
    storageLimitBytes: () async {
      final raw = await ref
          .read(settingsDaoProvider)
          .getSetting(StoreSettings.scienceSkyAtlasLimitGb.key);
      return parseSkyAtlasLimitGb(raw) * ByteFormat.bytesPerGiga;
    },
    onStorageLimitReached: (used, limit) {
      unawaited(
        ref
            .read(notificationServiceProvider)
            .notify(
              event: NotificationEvent.custom,
              title: 'Your Sky atlas is full',
              message:
                  'The atlas uses ${ByteFormat.size(used)}, its '
                  '${ByteFormat.size(limit)} limit. New frames are not being added; nothing was deleted. Raise the '
                  'limit or compress stored tiles in Settings > Science.',
            )
            .then<void>((_) {}, onError: (Object _) {}),
      );
    },
    onAtlasChanged: () => ref
        .read(hostMutationEventHubProvider)
        .publishRemoteOnly(
          entityType: HostMutationEntity.atlas,
          action: HostMutationAction.updated,
        ),
  );
});

/// The Your Sky atlas of whichever machine is the imaging host: its regions,
/// tiles and fold history.
///
/// The host reads its own atlas database and renders through the native
/// atlas. A linked client reads the host's atlas routes, again whenever the
/// host says the atlas changed.
abstract interface class YourSkyAtlas {
  /// Per-tile coverage, deepest first.
  Stream<List<AtlasTileCoverage>> watchCoverage();

  Stream<List<SkyAtlasRegionRow>> watchRegions();

  Future<SkyAtlasRegionRow?> region(int regionId);

  /// A region's tiles, deepest first.
  Future<List<SkyTileRow>> regionTiles(int regionId);

  /// A region's folds, oldest first.
  Stream<List<SkyAtlasFoldRow>> watchRegionTimeline(int regionId);

  Future<AtlasGrowthCurve> regionGrowth(int regionId);

  /// How the region's deepest tile came to be, or null when it has no tile.
  Future<TileProvenanceView?> regionProvenance(int regionId);

  /// The co-added region at its latest depth.
  Future<AtlasRegionCutoutImage> regionCutout(int regionId);

  /// Names a region of the atlas and returns its id.
  Future<int> ensureRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    String kind = 'custom',
    int? targetId,
  });
}

final yourSkyAtlasProvider = hostRoleProvider<YourSkyAtlas>(
  here: (ref) => _LocalYourSkyAtlas(
    ref.watch(skyAtlasServiceProvider),
    ref.watch(skyAtlasDaoProvider),
    // A client that is not connected has no host to name a region on, and
    // its own database is one no host reads.
    writable: ref.watch(backendProvider).ownsDeviceBridge,
  ),
  linked: (ref, host) => _HostYourSkyAtlas(ref, host.skyAtlas),
);

final class _LocalYourSkyAtlas implements YourSkyAtlas {
  _LocalYourSkyAtlas(this._service, this._dao, {required this.writable});

  final SkyAtlasService _service;
  final SkyAtlasDao _dao;
  final bool writable;

  /// The tile index in the database (the same numbers, no sidecar reads),
  /// read again whenever a fold changes the tiles.
  @override
  Stream<List<AtlasTileCoverage>> watchCoverage() =>
      _dao.watchAllTiles().asyncMap((_) => _service.coverageFromIndex());

  @override
  Stream<List<SkyAtlasRegionRow>> watchRegions() => _service.watchRegions();

  @override
  Future<SkyAtlasRegionRow?> region(int regionId) =>
      _service.getRegion(regionId);

  @override
  Future<List<SkyTileRow>> regionTiles(int regionId) =>
      _service.tilesForRegion(regionId);

  @override
  Stream<List<SkyAtlasFoldRow>> watchRegionTimeline(int regionId) =>
      _service.watchRegionTimeline(regionId);

  @override
  Future<AtlasGrowthCurve> regionGrowth(int regionId) async {
    final region = await _service.getRegion(regionId);
    if (region == null) return AtlasGrowthCurve.empty;
    return AtlasGrowthCurve.fromJson(
      await _service.growth(
        centerRaDeg: region.centerRaDeg,
        centerDecDeg: region.centerDecDeg,
        radiusDeg: region.radiusDeg,
      ),
    );
  }

  @override
  Future<TileProvenanceView?> regionProvenance(int regionId) async {
    final tiles = await _service.tilesForRegion(regionId);
    if (tiles.isEmpty) return null;
    return _service.tileInfo(tiles.first.tileId);
  }

  @override
  Future<AtlasRegionCutoutImage> regionCutout(int regionId) async {
    final region = await _service.getRegion(regionId);
    if (region == null) {
      throw StateError('region $regionId not found');
    }
    final result = await _service.cutout(
      centerRaDeg: region.centerRaDeg,
      centerDecDeg: region.centerDecDeg,
      radiusDeg: region.radiusDeg,
    );
    final pngPath = result['pngPath'] as String?;
    if (pngPath == null || pngPath.trim().isEmpty) {
      throw StateError('cutout produced no PNG for region $regionId');
    }
    return AtlasRegionCutoutImage.file(pngPath);
  }

  @override
  Future<int> ensureRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    String kind = 'custom',
    int? targetId,
  }) {
    if (!writable) {
      throw StateError(
        'Connect to an imaging host before naming a sky region.',
      );
    }
    return _service.ensureRegion(
      name: name,
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      radiusDeg: radiusDeg,
      kind: kind,
      targetId: targetId,
    );
  }
}

final class _HostYourSkyAtlas implements YourSkyAtlas {
  _HostYourSkyAtlas(this._ref, this._host);

  final Ref _ref;
  final HostSkyAtlas _host;

  /// A list read from the host, read again on an atlas-changing host event
  /// ([isAtlasChangingEvent]) at most once every
  /// [remoteAtlasRefetchMinInterval].
  Stream<List<T>> _watch<T>(
    Future<List<Map<String, dynamic>>> Function() fetch,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final logger = _ref.read(loggingServiceProvider);
    return remoteSnapshotStream<T>(
      backend: _ref.read(backendProvider),
      fetch: fetch,
      decode: fromJson,
      shouldRefetch: isAtlasChangingEvent,
      minInterval: remoteAtlasRefetchMinInterval,
      onRefetchError: (e) => logger.debug(
        'Remote atlas snapshot refetch failed; keeping last good snapshot: $e',
        source: 'SkyAtlasProvider',
      ),
    );
  }

  Future<List<SkyTileRow>> _tiles(int regionId) async {
    final raw = (await _host.getAtlasRegion(regionId))['tiles'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(skyTileRowFromWireJson)
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _folds(int regionId) async {
    final raw = (await _host.getAtlasRegionTimeline(regionId))['folds'];
    if (raw is! List) return const [];
    return raw.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  @override
  Stream<List<AtlasTileCoverage>> watchCoverage() =>
      _watch(_host.getAtlasCoverage, AtlasTileCoverage.fromJson);

  @override
  Stream<List<SkyAtlasRegionRow>> watchRegions() =>
      _watch(_host.getAtlasRegions, skyAtlasRegionFromWireJson);

  @override
  Future<SkyAtlasRegionRow?> region(int regionId) async {
    final region = (await _host.getAtlasRegion(regionId))['region'];
    if (region is! Map<String, dynamic>) return null;
    return skyAtlasRegionFromWireJson(region);
  }

  @override
  Future<List<SkyTileRow>> regionTiles(int regionId) => _tiles(regionId);

  @override
  Stream<List<SkyAtlasFoldRow>> watchRegionTimeline(int regionId) =>
      _watch(() => _folds(regionId), skyAtlasFoldRowFromWireJson);

  @override
  Future<AtlasGrowthCurve> regionGrowth(int regionId) async {
    final growth = (await _host.getAtlasRegionTimeline(regionId))['growth'];
    if (growth is! Map<String, dynamic>) return AtlasGrowthCurve.empty;
    return AtlasGrowthCurve.fromJson(growth);
  }

  /// Built from the region's deepest tile and the folds of that tile in the
  /// region timeline, the two payloads the host already serves.
  @override
  Future<TileProvenanceView?> regionProvenance(int regionId) async {
    final tiles = await _tiles(regionId);
    if (tiles.isEmpty) return null;
    final deepest = tiles.reduce(
      (a, b) => a.integrationSeconds >= b.integrationSeconds ? a : b,
    );
    final folds = (await _folds(regionId))
        .map(skyAtlasFoldRowFromWireJson)
        .where((f) => f.tileId == deepest.tileId)
        .toList(growable: false);
    return TileProvenanceView(
      tileId: deepest.tileId,
      centerRaDeg: deepest.centerRaDeg,
      centerDecDeg: deepest.centerDecDeg,
      channels: deepest.channels,
      coverageMean: deepest.coverageMean,
      totalFrames: deepest.totalFrames,
      totalIntegrationSeconds: deepest.integrationSeconds,
      contributors: <String>{
        for (final f in folds)
          if (f.contributor.trim().isNotEmpty) f.contributor.trim(),
      }.toList(growable: false),
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

  @override
  Future<AtlasRegionCutoutImage> regionCutout(int regionId) async =>
      AtlasRegionCutoutImage.bytes(await _host.getAtlasRegionCutout(regionId));

  @override
  Future<int> ensureRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    String kind = 'custom',
    int? targetId,
  }) => _host.createAtlasRegion(
    name: name,
    centerRaDeg: centerRaDeg,
    centerDecDeg: centerDecDeg,
    radiusDeg: radiusDeg,
    kind: kind,
    targetId: targetId,
  );
}

/// Whether Your Sky is on: the user's choice, off until they turn it on. Null
/// while the setting loads.
final skyAtlasEnabledProvider = Provider<bool?>((ref) {
  return ref.watch(
    scienceSettingsProvider.select((s) => s.valueOrNull?.skyAtlasEnabled),
  );
});

/// Bytes kept from before Your Sky became opt-in, when the one-time notice
/// about it is still owed; null once it is answered, on a companion, or when
/// there is nothing on disk to tell the user about (then it is settled
/// silently).
final skyAtlasOffNoticeProvider = FutureProvider.autoDispose<int?>((ref) async {
  if (ref.watch(isRemoteModeProvider)) return null;
  final settings = ref.read(settingsDaoProvider);
  if (await settings.read(StoreSettings.scienceSkyAtlasOffNotice) !=
      'pending') {
    return null;
  }
  final bytes = await ref.read(skyAtlasServiceProvider).storageBytes();
  if (bytes > 0) return bytes;
  await settings.write(StoreSettings.scienceSkyAtlasOffNotice, 'shown');
  return null;
});

/// Record that the user has answered the one-time notice.
Future<void> markSkyAtlasOffNoticeShown(WidgetRef ref) async {
  await ref
      .read(settingsDaoProvider)
      .write(StoreSettings.scienceSkyAtlasOffNotice, 'shown');
  ref.invalidate(skyAtlasOffNoticeProvider);
}

/// Bytes the Your Sky atlas takes on this machine's disk. Null on a companion,
/// whose atlas lives on the imaging host.
final skyAtlasStorageBytesProvider = FutureProvider.autoDispose<int?>((ref) {
  if (ref.watch(isRemoteModeProvider)) return null;
  return ref.watch(skyAtlasServiceProvider).storageBytes();
});

/// Per-tile coverage rows (deepest first) for the heat overlay / gallery.
/// Remote (companion) mode reads the host's coverage over REST, refreshed when
/// a backend event arrives (a fold is exactly what changes coverage); host mode
/// queries the native bridge directly.
final skyAtlasCoverageProvider =
    StreamProvider.autoDispose<List<AtlasTileCoverage>>(
      (ref) => ref.watch(yourSkyAtlasProvider).watchCoverage(),
    );

/// Atlas-wide totals counted once per frame, for the Your Sky headline. Host
/// only (the fold timeline lives in the host database); null on a companion,
/// whose overlay then shows per-tile depth instead of a total.
final skyAtlasTotalsProvider = FutureProvider.autoDispose<AtlasTotals?>((
  ref,
) async {
  if (ref.watch(isRemoteModeProvider)) return null;
  // Recount whenever coverage refreshes (a fold is what changes both).
  ref.watch(skyAtlasCoverageProvider);
  final totals = await ref.watch(skyAtlasDaoProvider).atlasTotals();
  return AtlasTotals(frames: totals.frames, integrationSeconds: totals.seconds);
});

/// Reactive list of persisted atlas regions for the browser. Remote (companion)
/// mode reads the host's regions over REST (event-refreshed); host mode watches
/// the local atlas DB live.
final skyAtlasRegionsProvider =
    StreamProvider.autoDispose<List<SkyAtlasRegionRow>>(
      (ref) => ref.watch(yourSkyAtlasProvider).watchRegions(),
    );

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

/// Shortest gap between two starts of the same remote atlas read. A host that
/// folds a frame every few seconds still sees at most one request per read per
/// interval from each companion.
const Duration remoteAtlasRefetchMinInterval = Duration(seconds: 15);

/// True for the host events after which an atlas read can differ: an atlas
/// mutation (fold, swarm merge, region change) or a captured-image change from
/// a host that predates atlas events.
bool isAtlasChangingEvent(SkotiqEvent event) {
  if (event.eventType != hostStateChangedEventType) return false;
  final entity = event.data['entityType'];
  return entity == HostMutationEntity.atlas ||
      entity == HostMutationEntity.capturedImage;
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
// goes to whichever machine is the imaging host: a companion reads the host's
// already-advertised `/api/atlas/region/<id>[/timeline]` routes; a host reads
// the local DAO/seam.

final atlasRegionProvider = FutureProvider.family<SkyAtlasRegionRow?, int>(
  (ref, regionId) => ref.watch(yourSkyAtlasProvider).region(regionId),
);

final atlasRegionTilesProvider = FutureProvider.family<List<SkyTileRow>, int>(
  (ref, regionId) => ref.watch(yourSkyAtlasProvider).regionTiles(regionId),
);

final atlasRegionTimelineProvider = StreamProvider.autoDispose
    .family<List<SkyAtlasFoldRow>, int>(
      (ref, regionId) =>
          ref.watch(yourSkyAtlasProvider).watchRegionTimeline(regionId),
    );

final atlasRegionGrowthProvider = FutureProvider.family<AtlasGrowthCurve, int>(
  (ref, regionId) => ref.watch(yourSkyAtlasProvider).regionGrowth(regionId),
);

final atlasRegionProvenanceProvider =
    FutureProvider.family<TileProvenanceView?, int>(
      (ref, regionId) =>
          ref.watch(yourSkyAtlasProvider).regionProvenance(regionId),
    );

/// Carries no `asOf`: the cutout is always the latest depth, and the time
/// scrub drives only the frame list and growth panels.
final atlasRegionCutoutProvider =
    FutureProvider.family<AtlasRegionCutoutImage, int>(
      (ref, regionId) => ref.watch(yourSkyAtlasProvider).regionCutout(regionId),
    );

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
