// Dart-side value types for Pillar A ("Your Sky") — the personal sky atlas.
//
// These model the JSON boundary documented in
// `docs/skotiq_5_0_contracts.md`: a [SolvedFrameRef] is one plate-solved
// light frame ready to fold (it knows
// how to emit the `<SipWcs JSON>` the bridge expects); [AtlasFoldSummary] /
// [AtlasTileCoverage] / [TileProvenanceView] decode the bridge's fold / coverage
// / info results. Field names mirror the wire contract (camelCase) so the maps
// round-trip straight through the FFI envelope.

import 'dart:math' as math;

import '../wcs/gnomonic_projection.dart';

/// Interpolator selection for atlas reprojection. The wire token is the
/// camelCase enum name (`bilinear` / `catmullRom` / `lanczos3`), matching the
/// bridge's `parse_interp` and the constants table in the 5.0 contract.
enum AtlasInterp {
  bilinear,
  catmullRom,
  lanczos3;

  /// Wire token sent inside the bridge JSON (`interp` field).
  String get wire => name;
}

/// The off-table v51 WCS distortion (full CD matrix + SIP) stored alongside a
/// captured image's isotropic solve. Mirrors the record returned by
/// `ImagesDao.getStoredWcsDistortion` + `decodeSolvedSip`; all fields default to
/// "absent / no distortion" so a plain isotropic solve constructs cleanly.
class SolvedWcsDistortion {
  final double? cd1_1;
  final double? cd1_2;
  final double? cd2_1;
  final double? cd2_2;
  final int aOrder;
  final int bOrder;
  final List<double> aCoeffs;
  final List<double> bCoeffs;
  final int apOrder;
  final int bpOrder;
  final List<double> apCoeffs;
  final List<double> bpCoeffs;

  const SolvedWcsDistortion({
    this.cd1_1,
    this.cd1_2,
    this.cd2_1,
    this.cd2_2,
    this.aOrder = 0,
    this.bOrder = 0,
    this.aCoeffs = const [],
    this.bCoeffs = const [],
    this.apOrder = 0,
    this.bpOrder = 0,
    this.apCoeffs = const [],
    this.bpCoeffs = const [],
  });
}

/// One plate-solved light frame ready to be folded into the atlas.
///
/// Carries the on-disk frame path plus the full CD + SIP astrometry it was
/// solved with, expressed as the FITS-convention WCS scalars the native
/// `SipWcs` struct consumes. [toWcsJson] emits exactly the `<SipWcs JSON>`
/// block the bridge `fold` action expects (keys per the contract).
class SolvedFrameRef {
  /// Light-frame path (FITS / XISF / etc.), already plate-solved.
  final String framePath;

  /// Integration weight (<= 0 folds as no contribution).
  final double weight;

  /// Exposure seconds, for the integration-time provenance tally.
  final double exposureSec;

  /// Reference RA / Dec (degrees, J2000) — `crval1` / `crval2`.
  final double crval1;
  final double crval2;

  /// 1-based reference pixel (FITS convention) — `crpix1` / `crpix2`.
  final double crpix1;
  final double crpix2;

  /// Full CD matrix (deg/pixel).
  final double cd1_1;
  final double cd1_2;
  final double cd2_1;
  final double cd2_2;

  /// Forward SIP distortion, row-major `i*(order+1)+j`. `order == 0` (or empty
  /// coefficients) means no forward distortion.
  final int aOrder;
  final int bOrder;
  final List<double> aCoeffs;
  final List<double> bCoeffs;

  /// Inverse SIP distortion (AP/BP). Empty -> the native side falls back to a
  /// Newton iteration for the world->pixel direction.
  final int apOrder;
  final int bpOrder;
  final List<double> apCoeffs;
  final List<double> bpCoeffs;

  const SolvedFrameRef({
    required this.framePath,
    this.weight = 1.0,
    this.exposureSec = 0.0,
    required this.crval1,
    required this.crval2,
    required this.crpix1,
    required this.crpix2,
    required this.cd1_1,
    required this.cd1_2,
    required this.cd2_1,
    required this.cd2_2,
    this.aOrder = 0,
    this.bOrder = 0,
    this.aCoeffs = const [],
    this.bCoeffs = const [],
    this.apOrder = 0,
    this.bpOrder = 0,
    this.apCoeffs = const [],
    this.bpCoeffs = const [],
  });

