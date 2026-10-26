import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('PlateSolveDataExtensions.pixelToSky', () {
    test('returns exact center coordinates at image center', () {
      const plateSolve = PlateSolveData(
        ra: 123.456,
        dec: -22.75,
        pixelScale: 1.2,
        rotation: 15.0,
        fieldWidth: 2.0,
        fieldHeight: 1.5,
        imageWidth: 4000,
        imageHeight: 3000,
      );

      // 0-based pixel centres: the centre of a 4000 x 3000 frame.
      final coords = plateSolve.pixelToSky(1999.5, 1499.5);
      expect(coords.ra, closeTo(123.456, 1e-9));
      expect(coords.dec, closeTo(-22.75, 1e-9));
    });

    test('round-trips sky->pixel->sky for in-frame coordinates', () {
      const plateSolve = PlateSolveData(
        ra: 200.0,
        dec: 30.0,
        pixelScale: 1.5,
        rotation: 32.0,
        fieldWidth: 1.8,
        fieldHeight: 1.2,
        imageWidth: 3000,
        imageHeight: 2000,
      );

      final pixel = plateSolve.skyToPixel(200.15, 30.08);
      expect(pixel, isNotNull);

      final sky = plateSolve.pixelToSky(pixel!.x, pixel.y);
      expect(sky.ra, closeTo(200.15, 1e-4));
      expect(sky.dec, closeTo(30.08, 1e-4));
    });
  });
}
