import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  group('Precession and nutation', () {
    test(
      'precession/nutation at celestial poles (+90/-90 deg) stays finite and round-trips',
      () {
        final dt = DateTime.utc(2026, 11, 21, 0, 0, 0);
        for (final poleDec in [90.0, -90.0, 89.999, -89.999]) {
          final (
            raDate,
            decDate,
          ) = AstronomyCalculations.precessFromJ2000ToDate(
            raDeg: 45.0,
            decDeg: poleDec,
            dt: dt,
          );
          expect(raDate.isFinite, isTrue);
          expect(decDate.isFinite, isTrue);
          expect(decDate, inInclusiveRange(-90.0, 90.0));

          final (
            raBack,
            decBack,
          ) = AstronomyCalculations.precessFromDateToJ2000(
            raDeg: raDate,
            decDeg: decDate,
            dt: dt,
          );
          expect(raBack.isFinite, isTrue);
          expect(decBack.isFinite, isTrue);
          expect(decBack, closeTo(poleDec, 1e-4));
        }
      },
    );

    test('Meeus nutation example for 1987 April 10', () {
      // Meeus Example 21.a (2nd ed. Example 22.a): JDE 2446895.5,
      // Δψ = -3.788", Δε = +9.443" from the full IAU 1980 series.
      // This code keeps the four dominant terms, documented to about 1".
      final (dPsiDeg, dEpsDeg) = AstronomyCalculations.nutation(2446895.5);
      expect(dPsiDeg * 3600, closeTo(-3.788, 1.0));
      expect(dEpsDeg * 3600, closeTo(9.443, 1.0));
    });

    test('Meeus precession of theta Persei to 2028 November 13.19', () {
      // Example 20.b starts from the J2000 mean place after proper motion
      // (α = 41.054063°, δ = +49.227750°) and precesses to the mean equinox
      // of 2028 Nov 13.19 TD (α = 41.547214°, δ = +49.348483°).
      // Example 22.a then adds nutation, before aberration:
      //   Δα = +15.843", Δδ = +6.218".
      // precessFromJ2000ToDate applies IAU 1976 precession and nutation,
      // and does not apply aberration, so the apparent place without
      // aberration is the reference.
      const raJ2000 = 41.054063;
      const decJ2000 = 49.227750;
      const raApparent = 41.547214 + 15.843 / 3600;
      const decApparent = 49.348483 + 6.218 / 3600;

      final (ra, dec) = AstronomyCalculations.precessFromJ2000ToDate(
        raDeg: raJ2000,
        decDeg: decJ2000,
        dt: DateTime.utc(2028, 11, 13, 4, 33, 36),
      );

      expect(ra, closeTo(raApparent, 0.002));
      expect(dec, closeTo(decApparent, 0.002));
    });
  });
}
