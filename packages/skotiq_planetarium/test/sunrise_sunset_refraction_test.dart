// Sunrise/sunset counts atmospheric refraction once.
//
// The dashboard night-timeline strip for 40.0N/-75.0W on 2026-08-01 otherwise
// reports Sunset 20:17 and Sunrise 05:55 local while the two twilight labels
// either side of them (astro dark 22:01, astro dawn 04:11) stay right to the
// minute. The crossing searches evaluate APPARENT altitude, but the rise/set
// target (-0.8333 deg = -34' refraction - 16' semi-diameter) is a GEOMETRIC
// sun-centre altitude that already spends 34' on refraction, so applying ~34'
// twice invents 7.5 minutes of daylight per day. The twilight angles escape
// because Sæmundsson refraction is suppressed below -2 deg.
//
// Ground truth below is an independent NOAA solar-position solve on a 30 s
// grid with 50-step bisection against a geometric sun-centre altitude of
// -0.8333 deg (script: scratchpad/sunsolve.py), which agrees with USNO/NOAA
// published times for this site and date.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  const lat = 40.0;
  const lon = -75.0;
  final date = DateTime(2026, 8, 1);

  // Absolute instants, so the assertions hold on any machine timezone. The
  // twilight model runs dusk-tonight -> dawn-tomorrow, so the morning events
  // belong to Aug 2 (20:13 / 22:01 / 04:11 / 05:59 local at this site).
  final expectedSunsetUtc = DateTime.utc(2026, 8, 2, 0, 13, 37);
  final expectedSunriseUtc = DateTime.utc(2026, 8, 2, 9, 59, 24);
  final expectedAstroDuskUtc = DateTime.utc(2026, 8, 2, 2, 1, 44);
  final expectedAstroDawnUtc = DateTime.utc(2026, 8, 2, 8, 11, 16);

  int minutesFrom(DateTime? actual, DateTime expected) =>
      actual!.toUtc().difference(expected).inSeconds.abs() ~/ 60;

  group('calculateTwilightTimes (dashboard night strip)', () {
    final tw = AstronomyCalculations.calculateTwilightTimes(
      date: date,
      latitudeDeg: lat,
      longitudeDeg: lon,
    );

    test('sunset matches the NOAA solve to under 2 minutes', () {
      expect(minutesFrom(tw.sunset, expectedSunsetUtc), lessThan(2));
    });

    test('sunrise matches the NOAA solve to under 2 minutes', () {
      expect(minutesFrom(tw.sunrise, expectedSunriseUtc), lessThan(2));
    });

    test('the twilight angles stay correct (they always were)', () {
      expect(
        minutesFrom(tw.astronomicalDusk, expectedAstroDuskUtc),
        lessThan(2),
      );
      expect(
        minutesFrom(tw.astronomicalDawn, expectedAstroDawnUtc),
        lessThan(2),
      );
    });

    test('geometric sun altitude at sunset/sunrise is the -0.8333 limb', () {
      for (final t in [tw.sunset!, tw.sunrise!]) {
        expect(
          AstronomyCalculations.sunAltitude(
            dt: t,
            latitudeDeg: lat,
            longitudeDeg: lon,
            apparent: false,
          ),
          closeTo(-0.8333, 0.02),
          reason:
              'refraction is the -34\' already inside the target, so the '
              'search must compare the unrefracted altitude',
        );
      }
    });
  });

  group('calculateSunVisibility / calculateMoonVisibility', () {
    test('sun rise/set carry the same convention as the twilight path', () {
      final vis = AstronomyCalculations.calculateSunVisibility(
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      // Sunset is the same event the twilight strip reports, to the second.
      expect(minutesFrom(vis.setTime, expectedSunsetUtc), lessThan(2));
      // Rise/transit/set describe ONE pass of the sky, so the sunrise here is
      // the one that opened the day of [date] — NOT the following morning that
      // `calculateTwilightTimes` pairs with this sunset. Use
      // calculateTwilightTimes for the dusk -> dawn span.
      expect(vis.riseTime!.isBefore(vis.transitTime!), isTrue);
      expect(vis.setTime!.isAfter(vis.transitTime!), isTrue);
      expect(
        expectedSunriseUtc.difference(vis.riseTime!.toUtc()).inMinutes,
        closeTo(24 * 60, 5),
        reason: 'it is the previous morning, one solar day earlier',
      );
      for (final t in [vis.riseTime!, vis.setTime!]) {
        expect(
          AstronomyCalculations.sunAltitude(
            dt: t,
            latitudeDeg: lat,
            longitudeDeg: lon,
            apparent: false,
          ),
          closeTo(-0.8333, 0.02),
        );
      }
    });

    test('moonrise/moonset sit on the geometric -0.7 limb', () {
      final vis = AstronomyCalculations.calculateMoonVisibility(
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      // The Moon's own -0.7 deg standard altitude is geometric for the same
      // reason, and it went through the identical double-count.
      for (final t in [vis.riseTime, vis.setTime]) {
        if (t == null) continue;
        final (ra, dec, _) = AstronomyCalculations.moonPosition(t);
        final (geoAlt, _) = AstronomyCalculations.equatorialToHorizontal(
          raDeg: ra,
          decDeg: dec,
          latitudeDeg: lat,
          lstHours: AstronomyCalculations.localSiderealTime(t, lon),
        );
        expect(geoAlt, closeTo(-0.7, 0.05));
      }
    });
  });
}
