import 'package:freezed_annotation/freezed_annotation.dart';

import '../services/wcs/gnomonic_projection.dart';
import '../services/wcs/wcs_sip_codec.dart';

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
    // The solver's CD matrix (deg/pixel). It carries the frame's parity,
    // which [rotation] cannot; null on solves that reported none.
    double? cd1_1,
    double? cd1_2,
    double? cd2_1,
    double? cd2_2,
    // SIP distortion block in the `solved_sip` encoding (wcs_sip_codec).
    String? sip,
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

/// Pixel <-> sky through the canonical TAN projection (services/wcs), so
/// annotation, click-to-identify and the celestial grid map the frame the
/// same way the science pipeline does. RA here is in degrees. Pixel
/// coordinates are 0-based with integers at pixel centres.
extension PlateSolveDataExtensions on PlateSolveData {
  /// The projection-model form of this solve.
  SolvedWcs toSolvedWcs() {
    final distortion = decodeSolvedSip(sip);
    return SolvedWcs(
      raHours: ra / 15.0,
      decDegrees: dec,
      rotationDeg: rotation,
      pixelScaleArcsec: pixelScale,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      cd1_1: cd1_1,
      cd1_2: cd1_2,
      cd2_1: cd2_1,
      cd2_2: cd2_2,
      aOrder: distortion?.aOrder ?? 0,
      bOrder: distortion?.bOrder ?? 0,
      aCoeffs: distortion?.aCoeffs ?? const [],
      bCoeffs: distortion?.bCoeffs ?? const [],
      apOrder: distortion?.apOrder ?? 0,
      bpOrder: distortion?.bpOrder ?? 0,
      apCoeffs: distortion?.apCoeffs ?? const [],
      bpCoeffs: distortion?.bpCoeffs ?? const [],
    );
  }

  GnomonicProjection? get _projection {
    final wcs = toSolvedWcs();
    return wcs.isValid ? GnomonicProjection(wcs) : null;
  }

  /// Convert sky coordinates (RA/Dec degrees) to image pixel coordinates, or
  /// null when the point is off the frame or behind the tangent plane.
  ({double x, double y})? skyToPixel(double ra, double dec) {
    final p = _projection?.worldToPixel(raDegrees: ra, decDegrees: dec);
    if (p == null || !p.onImage) return null;
    return (x: p.pixel.x, y: p.pixel.y);
  }

  /// Convert sky coordinates (RA/Dec) to image pixel coordinates without
  /// clamping to image bounds. Returns null only if the point is behind the
  /// tangent plane. Used for overlays like coordinate grids that need to draw
  /// lines extending to image edges.
  ({double x, double y})? skyToPixelUnclamped(double ra, double dec) {
    final p = _projection?.worldToPixel(raDegrees: ra, decDegrees: dec);
    if (p == null) return null;
    return (x: p.pixel.x, y: p.pixel.y);
  }

  /// Convert image pixel coordinates to sky coordinates (RA/Dec degrees).
  ({double ra, double dec}) pixelToSky(double x, double y) {
    final projection = _projection;
    if (projection == null) return (ra: ra, dec: dec);
    final sky = projection.pixelToWorld(x: x, y: y);
    return (ra: sky.raDegrees, dec: sky.decDegrees);
  }
}
