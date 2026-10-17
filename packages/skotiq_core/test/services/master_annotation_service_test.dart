import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/annotation.dart';
import 'package:skotiq_core/src/services/master_annotation_service.dart';
import 'package:skotiq_core/src/services/wcs_overlay.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

OpenNgcData _dso({
  required String name,
  required String type,
  required double raDeg,
  required double decDeg,
  double? majorAxis,
  double? positionAngle,
  String? messier,
  String? commonNames,
}) => OpenNgcData(
  name: name,
  type: type,
  ra: raDeg,
  dec: decDeg,
  magnitude: 9.0,
  majorAxis: majorAxis,
  minorAxis: majorAxis,
  positionAngle: positionAngle,
  messier: messier,
  commonNames: commonNames,
  constellation: 'And',
);

Star _star(String id, String name, double raDeg, double decDeg) => Star(
  id: id,
  name: name,
  coordinates: CelestialCoordinate(ra: raDeg / 15.0, dec: decDeg),
  magnitude: 2.0,
);

void main() {
  // WCS centred at RA=10°, Dec=20°, 2"/px, 200×200, no rotation.
  WcsOverlay buildWcs() => WcsOverlay(
    crpix1: 100,
    crpix2: 100,
    crval1: 10.0,
    crval2: 20.0,
    cdelt1: 2.0 / 3600.0,
    cdelt2: 2.0 / 3600.0,
  );

  test(
    'maps a known sky coord to the expected pixel and assigns kind/size',
    () async {
      final wcs = buildWcs();
      // Place a galaxy at the projection of pixel (150, 100): +50px in X from the
      // crpix centre at 2"/px. The marker must land back on (150, 100).
      final (gRa, gDec) = wcs.pixelToCelestial(150, 100);

      final svc = MasterAnnotationService(
        dsoSearch:
            ({
              required double ra,
              required double dec,
              required double radiusDegrees,
              double? maxMagnitude,
            }) async => [
              _dso(
                name: 'NGC 1',
                type: 'G',
                raDeg: gRa,
                decDeg: gDec,
                majorAxis: 4.0, // arcmin
                positionAngle: 45.0,
                messier: '110',
              ),
            ],
        starSearch: (_, __, {maxMagnitude}) async => const [],
      );

      final layer = await svc.annotate(
        wcs: wcs,
        width: 200,
        height: 200,
        fovDeg: 200 * 2.0 / 3600.0,
      );

      expect(layer.width, 200);
      expect(layer.height, 200);
      expect(layer.items, hasLength(1));
      final a = layer.items.single;
      expect(a.kind, AnnotationKind.galaxy);
      expect(a.label, 'M110'); // Messier preferred
      expect(a.paDeg, 45.0);
      // 4 arcmin major axis at 2"/px → 4*60/2 = 120 px.
      expect(a.sizePx, closeTo(120.0, 0.5));
      // Pixel position: the DSO was placed at the projection of (150,100).
      expect(a.x, closeTo(150.0, 0.5));
      expect(a.y, closeTo(100.0, 0.5));
    },
  );

  test('clips out-of-frame objects', () async {
    final wcs = buildWcs();

    // One in-frame star (centre) + one far off-frame DSO (well outside bounds).
    final (inRa, inDec) = wcs.pixelToCelestial(100, 100);
    final (outRa, outDec) = wcs.pixelToCelestial(5000, 5000);

    final svc = MasterAnnotationService(
      dsoSearch:
          ({
            required double ra,
            required double dec,
            required double radiusDegrees,
            double? maxMagnitude,
          }) async => [
            _dso(name: 'NGC off', type: 'PN', raDeg: outRa, decDeg: outDec),
          ],
      starSearch: (_, __, {maxMagnitude}) async => [
        _star('HIP1', 'Vega', inRa, inDec),
        _star('HIP2', 'OffStar', outRa, outDec),
      ],
    );

    final layer = await svc.annotate(
      wcs: wcs,
      width: 200,
      height: 200,
      fovDeg: 200 * 2.0 / 3600.0,
    );

    // The off-frame DSO and off-frame star are both clipped; only Vega remains.
    expect(layer.items, hasLength(1));
    final a = layer.items.single;
    expect(a.label, 'Vega');
    expect(a.kind, AnnotationKind.star);
    expect(a.x, closeTo(100.0, 0.5));
    expect(a.y, closeTo(100.0, 0.5));
  });

  test('maps OpenNGC type codes to annotation kinds', () async {
    final wcs = buildWcs();
    final (centreRa, centreDec) = wcs.pixelToCelestial(100, 100);

    Future<AnnotationKind> kindFor(String code) async {
      final svc = MasterAnnotationService(
        dsoSearch:
            ({
              required double ra,
              required double dec,
              required double radiusDegrees,
              double? maxMagnitude,
            }) async => [
              _dso(name: code, type: code, raDeg: centreRa, decDeg: centreDec),
            ],
        starSearch: (_, __, {maxMagnitude}) async => const [],
      );
      final layer = await svc.annotate(
        wcs: wcs,
        width: 200,
        height: 200,
        fovDeg: 200 * 2.0 / 3600.0,
      );
      return layer.items.single.kind;
    }

    expect(await kindFor('G'), AnnotationKind.galaxy);
    expect(await kindFor('OCl'), AnnotationKind.cluster);
    expect(await kindFor('GCl'), AnnotationKind.cluster);
    expect(await kindFor('PN'), AnnotationKind.nebula);
    expect(await kindFor('EmN'), AnnotationKind.nebula);
    expect(await kindFor('Dup'), AnnotationKind.other);
  });

  test('zero-size frame returns an empty layer', () async {
    final svc = MasterAnnotationService(
      dsoSearch:
          ({
            required double ra,
            required double dec,
            required double radiusDegrees,
            double? maxMagnitude,
          }) async => throw StateError('should not search'),
      starSearch: (_, __, {maxMagnitude}) async =>
          throw StateError('should not search'),
    );
    final layer = await svc.annotate(
      wcs: buildWcs(),
      width: 0,
      height: 0,
      fovDeg: 1.0,
    );
    expect(layer.items, isEmpty);
  });

  test('catalog error fail-softs to an empty (non-throwing) layer', () async {
    final svc = MasterAnnotationService(
      dsoSearch:
          ({
            required double ra,
            required double dec,
            required double radiusDegrees,
            double? maxMagnitude,
          }) async => throw StateError('catalog offline'),
      starSearch: (_, __, {maxMagnitude}) async =>
          throw StateError('catalog offline'),
    );
    final layer = await svc.annotate(
      wcs: buildWcs(),
      width: 200,
      height: 200,
      fovDeg: 0.1,
    );
    expect(layer.items, isEmpty);
    expect(layer.width, 200);
  });
}
