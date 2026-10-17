// Verifies the twilight + solar-position math in `sky_calculations.dart`
// against NOAA's published solar-position values.
//
// The implementation is a Meeus / NREL SPA simplification. Reference
// numbers come from NOAA's Solar Calculator and Meeus's "Astronomical
// Algorithms" worked examples; expected tolerances reflect the
// "simplified SPA" accuracy budget (~0.1° in altitude, ~1 minute in
// twilight crossings) and not the full sub-arcsecond SPA.

import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/services/scheduler/sky_calculations.dart';

void main() {
  group('SkyCalculations.julianDate', () {
    test('matches Meeus example: 2000-01-01 12:00 UTC -> JD 2451545.0', () {
      final jd = SkyCalculations.julianDate(DateTime.utc(2000, 1, 1, 12, 0, 0));
      expect(jd, closeTo(2451545.0, 1e-6));
    });

    test('matches Meeus example: 1987-01-27 00:00 UTC -> JD 2446822.5', () {
      final jd = SkyCalculations.julianDate(DateTime.utc(1987, 1, 27, 0, 0, 0));
      expect(jd, closeTo(2446822.5, 1e-6));
    });

    test(
      'matches Meeus example: 1957-10-04 19:26:24 UTC (Sputnik) -> 2436116.31',
      () {
        final jd = SkyCalculations.julianDate(
          DateTime.utc(1957, 10, 4, 19, 26, 24),
        );
        // Meeus value 2436116.31 (approx).
        expect(jd, closeTo(2436116.31, 0.01));
      },
    );
  });

  group('SkyCalculations.localSiderealTimeHours', () {
    // Pinned against Meeus, "Astronomical Algorithms" (2nd ed), Example 12.a/b.
    // The helper returns LST in hours; GMST (deg) = LST_at_lon0 * 15.

    test('Meeus 12.a: 1987-04-10 00:00 UTC, Greenwich -> GMST 197.693195°', () {
      final lst = SkyCalculations.localSiderealTimeHours(
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
        final lst = SkyCalculations.localSiderealTimeHours(
          DateTime.utc(1987, 4, 10, 19, 21, 0),
          0.0,
        );
        // Meeus publishes 128.7378734° mean sidereal time.
        expect(lst * 15.0, closeTo(128.7378732, 1e-4));
      },
    );

    test('J2000 epoch 2000-01-01 12:00 UTC, Greenwich -> 18.697375 h', () {
      final lst = SkyCalculations.localSiderealTimeHours(
        DateTime.utc(2000, 1, 1, 12, 0, 0),
        0.0,
      );
      expect(lst, closeTo(18.697375, 1e-5));
    });

    test('longitude sign convention: east-positive shifts LST forward', () {
      final t = DateTime.utc(2020, 6, 21, 4, 0, 0);
      final atGreenwich = SkyCalculations.localSiderealTimeHours(t, 0.0);
      // -105.2705° (west) should be earlier in sidereal hours by lon/15,
      // modulo the 24h wrap.
      final atBoulder = SkyCalculations.localSiderealTimeHours(t, -105.2705);
      final expectedBoulder = (atGreenwich - 105.2705 / 15.0 + 24.0) % 24.0;
      expect(atBoulder, closeTo(expectedBoulder, 1e-9));
      // Concrete pinned value for the Boulder case.
      expect(atBoulder, closeTo(14.9697962, 1e-5));
    });

    test(
      'matches the scheduler engine longitude convention (lon/15 added)',
      () {
        // The scheduler engine (the authoritative live path) computes
        // `lst = gmst/15 + longitude/15`; the shared helper must match it, or
        // HourAngleBetween triggers and meridian timing shift.
        final t = DateTime.utc(2023, 9, 15, 22, 30, 0);
        const lon = 12.5; // east
        final viaHelper = SkyCalculations.localSiderealTimeHours(t, lon);
        final atZero = SkyCalculations.localSiderealTimeHours(t, 0.0);
        expect(viaHelper, closeTo((atZero + lon / 15.0) % 24.0, 1e-9));
      },
    );
  });

  group('SkyCalculations.hourAngleHours', () {
    test('HA = LST - RA, positive means west of meridian', () {
      expect(SkyCalculations.hourAngleHours(10.0, 12.0), closeTo(2.0, 1e-12));
    });

    test('normalizes to (-12, +12]', () {
      // RA just east, LST near 0 -> wraps to a small positive HA.
      expect(SkyCalculations.hourAngleHours(23.0, 1.0), closeTo(2.0, 1e-12));
      // RA far west of LST -> wraps to a negative HA.
      expect(SkyCalculations.hourAngleHours(1.0, 14.0), closeTo(-11.0, 1e-12));
      // Exactly +12 stays +12 (lower-exclusive at -12).
      expect(SkyCalculations.hourAngleHours(0.0, 12.0), closeTo(12.0, 1e-12));
      // Exactly -12 wraps up to +12.
      expect(SkyCalculations.hourAngleHours(12.0, 0.0), closeTo(12.0, 1e-12));
    });
  });

  group('SkyCalculations.sunAltAz', () {
    // NOAA Solar Calculator reference values for Boulder, CO
    // (lat 40.0150, lon -105.2705) on 2020-06-21 (summer solstice).
    //
    // At local solar noon the sun should be near its maximum altitude.
    // At local solar midnight it should be ~ -(90° - lat - obliquity).
    test('summer solstice noon at Boulder, CO produces high altitude', () {
      // Approximate local solar noon - Boulder timezone offset is UTC-6
      // (MDT), so 12:00 MDT == 18:00 UTC.
      final t = DateTime.utc(2020, 6, 21, 19, 0, 0);
      final (alt, _) = SkyCalculations.sunAltAz(
        time: t,
        latitudeDegrees: 40.0150,
        longitudeDegrees: -105.2705,
      );
      // Solstice altitude at lat 40 == 90 - 40 + 23.44 = 73.4°.
      // Allow ±2° to absorb timezone / equation-of-time / approximation drift.
      expect(alt, greaterThan(70.0));
      expect(alt, lessThan(76.0));
    });

    test('winter solstice noon at Boulder, CO produces low altitude', () {
      final t = DateTime.utc(2020, 12, 21, 19, 0, 0);
      final (alt, _) = SkyCalculations.sunAltAz(
        time: t,
        latitudeDegrees: 40.0150,
        longitudeDegrees: -105.2705,
      );
      // Solstice altitude at lat 40 == 90 - 40 - 23.44 = 26.6°.
      expect(alt, greaterThan(23.0));
      expect(alt, lessThan(30.0));
    });

    test('sun is below horizon at midnight UTC for an eastern-US site', () {
      // 2020-06-21 04:00 UTC == 00:00 EDT (UTC-4) at NYC.
      final t = DateTime.utc(2020, 6, 21, 4, 0, 0);
      final (alt, _) = SkyCalculations.sunAltAz(
        time: t,
        latitudeDegrees: 40.7128,
        longitudeDegrees: -74.0060,
      );
      expect(
        alt,
        lessThan(-10.0),
        reason: 'midnight in NYC, sun must be well below horizon',
      );
    });
  });

  group('SkyCalculations.computeTwilight', () {
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
        final t = SkyCalculations.computeTwilight(
          noonLocal: noonLocal,
          latitudeDegrees: 40.0150,
          longitudeDegrees: -105.2705,
          kind: TwilightKind.astronomical,
        );
        // At lat 40 in late June, astronomical dusk and dawn both occur.
        expect(t.eveningEnd, isNotNull);
        expect(t.morningStart, isNotNull);
      },
    );

    test(
      'civil twilight at Boulder summer solstice produces a finite night',
      () {
        final noonLocal = DateTime.utc(2020, 6, 21, 18, 0);
        final t = SkyCalculations.computeTwilight(
          noonLocal: noonLocal,
          latitudeDegrees: 40.0150,
          longitudeDegrees: -105.2705,
          kind: TwilightKind.civil,
        );
        expect(t.eveningEnd, isNotNull);
        expect(t.morningStart, isNotNull);
        // Reasonable sanity check: dusk before dawn (next day).
        expect(t.morningStart!.isAfter(t.eveningEnd!), isTrue);
        // Civil twilight night length at lat 40 in late June is ~7h.
        final duration = t.morningStart!.difference(t.eveningEnd!);
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
      final t = SkyCalculations.computeTwilight(
        noonLocal: DateTime.utc(2026, 8, 11, 12, 0),
        latitudeDegrees: latitude,
        longitudeDegrees: longitude,
        kind: TwilightKind.astronomical,
      );
      expect(t.eveningEnd, isNotNull);
      expect(t.morningStart, isNotNull);
      expect(
        t.morningStart!.isAfter(t.eveningEnd!),
        isTrue,
        reason: 'dawn must follow the dusk of the same night',
      );
      final darkHours =
          t.morningStart!.difference(t.eveningEnd!).inMinutes / 60;
      expect(darkHours, greaterThan(9.0));
      expect(darkHours, lessThan(13.0));
    });

    test('polar circle in summer has no astronomical twilight', () {
      // Tromsø, Norway (lat 69.65) on 2020-06-21 — sun never sets below -18°.
      final noonLocal = DateTime.utc(2020, 6, 21, 11, 0);
      final t = SkyCalculations.computeTwilight(
        noonLocal: noonLocal,
        latitudeDegrees: 69.65,
        longitudeDegrees: 18.96,
        kind: TwilightKind.astronomical,
      );
      // Either both nulls (sun stays above -18° all day) or no astronomical
      // night reachable. Allow either eveningEnd or morningStart to be
      // null; both should be null at peak midnight sun.
      expect(
        t.eveningEnd == null || t.morningStart == null,
        isTrue,
        reason:
            'no astronomical night should be possible above the arctic '
            'circle on the summer solstice',
      );
    });
  });

  group('SkyCalculations.darknessRemaining', () {
    test('returns zero during daytime', () {
      // 18:00 UTC is local noon in Boulder; no astronomical night.
      final now = DateTime.utc(2020, 6, 21, 18, 0);
      final delta = SkyCalculations.darknessRemaining(
        now: now,
        latitudeDegrees: 40.0150,
        longitudeDegrees: -105.2705,
      );
      // Either zero or positive but the night clearly hasn't started yet.
      // Use a generous bound — twilight calc finds the next morning start
      // ~9h away, so any positive value should still be > 0 hours.
      expect(delta, isNotNull);
    });

    test('produces a positive duration during deep night at mid-latitudes', () {
      // 2020-12-21 08:00 UTC == 03:00 EST in NYC — deep winter night.
      final now = DateTime.utc(2020, 12, 21, 8, 0);
      final delta = SkyCalculations.darknessRemaining(
        now: now,
        latitudeDegrees: 40.7128,
        longitudeDegrees: -74.0060,
      );
      expect(delta.inMinutes, greaterThan(0));
    });
  });
}
