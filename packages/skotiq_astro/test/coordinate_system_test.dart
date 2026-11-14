import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  group('CelestialCoordinate', () {
    group('basic properties', () {
      test('raDegrees converts hours to degrees', () {
        // 6 hours = 90 degrees
        const coord = CelestialCoordinate(ra: 6.0, dec: 0.0);
        expect(coord.raDegrees, 90.0);
      });

      test('raRadians converts correctly', () {
        // 12 hours = 180 degrees = pi radians
        const coord = CelestialCoordinate(ra: 12.0, dec: 0.0);
        expect(coord.raRadians, closeTo(math.pi, 1e-10));
      });

      test('decRadians converts correctly', () {
        // 90 degrees = pi/2 radians
        const coord = CelestialCoordinate(ra: 0.0, dec: 90.0);
        expect(coord.decRadians, closeTo(math.pi / 2, 1e-10));
      });

      test('negative declination converts correctly', () {
        const coord = CelestialCoordinate(ra: 0.0, dec: -45.0);
        expect(coord.decRadians, closeTo(-math.pi / 4, 1e-10));
      });
    });

    group('Julian Date and sidereal time', () {
      test('J2000.0 is JD 2451545.0', () {
        expect(
          AstronomyCalculations.julianDate(DateTime.utc(2000, 1, 1, 12)),
          2451545.0,
        );
      });

      test('six hours add a quarter day', () {
        final midnight = AstronomyCalculations.julianDate(
          DateTime.utc(2024, 3, 20),
        );
        final sixAm = AstronomyCalculations.julianDate(
          DateTime.utc(2024, 3, 20, 6),
        );
        expect(sixAm - midnight, closeTo(0.25, 1e-9));
      });

      test('Greenwich sidereal time at J2000.0 is 18h 41m 50s', () {
        final lst = AstronomyCalculations.localSiderealTime(
          DateTime.utc(2000, 1, 1, 12),
          0.0,
        );
        expect(lst, closeTo(18.697374558, 1e-6));
      });

      test('15 degrees of east longitude add one sidereal hour', () {
        final t = DateTime.utc(2000, 1, 1, 12);
        final greenwich = AstronomyCalculations.localSiderealTime(t, 0.0);
        final east = AstronomyCalculations.localSiderealTime(t, 15.0);
        expect((east - greenwich) % 24, closeTo(1.0, 1e-9));
      });

      test('sidereal time stays within 0-24 hours', () {
        final lst = AstronomyCalculations.localSiderealTime(
          DateTime.utc(2000, 1, 1, 12),
          350.0,
        );
        expect(lst, greaterThanOrEqualTo(0.0));
        expect(lst, lessThan(24.0));
      });
    });

    group('RA/Dec to Alt/Az conversion', () {
      (double, double) altAz(
        CelestialCoordinate c,
        double latitude,
        double longitude,
        DateTime time,
      ) => AstronomyCalculations.equatorialToHorizontal(
        raDeg: c.raDegrees,
        decDeg: c.dec,
        latitudeDeg: latitude,
        lstHours: AstronomyCalculations.localSiderealTime(time, longitude),
      );

      test('Polaris altitude approximately equals observer latitude', () {
        const polaris = CelestialCoordinate(ra: 2.53, dec: 89.26);
        final (alt, _) = altAz(polaris, 45.0, -90.0, DateTime.utc(2024, 6, 15));
        expect(alt, closeTo(45.0, 0.75));
      });

      test('an equatorial object at transit sits at 90 - latitude', () {
        final j2000 = DateTime.utc(2000, 1, 1, 12);
        final lst = AstronomyCalculations.localSiderealTime(j2000, 0.0);
        final (alt, az) = altAz(
          CelestialCoordinate(ra: lst, dec: 0.0),
          40.0,
          0.0,
          j2000,
        );
        expect(alt, closeTo(50.0, 1e-6));
        expect(az, closeTo(180.0, 1e-6));
      });

      test('a far-southern object never rises from 45 N', () {
        const deepSouth = CelestialCoordinate(ra: 12.0, dec: -80.0);
        for (var hour = 0; hour < 24; hour++) {
          final (alt, _) = altAz(
            deepSouth,
            45.0,
            0.0,
            DateTime.utc(2024, 1, 15, hour),
          );
          expect(alt, lessThan(-34.9));
        }
      });

      test('an object at the zenith has altitude 90', () {
        final time = DateTime.utc(2024, 3, 20, 6);
        final lst = AstronomyCalculations.localSiderealTime(time, -100.0);
        final (alt, az) = altAz(
          CelestialCoordinate(ra: lst, dec: 35.0),
          35.0,
          -100.0,
          time,
        );
        expect(alt, closeTo(90.0, 1e-6));
        expect(az.isFinite, isTrue);
      });

      test('the celestial pole seen from the north pole stays finite', () {
        final (alt, az) = altAz(
          const CelestialCoordinate(ra: 0.0, dec: 90.0),
          90.0,
          0.0,
          DateTime.utc(2024, 6, 15),
        );
        expect(alt, closeTo(90.0, 0.001));
        expect(az, inInclusiveRange(0.0, 360.0));
      });

      test('Vega transits near the zenith from 40 N', () {
        const vega = CelestialCoordinate(ra: 18.615, dec: 38.78);
        var maxAlt = -90.0;
        for (var minute = 0; minute < 24 * 60; minute++) {
          final (alt, _) = altAz(
            vega,
            40.0,
            -75.0,
            DateTime.utc(2024, 7, 15).add(Duration(minutes: minute)),
          );
          if (alt > maxAlt) maxAlt = alt;
        }
        expect(maxAlt, closeTo(88.78, 0.05));
      });
    });

    group('Twilight edge cases', () {
      test('polar summer does not fabricate astronomical dusk or dawn', () {
        final twilight = AstronomyCalculations.calculateTwilightTimes(
          date: DateTime(2026, 6, 21),
          latitudeDeg: 69.0,
          longitudeDeg: 0.0,
        );

        expect(twilight.astronomicalDusk, isNull);
        expect(twilight.astronomicalDawn, isNull);
        expect(AstronomyCalculations.darknessHours(twilight), isNull);
      });
    });
  });
}
