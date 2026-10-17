import 'dart:math' as math;
import 'dart:ui';

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

  /// Convert pixel coordinates to celestial coordinates (RA/Dec)
  (double ra, double dec) pixelToCelestial(double x, double y) {
    // Simple TAN projection
    final dx = (x - crpix1) * cdelt1;
    final dy = (y - crpix2) * cdelt2;

    // Apply rotation
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

  /// Convert celestial coordinates to pixel coordinates
  (double x, double y) celestialToPixel(double ra, double dec) {
    // Inverse TAN projection
    final raDelta = _normalizeDeltaDegrees(ra - crval1);
    final dx2 = raDelta * math.cos(crval2 * math.pi / 180);
    final dy2 = dec - crval2;

    // Apply inverse rotation
    final angle = -crota2 * math.pi / 180;
    final dx = dx2 * math.cos(angle) - dy2 * math.sin(angle);
    final dy = dx2 * math.sin(angle) + dy2 * math.cos(angle);

    final x = crpix1 + dx / _safeScale(cdelt1);
    final y = crpix2 + dy / _safeScale(cdelt2);

    return (x, y);
  }

  /// Get the image center in celestial coordinates
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

/// WCS grid overlay painter
class WcsGridPainter {
  final WcsOverlay wcs;
  final Size imageSize;
  final Color gridColor;
  final double gridOpacity;

  WcsGridPainter({
    required this.wcs,
    required this.imageSize,
    this.gridColor = const Color(0xFF4FC3F7),
    this.gridOpacity = 0.5,
  });

  /// Generate grid lines for drawing
  List<GridLine> generateGridLines({
    double raSpacing = 1.0, // degrees
    double decSpacing = 1.0, // degrees
  }) {
    final lines = <GridLine>[];
    final fov = wcs.fieldOfView(
      imageSize.width.toInt(),
      imageSize.height.toInt(),
    );

    // Generate RA lines
    final raStart = (wcs.crval1 - fov.$1 / 2).floor().toDouble();
    final raEnd = (wcs.crval1 + fov.$1 / 2).ceil().toDouble();

    for (var ra = raStart; ra <= raEnd; ra += raSpacing) {
      final points = <Offset>[];
      final decStart = wcs.crval2 - fov.$2 / 2;
      final decEnd = wcs.crval2 + fov.$2 / 2;

      for (var dec = decStart; dec <= decEnd; dec += 0.1) {
        final (x, y) = wcs.celestialToPixel(ra, dec);
        if (x >= 0 && x < imageSize.width && y >= 0 && y < imageSize.height) {
          points.add(Offset(x, y));
        }
      }

      if (points.length >= 2) {
        lines.add(
          GridLine(
            points: points,
            label: '${(ra / 15).toStringAsFixed(1)}h',
            type: GridLineType.ra,
          ),
        );
      }
    }

    // Generate Dec lines
    final decStart = (wcs.crval2 - fov.$2 / 2).floor().toDouble();
    final decEnd = (wcs.crval2 + fov.$2 / 2).ceil().toDouble();

    for (var dec = decStart; dec <= decEnd; dec += decSpacing) {
      final points = <Offset>[];
      final raStartLine = wcs.crval1 - fov.$1 / 2;
      final raEndLine = wcs.crval1 + fov.$1 / 2;

      for (var ra = raStartLine; ra <= raEndLine; ra += 0.1) {
        final (x, y) = wcs.celestialToPixel(ra, dec);
        if (x >= 0 && x < imageSize.width && y >= 0 && y < imageSize.height) {
          points.add(Offset(x, y));
        }
      }

      if (points.length >= 2) {
        lines.add(
          GridLine(
            points: points,
            label: '${dec.toStringAsFixed(0)}°',
            type: GridLineType.dec,
          ),
        );
      }
    }

    return lines;
  }
}

/// Grid line data
class GridLine {
  final List<Offset> points;
  final String label;
  final GridLineType type;

  GridLine({required this.points, required this.label, required this.type});
}

/// Grid line type
enum GridLineType { ra, dec }

/// Annotation for catalog objects
class WcsAnnotation {
  final String name;
  final String catalog;
  final double ra; // hours
  final double dec; // degrees
  final double? magnitude;
  final double? sizeArcMin;

  WcsAnnotation({
    required this.name,
    required this.catalog,
    required this.ra,
    required this.dec,
    this.magnitude,
    this.sizeArcMin,
  });

  /// Get pixel position on image
  Offset? pixelPosition(WcsOverlay wcs, Size imageSize) {
    final (x, y) = wcs.celestialToPixel(ra * 15, dec);
    if (x >= 0 && x < imageSize.width && y >= 0 && y < imageSize.height) {
      return Offset(x, y);
    }
    return null;
  }
}
