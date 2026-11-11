// Worked examples from Meeus, "Astronomical Algorithms", and NOAA's Solar
// Calculator, as a second reference beside the astropy grid.

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  group('AstronomyCalculations.julianDate', () {
    test('matches Meeus example: 2000-01-01 12:00 UTC -> JD 2451545.0', () {
      final jd = AstronomyCalculations.julianDate(
        DateTime.utc(2000, 1, 1, 12, 0, 0),
      );
      expect(jd, closeTo(2451545.0, 1e-6));
    });

    test('matches Meeus example: 1987-01-27 00:00 UTC -> JD 2446822.5', () {
      final jd = AstronomyCalculations.julianDate(
        DateTime.utc(1987, 1, 27, 0, 0, 0),
      );
      expect(jd, closeTo(2446822.5, 1e-6));
    });

    test(
      'matches Meeus example: 1957-10-04 19:26:24 UTC (Sputnik) -> 2436116.31',
      () {
        final jd = AstronomyCalculations.julianDate(
          DateTime.utc(1957, 10, 4, 19, 26, 24),
        );
        // Meeus value 2436116.31 (approx).
        expect(jd, closeTo(2436116.31, 0.01));
      },
    );
  });

  group('localSiderealTime', () {
    // Pinned against Meeus, "Astronomical Algorithms" (2nd ed), Example 12.a/b.
    // The helper returns LST in hours; GMST (deg) = LST_at_lon0 * 15.

    test('Meeus 12.a: 1987-04-10 00:00 UTC, Greenwich -> GMST 197.693195°', () {
      final lst = AstronomyCalculations.localSiderealTime(
        DateTime.utc(1987, 4, 10, 0, 0, 0),
        0.0,
      );
      // Meeus publishes mean sidereal time 13h 10m 46.3668s = 197.693195°.
      expect(lst * 15.0, closeTo(197.693195, 1e-4));
      expect(lst, closeTo(13.1795463, 1e-6));
    });

    test(
      'Meeus 12.b: 1987-04-10 19:21:00 UTC, Greenwich -> GMST 128.73787°',
      () {
        final lst = AstronomyCalculations.localSiderealTime(
          DateTime.utc(1987, 4, 10, 19, 21, 0),
          0.0,
        );
        // Meeus publishes 128.7378734° mean sidereal time.
        expect(lst * 15.0, closeTo(128.7378732, 1e-4));
      },
    );

    test('J2000 epoch 2000-01-01 12:00 UTC, Greenwich -> 18.697375 h', () {
      final lst = AstronomyCalculations.localSiderealTime(
        DateTime.utc(2000, 1, 1, 12, 0, 0),
        0.0,
      );
      expect(lst, closeTo(18.697375, 1e-5));
    });

    test('longitude sign convention: east-positive shifts LST forward', () {
      final t = DateTime.utc(2020, 6, 21, 4, 0, 0);
      final atGreenwich = AstronomyCalculations.localSiderealTime(t, 0.0);
      // -105.2705° (west) should be earlier in sidereal hours by lon/15,
      // modulo the 24h wrap.
      final atBoulder = AstronomyCalculations.localSiderealTime(t, -105.2705);
      final expectedBoulder = (atGreenwich - 105.2705 / 15.0 + 24.0) % 24.0;
      expect(atBoulder, closeTo(expectedBoulder, 1e-9));
      // Concrete pinned value for the Boulder case.
      expect(atBoulder, closeTo(14.9697962, 1e-5));
    });

    test('east longitude adds lon/15 hours', () {
      final t = DateTime.utc(2023, 9, 15, 22, 30, 0);
      const lon = 12.5; // east
      final viaHelper = AstronomyCalculations.localSiderealTime(t, lon);
      final atZero = AstronomyCalculations.localSiderealTime(t, 0.0);
      expect(viaHelper, closeTo((atZero + lon / 15.0) % 24.0, 1e-9));
    });
  });

  group('AstronomyCalculations.hourAngleHours', () {
    test('HA = LST - RA, positive means west of meridian', () {
      expect(
        AstronomyCalculations.hourAngleHours(10.0, 12.0),
        closeTo(2.0, 1e-12),
      );
    });

    test('normalizes to (-12, +12]', () {
      // RA just east, LST near 0 -> wraps to a small positive HA.
      expect(
        AstronomyCalculations.hourAngleHours(23.0, 1.0),
        closeTo(2.0, 1e-12),
      );
      // RA far west of LST -> wraps to a negative HA.
      expect(
        AstronomyCalculations.hourAngleHours(1.0, 14.0),
        closeTo(-11.0, 1e-12),
      );
      // Exactly +12 stays +12 (lower-exclusive at -12).
      expect(
        AstronomyCalculations.hourAngleHours(0.0, 12.0),
        closeTo(12.0, 1e-12),
      );
      // Exactly -12 wraps up to +12.
      expect(
        AstronomyCalculations.hourAngleHours(12.0, 0.0),
        closeTo(12.0, 1e-12),
      );
    });
  });

  group('sunAltAz', () {
    // NOAA Solar Calculator reference values for Boulder, CO
    // (lat 40.0150, lon -105.2705) on 2020-06-21 (summer solstice).
    //
    // At local solar noon the sun should be near its maximum altitude.
    // At local solar midnight it should be ~ -(90° - lat - obliquity).
    test('summer solstice noon at Boulder, CO produces high altitude', () {
      // Approximate local solar noon - Boulder timezone offset is UTC-6
      // (MDT), so 12:00 MDT == 18:00 UTC.
      final t = DateTime.utc(2020, 6, 21, 19, 0, 0);
      final (alt, _) = AstronomyCalculations.sunAltAz(
        dt: t,
        latitudeDeg: 40.0150,
        longitudeDeg: -105.2705,
      );
      // Solstice altitude at lat 40 == 90 - 40 + 23.44 = 73.4°.
      // Allow ±2° to absorb timezone / equation-of-time / approximation drift.
      expect(alt, greaterThan(70.0));
      expect(alt, lessThan(76.0));
    });

    test('winter solstice noon at Boulder, CO produces low altitude', () {
      final t = DateTime.utc(2020, 12, 21, 19, 0, 0);
      final (alt, _) = AstronomyCalculations.sunAltAz(
        dt: t,
        latitudeDeg: 40.0150,
        longitudeDeg: -105.2705,
      );
      // Solstice altitude at lat 40 == 90 - 40 - 23.44 = 26.6°.
      expect(alt, greaterThan(23.0));
      expect(alt, lessThan(30.0));
    });

    test('sun is below horizon at midnight UTC for an eastern-US site', () {
      // 2020-06-21 04:00 UTC == 00:00 EDT (UTC-4) at NYC.
      final t = DateTime.utc(2020, 6, 21, 4, 0, 0);
      final (alt, _) = AstronomyCalculations.sunAltAz(
        dt: t,
        latitudeDeg: 40.7128,
        longitudeDeg: -74.0060,
      );
      expect(
        alt,
        lessThan(-10.0),
        reason: 'midnight in NYC, sun must be well below horizon',
      );
    });
  });

  group('twilightTimesNear', () {
    // NOAA: Boulder, CO 2020-06-21
    //   Civil dawn       ~ 05:01 MDT (11:01 UTC)
    //   Astronomical dawn ~ 03:09 MDT (09:09 UTC)
    //   Civil dusk       ~ 21:00 MDT (03:00 UTC next day)
    //   Astronomical dusk ~ 22:52 MDT (04:52 UTC next day)
    test(
      'astronomical twilight at Boulder summer solstice has both events',
      () {
        // Search starts at local noon == 18:00 UTC.
        final noonLocal = DateTime.utc(2020, 6, 21, 18, 0);
        final t = AstronomyCalculations.twilightTimesNear(
          instant: noonLocal,
          latitudeDeg: 40.0150,
          longitudeDeg: -105.2705,
        );
        const kind = TwilightKind.astronomical;
        // At lat 40 in late June, astronomical dusk and dawn both occur.
        expect(t.dusk(kind), isNotNull);
        expect(t.dawn(kind), isNotNull);
      },
    );

    test(
      'civil twilight at Boulder summer solstice produces a finite night',
      () {
        final noonLocal = DateTime.utc(2020, 6, 21, 18, 0);
        final t = AstronomyCalculations.twilightTimesNear(
          instant: noonLocal,
          latitudeDeg: 40.0150,
          longitudeDeg: -105.2705,
        );
        const kind = TwilightKind.civil;
        expect(t.dusk(kind), isNotNull);
        expect(t.dawn(kind), isNotNull);
        // Reasonable sanity check: dusk before dawn (next day).
        expect(t.dawn(kind)!.isAfter(t.dusk(kind)!), isTrue);
        // Civil twilight night length at lat 40 in late June is ~7h.
        final duration = t.dawn(kind)!.difference(t.dusk(kind)!);
        expect(duration.inHours, greaterThanOrEqualTo(6));
        expect(duration.inHours, lessThanOrEqualTo(9));
      },
    );

    // The forecast anchors each night at the MACHINE's local noon; on a host
    // whose clock is not the site's (UTC here, site at UTC+10) that anchor
    // lands in the middle of the site's night, so the search finds the morning
    // crossing first and returns a dawn EARLIER than its dusk — which the
    // forecast reads as zero dark hours. Plan Tonight then says "No
    // astronomical darkness" for all seven nights at a latitude-35 site in
    // August while the Dashboard counts down "Dark 4h 56m left".
    test('an anchor that is not the site\'s noon still brackets one night', () {
      const latitude = -35.0;
      const longitude = 148.0; // UTC+9.9 — 10 hours from the host's UTC clock.
      final t = AstronomyCalculations.twilightTimesNear(
        instant: DateTime.utc(2026, 8, 11, 12, 0),
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );
      const kind = TwilightKind.astronomical;
      expect(t.dusk(kind), isNotNull);
      expect(t.dawn(kind), isNotNull);
      expect(
        t.dawn(kind)!.isAfter(t.dusk(kind)!),
        isTrue,
        reason: 'dawn must follow the dusk of the same night',
      );
      final darkHours = t.dawn(kind)!.difference(t.dusk(kind)!).inMinutes / 60;
      expect(darkHours, greaterThan(9.0));
      expect(darkHours, lessThan(13.0));
    });

    test('polar circle in summer has no astronomical twilight', () {
      // Tromsø, Norway (lat 69.65) on 2020-06-21 — sun never sets below -18°.
      final noonLocal = DateTime.utc(2020, 6, 21, 11, 0);
      final t = AstronomyCalculations.twilightTimesNear(
        instant: noonLocal,
        latitudeDeg: 69.65,
        longitudeDeg: 18.96,
      );
      const kind = TwilightKind.astronomical;
      // Either both nulls (sun stays above -18° all day) or no astronomical
      // night reachable. Allow either eveningEnd or morningStart to be
      // null; both should be null at peak midnight sun.
      expect(
        t.dusk(kind) == null || t.dawn(kind) == null,
        isTrue,
        reason:
            'no astronomical night should be possible above the arctic '
            'circle on the summer solstice',
      );
    });
  });
}
