part of '../sky_atlas_service.dart';

/// The on-disk co-add a region exports: a sharable PNG (when rendered) and the
/// photometric FITS that can seed a follow-up live-stack as a reference frame.
class RegionCutoutExport {
  /// The region's display name (for the share caption / snackbars).
  final String regionName;

  /// The co-added FITS path — the reference-frame candidate.
  final String fitsPath;

  /// The co-added PNG path for Share/Export, or null when PNG was not rendered.
  final String? pngPath;

  const RegionCutoutExport({
    required this.regionName,
    required this.fitsPath,
    required this.pngPath,
  });
}

/// The result of [SkyAtlasService.exportDelta]: the written `.skt` delta path
/// plus the post-anchor own-light tally carved out for the federation push.
class AtlasDeltaExport {
  /// On-disk path of the exported `.skt` delta accumulator.
  final String path;

  /// Frames attributable to LOCAL folds strictly after the export anchor — the
  /// true delta to advertise to the hub (0 when nothing new has been imaged).
  final int framesInDelta;

  /// Integration seconds attributable to those same post-anchor own folds.
  final double integrationSeconds;

  const AtlasDeltaExport({
    required this.path,
    required this.framesInDelta,
    required this.integrationSeconds,
  });

  /// Whether this export carries new own-light to contribute.
  bool get isEmpty => framesInDelta <= 0;
}

/// The slice of a target the atlas needs to ensure + name a region on fold:
/// the human name and the sky coordinates (degrees) of its centre. Kept here so
/// the core [SkyAtlasService] never depends on the Targets DAO directly — the
/// provider injects a resolver that maps a `targetId` to one of these.
class AtlasTargetRef {
  /// Human-facing name to title the region with (e.g. "M31" / "NGC 7000").
  final String name;

  /// Target centre RA, degrees (J2000).
  final double raDeg;

  /// Target centre Dec, degrees (J2000).
  final double decDeg;

  const AtlasTargetRef({
    required this.name,
    required this.raDeg,
    required this.decDeg,
  });
}

/// Outcome of [SkyAtlasService.compactTiles].
class AtlasCompactionResult {
  /// Tiles rewritten in the compressed format.
  final int compacted;

  /// Tiles that were already compressed.
  final int alreadyCompact;

  /// Tiles that could not be read and were left as they were.
  final int unreadable;

  /// Bytes the rewritten tiles took before.
  final int bytesBefore;

  /// Bytes the rewritten tiles take now.
  final int bytesAfter;

  const AtlasCompactionResult({
    required this.compacted,
    required this.alreadyCompact,
    required this.unreadable,
    required this.bytesBefore,
    required this.bytesAfter,
  });

  factory AtlasCompactionResult.fromJson(Map<String, dynamic> json) {
    int read(String key) => (json[key] as num?)?.toInt() ?? 0;
    return AtlasCompactionResult(
      compacted: read('compacted'),
      alreadyCompact: read('alreadyCompact'),
      unreadable: read('unreadable'),
      bytesBefore: read('bytesBefore'),
      bytesAfter: read('bytesAfter'),
    );
  }
}
