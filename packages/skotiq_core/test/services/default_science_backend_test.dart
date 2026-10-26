import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/science/default_science_backend.dart';

/// Unit tests for `default_science_backend.dart`:
///   - the sky position angle (skyPositionAngleDegrees)
///   - the ScienceCalibrationError structured surface
///   - the LineRatioError structured surface
void main() {
  group('skyPositionAngleDegrees', () {
    // PA runs from celestial north (0) through east (90).
    test('due north is 0 and due east is 90', () {
      expect(
        skyPositionAngleDegrees(
          fromRaDegrees: 35.6,
          fromDecDegrees: 42.3,
          toRaDegrees: 35.6,
          toDecDegrees: 42.31,
        ),
        closeTo(0, 1e-6),
      );
      expect(
        skyPositionAngleDegrees(
          fromRaDegrees: 35.6,
          fromDecDegrees: 42.3,
          toRaDegrees: 35.61,
          toDecDegrees: 42.3,
        ),
        closeTo(90, 0.01),
      );
    });

    test('south and west, across RA 0', () {
      expect(
        skyPositionAngleDegrees(
          fromRaDegrees: 0.005,
          fromDecDegrees: 10,
          toRaDegrees: 359.995,
          toDecDegrees: 10,
        ),
        closeTo(270, 0.01),
      );
      expect(
        skyPositionAngleDegrees(
          fromRaDegrees: 120,
          fromDecDegrees: -30,
          toRaDegrees: 120,
          toDecDegrees: -30.01,
        ),
        closeTo(180, 1e-6),
      );
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
