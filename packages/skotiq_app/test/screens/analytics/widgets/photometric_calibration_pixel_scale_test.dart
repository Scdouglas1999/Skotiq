// Unit tests for the photometric-calibration wizard's pixel-scale fallback.
//
// When a frame carries no stored `solvedPixelScale` the wizard recovers the
// scale from the rig geometry (sensor pitch + focal length) rather than
// guessing a fixed value. These tests pin the formula and the "only fall back
// to the default when BOTH inputs are missing" contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/photometric_calibration_wizard.dart';

void main() {
  group('fallbackPixelScaleArcsecPerPixel', () {
    test('computes 206.265 * pixelSizeUm / focalLengthMm', () {
      // 3.76 µm sensor at 530 mm -> 206.265 * 3.76 / 530 ≈ 1.4634"/px.
      final scale = fallbackPixelScaleArcsecPerPixel(
        pixelSizeUm: 3.76,
        focalLengthMm: 530,
      );
      expect(scale, closeTo(1.464, 0.001));
    });

    test('matches the small-angle formula across a range of geometries', () {
      // 9 µm pixels at 1000 mm -> 1.856"/px.
      expect(
        fallbackPixelScaleArcsecPerPixel(pixelSizeUm: 9.0, focalLengthMm: 1000),
        closeTo(206.265 * 9.0 / 1000, 1e-9),
      );
      // 2.4 µm pixels at 250 mm -> ~1.980"/px.
      expect(
        fallbackPixelScaleArcsecPerPixel(pixelSizeUm: 2.4, focalLengthMm: 250),
        closeTo(206.265 * 2.4 / 250, 1e-9),
      );
    });

    test('falls back to the default when pixel size is missing', () {
      expect(
        fallbackPixelScaleArcsecPerPixel(focalLengthMm: 530),
        kDefaultFallbackPixelScale,
      );
    });

    test('falls back to the default when focal length is missing', () {
      expect(
        fallbackPixelScaleArcsecPerPixel(pixelSizeUm: 3.76),
        kDefaultFallbackPixelScale,
      );
    });

    test('falls back to the default when both inputs are missing', () {
      expect(fallbackPixelScaleArcsecPerPixel(), kDefaultFallbackPixelScale);
      expect(kDefaultFallbackPixelScale, 1.5);
    });

    test('treats non-positive inputs as unavailable (no divide-by-zero)', () {
      expect(
        fallbackPixelScaleArcsecPerPixel(pixelSizeUm: 0, focalLengthMm: 530),
        kDefaultFallbackPixelScale,
      );
      expect(
        fallbackPixelScaleArcsecPerPixel(pixelSizeUm: 3.76, focalLengthMm: 0),
        kDefaultFallbackPixelScale,
      );
      expect(
        fallbackPixelScaleArcsecPerPixel(
          pixelSizeUm: -3.76,
          focalLengthMm: 530,
        ),
        kDefaultFallbackPixelScale,
      );
    });
  });
}
