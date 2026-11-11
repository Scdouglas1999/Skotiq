import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  group('image scale feeding the presets', () {
    test('small-angle formula: 206.265 * pixelSizeUm / focalLengthMm', () {
      // 3.76 µm at 530 mm -> ~1.4634"/px (ASI2600 on a typical refractor).
      expect(
        FOVCalculator.imageScaleOrNull(pixelSizeMicrons: 3.76, focalLengthMm: 530),
        closeTo(206.265 * 3.76 / 530, 1e-9),
      );
    });

    test('returns null when either input is missing or non-positive', () {
      expect(
        FOVCalculator.imageScaleOrNull(pixelSizeMicrons: 0, focalLengthMm: 530),
        isNull,
      );
      expect(
        FOVCalculator.imageScaleOrNull(pixelSizeMicrons: 3.76, focalLengthMm: 0),
        isNull,
      );
      expect(
        FOVCalculator.imageScaleOrNull(pixelSizeMicrons: null, focalLengthMm: 530),
        isNull,
      );
    });
  });

  group('deriveDitherSettleValues — sane values for a sample rig', () {
    // Sample rig: 3.76 µm sensor at 530 mm focal length -> ~1.463"/px.
    const pixelScale = 206.265 * 3.76 / 530;

    test('good seeing: tight threshold, moderate dwell', () {
      final v = deriveDitherSettleValues(
        preset: DitherSettlePreset.goodSeeing,
        pixelScaleArcsecPerPixel: pixelScale,
      );
      // 1.0" tolerance / 1.463"/px ≈ 0.68px.
      expect(v.settlePixels, closeTo(0.7, 0.05));
      expect(v.settleTime, 8.0);
    });

    test('windy: looser threshold, long dwell', () {
      final v = deriveDitherSettleValues(
        preset: DitherSettlePreset.windy,
        pixelScaleArcsecPerPixel: pixelScale,
      );
      // 2.5" tolerance / 1.463"/px ≈ 1.71px.
      expect(v.settlePixels, closeTo(1.7, 0.05));
      expect(v.settleTime, 20.0);
      // Windy must be looser and dwell longer than good-seeing.
      final good = deriveDitherSettleValues(
        preset: DitherSettlePreset.goodSeeing,
        pixelScaleArcsecPerPixel: pixelScale,
      );
      expect(v.settlePixels, greaterThan(good.settlePixels));
      expect(v.settleTime, greaterThan(good.settleTime));
    });

    test('fast optics: shortest dwell to keep cadence high', () {
      final fast = deriveDitherSettleValues(
        preset: DitherSettlePreset.fastOptics,
        pixelScaleArcsecPerPixel: pixelScale,
      );
      final windy = deriveDitherSettleValues(
        preset: DitherSettlePreset.windy,
        pixelScaleArcsecPerPixel: pixelScale,
      );
      expect(fast.settleTime, lessThan(windy.settleTime));
    });

    test('all presets produce in-band, usable values', () {
      for (final preset in DitherSettlePreset.values) {
        final v = deriveDitherSettleValues(
          preset: preset,
          pixelScaleArcsecPerPixel: pixelScale,
        );
        expect(
          v.settlePixels,
          inInclusiveRange(kDitherSettleMinPixels, kDitherSettleMaxPixels),
        );
        expect(v.settlePixels, greaterThan(0));
        expect(v.settleTime, greaterThan(0));
      }
    });
  });

  group('deriveDitherSettleValues — clamping and fallbacks', () {
    test('extreme long focal length is clamped to the minimum pixels', () {
      // 2.4 µm at 4000 mm -> ~0.124"/px. Good-seeing 1.0" tolerance would be
      // ~8px raw, but it is clamped down so it stays usable.
      final scale = FOVCalculator.imageScaleOrNull(
        pixelSizeMicrons: 2.4,
        focalLengthMm: 4000,
      );
      final v = deriveDitherSettleValues(
        preset: DitherSettlePreset.windy,
        pixelScaleArcsecPerPixel: scale,
      );
      expect(
        v.settlePixels,
        inInclusiveRange(kDitherSettleMinPixels, kDitherSettleMaxPixels),
      );
    });

    test(
      'null pixel scale falls back to tolerance-as-pixels (still clamped)',
      () {
        final v = deriveDitherSettleValues(
          preset: DitherSettlePreset.windy,
          pixelScaleArcsecPerPixel: null,
        );
        // 2.5" tolerance interpreted directly as 2.5px.
        expect(v.settlePixels, closeTo(2.5, 1e-9));
        expect(v.settleTime, 20.0);
      },
    );

    test('rig convenience overload matches the scale-based path', () {
      final fromRig = deriveDitherSettleValuesFromRig(
        preset: DitherSettlePreset.goodSeeing,
        pixelSizeUm: 3.76,
        focalLengthMm: 530,
      );
      final fromScale = deriveDitherSettleValues(
        preset: DitherSettlePreset.goodSeeing,
        pixelScaleArcsecPerPixel: 206.265 * 3.76 / 530,
      );
      expect(fromRig, fromScale);
    });
  });
}
