// The product's one airmass model, pinned against published values.
//
// Airmass reaches three published surfaces — the `AIRMASS` card of every FITS
// frame, the `AMASS` column of an AAVSO submission, and the extinction
// coefficient `k` fitted by the photometric-calibration wizard. Those numbers
// are only comparable if one function produces all of them, so this file pins
// that function's values rather than its formula: if someone re-derives a
// formula at a call site, the reference values below are what catches it.
//
// Reference values are the standard-atmosphere relative air masses tabulated
// in the airmass literature (Kasten & Young 1989 Appl. Opt. 28:4735; Young
// 1994 Appl. Opt. 33:1108; Pickering 2002 DIO 12:1). Two conventions matter
// when reading them:
//
//  * Published tables are indexed by APPARENT (refracted) zenith angle.
//    [airmassForTrueAltitude] takes TRUE (geometric) altitude — what a mount
//    reports and what the FITS writer is handed — so near the horizon a table
//    row must be converted before it can be compared. See the h = 5° case.
//  * The zenith-angle secant is the vacuum limit, not the atmosphere: real
//    airmass is always slightly below sec z, and the gap grows with z.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

double _secantZenith(double altitudeDegrees) =>
    1.0 / math.sin(altitudeDegrees * math.pi / 180.0);

/// Kasten & Young (1989). Kept here, and nowhere in `lib/`, so the tests can
/// state how far an alternative formula sits from the product's model.
double _kastenYoung1989(double altitudeDegrees) =>
    1.0 /
    (math.sin(altitudeDegrees * math.pi / 180.0) +
        0.50572 * math.pow(altitudeDegrees + 6.07995, -1.6364));

/// Pickering (2002) with no low-altitude switch.
double _pickering2002(double altitudeDegrees) =>
    1.0 /
    math.sin(
      (altitudeDegrees +
              244.0 / (165.0 + 47.0 * math.pow(altitudeDegrees, 1.1))) *
          math.pi /
          180.0,
    );