  /// Build a fold reference from a [SolvedWcs] (the catalog-overlay / science
  /// WCS model) for the frame at [framePath].
  ///
  /// `crval` comes from the solved image centre (RA hours -> degrees), `crpix`
  /// from the image centre in 1-based FITS pixels. The CD matrix is taken
  /// directly when present; otherwise it is reconstructed from the isotropic
  /// pixel scale + rotation using the same sign convention as the native
  /// `WcsInfo::from_plate_solve` (`cd1_1 = -scale*cos`, `cd1_2 = scale*sin`,
  /// `cd2_1 = scale*sin`, `cd2_2 = scale*cos`), so a CD-only and a
  /// scale+rotation solve fold onto identical geometry.
  factory SolvedFrameRef.fromSolvedWcs({
    required String framePath,
    required SolvedWcs wcs,
    double weight = 1.0,
    double exposureSec = 0.0,
  }) {
    final crval1 = _normalizeRaDeg(wcs.raHours * 15.0);
    final crval2 = wcs.decDegrees;
    // FITS CRPIX is 1-based and references the image centre for a solve.
    final crpix1 = wcs.imageWidth / 2.0 + 0.5;
    final crpix2 = wcs.imageHeight / 2.0 + 0.5;

    final double cd11, cd12, cd21, cd22;
    if (wcs.hasCdMatrix) {
      cd11 = wcs.cd1_1!;
      cd12 = wcs.cd1_2!;
      cd21 = wcs.cd2_1!;
      cd22 = wcs.cd2_2!;
    } else {
      // Reconstruct from isotropic scale (arcsec/px -> deg/px) + rotation.
      final scaleDeg = wcs.pixelScaleArcsec / 3600.0;
      final rot = wcs.rotationDeg * math.pi / 180.0;
      final cosR = math.cos(rot);
      final sinR = math.sin(rot);
      cd11 = -scaleDeg * cosR;
      cd12 = scaleDeg * sinR;
      cd21 = scaleDeg * sinR;
      cd22 = scaleDeg * cosR;
    }

    return SolvedFrameRef(
      framePath: framePath,
      weight: weight,
      exposureSec: exposureSec,
      crval1: crval1,
      crval2: crval2,
      crpix1: crpix1,
      crpix2: crpix2,
      cd1_1: cd11,
      cd1_2: cd12,
      cd2_1: cd21,
      cd2_2: cd22,
      aOrder: wcs.aOrder,
      bOrder: wcs.bOrder,
      aCoeffs: wcs.aCoeffs,
      bCoeffs: wcs.bCoeffs,
      apOrder: wcs.apOrder,
      bpOrder: wcs.bpOrder,
      apCoeffs: wcs.apCoeffs,
      bpCoeffs: wcs.bpCoeffs,
    );
  }

  /// The `<SipWcs JSON>` block for the bridge fold payload (keys verbatim per
  /// the contract).
  Map<String, dynamic> toWcsJson() => <String, dynamic>{
    'crval1': crval1,
    'crval2': crval2,
    'crpix1': crpix1,
    'crpix2': crpix2,
    'cd1_1': cd1_1,
    'cd1_2': cd1_2,
    'cd2_1': cd2_1,
    'cd2_2': cd2_2,
    'aOrder': aOrder,
    'bOrder': bOrder,
    'aCoeffs': aCoeffs,
    'bCoeffs': bCoeffs,
    'apOrder': apOrder,
    'bpOrder': bpOrder,
    'apCoeffs': apCoeffs,
    'bpCoeffs': bpCoeffs,
  };

  /// The per-frame entry inside the fold action's `frames` array.
  Map<String, dynamic> toFoldFrameJson() => <String, dynamic>{
    'framePath': framePath,
    'weight': weight,
    'exposureSec': exposureSec,
    'wcs': toWcsJson(),
  };

  /// True iff the CD matrix is finite and non-singular — a frame that would
  /// otherwise fail the native invertibility gate is dropped before the fold.
  bool get hasInvertibleWcs {
    if (![cd1_1, cd1_2, cd2_1, cd2_2].every((v) => v.isFinite)) return false;
    final det = cd1_1 * cd2_2 - cd1_2 * cd2_1;
    return det.abs() > 1e-18;
  }

  static double _normalizeRaDeg(double ra) {
    var v = ra % 360.0;
    if (v < 0) v += 360.0;
    return v;
  }
}

/// One tile's contribution within a fold call — decoded from a `foldsByTile`
/// entry plus the post-fold tile state the bridge returns alongside it.
class AtlasFoldTile {
  final int tileId;
  final int framesAdded;
  final double weightAdded;
  final int rejected;
  final double coverageMean;
  final double centerRaDeg;
  final double centerDecDeg;
  final int totalFrames;
  final double integrationSeconds;
  final int channels;

  const AtlasFoldTile({
    required this.tileId,
    required this.framesAdded,
    required this.weightAdded,
    required this.rejected,
    required this.coverageMean,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.totalFrames,
    required this.integrationSeconds,
    required this.channels,
  });

