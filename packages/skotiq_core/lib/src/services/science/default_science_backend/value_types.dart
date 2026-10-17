part of '../default_science_backend.dart';

class _ProjectedCatalogStar {
  final String id;
  final double x;
  final double y;
  final double mag;

  const _ProjectedCatalogStar({
    required this.id,
    required this.x,
    required this.y,
    required this.mag,
  });
}

class _CatalogMatch {
  final StarMeasurement detected;
  final double catalogX;
  final double catalogY;
  final double catalogMag;

  const _CatalogMatch({
    required this.detected,
    required this.catalogX,
    required this.catalogY,
    required this.catalogMag,
  });
}

class _LinearFitResult {
  final double slope;
  final double intercept;
  final double rms;

  const _LinearFitResult({
    required this.slope,
    required this.intercept,
    required this.rms,
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
double computePixelMotionPositionAngle({
  required double dxPixels,
  required double dyPixels,
  required double wcsRotationDegrees,
}) {
  // Pixel Y axis is flipped relative to celestial North.
  final dxUp = dxPixels;
  final dyUp = -dyPixels;
  final rotRad = wcsRotationDegrees * math.pi / 180.0;
  final cosR = math.cos(rotRad);
  final sinR = math.sin(rotRad);
  // Inverse rotation (transpose of standard 2D R) takes the image-up vector
  // to the celestial-N/E frame.
  final dxSky = dxUp * cosR + dyUp * sinR;
  final dySky = -dxUp * sinR + dyUp * cosR;
  // PA is measured from North (+sky-Y) through East (+sky-X), which is
  // exactly atan2(east, north).
  final pa = (math.atan2(dxSky, dySky) * 180.0 / math.pi + 360.0) % 360.0;
  return pa;
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
