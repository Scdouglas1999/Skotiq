import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/catalog_overlay_service.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class _FakeCatalogOverlaySource implements CatalogOverlaySource {
  _FakeCatalogOverlaySource({
    this.dsos = const <DeepSkyObject>[],
    this.stars = const <Star>[],
    this.available = true,
  });

  final List<DeepSkyObject> dsos;
  final List<Star> stars;
  final bool available;

  @override
  Future<List<DeepSkyObject>> loadDsos() async => dsos;

  @override
  Future<List<Star>> loadStars() async => stars;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> get dsoCatalogAvailable async => available && dsos.isNotEmpty;

  @override
  Future<bool> get starCatalogAvailable async => available && stars.isNotEmpty;
}

DeepSkyObject _dso({
  required String id,
  required double raHours,
  required double decDeg,
  double? magnitude,
  double? sizeArcMin,
  List<String> catalogIds = const [],
  DsoType type = DsoType.galaxy,
}) {
  return DeepSkyObject(
    id: id,
    name: id,
    coordinates: CelestialCoordinate(ra: raHours, dec: decDeg),
    type: type,
    magnitude: magnitude,
    sizeArcMin: sizeArcMin,
    catalogIds: catalogIds,
  );
}

Star _star({
  required String id,
  required double raHours,
  required double decDeg,
  required double magnitude,
}) {
  return Star(
    id: id,
    name: id,
    coordinates: CelestialCoordinate(ra: raHours, dec: decDeg),
    magnitude: magnitude,
  );
}

const _wcs = SolvedWcs(
  raHours: 5.5,
  decDegrees: -5.0,
  rotationDeg: 0.0,
  pixelScaleArcsec: 1.5,
  imageWidth: 2048,
  imageHeight: 2048,
);

