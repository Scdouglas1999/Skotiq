import 'dart:math' as math;
import 'package:freezed_annotation/freezed_annotation.dart';

part 'annotation_data.freezed.dart';
part 'annotation_data.g.dart';

/// Type of celestial object for visual differentiation
enum ObjectType {
  galaxy,
  nebula,
  starCluster,
  planetaryNebula,
  star,
  doubleStar,
  asterism,
  unknown,
}

/// Classification of star types for detailed information
enum SpectralClass {
  o, // Blue, very hot
  b, // Blue-white
  a, // White
  f, // Yellow-white
  g, // Yellow (like our Sun)
  k, // Orange
  m, // Red
  unknown,
}

@freezed
abstract class ImageAnnotation with _$ImageAnnotation {
  const factory ImageAnnotation({
    required String imagePath,
    required DateTime timestamp,
    required PlateSolveData plateSolve,
    required List<CelestialObjectAnnotation> objects,
    @Default(true) bool visible,
  }) = _ImageAnnotation;

  factory ImageAnnotation.fromJson(Map<String, dynamic> json) =>
      _$ImageAnnotationFromJson(json);
}

@freezed
abstract class PlateSolveData with _$PlateSolveData {
  const factory PlateSolveData({
    required double ra,
    required double dec,
    required double pixelScale, // arcsec/pixel
    required double rotation, // degrees
    required double fieldWidth, // degrees
    required double fieldHeight, // degrees
    required int imageWidth, // pixels
    required int imageHeight, // pixels
  }) = _PlateSolveData;

  factory PlateSolveData.fromJson(Map<String, dynamic> json) =>
      _$PlateSolveDataFromJson(json);
}

@freezed
abstract class CelestialObjectAnnotation with _$CelestialObjectAnnotation {
  const factory CelestialObjectAnnotation({
    required String id,
    required String name,
    required ObjectType type,
    required double ra, // J2000
    required double dec, // J2000
    required double x, // Image pixel X
    required double y, // Image pixel Y
    String? catalogId, // e.g., "NGC 224", "M 31"
    String? commonName, // Common name (e.g., "Andromeda Galaxy")
    double? magnitude,
    double? size, // arcminutes
    ObjectData? detailedData,
    @Default(true) bool visible,
  }) = _CelestialObjectAnnotation;

  factory CelestialObjectAnnotation.fromJson(Map<String, dynamic> json) =>
      _$CelestialObjectAnnotationFromJson(json);
}

@freezed
abstract class ObjectData with _$ObjectData {
  const factory ObjectData({
    // Basic info
    String? description,
    String? objectClass, // e.g., "Spiral Galaxy", "Open Cluster"
    // Stellar data (for stars)
    SpectralClass? spectralType,
    double? temperature, // Kelvin
    double? mass, // Solar masses
    double? radius, // Solar radii
    double? luminosity, // Solar luminosities
    double? distance, // parsecs
    double? parallax, // milliarcseconds
    String? properMotion,

    // Exoplanet data
    List<ExoplanetData>? exoplanets,

    // DSO data (galaxies, nebulae, clusters)
    double? surfaceBrightness,
    double? redshift,
    String? morphology,

    // External references
    String? simbadId,
    String? wikipediaUrl,
    Map<String, String>? catalogIds, // {"NGC": "224", "M": "31"}
    // Cache metadata
    DateTime? lastUpdated,
    String? dataSource, // "SIMBAD", "Gaia", "Exoplanet Archive"
  }) = _ObjectData;

  factory ObjectData.fromJson(Map<String, dynamic> json) =>
      _$ObjectDataFromJson(json);
}

@freezed
abstract class ExoplanetData with _$ExoplanetData {
  const factory ExoplanetData({
    required String name,
    double? mass, // Jupiter masses
    double? radius, // Jupiter radii
    double? orbitalPeriod, // days
    double? semiMajorAxis, // AU
    double? eccentricity,
    String? discoveryMethod,
    int? discoveryYear,
    double? equilibriumTemp, // Kelvin
  }) = _ExoplanetData;

  factory ExoplanetData.fromJson(Map<String, dynamic> json) =>
      _$ExoplanetDataFromJson(json);
}