void main() {
  group('airmassForTrueAltitude — published values', () {
    test('is exactly 1.0 at the zenith', () {
      expect(airmassForTrueAltitude(90.0), 1.0);
      // Numerical noise from a mount that reports 90.000001 must not push
      // sin() past 1 and produce a NaN or a sub-1 airmass.
      expect(airmassForTrueAltitude(90.000001), 1.0);
      expect(airmassForTrueAltitude(89.95), 1.0);
    });

    test('tracks the tabulated standard atmosphere from 60° down to 10°', () {
      // Published relative air mass (apparent zenith angle z = 90 - h). At
      // these altitudes refraction is under 6", so the true/apparent
      // distinction is far below the tolerance.
      //   z = 30°  X = 1.154
      //   z = 45°  X = 1.413
      //   z = 60°  X = 1.995
      //   z = 70°  X = 2.904
      //   z = 80°  X = 5.600
      expect(airmassForTrueAltitude(60.0), closeTo(1.154, 0.002));
      expect(airmassForTrueAltitude(45.0), closeTo(1.413, 0.002));
      expect(airmassForTrueAltitude(30.0), closeTo(1.995, 0.003));
      expect(airmassForTrueAltitude(20.0), closeTo(2.904, 0.006));
      expect(airmassForTrueAltitude(10.0), closeTo(5.600, 0.025));
    });

    test('stays just under the secant of the zenith angle', () {
      for (final altitude in [80.0, 60.0, 45.0, 30.0, 20.0, 15.0]) {
        final airmass = airmassForTrueAltitude(altitude)!;
        final secant = _secantZenith(altitude);
        expect(
          airmass,
          lessThan(secant),
          reason: 'airmass must be below the vacuum secant at $altitude°',
        );
        expect(
          airmass,
          greaterThan(secant * 0.98),
          reason: 'airmass must stay within 2% of sec z at $altitude°',
        );
      }
    });

    test(
      'reproduces the z = 85° table row once refraction is accounted for',
      () {
        // The tables give X = 10.32 at APPARENT z = 85°. Refraction at that
        // zenith angle is ~9.9', so the true altitude of that row is
        // 5° - 0.165° = 4.835°, and that is the input this function takes.
        expect(airmassForTrueAltitude(4.835), closeTo(10.32, 0.02));
        // At a TRUE altitude of 5° the object is apparently higher, so its
        // airmass is correspondingly lower than the 5°-apparent table row.
        expect(airmassForTrueAltitude(5.0), closeTo(10.06, 0.02));
        expect(
          airmassForTrueAltitude(5.0)!,
          lessThan(airmassForTrueAltitude(4.835)!),
        );
      },
    );

    test('is Young 1994 at the horizon, not Pickering and not a clamp', () {
      // Young (1994) at z = 90° evaluates to 31.73; the accepted
      // standard-atmosphere value is 31.78. Pickering's expression run all the
      // way down reads 38.75 there — 22% high — and a clamp(1, 40) never binds
      // it.
      final horizon = airmassForTrueAltitude(0.0)!;
      expect(horizon, closeTo(31.74, 0.05));
      expect(_pickering2002(0.0), closeTo(38.75, 0.05));
      expect(
        (horizon - _pickering2002(0.0)).abs(),
        greaterThan(6.0),
        reason: 'the horizon is exactly where the retired copy was wrong',
      );
    });

    test('rises monotonically all the way to the horizon', () {
      // The extinction fit reads the SLOPE of magnitude against airmass, so a
      // non-monotonic model would invert the sign of k somewhere.
      var previous = airmassForTrueAltitude(90.0)!;
      for (var altitude = 89.0; altitude >= 0.0; altitude -= 0.25) {
        final airmass = airmassForTrueAltitude(altitude)!;
        expect(
          airmass,
          greaterThan(previous),
          reason: 'airmass must increase as altitude falls (at $altitude°)',
        );
        previous = airmass;
      }
      expect(previous, closeTo(31.74, 0.05));
    });

    test('is continuous across the 10° Pickering/Young handover', () {
      // The model is piecewise: Pickering above 10°, Young below it. A step at
      // the seam would show up as a discontinuity in a light curve of a target
      // setting through it, so the size of that step is pinned rather than
      // left to be discovered on sky.
      final above = airmassForTrueAltitude(10.0)!;
      final below = airmassForTrueAltitude(9.999)!;
      expect(
        (above - below).abs(),
        lessThan(0.05),
        reason:
            'handover step must stay under 0.05 airmass (~0.01 mag at '
            'k = 0.2), got ${(above - below).abs()}',
      );
    });
  });

  group('airmassForTrueAltitude — undefined inputs', () {
    test('returns null below the horizon rather than inventing a value', () {
      expect(airmassForTrueAltitude(-0.001), isNull);
      expect(airmassForTrueAltitude(-15.0), isNull);
    });

    test('returns null for non-finite altitudes', () {
      expect(airmassForTrueAltitude(double.nan), isNull);
      expect(airmassForTrueAltitude(double.infinity), isNull);
      expect(airmassForTrueAltitude(double.negativeInfinity), isNull);
    });
  });

  group('the retired copies really did disagree', () {
    // Each asserts the number one of the retired formulas publishes, so
    // re-introducing any of them is a test failure rather than a silent drift
    // between surfaces.
    test('the wizard clamp(1, 8) erased the low-altitude leverage it needs', () {
      // At 4° true altitude the atmosphere is ~11.9 air masses deep. The
      // wizard reported 8.0 — and 8.0 for every frame below ~7°, which flattens
      // exactly the part of the extinction fit that carries the signal.
      expect(airmassForTrueAltitude(4.0), closeTo(11.897, 0.005));
      expect(_kastenYoung1989(4.0).clamp(1.0, 8.0), 8.0);

      // The clamp binds from ~6.6° down, so every frame in the entire band the
      // fit most needs was reported as the same constant 8.0 while the real
      // airmass ran from 8.8 to 31.7 — a fit over those frames sees no spread
      // in x at all.
      for (final altitude in [6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0]) {
        expect(
          _kastenYoung1989(altitude).clamp(1.0, 8.0),
          8.0,
          reason: 'the retired clamp pinned $altitude° to 8.0',
        );
      }
      expect(airmassForTrueAltitude(6.0)!, greaterThan(8.5));
      expect(airmassForTrueAltitude(0.0)!, greaterThan(31.0));
    });

    test('the exporter and the wizard disagreed with each other', () {
      // Same frame, two surfaces, two published numbers. This is the defect in
      // one line: at 4° the AAVSO file said 12.36 and the extinction fit used
      // 8.0.
      expect(_pickering2002(4.0).clamp(1.0, 40.0), closeTo(12.361, 0.005));
      expect(_kastenYoung1989(4.0).clamp(1.0, 8.0), 8.0);
      // Both now resolve to the one model.
      expect(airmassForTrueAltitude(4.0), closeTo(11.897, 0.005));
    });

    test('above 10° the model is Pickering, so high frames are unchanged', () {
      for (final altitude in [15.0, 30.0, 45.0, 70.0]) {
        expect(
          airmassForTrueAltitude(altitude),
          closeTo(_pickering2002(altitude), 1e-9),
          reason: 'Pickering must still be the model at $altitude°',
        );
      }
    });
  });
}