void main() {
  group('CatalogOverlayService.queryFov', () {
    test(
      'returns empty + catalogAvailable=false when WCS is invalid',
      () async {
        final svc = CatalogOverlayService(source: _FakeCatalogOverlaySource());
        const badWcs = SolvedWcs(
          raHours: 0,
          decDegrees: 0,
          rotationDeg: 0,
          pixelScaleArcsec: 0,
          imageWidth: 100,
          imageHeight: 100,
        );

        final result = await svc.queryFov(wcs: badWcs, magnitudeLimit: 10);

        expect(result.objects, isEmpty);
        expect(result.catalogAvailable, isFalse);
      },
    );

    test(
      'flags catalog unavailable when source.isAvailable is false',
      () async {
        final svc = CatalogOverlayService(
          source: _FakeCatalogOverlaySource(available: false),
        );
        final result = await svc.queryFov(wcs: _wcs, magnitudeLimit: 10);
        expect(result.catalogAvailable, isFalse);
        expect(result.objects, isEmpty);
      },
    );

    test('drops objects outside the magnitude limit', () async {
      final svc = CatalogOverlayService(
        source: _FakeCatalogOverlaySource(
          dsos: [
            _dso(id: 'M99', raHours: 5.5, decDeg: -5.0, magnitude: 9.0),
            _dso(id: 'NGC9999', raHours: 5.5, decDeg: -5.0, magnitude: 15.0),
          ],
        ),
      );
      final result = await svc.queryFov(wcs: _wcs, magnitudeLimit: 10);
      expect(result.objects.length, 1);
      expect(result.objects.first.id, 'M99');
    });

    test('keeps Messier objects with unknown magnitude', () async {
      final svc = CatalogOverlayService(
        source: _FakeCatalogOverlaySource(
          dsos: [
            // Synthetic Messier with no magnitude — should still appear.
            _dso(
              id: 'M999',
              raHours: 5.5,
              decDeg: -5.0,
              magnitude: null,
              catalogIds: ['M999'],
            ),
            // NGC without magnitude — dropped.
            _dso(id: 'NGC9001', raHours: 5.5, decDeg: -5.0, magnitude: null),
          ],
        ),
      );
      final result = await svc.queryFov(wcs: _wcs, magnitudeLimit: 10);
      expect(result.objects.length, 1);
      expect(result.objects.first.id, 'M999');
    });

    test(
      'projects objects to the image centre when they sit at the WCS centre',
      () async {
        final svc = CatalogOverlayService(
          source: _FakeCatalogOverlaySource(
            stars: [
              _star(id: 'star1', raHours: 5.5, decDeg: -5.0, magnitude: 4.0),
            ],
          ),
        );
        final result = await svc.queryFov(wcs: _wcs, magnitudeLimit: 10);
        expect(result.objects.length, 1);
        expect(result.objects.first.imageX, closeTo(1024, 1e-3));
        expect(result.objects.first.imageY, closeTo(1024, 1e-3));
      },
    );

    test(
      'derives DSO marker radius from angular size and plate scale',
      () async {
        final svc = CatalogOverlayService(
          source: _FakeCatalogOverlaySource(
            dsos: [
              _dso(
                id: 'M31',
                raHours: 5.5,
                decDeg: -5.0,
                magnitude: 4.0,
                sizeArcMin: 2.0,
              ),
            ],
          ),
        );

        final result = await svc.queryFov(wcs: _wcs, magnitudeLimit: 10);

        expect(result.objects.single.markerRadiusPx, closeTo(40.0, 1e-6));
        expect(result.objects.single.hitRadius, closeTo(40.0, 1e-6));
      },
    );

    test(
      'does not load a selected source when that catalog is unavailable',
      () async {
        final svc = CatalogOverlayService(
          source: _FakeCatalogOverlaySource(
            dsos: [_dso(id: 'M99', raHours: 5.5, decDeg: -5.0, magnitude: 9.0)],
          ),
        );

        final result = await svc.queryFov(
          wcs: _wcs,
          magnitudeLimit: 10,
          includeDsos: false,
          includeStars: true,
        );

        expect(result.catalogAvailable, isTrue);
        expect(result.dsoCatalogAvailable, isTrue);
        expect(result.starCatalogAvailable, isFalse);
        expect(result.objects, isEmpty);
      },
    );

    test('drops objects projecting outside the image bounds', () async {
      final svc = CatalogOverlayService(
        source: _FakeCatalogOverlaySource(
          stars: [
            // 30 degrees away from the centre — way outside the ~50 arcmin
            // FOV.
            _star(id: 'farStar', raHours: 8.0, decDeg: -5.0, magnitude: 4.0),
          ],
        ),
      );
      final result = await svc.queryFov(wcs: _wcs, magnitudeLimit: 10);
      expect(result.objects, isEmpty);
      expect(result.totalInFov, 0);
    });

    test('downsamples when more than maxObjects fall inside the FOV', () async {
      final stars = <Star>[];
      // Pack 12 stars near the centre with varying magnitudes.
      for (var i = 0; i < 12; i++) {
        stars.add(
          _star(
            id: 'S$i',
            raHours: 5.5 + 0.0001 * (i - 6),
            decDeg: -5.0,
            magnitude: 5.0 + i * 0.1,
          ),
        );
      }

      final svc = CatalogOverlayService(
        source: _FakeCatalogOverlaySource(stars: stars),
        maxObjects: 5,
      );
      final result = await svc.queryFov(wcs: _wcs, magnitudeLimit: 10);

      expect(result.objects.length, 5);
      expect(result.totalInFov, 12);
      expect(result.wasDownsampled, isTrue);
      // Truncation must keep the brightest stars (lowest magnitude
      // values) — confirm the cutoff matches the 5th-brightest entry.
      final mags = result.objects.map((o) => o.magnitude!).toList()..sort();
      expect(mags.first, closeTo(5.0, 1e-9));
      expect(mags.last, lessThanOrEqualTo(result.downsampleMagnitudeCutoff!));
    });

    test('treats raMin > raMax bounding boxes as a wrap', () async {
      // Pick a frame that straddles RA=0.
      const wrapWcs = SolvedWcs(
        raHours: 0.02,
        decDegrees: 0,
        rotationDeg: 0,
        pixelScaleArcsec: 5.0,
        imageWidth: 1024,
        imageHeight: 1024,
      );
      final svc = CatalogOverlayService(
        source: _FakeCatalogOverlaySource(
          stars: [
            _star(id: 'east', raHours: 0.01, decDeg: 0, magnitude: 4.0),
            _star(id: 'west', raHours: 23.99, decDeg: 0, magnitude: 4.5),
            _star(id: 'far', raHours: 12.0, decDeg: 0, magnitude: 3.0),
          ],
        ),
      );
      final result = await svc.queryFov(wcs: wrapWcs, magnitudeLimit: 10);

      final ids = result.objects.map((o) => o.id).toSet();
      expect(ids, containsAll(<String>['east', 'west']));
      expect(ids.contains('far'), isFalse);
    });

    // BboxPaddingFraction promoted
    // from hardcoded 0.05 to a user-configurable constructor parameter.
    test('bboxPaddingFraction widens the catalog query bbox so off-frame DSOs '
        'just past the chip edge are returned', () async {
      // Centre frame on (5.5h, -5°). At pixelScale 1.5"/px and 2048×2048,
      // the chip is ~0.85° on a side, so ~0.43° half-FOV. Place a DSO
      // 0.1° east of the centre — well inside the chip at any padding.
      final inFovDso = _dso(
        id: 'in-fov',
        raHours: 5.5 + 0.1 / 15.0,
        decDeg: -5.0,
        magnitude: 6.0,
      );

      // Default padding (5 %): the DSO should be returned (it's in-frame).
      final defaultSvc = CatalogOverlayService(
        source: _FakeCatalogOverlaySource(dsos: [inFovDso]),
      );
      expect(defaultSvc.bboxPaddingFraction, 0.05);
      final defaultResult = await defaultSvc.queryFov(
        wcs: _wcs,
        magnitudeLimit: 10,
      );
      expect(
        defaultResult.objects.map((o) => o.id),
        contains('in-fov'),
        reason: 'in-FOV DSO must be returned at default padding',
      );

      // Wide padding (50 %): same DSO still returned — the setting widens
      // the query, never narrows it. This proves the parameter is wired
      // through to the bounding-box computation rather than being silently
      // ignored.
      final widePaddingSvc = CatalogOverlayService(
        source: _FakeCatalogOverlaySource(dsos: [inFovDso]),
        bboxPaddingFraction: 0.5,
      );
      expect(widePaddingSvc.bboxPaddingFraction, 0.5);
      final wideResult = await widePaddingSvc.queryFov(
        wcs: _wcs,
        magnitudeLimit: 10,
      );
      expect(
        wideResult.objects.map((o) => o.id),
        contains('in-fov'),
        reason: 'wider padding must not drop in-FOV DSOs',
      );
    });
  });
}