/// Helper extension for coordinate transformations
extension PlateSolveDataExtensions on PlateSolveData {
  /// Convert sky coordinates (RA/Dec) to image pixel coordinates
  ({double x, double y})? skyToPixel(double ra, double dec) {
    // Convert RA/Dec to standard coordinates
    final raRad = ra * (3.141592653589793 / 180.0);
    final decRad = dec * (3.141592653589793 / 180.0);
    final centerRaRad = this.ra * (3.141592653589793 / 180.0);
    final centerDecRad = this.dec * (3.141592653589793 / 180.0);

    // Simple gnomonic projection (tangent plane)
    final cosDec = math.cos(decRad);
    final sinDec = math.sin(decRad);
    final cosCenterDec = math.cos(centerDecRad);
    final sinCenterDec = math.sin(centerDecRad);
    final dRa = raRad - centerRaRad;

    final denominator =
        sinCenterDec * sinDec + cosCenterDec * cosDec * math.cos(dRa);

    if (denominator <= 0) {
      // Object is behind the tangent plane
      return null;
    }

    final xi = cosDec * math.sin(dRa) / denominator;
    final eta =
        (cosCenterDec * sinDec - sinCenterDec * cosDec * math.cos(dRa)) /
        denominator;

    // Convert to degrees
    final xiDeg = xi * (180.0 / 3.141592653589793);
    final etaDeg = eta * (180.0 / 3.141592653589793);

    // Account for rotation and convert to pixels
    final rotRad = rotation * (3.141592653589793 / 180.0);
    final cosRot = math.cos(rotRad);
    final sinRot = math.sin(rotRad);

    final xiRot = xiDeg * cosRot - etaDeg * sinRot;
    final etaRot = xiDeg * sinRot + etaDeg * cosRot;

    // Convert from degrees to pixels
    final xPixels = (xiRot * 3600.0 / pixelScale) + imageWidth / 2;
    final yPixels = (imageHeight / 2) - (etaRot * 3600.0 / pixelScale);

    // Check if within image bounds
    if (xPixels < 0 ||
        xPixels >= imageWidth ||
        yPixels < 0 ||
        yPixels >= imageHeight) {
      return null;
    }

    return (x: xPixels, y: yPixels);
  }

  /// Convert sky coordinates (RA/Dec) to image pixel coordinates without
  /// clamping to image bounds. Returns null only if the point is behind the
  /// tangent plane. Used for overlays like coordinate grids that need to draw
  /// lines extending to image edges.
  ({double x, double y})? skyToPixelUnclamped(double ra, double dec) {
    final raRad = ra * (3.141592653589793 / 180.0);
    final decRad = dec * (3.141592653589793 / 180.0);
    final centerRaRad = this.ra * (3.141592653589793 / 180.0);
    final centerDecRad = this.dec * (3.141592653589793 / 180.0);

    final cosDec = math.cos(decRad);
    final sinDec = math.sin(decRad);
    final cosCenterDec = math.cos(centerDecRad);
    final sinCenterDec = math.sin(centerDecRad);
    final dRa = raRad - centerRaRad;

    final denominator =
        sinCenterDec * sinDec + cosCenterDec * cosDec * math.cos(dRa);
    if (denominator <= 0) {
      return null;
    }

    final xi = cosDec * math.sin(dRa) / denominator;
    final eta =
        (cosCenterDec * sinDec - sinCenterDec * cosDec * math.cos(dRa)) /
        denominator;

    final xiDeg = xi * (180.0 / 3.141592653589793);
    final etaDeg = eta * (180.0 / 3.141592653589793);

    final rotRad = rotation * (3.141592653589793 / 180.0);
    final cosRot = math.cos(rotRad);
    final sinRot = math.sin(rotRad);

    final xiRot = xiDeg * cosRot - etaDeg * sinRot;
    final etaRot = xiDeg * sinRot + etaDeg * cosRot;

    final xPixels = (xiRot * 3600.0 / pixelScale) + imageWidth / 2;
    final yPixels = (imageHeight / 2) - (etaRot * 3600.0 / pixelScale);

    return (x: xPixels, y: yPixels);
  }

  /// Convert image pixel coordinates to sky coordinates (RA/Dec)
  ({double ra, double dec}) pixelToSky(double x, double y) {
    // Convert pixels to degrees from center
    final xDeg = (x - imageWidth / 2) * pixelScale / 3600.0;
    final yDeg = (imageHeight / 2 - y) * pixelScale / 3600.0;

    // Account for rotation
    final rotRad = rotation * (3.141592653589793 / 180.0);
    final cosRot = math.cos(rotRad);
    final sinRot = math.sin(rotRad);

    final xi = xDeg * cosRot + yDeg * sinRot;
    final eta = -xDeg * sinRot + yDeg * cosRot;

    // Convert to radians
    final xiRad = xi * (3.141592653589793 / 180.0);
    final etaRad = eta * (3.141592653589793 / 180.0);

    // Inverse gnomonic projection
    final centerRaRad = ra * (3.141592653589793 / 180.0);
    final centerDecRad = dec * (3.141592653589793 / 180.0);

    final rho = math.sqrt(xiRad * xiRad + etaRad * etaRad);
    if (rho < 1e-12) {
      var raCenter = ra;
      while (raCenter < 0) {
        raCenter += 360;
      }
      while (raCenter >= 360) {
        raCenter -= 360;
      }
      return (ra: raCenter, dec: dec);
    }
    final c = math.atan(rho);

    final sinC = math.sin(c);
    final cosC = math.cos(c);
    final sinCenterDec = math.sin(centerDecRad);
    final cosCenterDec = math.cos(centerDecRad);

    final decRad = math.asin(
      cosC * sinCenterDec + etaRad * sinC * cosCenterDec / rho,
    );
    final raRad =
        centerRaRad +
        math.atan2(
          xiRad * sinC,
          rho * cosCenterDec * cosC - etaRad * sinCenterDec * sinC,
        );

    var raResult = raRad * (180.0 / 3.141592653589793);
    final decResult = decRad * (180.0 / 3.141592653589793);

    // Normalize RA to 0-360
    while (raResult < 0) {
      raResult += 360;
    }
    while (raResult >= 360) {
      raResult -= 360;
    }

    return (ra: raResult, dec: decResult);
  }
}
