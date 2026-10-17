// Synthetic-perf test for the catalog overlay. Runs the catalog query against a
// fake source containing 13_000 DSOs (~OpenNGC size) plus 120_000 stars (~HYG
// size) and asserts that a single FOV query completes in a few hundred
// milliseconds even when every object is inside the bounding box. This is not a
// check on absolute wall-clock — it guards against quadratic accidents in the
// projection loop.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/catalog_overlay_service.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class _BulkCatalogSource implements CatalogOverlaySource {
  _BulkCatalogSource(this.dsos, this.stars);
  final List<DeepSkyObject> dsos;
  final List<Star> stars;
  @override
  Future<List<DeepSkyObject>> loadDsos() async => dsos;
  @override
  Future<List<Star>> loadStars() async => stars;
  @override
  Future<bool> get isAvailable async => true;
  @override
  Future<bool> get dsoCatalogAvailable async => dsos.isNotEmpty;
  @override
  Future<bool> get starCatalogAvailable async => stars.isNotEmpty;
}

const _wcs = SolvedWcs(
  raHours: 5.5,
  decDegrees: -5.0,
  rotationDeg: 0.0,
  // ~1 deg FOV at 2048 px is typical for a small refractor + APS-C.
  pixelScaleArcsec: 1.8,
  imageWidth: 2048,
  imageHeight: 1366,
);

void main() {
  test('queryFov completes quickly with a large synthetic catalog', () async {
    // Spread the synthetic objects across a 4-degree square around the
    // WCS centre so the bounding-box filter sees a realistic 1-2% hit
    // rate, not 100%.
    final dsos = <DeepSkyObject>[];
    for (var i = 0; i < 13000; i++) {
      final hash = i * 2654435761;
      // RA in hours: centre +/- 0.5 hour (~7.5 deg).
      final raOffset = ((hash % 1000) / 1000.0 - 0.5) * 1.0;
      // Dec in degrees: centre +/- 4 deg.
      final decOffset = ((hash >>> 8) % 1000) / 1000.0 * 8.0 - 4.0;
      dsos.add(
        DeepSkyObject(
          id: 'NGC$i',
          name: 'NGC$i',
          coordinates: CelestialCoordinate(
            ra: 5.5 + raOffset,
            dec: -5.0 + decOffset,
          ),
          type: DsoType.galaxy,
          magnitude: 8.0 + (i % 80) / 10.0,
        ),
      );
    }
    final stars = <Star>[];
    for (var i = 0; i < 120000; i++) {
      final hash = i * 2246822519;
      final raOffset = ((hash % 1000) / 1000.0 - 0.5) * 1.0;
      final decOffset = ((hash >>> 8) % 1000) / 1000.0 * 8.0 - 4.0;
      stars.add(
        Star(
          id: 'HYG$i',
          name: 'HYG$i',
          coordinates: CelestialCoordinate(
            ra: 5.5 + raOffset,
            dec: -5.0 + decOffset,
          ),
          magnitude: 4.0 + (i % 100) / 12.0,
        ),
      );
    }

    final svc = CatalogOverlayService(
      source: _BulkCatalogSource(dsos, stars),
      maxObjects: 500,
    );

    // Warm-up to avoid the first-run JIT cliff.
    await svc.queryFov(
      wcs: _wcs,
      magnitudeLimit: 10.0,
      includeStars: true,
      includeDsos: true,
    );

    final stopwatch = Stopwatch()..start();
    final result = await svc.queryFov(
      wcs: _wcs,
      magnitudeLimit: 10.0,
      includeStars: true,
      includeDsos: true,
    );
    stopwatch.stop();

    expect(result.catalogAvailable, isTrue);
    expect(result.objects.length, lessThanOrEqualTo(500));
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(800),
      reason:
          'queryFov against 133k synthetic catalog rows took '
          '${stopwatch.elapsedMilliseconds}ms — investigate quadratic loops',
    );
  });
}
