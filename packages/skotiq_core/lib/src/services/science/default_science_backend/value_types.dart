part of '../default_science_backend.dart';

class _ProjectedCatalogStar {
  final String id;
  final double x;
  final double y;
  final PhotometricCatalogStar star;

  const _ProjectedCatalogStar({
    required this.id,
    required this.x,
    required this.y,
    required this.star,
  });
}

class _CatalogMatch {
  final StarMeasurement detected;
  final double catalogX;
  final double catalogY;
  final PhotometricCatalogStar catalogStar;

  const _CatalogMatch({
    required this.detected,
    required this.catalogX,
    required this.catalogY,
    required this.catalogStar,
  });

  /// Johnson V, the magnitude astrometric matching ranks by.
  double get catalogMag => catalogStar.magV;

  double get separationPx {
    final dx = detected.x - catalogX;
    final dy = detected.y - catalogY;
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// Stars detected on a frame plus the detector's frame-level measurements.
class _DetectedField {
  final List<StarMeasurement> stars;

  /// Per-pixel background noise in ADU, measured by the detector.
  final double noiseAdu;

  /// Median star FWHM in pixels.
  final double medianFwhm;

  const _DetectedField({
    required this.stars,
    required this.noiseAdu,
    required this.medianFwhm,
  });
}

class _QualityResult {
  final ScienceFrameQualityMetrics frame;
  final List<ScienceTileMetric> tiles;

  const _QualityResult({required this.frame, required this.tiles});
}

final scienceBackendProvider = Provider<ScienceBackend>((ref) {
  return DefaultScienceBackend(ref);
});

/// Convert a pixel-space motion vector (dxPixels, dyPixels in image pixels)
/// to a celestial position angle measured North-through-East in degrees,
/// given a WCS rotation in degrees.
///
/// WHY: the rotation convention here is "WCS rotation = angle from celestial
/// North to image up (after the standard pixel-Y → sky-Y flip)", matching
/// the FITS CROTA2 sense used by ASTAP and Astrometry.net. Under that
/// convention the inverse-rotation matrix is the *transpose* of the standard
/// 2D rotation, which is what we apply here. If a future plate solver
/// reports rotation in the opposite sense, flip the sign of `wcsRotationDegrees`
/// at the boundary rather than rewriting this transform.
///
/// Visible for tests so the convention can be verified against known WCS
/// solutions and MPC astrometric reports.
/// Position angle in degrees (north through east, [0, 360)) of the motion
/// from one sky position to another.
double skyPositionAngleDegrees({
  required double fromRaDegrees,
  required double fromDecDegrees,
  required double toRaDegrees,
  required double toDecDegrees,
}) {
  const rad = math.pi / 180.0;
  var dRa = (toRaDegrees - fromRaDegrees) % 360.0;
  if (dRa > 180.0) dRa -= 360.0;
  final d1 = fromDecDegrees * rad;
  final d2 = toDecDegrees * rad;
  final y = math.sin(dRa * rad) * math.cos(d2);
  final x =
      math.cos(d1) * math.sin(d2) -
      math.sin(d1) * math.cos(d2) * math.cos(dRa * rad);
  return (math.atan2(y, x) / rad + 360.0) % 360.0;
}

/// Error codes emitted by photometric calibration when a structured failure
/// must propagate to the caller (UI / handler) instead of producing a
/// poisoned database row.
enum ScienceCalibrationErrorCode {
  /// Photometric fit produced a non-finite zero-point or RMS.
  fitFailed,
}

class ScienceCalibrationError implements Exception {
  final ScienceCalibrationErrorCode code;
  final String message;

  const ScienceCalibrationError({required this.code, required this.message});

  @override
  String toString() => 'ScienceCalibrationError(${code.name}): $message';
}

/// Error codes emitted by line-ratio computation when the inputs cannot
/// produce a meaningful ratio. The UI must render an explicit error tile;
/// fake-zero ratios must never be persisted.
enum LineRatioErrorCode { dimensionMismatch, emptyPixelData }

class LineRatioError implements Exception {
  final LineRatioErrorCode code;
  final String message;

  const LineRatioError({required this.code, required this.message});

  @override
  String toString() => 'LineRatioError(${code.name}): $message';
}
