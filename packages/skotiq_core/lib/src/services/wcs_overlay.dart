import 'dart:math' as math;

/// WCS (World Coordinate System) overlay for images
class WcsOverlay {
  static const double _epsilon = 1e-9;

  final double crpix1; // Reference pixel X
  final double crpix2; // Reference pixel Y
  final double crval1; // Reference RA (degrees)
  final double crval2; // Reference Dec (degrees)
  final double cdelt1; // Pixel scale X (degrees/pixel)
  final double cdelt2; // Pixel scale Y (degrees/pixel)
  final double crota2; // Rotation angle (degrees)

  WcsOverlay({
    required this.crpix1,
    required this.crpix2,
    required this.crval1,
    required this.crval2,
    required this.cdelt1,
    required this.cdelt2,
    this.crota2 = 0,
  });

  /// The overlay equivalent to a CD matrix, parity included.
  ///
  /// The overlay maps through `CD = R(crota2) · diag(cdelt1, cdelt2)`, so
  /// `cdelt2 = ‖(cd1_2, cd2_2)‖`, `crota2 = atan2(−cd1_2, cd2_2)` and
  /// `cdelt1` is column one projected on the rotated x axis: negative for the
  /// sky's own parity (east left of north) and positive for a frame seen
  /// through one mirror, such as a Newtonian's.
  factory WcsOverlay.fromCd({
    required double crpix1,
    required double crpix2,
    required double crval1,
    required double crval2,
    required double cd1_1,
    required double cd1_2,
    required double cd2_1,
    required double cd2_2,
  }) {
    final cdelt2 = math.sqrt(cd1_2 * cd1_2 + cd2_2 * cd2_2);
    final rho = math.atan2(-cd1_2, cd2_2);
    final cdelt1 = cd1_1 * math.cos(rho) + cd2_1 * math.sin(rho);
    return WcsOverlay(
      crpix1: crpix1,
      crpix2: crpix2,
      crval1: crval1,
      crval2: crval2,
      cdelt1: cdelt1,
      cdelt2: cdelt2,
      crota2: rho * 180 / math.pi,
    );
  }

  (double ra, double dec) pixelToCelestial(double x, double y) {
    // Simple TAN projection
    final dx = (x - crpix1) * cdelt1;
    final dy = (y - crpix2) * cdelt2;

    final angle = crota2 * math.pi / 180;
    final dx2 = dx * math.cos(angle) - dy * math.sin(angle);
    final dy2 = dx * math.sin(angle) + dy * math.cos(angle);

    // Convert to spherical. RA is undefined exactly at the pole; keep the
    // overlay finite by preserving the reference RA when the denominator is
    // numerically singular.
    final cosRefDec = math.cos(crval2 * math.pi / 180);
    final raOffset = cosRefDec.abs() < _epsilon ? 0.0 : dx2 / cosRefDec;
    final ra = _normalizeDegrees(crval1 + raOffset);
    final dec = (crval2 + dy2).clamp(-90.0, 90.0);

    return (ra, dec);
  }

  (double x, double y) celestialToPixel(double ra, double dec) {
    // Inverse TAN projection
    final raDelta = _normalizeDeltaDegrees(ra - crval1);
    final dx2 = raDelta * math.cos(crval2 * math.pi / 180);
    final dy2 = dec - crval2;

    final angle = -crota2 * math.pi / 180;
    final dx = dx2 * math.cos(angle) - dy2 * math.sin(angle);
    final dy = dx2 * math.sin(angle) + dy2 * math.cos(angle);

    final x = crpix1 + dx / _safeScale(cdelt1);
    final y = crpix2 + dy / _safeScale(cdelt2);

    return (x, y);
  }

  (double ra, double dec) get imageCenter {
    return (crval1 / 15, crval2); // RA in hours, Dec in degrees
  }

  /// Get the field of view in degrees
  (double width, double height) fieldOfView(int imageWidth, int imageHeight) {
    final width = imageWidth.abs() * cdelt1.abs();
    final height = imageHeight.abs() * cdelt2.abs();
    return (width, height);
  }

  /// Get the pixel scale in arcseconds per pixel
  double get pixelScale => cdelt1.abs() * 3600;

  static double _normalizeDegrees(double degrees) {
    var normalized = degrees % 360.0;
    if (normalized < 0) normalized += 360.0;
    return normalized;
  }

  static double _normalizeDeltaDegrees(double degrees) {
    var normalized = degrees % 360.0;
    if (normalized > 180.0) normalized -= 360.0;
    if (normalized < -180.0) normalized += 360.0;
    return normalized;
  }

  static double _safeScale(double value) {
    if (value.abs() >= _epsilon) return value;
    return value.isNegative ? -_epsilon : _epsilon;
  }
}

