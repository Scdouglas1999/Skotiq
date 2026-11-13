import 'dart:async';

import 'package:skotiq_astro/skotiq_astro.dart';

import '../models/imaging/annotation.dart';
import 'wcs/gnomonic_projection.dart';

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
///     centred on the image, radius = half the FOV diagonal.
///  2. **Project** each object's (RA, Dec) to a pixel via
///     [GnomonicProjection.worldToPixel].
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

  /// Build the annotation layer for the master whose solved WCS is [wcs].
  /// [maxMagnitude] optionally limits both catalog searches to brighter
  /// objects.
  ///
  /// Returns an [AnnotationLayer] of in-frame, kinded, pixel-placed markers.
  Future<AnnotationLayer> annotate({
    required SolvedWcs wcs,
    double? maxMagnitude,
  }) async {
    final width = wcs.imageWidth;
    final height = wcs.imageHeight;
    if (!wcs.isValid) {
      return AnnotationLayer(width: width, height: height, items: const []);
    }

    final projection = GnomonicProjection(wcs);
    final centre = projection.imageCentre;
    final radiusDeg = wcs.coneSearchRadiusDegrees;
    final pixelScaleArcsec = wcs.pixelScaleArcsec;

    final dsos = await _safeDsoSearch(
      ra: centre.raDegrees,
      dec: centre.decDegrees,
      radiusDegrees: radiusDeg,
      maxMagnitude: maxMagnitude,
    );
    final stars = await _safeStarSearch(
      CelestialCoordinate(ra: centre.raDegrees / 15.0, dec: centre.decDegrees),
      radiusDeg,
      maxMagnitude: maxMagnitude,
    );

    final items = <Annotation>[];

    for (final dso in dsos) {
      final projected = projection.worldToPixel(
        raDegrees: dso.coordinates.raDegrees,
        decDegrees: dso.coordinates.dec,
      );
      if (projected == null || !projected.onImage) continue;
      final PixelPoint(:x, :y) = projected.pixel;
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
      final projected = projection.worldToPixel(
        raDegrees: star.coordinates.raDegrees,
        decDegrees: star.coordinates.dec,
      );
      if (projected == null || !projected.onImage) continue;
      final PixelPoint(:x, :y) = projected.pixel;
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
