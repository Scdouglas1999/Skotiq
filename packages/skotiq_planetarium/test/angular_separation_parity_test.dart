import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Pins the single angular-separation implementation this package has.
///
/// Hand-rolled great-circle helpers fork easily — some taking RA in hours,
/// some in degrees, some by the spherical law of cosines and some by haversine
/// — and they disagree at arcsecond scale, which is exactly the scale the
/// coincident-star merge and the catalog cone search compare at. These tests
/// hold the implementations to one another so a future edit cannot silently
/// re-fork them.
void main() {
  /// The law-of-cosines form, kept here as the reference the canonical helper
  /// must agree with at ordinary separations.
  double lawOfCosinesDegrees(
    double ra1Deg,
    double dec1Deg,
    double ra2Deg,
    double dec2Deg,
  ) {
    const d2r = math.pi / 180;
    final dec1 = dec1Deg * d2r;
    final dec2 = dec2Deg * d2r;
    final cosSep =
        math.sin(dec1) * math.sin(dec2) +
        math.cos(dec1) * math.cos(dec2) * math.cos((ra1Deg - ra2Deg) * d2r);
    return math.acos(cosSep.clamp(-1.0, 1.0)) / d2r;
  }

  group('CelestialCoordinate.separationDegrees', () {
    test('agrees with AstronomyCalculations.angularSeparation', () {
      // RA in HOURS on the coordinate, DEGREES on the static helper — the unit
      // mismatch that the four-way duplication invited.
      const a = CelestialCoordinate(ra: 5.5, dec: -5.4);
      const b = CelestialCoordinate(ra: 5.6, dec: -1.2);

      expect(
        a.separationDegrees(b),
        closeTo(
          AstronomyCalculations.angularSeparation(
            ra1Deg: a.raDegrees,
            dec1Deg: a.dec,
            ra2Deg: b.raDegrees,
            dec2Deg: b.dec,
          ),
          1e-12,
        ),
      );
    });

    test('is symmetric and zero for a coordinate against itself', () {
      const a = CelestialCoordinate(ra: 13.4, dec: 54.9);
      const b = CelestialCoordinate(ra: 2.1, dec: -60.0);

      expect(a.separationDegrees(a), closeTo(0, 1e-12));
      expect(a.separationDegrees(b), closeTo(b.separationDegrees(a), 1e-12));
    });
  });

  group('angularSeparation matches the law-of-cosines form it replaced', () {
    test('over a spread of ordinary separations', () {
      const cases = <(double, double, double, double)>[
        (0, 0, 90, 0),
        (10, 20, 200, -35),
        (359.9, 89.0, 0.1, 88.0),
        (83.0, -5.4, 84.05, -1.2),
        (201.3, 54.9, 201.5, 54.99),
      ];

      for (final (ra1, dec1, ra2, dec2) in cases) {
        expect(
          AstronomyCalculations.angularSeparation(
            ra1Deg: ra1,
            dec1Deg: dec1,
            ra2Deg: ra2,
            dec2Deg: dec2,
          ),
          closeTo(lawOfCosinesDegrees(ra1, dec1, ra2, dec2), 1e-9),
          reason: 'separation ($ra1,$dec1)->($ra2,$dec2)',
        );
      }
    });

    test('resolves an arcsecond split the law of cosines cannot', () {
      // Two positions one arcsecond apart in dec. acos() of a cosine this close
      // to 1 loses about half the mantissa; haversine keeps it. The reference is
      // the doubles' own difference, not the nominal arcsecond, so the test
      // measures the formula rather than the inputs' rounding.
      const dec1 = 30.0;
      const dec2 = 30.0 + 1 / 3600.0;
      const expected = dec2 - dec1;

      final sep = AstronomyCalculations.angularSeparation(
        ra1Deg: 120.0,
        dec1Deg: dec1,
        ra2Deg: 120.0,
        dec2Deg: dec2,
      );
      final legacy = lawOfCosinesDegrees(120.0, dec1, 120.0, dec2);

      // ~5e-16 deg observed, i.e. below a nanoarcsecond.
      expect(sep, closeTo(expected, 1e-14));
      // ~7e-10 deg observed — 2.6 microarcseconds of avoidable error.
      expect(
        (legacy - expected).abs(),
        greaterThan(100 * (sep - expected).abs()),
        reason: 'haversine must be decisively more accurate here',
      );
    });
  });
}
