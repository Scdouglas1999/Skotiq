import 'dart:typed_data';

import 'package:skotiq_core/skotiq_core.dart';

/// [HostSkyAtlas] on a linked host.
final class RemoteHostSkyAtlas implements HostSkyAtlas {
  RemoteHostSkyAtlas(this._host);

  final NetworkBackend _host;

  @override
  Future<List<Map<String, dynamic>>> getAtlasCoverage() =>
      _host.getAtlasCoverage();

  @override
  Future<List<Map<String, dynamic>>> getAtlasRegions() =>
      _host.getAtlasRegions();

  @override
  Future<Map<String, dynamic>> getAtlasRegion(int regionId) =>
      _host.getAtlasRegion(regionId);

  @override
  Future<Map<String, dynamic>> getAtlasRegionTimeline(int regionId) =>
      _host.getAtlasRegionTimeline(regionId);

  @override
  Future<Uint8List> getAtlasRegionCutout(
    int regionId, {
    int outPixels = 2048,
    String? interp,
  }) => _host.getAtlasRegionCutout(
    regionId,
    outPixels: outPixels,
    interp: interp,
  );

  @override
  Future<int> createAtlasRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    required String kind,
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
