part of '../network_backend.dart';

/// The sky atlas a linked imaging host builds from its frames.
final class HostSkyAtlas {
  HostSkyAtlas(this._host);

  final NetworkBackend _host;

  /// Fetch the co-added region cone as PNG bytes (latest depth) so the companion
  /// renders the cutout via `Image.memory` — the host-local file path the FFI
  /// path uses is not portable over the wire. Maps to the advertised
  /// `GET /api/atlas/region/<id>/cutout`.
  Future<Uint8List> getAtlasRegionCutout(
    int regionId, {
    int outPixels = 2048,
    String? interp,
  }) {
    return _host._downloadBytes(
      AtlasApi.getRegionCutout,
      path: {'id': regionId},
      query: {
        'outPixels': outPixels.toString(),
        if (interp != null) 'interp': interp,
      },
    );
  }

  /// Fetch the host's per-tile atlas coverage (deepest first) — the heat-overlay
  /// / gallery feed and the source of the Constellation "your contribution" sum.
  /// The native coverage query runs on the host. Callers reconstruct rows via
  /// `AtlasTileCoverage.fromJson`.
  Future<List<Map<String, dynamic>>> getAtlasCoverage() async {
    final json = await _host._get(AtlasApi.getCoverage);
    return _host._sessionScienceObjectList(json, 'tiles', 'GET /api/atlas/coverage');
  }

  // Sky Atlas — Pillar A ("Your Sky") personal atlas

  /// Fetch the host's persisted atlas regions (the "Your Sky" browser list).
  /// The imaging pipeline that folds frames into the atlas runs on the host, so
  /// a remote client reads its regions here instead of its (empty) local store.
  /// Callers reconstruct rows via `skyAtlasRegionFromWireJson`.
  Future<List<Map<String, dynamic>>> getAtlasRegions() async {
    final json = await _host._get(AtlasApi.getRegions);
    return _host._sessionScienceObjectList(json, 'regions', 'GET /api/atlas/regions');
  }

  /// Fetch one region's detail from the host: its row (`region`), live native
  /// cone coverage (`coverage`) and the region's tiles (`tiles`). Backs the
  /// companion's region-detail screen, which reads an empty local store on a
  /// slave and so must branch here. Maps to the already-advertised
  /// `GET /api/atlas/region/<id>` route (no catalog change).
  Future<Map<String, dynamic>> getAtlasRegion(int regionId) async {
    return _host._get(AtlasApi.getRegion, path: {'id': regionId});
  }

  /// Fetch a region's fold timeline (`folds`) + deepening growth curve
  /// (`growth`) from the host — the scrubber stops + contributing-frames list on
  /// a slave. Maps to the advertised `GET /api/atlas/region/<id>/timeline`.
  Future<Map<String, dynamic>> getAtlasRegionTimeline(int regionId) async {
    return _host._get(AtlasApi.getRegionTimeline, path: {'id': regionId});
  }

  /// Create or update a named region in the host-owned atlas. The companion
  /// sends only metadata; all tile/fold data remains on the imaging host.
  Future<int> createAtlasRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    required String kind,
    int? targetId,
  }) async {
    final response = await _host._post(
      AtlasApi.createRegion,
      body: {
        'name': name,
        'centerRaDeg': centerRaDeg,
        'centerDecDeg': centerDecDeg,
        'radiusDeg': radiusDeg,
        'kind': kind,
        if (targetId != null) 'targetId': targetId,
      },
    );
    final raw = response['id'];
    if (raw is! num || !raw.isFinite || raw.toInt() != raw || raw <= 0) {
      throw const FormatException(
        'POST /api/atlas/regions returned no positive whole-number `id`',
      );
    }
    return raw.toInt();
  }
}
