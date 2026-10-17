// Focused tests for the polar-alignment config model's two hardened surfaces:
//  * capability-aware gain/offset/binning validation (with null = camera
//    default preserved), and
//  * defensive numeric parsing of wire event data (int vs double vs string),
//    which otherwise crashes the event stream on integer JSON payloads.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_capabilities.dart';
import 'package:skotiq_core/src/models/polar_alignment_config.dart';

CameraCapabilities _caps({
  bool canSetGain = true,
  int? gainMin = 0,
  int? gainMax = 100,
  bool canSetOffset = true,
  int? offsetMin = 0,
  int? offsetMax = 50,
  bool canBin = true,
  int maxBinX = 2,
  int maxBinY = 2,
}) {
  return CameraCapabilities(
    maxWidth: 1000,
    maxHeight: 1000,
    bitDepth: 16,
    canSetGain: canSetGain,
    gainMin: gainMin,
    gainMax: gainMax,
    canSetOffset: canSetOffset,
    offsetMin: offsetMin,
    offsetMax: offsetMax,
    canBin: canBin,
    maxBinX: maxBinX,
    maxBinY: maxBinY,
  );
}

void main() {
  group('PolarAlignmentConfig.validateForCamera', () {
    test('null gain/offset always pass (camera default is preserved)', () {
      const config = PolarAlignmentConfig(binning: 2, gain: null, offset: null);
      expect(config.validateForCamera(_caps()), isEmpty);
    });

    test('gain outside the camera range is rejected, in-range accepted', () {
      expect(
        const PolarAlignmentConfig(
          binning: 2,
          gain: 200,
        ).validateForCamera(_caps(gainMax: 100)),
        contains(contains('Gain must be between 0 and 100')),
      );
      expect(
        const PolarAlignmentConfig(
          binning: 2,
          gain: 50,
        ).validateForCamera(_caps(gainMax: 100)),
        isEmpty,
      );
    });

    test('setting gain on a camera that cannot set gain is rejected', () {
      final errors = const PolarAlignmentConfig(
        binning: 2,
        gain: 10,
      ).validateForCamera(_caps(canSetGain: false));
      expect(errors, contains('This camera does not support setting gain'));
    });

    test('offset is validated against the real range / capability', () {
      expect(
        const PolarAlignmentConfig(
          binning: 2,
          offset: 999,
        ).validateForCamera(_caps(offsetMax: 50)),
        isNotEmpty,
      );
      expect(
        const PolarAlignmentConfig(
          binning: 2,
          offset: 10,
        ).validateForCamera(_caps(canSetOffset: false)),
        contains('This camera does not support setting offset'),
      );
    });

    test('binning is bounded by the camera maximum, not a hardcoded 4', () {
      // maxBin 2: 4x4 is rejected even though the hardcoded validate() allows it.
      final errors = const PolarAlignmentConfig(
        binning: 4,
      ).validateForCamera(_caps(maxBinX: 2, maxBinY: 2));
      expect(
        errors,
        contains('Binning must be between 1 and 2 for this camera'),
      );

      // And a camera that supports 4x4 accepts it.
      expect(
        const PolarAlignmentConfig(
          binning: 4,
        ).validateForCamera(_caps(maxBinX: 4, maxBinY: 4)),
        isEmpty,
      );
    });

    test('null capabilities fall back to the built-in ranges', () {
      // gain 5000 is out of the hardcoded 0..1000 range.
      final errors = const PolarAlignmentConfig(
        gain: 5000,
      ).validateForCamera(null);
      expect(errors, isNotEmpty);
      expect(errors, equals(const PolarAlignmentConfig(gain: 5000).validate()));
    });
  });

  group('PolarAlignmentError.fromEventData defensive parsing', () {
    test('integer JSON payloads parse without throwing', () {
      final error = PolarAlignmentError.fromEventData(const {
        // int values (as they arrive over JSON when whole numbers)
        'azimuth_error': 2,
        'altitude_error': 3,
        'total_error': 4,
        'current_ra': 120,
        'current_dec': 45,
        'target_ra': 0,
        'target_dec': 90,
      });
      expect(error.azimuthError, 2.0);
      expect(error.totalError, 4.0);
      expect(error.currentRa, 120.0);
      expect(error.targetDec, 90.0);
    });

    test('double and numeric-string payloads both parse', () {
      final error = PolarAlignmentError.fromEventData(const {
        'azimuth_error': 1.5,
        'altitude_error': '-0.75',
        'total_error': 1.68,
      });
      expect(error.azimuthError, 1.5);
      expect(error.altitudeError, -0.75);
      expect(error.totalError, closeTo(1.68, 1e-9));
    });

    test('missing / unparseable fields fall back to 0 instead of throwing', () {
      final error = PolarAlignmentError.fromEventData(const {
        'azimuth_error': 'not-a-number',
        // other keys absent
      });
      expect(error.azimuthError, 0.0);
      expect(error.totalError, 0.0);
      expect(error.targetRa, 0.0);
    });
  });
}
