import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/science/default_science_backend.dart';

/// Unit tests for `default_science_backend.dart`:
///   - the PA matrix convention (computePixelMotionPositionAngle)
///   - the ScienceCalibrationError structured surface
///   - the LineRatioError structured surface
void main() {
  group('computePixelMotionPositionAngle', () {
    // PA convention: measured from celestial North (0°) through East (90°).
    // The pixel→sky transform negates pixel-Y (image Y-axis points "down" in
    // the sky frame). The WCS rotation is interpreted as the angle from
    // celestial North to image-up (matching FITS CROTA2 sense).
    //
    // For each case below, hand-compute the expected PA and verify the
    // helper agrees to within 1e-6 degrees.

    test('rotation 0: pixel +X (right) ⇒ celestial East (PA 90°)', () {
      final pa = computePixelMotionPositionAngle(
        dxPixels: 1.0,
        dyPixels: 0.0,
        wcsRotationDegrees: 0.0,
      );
      expect(pa, closeTo(90.0, 1e-9));
    });

    test('rotation 0: pixel -Y (up in image) ⇒ celestial North (PA 0°)', () {
      final pa = computePixelMotionPositionAngle(
        dxPixels: 0.0,
        dyPixels: -1.0,
        wcsRotationDegrees: 0.0,
      );
      expect(pa, closeTo(0.0, 1e-9));
    });

    test(
      'rotation 0: pixel +Y (down in image) ⇒ celestial South (PA 180°)',
      () {
        final pa = computePixelMotionPositionAngle(
          dxPixels: 0.0,
          dyPixels: 1.0,
          wcsRotationDegrees: 0.0,
        );
        expect(pa, closeTo(180.0, 1e-9));
      },
    );

    test('rotation 0: pixel -X (left) ⇒ celestial West (PA 270°)', () {
      final pa = computePixelMotionPositionAngle(
        dxPixels: -1.0,
        dyPixels: 0.0,
        wcsRotationDegrees: 0.0,
      );
      expect(pa, closeTo(270.0, 1e-9));
    });

    test('rotation 90 (image rotated CCW, image-up = celestial East): '
        'pixel +X ⇒ celestial South (PA 180°)', () {
      final pa = computePixelMotionPositionAngle(
        dxPixels: 1.0,
        dyPixels: 0.0,
        wcsRotationDegrees: 90.0,
      );
      expect(pa, closeTo(180.0, 1e-9));
    });

    test('rotation 90: pixel +Y (down in image, image-down = celestial West) '
        '⇒ celestial West (PA 270°)', () {
      final pa = computePixelMotionPositionAngle(
        dxPixels: 0.0,
        dyPixels: 1.0,
        wcsRotationDegrees: 90.0,
      );
      expect(pa, closeTo(270.0, 1e-9));
    });

    test('rotation -90: pixel +X ⇒ celestial North (PA 0°)', () {
      final pa = computePixelMotionPositionAngle(
        dxPixels: 1.0,
        dyPixels: 0.0,
        wcsRotationDegrees: -90.0,
      );
      expect(pa, closeTo(0.0, 1e-9));
    });

    test('result is always in [0, 360)', () {
      for (final dx in const [-3.0, -1.5, 0.0, 1.5, 3.0]) {
        for (final dy in const [-3.0, -1.5, 0.0, 1.5, 3.0]) {
          if (dx == 0.0 && dy == 0.0) continue;
          for (final rot in const [-180.0, -45.0, 0.0, 17.5, 90.0, 270.0]) {
            final pa = computePixelMotionPositionAngle(
              dxPixels: dx,
              dyPixels: dy,
              wcsRotationDegrees: rot,
            );
            expect(pa, greaterThanOrEqualTo(0.0));
            expect(pa, lessThan(360.0));
            expect(pa.isFinite, isTrue);
          }
        }
      }
    });

    test('rotating WCS by Δ rotates the reported PA by -Δ (mod 360) '
        '— consistency check', () {
      // For a fixed pixel motion, increasing the WCS rotation by Δ degrees
      // must shift the PA by -Δ degrees (mod 360). This catches sign
      // errors in the rotation matrix.
      const dx = 1.7;
      const dy = -0.9;
      const baseRot = 12.5;
      const delta = 37.0;
      final paBase = computePixelMotionPositionAngle(
        dxPixels: dx,
        dyPixels: dy,
        wcsRotationDegrees: baseRot,
      );
      final paShift = computePixelMotionPositionAngle(
        dxPixels: dx,
        dyPixels: dy,
        wcsRotationDegrees: baseRot + delta,
      );
      final diff = (paBase - paShift + 540.0) % 360.0 - 180.0; // signed Δ
      expect(diff, closeTo(-delta, 1e-9));
    });

    test('reference vector: dx=3, dy=-4, rot=30° matches hand calculation', () {
      // Hand calculation:
      //   dxUp = 3, dyUp = 4 (pixel-Y flipped)
      //   rot  = 30°, c = √3/2, s = 1/2
      //   dxSky = 3·c + 4·s = 3·(√3/2) + 2 = 1.5·√3 + 2
      //   dySky = -3·s + 4·c = -1.5 + 4·(√3/2) = -1.5 + 2·√3
      //   PA    = atan2(dxSky, dySky) (deg, mod 360)
      final dxSky = 3.0 * (math.sqrt(3) / 2.0) + 2.0;
      final dySky = -1.5 + 2.0 * math.sqrt(3);
      final expected =
          (math.atan2(dxSky, dySky) * 180.0 / math.pi + 360.0) % 360.0;

      final pa = computePixelMotionPositionAngle(
        dxPixels: 3.0,
        dyPixels: -4.0,
        wcsRotationDegrees: 30.0,
      );
      expect(pa, closeTo(expected, 1e-9));
    });
  });

  group('ScienceCalibrationError', () {
    test('exposes a structured error code', () {
      const err = ScienceCalibrationError(
        code: ScienceCalibrationErrorCode.fitFailed,
        message: 'Photometric fit produced non-finite zero-point=NaN rms=NaN.',
      );
      expect(err.code, ScienceCalibrationErrorCode.fitFailed);
      expect(err.toString(), contains('fitFailed'));
      expect(err.toString(), contains('non-finite'));
    });

    test('all defined error codes are unique', () {
      const codes = ScienceCalibrationErrorCode.values;
      expect(codes.toSet().length, codes.length);
    });
  });

  group('LineRatioError', () {
    test('dimension-mismatch error carries actionable detail', () {
      const err = LineRatioError(
        code: LineRatioErrorCode.dimensionMismatch,
        message:
            'Narrowband frame dimensions differ: '
            'Ha=4096x2160 OIII=4096x2160 SII=2048x1080.',
      );
      expect(err.code, LineRatioErrorCode.dimensionMismatch);
      expect(err.toString(), contains('dimensionMismatch'));
      expect(err.toString(), contains('SII=2048x1080'));
    });

    test('empty-pixel-data error is distinct from dimension mismatch', () {
      const dims = LineRatioError(
        code: LineRatioErrorCode.dimensionMismatch,
        message: 'x',
      );
      const empty = LineRatioError(
        code: LineRatioErrorCode.emptyPixelData,
        message: 'x',
      );
      expect(dims.code, isNot(equals(empty.code)));
    });
  });
}