  factory AtlasFoldTile.fromJson(Map<String, dynamic> json) => AtlasFoldTile(
    tileId: (json['tileId'] as num).toInt(),
    framesAdded: (json['framesAdded'] as num?)?.toInt() ?? 0,
    weightAdded: (json['weightAdded'] as num?)?.toDouble() ?? 0.0,
    rejected: (json['rejected'] as num?)?.toInt() ?? 0,
    coverageMean: (json['coverageMean'] as num?)?.toDouble() ?? 0.0,
    centerRaDeg: (json['centerRa'] as num?)?.toDouble() ?? 0.0,
    centerDecDeg: (json['centerDec'] as num?)?.toDouble() ?? 0.0,
    totalFrames: (json['totalFrames'] as num?)?.toInt() ?? 0,
    integrationSeconds: (json['integrationSeconds'] as num?)?.toDouble() ?? 0.0,
    channels: (json['channels'] as num?)?.toInt() ?? 0,
  );
}

/// Result of folding a session's frames into the atlas.
class AtlasFoldSummary {
  /// Ascending, deduplicated ids of every tile the fold touched.
  final List<int> tilesTouched;

  /// Per-tile fold + post-fold-state summaries.
  final List<AtlasFoldTile> tiles;

  /// Frames whose footprint covered no tiles (dropped, not fatal).
  final int framesSkippedNoCoverage;

  const AtlasFoldSummary({
    required this.tilesTouched,
    required this.tiles,
    required this.framesSkippedNoCoverage,
  });

  /// Total frames folded across every touched tile.
  int get totalFramesFolded => tiles.fold(0, (sum, t) => sum + t.framesAdded);

  factory AtlasFoldSummary.fromJson(Map<String, dynamic> json) {
    final touched = (json['tilesTouched'] as List? ?? const [])
        .map((v) => (v as num).toInt())
        .toList(growable: false);
    final tiles = (json['foldsByTile'] as List? ?? const [])
        .map((e) => AtlasFoldTile.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return AtlasFoldSummary(
      tilesTouched: touched,
      tiles: tiles,
      framesSkippedNoCoverage:
          (json['framesSkippedNoCoverage'] as num?)?.toInt() ?? 0,
    );
  }

  static const empty = AtlasFoldSummary(
    tilesTouched: [],
    tiles: [],
    framesSkippedNoCoverage: 0,
  );
}

/// Coverage summary for one materialized tile (the heat-overlay / gallery row).
class AtlasTileCoverage {
  final int tileId;
  final double centerRaDeg;
  final double centerDecDeg;
  final double coverageMean;
  final int totalFrames;
  final double integrationSeconds;
  final String? lastFoldIso;
  final int channels;

  const AtlasTileCoverage({
    required this.tileId,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.coverageMean,
    required this.totalFrames,
    required this.integrationSeconds,
    required this.lastFoldIso,
    required this.channels,
  });

