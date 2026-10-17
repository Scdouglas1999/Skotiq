import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Tests for the body-aware, iterative rise/transit/set machinery plus the
/// precession/nutation reduction. Assertions are framed around physical
/// invariants (transit altitude, the apparent altitude at the rise/set limb,
/// hour angle at transit, twilight ordering) so they hold regardless of the
/// test machine's local timezone, while still pinning real ephemeris values to
/// the ~1-2 minute / sub-degree tolerance the feature targets.
void main() {
  // New York City.
  const lat = 40.7128;
  const lon = -74.0060;

  group('Sun rise/transit/set', () {
    final visibility = AstronomyCalculations.calculateSunVisibility(
      date: DateTime(2024, 3, 20), // vernal equinox
      latitudeDeg: lat,
      longitudeDeg: lon,
    );

    test('all events are found on the equinox at mid-latitude', () {
      expect(visibility.riseTime, isNotNull);
      expect(visibility.transitTime, isNotNull);
      expect(visibility.setTime, isNotNull);
      expect(visibility.isCircumpolar, isFalse);
      expect(visibility.neverRises, isFalse);
    });

    test('transit altitude equals 90 - |lat - dec| on the equinox (~49.5)', () {
      // On the equinox the Sun's declination is ~0, so the noon altitude is
      // 90 - latitude. Apparent (refracted) altitude is a hair higher.
      expect(visibility.transitAltitude, closeTo(90 - lat, 0.4));
    });

    // The -0.8333 deg limb is a GEOMETRIC sun-centre altitude: the -34' in it
    // IS the refraction allowance (plus -16' of semi-diameter), which is why
    // it is checked against the unrefracted altitude. Asserting it against the
    // refracted altitude is the double-count that put sunset ~3.5 min late.
    test('geometric Sun altitude at sunset sits on the -0.833 limb', () {
      final geoAlt = AstronomyCalculations.sunAltitude(
        dt: visibility.setTime!,
        latitudeDeg: lat,
        longitudeDeg: lon,
        apparent: false,
      );
      // -34' refraction - 16' semi-diameter = -50' = -0.833 deg.
      expect(geoAlt, closeTo(-0.8333, 0.02));
    });

    test('geometric Sun altitude at sunrise sits on the -0.833 limb', () {
      final geoAlt = AstronomyCalculations.sunAltitude(
        dt: visibility.riseTime!,
        latitudeDeg: lat,
        longitudeDeg: lon,
        apparent: false,
      );
      expect(geoAlt, closeTo(-0.8333, 0.02));
    });

    test('transit occurs at the meridian (hour angle ~0)', () {
      final lst = AstronomyCalculations.localSiderealTime(
        visibility.transitTime!,
        lon,
      );
      final (ra, _) = AstronomyCalculations.sunPosition(
        visibility.transitTime!,
      );
      // Hour angle = LST - RA, normalised to [-12, 12] hours.
      var ha = lst - ra / 15;
      while (ha > 12) {
        ha -= 24;
      }
      while (ha < -12) {
        ha += 24;
      }
      expect(ha.abs(), lessThan(0.5 / 60)); // < 0.5 minutes of time
    });

    test('NYC vernal-equinox solar transit matches published ~17:03 UTC', () {
      // USNO solar transit for NYC on 2024-03-20 is 13:03 EDT = 17:03 UTC.
      final utc = visibility.transitTime!.toUtc();
      final expected = DateTime.utc(2024, 3, 20, 17, 3);
      expect(utc.difference(expected).inMinutes.abs(), lessThanOrEqualTo(2));
    });
  });

  group('Bright star transit (Vega)', () {
    // Vega J2000: RA 18h36m56s = 279.2347 deg, Dec +38.7837 deg.
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: 279.2347,
      decDeg: 38.7837,
      date: DateTime(2024, 7, 15),
      latitudeDeg: 40.0,
      longitudeDeg: -75.0,
    );

    test('transit altitude approaches the zenith from 40N', () {
      // Transit altitude = 90 - |lat - dec| = 90 - |40 - 38.78| ~= 88.78.
      expect(visibility.transitAltitude, closeTo(88.78, 0.3));
    });

    test('Vega is not circumpolar and does set from 40N', () {
      expect(visibility.isCircumpolar, isFalse);
      expect(visibility.neverRises, isFalse);
      expect(visibility.riseTime, isNotNull);
      expect(visibility.setTime, isNotNull);
    });

    test('at transit the star is on the meridian', () {
      final lst = AstronomyCalculations.localSiderealTime(
        visibility.transitTime!,
        -75.0,
      );
      var ha = lst - 279.2347 / 15;
      while (ha > 12) {
        ha -= 24;
      }
      while (ha < -12) {
        ha += 24;
      }
      expect(ha.abs(), lessThan(0.5 / 60));
    });
  });

  test('set paired with a late-window rise is the following set', () {
    // This target is above the horizon at local noon, so the first sampled
    // event is today's set and the second is tomorrow's rise. Pairing those
    // yields -11.6 hours.
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: 12.5 * 15.0,
      decDeg: 35.0,
      date: DateTime(2026, 7, 23),
      latitudeDeg: 39.9719,
      longitudeDeg: -75.3576,
    );

    expect(visibility.riseTime, isNotNull);
    expect(visibility.setTime, isNotNull);
    expect(visibility.setTime!.isAfter(visibility.riseTime!), isTrue);
    expect(visibility.durationAboveHorizon, isNotNull);
    expect(visibility.durationAboveHorizon!.isNegative, isFalse);
    expect(
      visibility.durationAboveHorizon,
      lessThan(const Duration(hours: 24)),
    );
  });

  group('Circumpolar / never-rises classification', () {
    test('high-dec star is circumpolar from a high latitude', () {
      final v = AstronomyCalculations.calculateObjectVisibility(
        raDeg: 100.0,
        decDeg: 85.0,
        date: DateTime(2024, 1, 15),
        latitudeDeg: 60.0,
        longitudeDeg: 0.0,
      );
      expect(v.isCircumpolar, isTrue);
      expect(v.neverRises, isFalse);
      expect(v.riseTime, isNull);
      expect(v.setTime, isNull);
    });

    test('deep-south star never rises from a northern latitude', () {
      final v = AstronomyCalculations.calculateObjectVisibility(
        raDeg: 100.0,
        decDeg: -85.0,
        date: DateTime(2024, 1, 15),
        latitudeDeg: 60.0,
        longitudeDeg: 0.0,
      );
      expect(v.neverRises, isTrue);
      expect(v.isCircumpolar, isFalse);
      expect(v.riseTime, isNull);
      expect(v.transitTime, isNull);
      expect(v.setTime, isNull);
    });
  });

  group('Twilight ordering', () {
    final tw = AstronomyCalculations.calculateTwilightTimes(
      date: DateTime(2024, 3, 20),
      latitudeDeg: lat,
      longitudeDeg: lon,
    );

    test('all twilight phases are present at mid-latitude on the equinox', () {
      expect(tw.sunset, isNotNull);
      expect(tw.civilDusk, isNotNull);
      expect(tw.nauticalDusk, isNotNull);
      expect(tw.astronomicalDusk, isNotNull);
      expect(tw.astronomicalDawn, isNotNull);
      expect(tw.nauticalDawn, isNotNull);
      expect(tw.civilDawn, isNotNull);
      expect(tw.sunrise, isNotNull);
    });

    test('dusk phases descend in the correct order', () {
      expect(tw.sunset!.isBefore(tw.civilDusk!), isTrue);
      expect(tw.civilDusk!.isBefore(tw.nauticalDusk!), isTrue);
      expect(tw.nauticalDusk!.isBefore(tw.astronomicalDusk!), isTrue);
    });

    test('dawn phases ascend in the correct order', () {
      expect(tw.astronomicalDawn!.isBefore(tw.nauticalDawn!), isTrue);
      expect(tw.nauticalDawn!.isBefore(tw.civilDawn!), isTrue);
      expect(tw.civilDawn!.isBefore(tw.sunrise!), isTrue);
    });

    test('astronomical darkness spans dusk to dawn', () {
      final dark = AstronomyCalculations.darknessHours(tw);
      expect(dark, isNotNull);
      expect(dark!.inHours, greaterThan(6));
      expect(dark.inHours, lessThan(11));
    });
  });

  group('Precession and nutation', () {
    test('precession of J2000 coords to 2050 moves by the expected amount', () {
      // General precession is ~50.3"/yr in ecliptic longitude. Over 50 years
      // the equatorial position shifts by order ~0.4 deg; the exact split
      // between RA and Dec depends on the star. We pin the magnitude.
      final (ra, dec) = AstronomyCalculations.precessFromJ2000ToDate(
        raDeg: 279.2347,
        decDeg: 38.7837,
        dt: DateTime.utc(2050, 1, 1),
      );
      final sep = AstronomyCalculations.angularSeparation(
        ra1Deg: 279.2347,
        dec1Deg: 38.7837,
        ra2Deg: ra,
        dec2Deg: dec,
      );
      // ~50 yr of precession ~= 50 * 50.3" ~= 0.70 deg of great-circle motion,
      // reduced by the projection onto this star's position; allow a band.
      expect(sep, greaterThan(0.2));
      expect(sep, lessThan(0.8));
    });

    test('precessing to the J2000 epoch itself is a near no-op', () {
      final (ra, dec) = AstronomyCalculations.precessFromJ2000ToDate(
        raDeg: 100.0,
        decDeg: 20.0,
        dt: DateTime.utc(2000, 1, 1, 12), // J2000.0
      );
      // Only nutation (~arcseconds) remains at the epoch.
      final sep = AstronomyCalculations.angularSeparation(
        ra1Deg: 100.0,
        dec1Deg: 20.0,
        ra2Deg: ra,
        dec2Deg: dec,
      );
      expect(sep, lessThan(0.01)); // < 36 arcsec
    });

    test('mean obliquity at J2000 equals the IAU value', () {
      final eps = AstronomyCalculations.meanObliquity(2451545.0);
      expect(eps, closeTo(23.439291, 1e-4));
    });

    test('nutation in longitude stays within the expected bound', () {
      final (dPsi, dEps) = AstronomyCalculations.nutation(2451545.0);
      // |dPsi| < ~17.2" = 0.00478 deg; |dEps| < ~9.2" = 0.00256 deg.
      expect(dPsi.abs(), lessThan(0.006));
      expect(dEps.abs(), lessThan(0.004));
      expect(dPsi, isNot(equals(0.0)));
    });
  });

  group('Body-aware vs fixed positions', () {
    test('moving-Sun set differs from a frozen-Sun set by a real amount', () {
      // Freeze the Sun at its noon position and compare the resulting set time
      // to the body-aware result. Because the Sun's RA advances ~1deg/day, the
      // two must differ measurably, proving positionAt is actually consulted.
      final date = DateTime(2024, 6, 21);
      final moving = AstronomyCalculations.calculateSunVisibility(
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      final (frozenRa, frozenDec) = AstronomyCalculations.sunPosition(date);
      final frozen = AstronomyCalculations.calculateObjectVisibility(
        raDeg: frozenRa,
        decDeg: frozenDec,
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
        standardAltitude: -0.8333,
        // no positionAt: treated as fixed
      );
      expect(moving.setTime, isNotNull);
      expect(frozen.setTime, isNotNull);
      final deltaSec = moving.setTime!
          .difference(frozen.setTime!)
          .inSeconds
          .abs();
      expect(deltaSec, greaterThan(2));
    });
  });

  group('Sub-minute convergence', () {
    test('refined Sun transit altitude is at its local maximum', () {
      final v = AstronomyCalculations.calculateSunVisibility(
        date: DateTime(2024, 9, 1),
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      final tTransit = v.transitTime!;
      final before = AstronomyCalculations.sunAltitude(
        dt: tTransit.subtract(const Duration(minutes: 2)),
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      final at = AstronomyCalculations.sunAltitude(
        dt: tTransit,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      final after = AstronomyCalculations.sunAltitude(
        dt: tTransit.add(const Duration(minutes: 2)),
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      expect(at, greaterThanOrEqualTo(before - 1e-9));
      expect(at, greaterThanOrEqualTo(after - 1e-9));
      // The cap on residual: the true peak is within the 5-min sample grid
      // refined to ~1s, so neighbours 2 min away must be at least slightly
      // lower (the Sun moves ~0.0x deg/min near noon, so allow a small margin).
      expect(at - math.min(before, after), greaterThan(0.0));
    });
  });
}
