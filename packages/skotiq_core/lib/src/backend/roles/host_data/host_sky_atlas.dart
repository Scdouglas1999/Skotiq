import 'dart:typed_data';

/// The sky atlas a linked imaging host builds from its frames.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostSkyAtlas {
  Future<Uint8List> getAtlasRegionCutout(
    int regionId, {
    int outPixels = 2048,
    String? interp,
  });

  Future<List<Map<String, dynamic>>> getAtlasCoverage();

  Future<List<Map<String, dynamic>>> getAtlasRegions();

  Future<Map<String, dynamic>> getAtlasRegion(int regionId);

  Future<Map<String, dynamic>> getAtlasRegionTimeline(int regionId);

  Future<int> createAtlasRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    required String kind,
    int? targetId,
  });
}
