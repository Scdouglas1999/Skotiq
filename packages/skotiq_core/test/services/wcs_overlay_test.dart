import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('WcsOverlay', () {
    test('keeps polar pixel conversion finite', () {
      final wcs = WcsOverlay(
        crpix1: 100,
        crpix2: 100,
        crval1: 12,
        crval2: 90,
        cdelt1: 0.001,
        cdelt2: 0.001,
      );

      final (ra, dec) = wcs.pixelToCelestial(110, 90);

      expect(ra.isFinite, isTrue);
      expect(dec.isFinite, isTrue);
      expect(ra, inInclusiveRange(0, 360));
      expect(dec, inInclusiveRange(-90, 90));
    });

    test('normalizes RA wrap for celestial conversion', () {
      final wcs = WcsOverlay(
        crpix1: 100,
        crpix2: 100,
        crval1: 359.9,
        crval2: 30,
        cdelt1: 0.001,
        cdelt2: 0.001,
      );

      final (xNearWrap, _) = wcs.celestialToPixel(0.1, 30);
      final (xFarWithoutWrap, _) = wcs.celestialToPixel(180, 30);

      expect(xNearWrap.isFinite, isTrue);
      expect(xFarWithoutWrap.isFinite, isTrue);
      expect((xNearWrap - 100).abs(), lessThan(1000));
    });
  });
}