  factory AtlasTileCoverage.fromJson(Map<String, dynamic> json) =>
      AtlasTileCoverage(
        tileId: (json['tileId'] as num).toInt(),
        centerRaDeg: (json['centerRa'] as num?)?.toDouble() ?? 0.0,
        centerDecDeg: (json['centerDec'] as num?)?.toDouble() ?? 0.0,
        coverageMean: (json['coverageMean'] as num?)?.toDouble() ?? 0.0,
        totalFrames: (json['totalFrames'] as num?)?.toInt() ?? 0,
        integrationSeconds:
            (json['integrationSeconds'] as num?)?.toDouble() ?? 0.0,
        lastFoldIso: json['lastFoldIso'] as String?,
        channels: (json['channels'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tileId': tileId,
    'centerRaDeg': centerRaDeg,
    'centerDecDeg': centerDecDeg,
    'coverageMean': coverageMean,
    'totalFrames': totalFrames,
    'integrationSeconds': integrationSeconds,
    'lastFoldIso': lastFoldIso,
    'channels': channels,
  };
}

/// One fold entry inside a tile's provenance log.
class TileFoldView {
  final int framesAdded;
  final double weightAdded;
  final double integrationSecondsAdded;
  final int rejected;
  final String label;
  final String contributor;

  const TileFoldView({
    required this.framesAdded,
    required this.weightAdded,
    required this.integrationSecondsAdded,
    required this.rejected,
    required this.label,
    required this.contributor,
  });

  factory TileFoldView.fromJson(Map<String, dynamic> json) => TileFoldView(
    framesAdded: (json['framesAdded'] as num?)?.toInt() ?? 0,
    weightAdded: (json['weightAdded'] as num?)?.toDouble() ?? 0.0,
    integrationSecondsAdded:
        (json['integrationSecondsAdded'] as num?)?.toDouble() ?? 0.0,
    rejected: (json['rejected'] as num?)?.toInt() ?? 0,
    label: json['label'] as String? ?? '',
    contributor: json['contributor'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'framesAdded': framesAdded,
    'weightAdded': weightAdded,
    'integrationSecondsAdded': integrationSecondsAdded,
    'rejected': rejected,
    'label': label,
    'contributor': contributor,
  };
}

/// Decoded provenance for a single tile (the `info` action result).
class TileProvenanceView {
  final int tileId;
  final double centerRaDeg;
  final double centerDecDeg;
  final int channels;
  final double coverageMean;
  final int totalFrames;
  final double totalIntegrationSeconds;
  final List<String> contributors;
  final List<TileFoldView> folds;

  const TileProvenanceView({
    required this.tileId,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.channels,
    required this.coverageMean,
    required this.totalFrames,
    required this.totalIntegrationSeconds,
    required this.contributors,
    required this.folds,
  });

  factory TileProvenanceView.fromJson(int tileId, Map<String, dynamic> json) {
    final prov =
        (json['provenance'] as Map?)?.cast<String, dynamic>() ?? const {};
    final folds = (prov['folds'] as List? ?? const [])
        .map((e) => TileFoldView.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    final contributors = (prov['contributors'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);
    return TileProvenanceView(
      tileId: tileId,
      centerRaDeg: (json['centerRa'] as num?)?.toDouble() ?? 0.0,
      centerDecDeg: (json['centerDec'] as num?)?.toDouble() ?? 0.0,
      channels: (json['channels'] as num?)?.toInt() ?? 0,
      coverageMean: (json['coverageMean'] as num?)?.toDouble() ?? 0.0,
      totalFrames: (prov['totalFrames'] as num?)?.toInt() ?? 0,
      totalIntegrationSeconds:
          (prov['totalIntegrationSeconds'] as num?)?.toDouble() ?? 0.0,
      contributors: contributors,
      folds: folds,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tileId': tileId,
    'centerRaDeg': centerRaDeg,
    'centerDecDeg': centerDecDeg,
    'channels': channels,
    'coverageMean': coverageMean,
    'totalFrames': totalFrames,
    'totalIntegrationSeconds': totalIntegrationSeconds,
    'contributors': contributors,
    'folds': folds.map((f) => f.toJson()).toList(growable: false),
  };
}

/// One point on a region's deepening growth curve: a single night (fold label)
/// with the frames / integration it added and the cumulative running totals.
class AtlasGrowthPoint {
  /// Fold label (an ISO date for an auto-fold, else a session id).
  final String label;
  final int framesAdded;
  final double secondsAdded;
  final int cumulativeFrames;
  final double cumulativeSeconds;
  final String contributor;

  const AtlasGrowthPoint({
    required this.label,
    required this.framesAdded,
    required this.secondsAdded,
    required this.cumulativeFrames,
    required this.cumulativeSeconds,
    required this.contributor,
  });

  factory AtlasGrowthPoint.fromJson(Map<String, dynamic> json) =>
      AtlasGrowthPoint(
        label: json['label'] as String? ?? '',
        framesAdded: (json['framesAdded'] as num?)?.toInt() ?? 0,
        secondsAdded: (json['secondsAdded'] as num?)?.toDouble() ?? 0.0,
        cumulativeFrames: (json['cumulativeFrames'] as num?)?.toInt() ?? 0,
        cumulativeSeconds:
            (json['cumulativeSeconds'] as num?)?.toDouble() ?? 0.0,
        contributor: json['contributor'] as String? ?? '',
      );

  /// Parse the fold label as a calendar day when it is an ISO date; null for a
  /// non-dated (session-id) label, so the chart can fall back to point index.
  DateTime? get date => DateTime.tryParse(label);
}

/// A region's deepening growth curve — the cumulative-integration-vs-night
/// series the bridge `growth` action returns (and the host's
/// `/api/atlas/region/<id>/timeline` payload mirrors under `growth`), decoded
/// once for the region-detail chart. Points are chronological (one per fold
/// label / night), totals are the region cone's lifetime sums.
class AtlasGrowthCurve {
  final List<AtlasGrowthPoint> points;
  final int totalFrames;
  final double totalSeconds;

  const AtlasGrowthCurve({
    required this.points,
    required this.totalFrames,
    required this.totalSeconds,
  });

  static const AtlasGrowthCurve empty = AtlasGrowthCurve(
    points: [],
    totalFrames: 0,
    totalSeconds: 0.0,
  );

  factory AtlasGrowthCurve.fromJson(Map<String, dynamic> json) {
    final raw = json['points'];
    final points = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(AtlasGrowthPoint.fromJson)
              .toList(growable: false)
        : const <AtlasGrowthPoint>[];
    return AtlasGrowthCurve(
      points: points,
      totalFrames: (json['totalFrames'] as num?)?.toInt() ?? 0,
      totalSeconds: (json['totalSeconds'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
