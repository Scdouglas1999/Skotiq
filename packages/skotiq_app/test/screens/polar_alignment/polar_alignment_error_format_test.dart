// Polar-axis error readouts speak the unit the operator's bolts are in.
//
// A user turning altitude/azimuth bolts thinks in arcminutes and degrees.
// Converting a raw arcsecond count like 2287.9" to 38' in their head at 2am is
// not a reasonable ask.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_error_format.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('formatPolarError', () {
    test('keeps arcseconds where the arcsecond is the meaningful unit', () {
      expect(formatPolarError(0), '0.0"');
      expect(formatPolarError(12.34), '12.3"');
      expect(formatPolarError(59.9), '59.9"');
    });

    test('switches to arcminutes above one arcminute', () {
      expect(formatPolarError(60), "1' 00\"");
      expect(formatPolarError(2287.9), "38' 08\"");
      expect(formatPolarError(1800), "30' 00\"");
      expect(formatPolarError(2327.5), "38' 48\"");
    });

    test('switches to degrees above one degree', () {
      expect(formatPolarError(3600), "1° 00' 00\"");
      // 11 degrees — the value the All-Sky run threw out on its second sample.
      expect(formatPolarError(40104), "11° 08' 24\"");
    });

    test('carries a rounded 60 into the next unit', () {
      expect(formatPolarError(3599.7), "1° 00' 00\"");
      expect(formatPolarError(119.7), "2' 00\"");
    });

    test('preserves the sign of a signed az/alt component', () {
      expect(formatPolarError(-427.6), "-7' 08\"");
      expect(formatPolarError(-12.3), '-12.3"');
    });

    test('renders a non-finite value as unknown, never as NaN', () {
      // The kit's unknown marker (an em dash), not a pair of hyphens.
      expect(formatPolarError(double.nan), kReadoutUnknown);
      expect(formatPolarError(double.infinity), kReadoutUnknown);
    });
  });
}
