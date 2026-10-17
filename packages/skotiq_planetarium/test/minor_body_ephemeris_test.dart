import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/catalogs/minor_planet_catalog.dart';
import 'package:skotiq_planetarium/src/catalogs/mpcorb.dart';

void main() {
  // (1) Ceres, MPCORB epoch K239D (2023-09-13).
  const ceresLine =
      '00001    3.34  0.12 K239D  60.07881   73.42179   80.25496   10.58688  '
      '0.0788175  0.21424651   2.7656460  0 MPO719049  7283 122 1801-2023 0.65 '
      'M-v 30h MPCLINUX   0000      (1) Ceres              20230906';

  group('Keplerian ephemeris sanity vs published values', () {
    test('Ceres position on 2024-01-01 is close to JPL Horizons', () {
      final el = MpcOrbParser.parseAsteroidLine(ceresLine)!;
      final data = KeplerianPropagator.propagate(
        el,
        DateTime.utc(2024, 1, 1, 0, 0, 0),
      );

      // JPL Horizons geocentric astrometric (2024-Jan-01 00:00 UT):
      //   RA ≈ 15h17m  (15.29 h), Dec ≈ -14.6°, r ≈ 2.76 AU, V ≈ 7.9
      expect(data.ra, closeTo(15.29, 0.25)); // within ~0.25h (~15 arcmin in RA)
      expect(data.dec, closeTo(-14.6, 1.0)); // within ~1°
      expect(data.heliocentricDistanceAU, closeTo(2.76, 0.05));
      expect(data.distanceAU, closeTo(2.01, 0.15));
      expect(data.visualMag, closeTo(7.9, 0.6));
    });

    test('heliocentric distance stays inside the orbit bounds', () {
      final el = MpcOrbParser.parseAsteroidLine(ceresLine)!;
      for (final date in [
        DateTime.utc(2024, 1, 1),
        DateTime.utc(2024, 7, 1),
        DateTime.utc(2025, 1, 1),
        DateTime.utc(2026, 1, 1),
      ]) {
        final data = KeplerianPropagator.propagate(el, date);
        expect(
          data.heliocentricDistanceAU,
          inInclusiveRange(
            el.perihelionDistance - 0.01,
            el.aphelionDistance + 0.01,
          ),
        );
        expect(data.ra, inInclusiveRange(0.0, 24.0));
        expect(data.dec, inInclusiveRange(-90.0, 90.0));
      }
    });

    test('bundled Ceres elements produce a physically valid position', () {
      // The embedded catalog uses an older osculating epoch (2024 Jan 1) with
      // its own mean anomaly, so it need not match the fresh MPCORB position
      // exactly — but it must stay a sane point on Ceres's orbit.
      final bundled = MinorPlanetCatalog.asteroids.firstWhere(
        (a) => a.commonName == 'Ceres',
      );
      final data = KeplerianPropagator.propagate(
        bundled,
        DateTime.utc(2024, 1, 1),
      );
      expect(data.ra, inInclusiveRange(0.0, 24.0));
      expect(data.dec, inInclusiveRange(-90.0, 90.0));
      expect(
        data.heliocentricDistanceAU,
        closeTo(bundled.semiMajorAxis, bundled.semiMajorAxis * 0.1),
      );
    });
  });
}
