import 'dart:async';

import 'package:skotiq_astro/skotiq_astro.dart';

import '../models/imaging/annotation.dart';
import 'wcs_overlay.dart';

/// A DSO cone search over the deep-sky catalog: the OpenNGC rows within
/// [radiusDegrees] of ([ra], [dec]) in degrees, optionally magnitude-limited.
///
/// Mirrors `CatalogManager.searchDsoNearby`. Injected as a closure so the
/// service runs against an in-memory catalog stub in tests.
typedef DsoConeSearch =
    Future<List<DeepSkyObject>> Function({
      required double ra,
      required double dec,
      required double radiusDegrees,
      double? maxMagnitude,
    });

/// A named-star cone search over the photometric catalog: the [Star]s within
/// [radiusDegrees] of [center], optionally magnitude-limited.
///
/// Mirrors `HygStarCatalog.getStarsNear`.
typedef StarConeSearchForAnnotation =
    Future<List<Star>> Function(
      CelestialCoordinate center,
      double radiusDegrees, {
      double? maxMagnitude,
    });

/// Builds the catalog-powered [AnnotationLayer] drawn over a finished master:
/// labelled, kinded markers at pixel positions for the deep-sky objects and
/// named bright stars that fall inside the master's field.
///
/// The pipeline (per the Smart Morning Report design, Pillar 3):
///  1. **Cone-search** the DSO catalog ([CatalogManager.searchDsoNearby]) and
///     the star catalog ([HygStarCatalog.getStarsNear]) over the master's field,
///     centred on the WCS reference, radius = half the FOV diagonal.
///  2. **Project** each object's (RA, Dec) to a pixel via
///     [WcsOverlay.celestialToPixel].
///  3. **Clip** to the image bounds and **map** the catalog type to an
///     [AnnotationKind] + a pixel size from the object's angular size and the
///     WCS pixel scale.
///
/// Pure orchestration — the UI draws the returned layer. Fail-soft: a catalog
/// error or an empty field yields an empty layer rather than throwing.
class MasterAnnotationService {
  MasterAnnotationService({
    required DsoConeSearch dsoSearch,
    required StarConeSearchForAnnotation starSearch,
  }) : _dsoSearch = dsoSearch,
       _starSearch = starSearch;

  final DsoConeSearch _dsoSearch;
  final StarConeSearchForAnnotation _starSearch;

  /// Only stars with a proper name (not a bare catalog id) are annotated, to
  /// keep the layer to recognisable landmarks; this caps how many per field.
  static const int maxNamedStars = 24;

  /// Build the annotation layer for the master of [width] × [height] px whose
  /// solved WCS is [wcs] and whose field of view is [fovDeg] degrees (the larger
  /// axis). [maxMagnitude] optionally limits both catalog searches to brighter
  /// objects.
  ///
  /// Returns an [AnnotationLayer] of in-frame, kinded, pixel-placed markers.
  Future<AnnotationLayer> annotate({
    required WcsOverlay wcs,
    required int width,
    required int height,
    required double fovDeg,
    double? maxMagnitude,
  }) async {
    if (width <= 0 || height <= 0) {
      return AnnotationLayer(width: width, height: height, items: const []);
    }

    // Search radius: 0.75 x the larger axis, which covers half the diagonal of
    // any field up to a square one (0.71 x), so corner objects are included.
    final radiusDeg = (fovDeg.abs() * 0.75).clamp(0.02, 30.0);
    final pixelScaleArcsec = wcs.pixelScale; // arcsec / px (|cdelt1| * 3600)

    final dsos = await _safeDsoSearch(
      ra: wcs.crval1,
      dec: wcs.crval2,
      radiusDegrees: radiusDeg,
      maxMagnitude: maxMagnitude,
    );
    final stars = await _safeStarSearch(
      CelestialCoordinate(ra: wcs.crval1 / 15.0, dec: wcs.crval2),
      radiusDeg,
      maxMagnitude: maxMagnitude,
    );

    final items = <Annotation>[];

    for (final dso in dsos) {
      final (x, y) = wcs.celestialToPixel(
        dso.coordinates.raDegrees,
        dso.coordinates.dec,
      );
      if (!_inBounds(x, y, width, height)) continue;
      items.add(
        Annotation(
          label: dso.name,
          x: x,
          y: y,
          kind: _kindFor(dso.type),
          sizePx: _dsoSizePx(dso, pixelScaleArcsec),
          paDeg: dso.positionAngle,
        ),
      );
    }

    var namedStars = 0;
    for (final star in stars) {
      if (namedStars >= maxNamedStars) break;
      if (!_hasProperName(star)) continue;
      final (x, y) = wcs.celestialToPixel(
        star.coordinates.raDegrees,
        star.coordinates.dec,
      );
      if (!_inBounds(x, y, width, height)) continue;
      items.add(
        Annotation(
          label: star.name,
          x: x,
          y: y,
          kind: AnnotationKind.star,
          sizePx: 0.0,
        ),
      );
      namedStars++;
    }

    return AnnotationLayer(width: width, height: height, items: items);
  }

  Future<List<DeepSkyObject>> _safeDsoSearch({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    try {
      return await _dsoSearch(
        ra: ra,
        dec: dec,
        radiusDegrees: radiusDegrees,
        maxMagnitude: maxMagnitude,
      );
    } catch (_) {
      return const [];
    }
  }

  Future<List<Star>> _safeStarSearch(
    CelestialCoordinate center,
    double radiusDegrees, {
    double? maxMagnitude,
  }) async {
    try {
      return await _starSearch(
        center,
        radiusDegrees,
        maxMagnitude: maxMagnitude,
      );
    } catch (_) {
      return const [];
    }
  }

  static bool _inBounds(double x, double y, int width, int height) =>
      x.isFinite && y.isFinite && x >= 0 && x < width && y >= 0 && y < height;

  static bool _hasProperName(Star star) =>
      star.name.trim().isNotEmpty && star.name.trim() != star.id.trim();

  /// Apparent diameter in master pixels from the object's major angular axis
  /// (arcmin) and the WCS pixel scale (arcsec/px). Falls back to 0 (a point
  /// marker) when the catalog has no size.
  static double _dsoSizePx(DeepSkyObject dso, double pixelScaleArcsec) {
    final majorArcmin = dso.sizeArcMin;
    if (majorArcmin == null || majorArcmin <= 0) return 0.0;
    if (pixelScaleArcsec <= 0) return 0.0;
    return majorArcmin * 60.0 / pixelScaleArcsec;
  }

  static AnnotationKind _kindFor(DsoType type) => switch (type) {
    DsoType.star ||
    DsoType.doubleStar ||
    DsoType.association => AnnotationKind.star,
    DsoType.openCluster || DsoType.globularCluster => AnnotationKind.cluster,
    // A cluster in nebulosity is drawn as the nebula it sits in.
    DsoType.clusterWithNebulosity => AnnotationKind.nebula,
    _ when type.isGalaxy => AnnotationKind.galaxy,
    _ when type.isNebula => AnnotationKind.nebula,
    _ => AnnotationKind.other,
  };
}
