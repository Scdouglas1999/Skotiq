import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/polar_alignment_config.dart';

PolarAlignmentError _err({required double az, required double alt}) =>
    PolarAlignmentError(
      azimuthError: az,
      altitudeError: alt,
      totalError: 0,
      currentRa: 0,
      currentDec: 0,
      targetRa: 0,
      targetDec: 0,
      timestamp: DateTime.utc(2026),
    );

void main() {
  group('PolarAlignmentError adjustment directions', () {
    test('pole east of true pole is corrected by moving Left', () {
      // Northern-hemisphere run: positive azimuth means the mechanical pole
      // is east of the true pole and the correcting bolt turn is westward,
      // shown as Left — opposite the bullseye marker (which renders east to
      // the right).
      expect(_err(az: 42, alt: 0).azimuthAdjustment, 'Left');
    });

    test('pole west of true pole is corrected by moving Right', () {
      // Southern-hemisphere run (or opposite azimuth drift): negative
      // azimuth is corrected by turning the bolt eastward, shown as Right.
      expect(_err(az: -42, alt: 0).azimuthAdjustment, 'Right');
    });

    test('pole above true pole is corrected by moving Down', () {
      expect(_err(az: 0, alt: 30).altitudeAdjustment, 'Down');
    });

    test('pole below true pole is corrected by moving Up', () {
      expect(_err(az: 0, alt: -30).altitudeAdjustment, 'Up');
    });
  });
}
