import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/scheduler/sky_calculations.dart';

/// Parity harness for the astronomy consolidation (release pass, Wave C2).
///
/// Nine files in `skotiq_core` each carried their own Julian Date / GMST /
/// altitude arithmetic. They now call [SkyCalculations]. Every retired copy is
/// reproduced verbatim below, and every assertion is exact `==` on doubles —
/// not `closeTo`. A tolerance would hide precisely the class of change this
/// consolidation must not make: a scheduler that ranks targets a hair
/// differently than the goldens it is pinned to.
void main() {
  // The retired copies, transcribed byte-for-byte

  /// `scheduler_service.dart:140` and `night_analysis_service.dart:1039` and
  /// the inline block in `scheduler_engine/astronomy_helpers.dart:_moonPosition`
  /// — whole-second day fraction.
  double retiredJulianDateWholeSeconds(DateTime dt) {
    final utc = dt.toUtc();
    int y = utc.year;
    int m = utc.month;
    final d =
        utc.day + utc.hour / 24.0 + utc.minute / 1440.0 + utc.second / 86400.0;
    if (m <= 2) {
      y -= 1;
      m += 12;
    }
    final a = (y / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (y + 4716)).floor() +
        (30.6001 * (m + 1)).floor() +
        d +
        b -
        1524.5;
  }

  /// `targets_dao.dart:273` and `coimaging_session_service.dart:984` —
  /// millisecond day fraction, `floorToDouble` instead of `floor`.
  double retiredJulianDateMilliseconds(DateTime atUtc) {
    final utc = atUtc.toUtc();
    var year = utc.year;
    var month = utc.month;
    final dayFraction =
        utc.day +
        (utc.hour / 24.0) +
        (utc.minute / 1440.0) +
        (utc.second / 86400.0) +
        (utc.millisecond / 86400000.0);
    if (month <= 2) {
      year -= 1;
      month += 12;
    }
    final a = (year / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (year + 4716)).floorToDouble() +
        (30.6001 * (month + 1)).floorToDouble() +
        dayFraction +
        b -
        1524.5;
  }

  /// `scheduler_service.dart:107` / `night_analysis_service.dart:1019` — LST in
  /// hours, GMST wrapped before the longitude is added in hours.
  double retiredLstHours(DateTime time, double lonDeg) {
    final jd = retiredJulianDateWholeSeconds(time);
    final t = (jd - 2451545.0) / 36525.0;
    var gmst =
        280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        t * t * t / 38710000.0;
    gmst %= 360.0;
    if (gmst < 0) gmst += 360.0;
    var lst = gmst / 15.0 + lonDeg / 15.0;
    while (lst < 0) {
      lst += 24.0;
    }
    while (lst >= 24) {
      lst -= 24.0;
    }
    return lst;
  }

  /// `targets_dao.dart:262` — GMST in degrees, wrapped into [0,360).
  double retiredGmstDegrees(DateTime atUtc) {
    final jd = retiredJulianDateMilliseconds(atUtc);
    final t = (jd - 2451545.0) / 36525.0;
    final gmst =
        280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        (t * t * t) / 38710000.0;
    var n = gmst % 360.0;
    if (n < 0) n += 360.0;
    return n;
  }

  /// `coimaging_session_service.dart:974` — LST in degrees, wrapped ONCE after
  /// the longitude is added.
  double retiredCoimagingLstDegrees(DateTime atUtc, double longitudeDeg) {
    final jd = retiredJulianDateMilliseconds(atUtc);
    final t = (jd - 2451545.0) / 36525.0;
    final gmst =
        280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        (t * t * t) / 38710000.0;
    final lst = (gmst + longitudeDeg) % 360.0;
    return lst < 0 ? lst + 360.0 : lst;
  }

  /// `forecast_planning_service.dart:396` — LST in hours via degrees.
  double retiredForecastLstHours(DateTime timeUtc, double longitudeDegrees) {
    final jd = retiredJulianDateMilliseconds(timeUtc);
    final t = (jd - 2451545.0) / 36525.0;
    var gmstDeg =
        280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        t * t * t / 38710000.0;
    gmstDeg %= 360.0;
    if (gmstDeg < 0) gmstDeg += 360.0;
    var lstDeg = (gmstDeg + longitudeDegrees) % 360.0;
    if (lstDeg < 0) lstDeg += 360.0;
    return lstDeg / 15.0;
  }

  /// The altitude formula as it stood in `targets_dao`,
  /// `night_analysis_service` and `forecast_planning_service`.
  double retiredAltitudeDegrees({
    required double hourAngleDegrees,
    required double declinationDegrees,
    required double latitudeDegrees,
  }) {
    final latRad = latitudeDegrees * math.pi / 180.0;
    final decRad = declinationDegrees * math.pi / 180.0;
    final haRad = hourAngleDegrees * math.pi / 180.0;
    final sinAlt =
        math.sin(decRad) * math.sin(latRad) +
        math.cos(decRad) * math.cos(latRad) * math.cos(haRad);
    final clamped = sinAlt.clamp(-1.0, 1.0);
    return math.asin(clamped) * 180.0 / math.pi;
  }

  /// `scheduler_service.calculateAltAz` / `astronomy_helpers._calculateAltAz`.
  (double, double) retiredAltAz({
    required double raHours,
    required double decDegrees,
    required double latitudeDegrees,
    required double lstHours,
  }) {
    final dec = decDegrees * math.pi / 180.0;
    final lat = latitudeDegrees * math.pi / 180.0;
    final ha = (lstHours - raHours) * 15.0 * math.pi / 180.0;
    final sinAlt =
        math.sin(dec) * math.sin(lat) +
        math.cos(dec) * math.cos(lat) * math.cos(ha);
    final alt = math.asin(sinAlt.clamp(-1.0, 1.0));
    final y = -math.sin(ha) * math.cos(dec);
    final x =
        math.sin(dec) * math.cos(lat) -
        math.cos(dec) * math.sin(lat) * math.cos(ha);
    var az = math.atan2(y, x);
    if (az < 0) az += 2 * math.pi;
    return (alt * 180.0 / math.pi, az * 180.0 / math.pi);
  }

  // Sample instants
  //
  // Chosen to walk every branch the calendar arithmetic has: the January /
  // February month rollback, leap day, the century-and-400-year Gregorian
  // corrections, midnight and the last millisecond of a day, the J2000 epoch
  // itself, and dates on both sides of "now".
  final instants = <DateTime>[
    DateTime.utc(2000, 1, 1, 12), // J2000.0 exactly
    DateTime.utc(1999, 12, 31, 23, 59, 59, 999), // last ms before a year roll
    DateTime.utc(2026, 1, 1), // midnight, month <= 2 branch
    DateTime.utc(2026, 2, 28, 23, 59, 59, 999),
    DateTime.utc(2024, 2, 29, 6, 30, 15, 250), // leap day
    DateTime.utc(1900, 3, 1), // century, not a leap year
    DateTime.utc(2000, 3, 1), // century that IS a leap year
    DateTime.utc(2100, 7, 4, 18, 45, 12, 1),
    DateTime.utc(2026, 8, 13, 3, 21, 44, 617),
    DateTime.utc(2026, 12, 31, 23, 59, 59),
    // A non-UTC instant: everything must normalize before it computes.
    DateTime(2026, 8, 13, 3, 21, 44, 617),
  ];

  // Longitudes: east, west, prime meridian, past the antimeridian in both
  // directions so the wrap loops actually run more than once.
  const longitudes = <double>[
    0.0,
    -122.4194,
    151.2093,
    179.9999,
    -179.9999,
    360.0,
    -400.0,
  ];

  group('Julian Date', () {
    test('millisecond precision matches the retired DAO/co-imaging copy', () {
      for (final t in instants) {
        expect(
          SkyCalculations.julianDate(t),
          equals(retiredJulianDateMilliseconds(t)),
          reason: 'JD(ms) diverged at $t',
        );
      }
    });

    test('whole-second precision matches the retired scheduler copy', () {
      for (final t in instants) {
        expect(
          SkyCalculations.julianDate(t, includeMilliseconds: false),
          equals(retiredJulianDateWholeSeconds(t)),
          reason: 'JD(s) diverged at $t',
        );
      }
    });

    test('the two precisions really are different numbers', () {
      // Guards the flag itself: if `includeMilliseconds` ever stopped being
      // wired through, both branches would still pass their own parity test
      // while silently collapsing to one behaviour.
      final t = DateTime.utc(2026, 8, 13, 3, 21, 44, 617);
      expect(
        SkyCalculations.julianDate(t),
        isNot(
          equals(SkyCalculations.julianDate(t, includeMilliseconds: false)),
        ),
      );
    });

    test('a zero-millisecond instant is identical under both flags', () {
      final t = DateTime.utc(2026, 8, 13, 3, 21, 44);
      expect(
        SkyCalculations.julianDate(t),
        equals(SkyCalculations.julianDate(t, includeMilliseconds: false)),
      );
    });

    test('J2000.0 is 2451545.0 on the nose', () {
      expect(
        SkyCalculations.julianDate(DateTime.utc(2000, 1, 1, 12)),
        2451545.0,
      );
    });
  });

  group('sidereal time', () {
    test(
      'LST in hours matches the retired scheduler / night-analysis copy',
      () {
        for (final t in instants) {
          for (final lon in longitudes) {
            expect(
              SkyCalculations.localSiderealTimeHours(t, lon),
              equals(retiredLstHours(t, lon)),
              reason: 'LST(h) diverged at $t lon=$lon',
            );
          }
        }
      },
    );

    test('LST stays inside [0, 24) for every sample', () {
      for (final t in instants) {
        for (final lon in longitudes) {
          final lst = SkyCalculations.localSiderealTimeHours(t, lon);
          expect(lst, greaterThanOrEqualTo(0.0));
          expect(lst, lessThan(24.0));
        }
      }
    });

    test('wrapped GMST degrees match the retired TargetsDao copy', () {
      for (final t in instants) {
        expect(
          SkyCalculations.wrap360(
            SkyCalculations.gmstDegreesRaw(SkyCalculations.julianDate(t)),
          ),
          equals(retiredGmstDegrees(t)),
          reason: 'GMST(deg) diverged at $t',
        );
      }
    });

    test('co-imaging LST degrees match its retired single-wrap copy', () {
      for (final t in instants) {
        for (final lon in longitudes) {
          final gmst = SkyCalculations.gmstDegreesRaw(
            SkyCalculations.julianDate(t),
          );
          final lst = (gmst + lon) % 360.0;
          expect(
            lst < 0 ? lst + 360.0 : lst,
            equals(retiredCoimagingLstDegrees(t, lon)),
            reason: 'co-imaging LST(deg) diverged at $t lon=$lon',
          );
        }
      }
    });

    test('forecast LST hours match its retired degrees-then-divide copy', () {
      for (final t in instants) {
        for (final lon in longitudes) {
          var gmstDeg = SkyCalculations.gmstDegreesRaw(
            SkyCalculations.julianDate(t),
          );
          gmstDeg %= 360.0;
          if (gmstDeg < 0) gmstDeg += 360.0;
          var lstDeg = (gmstDeg + lon) % 360.0;
          if (lstDeg < 0) lstDeg += 360.0;
          expect(
            lstDeg / 15.0,
            equals(retiredForecastLstHours(t, lon)),
            reason: 'forecast LST(h) diverged at $t lon=$lon',
          );
        }
      }
    });

    test('the two wrap orders are NOT interchangeable', () {
      // This is why `gmstDegreesRaw` is shared but the wrap is not. If this
      // ever starts passing, the ~1e-9° gap closed and the per-site wraps
      // could be unified — until then, unifying them would move numbers.
      var found = false;
      for (final t in instants) {
        for (final lon in longitudes) {
          final raw = SkyCalculations.gmstDegreesRaw(
            SkyCalculations.julianDate(t),
          );
          final wrapFirst = SkyCalculations.wrap360(
            SkyCalculations.wrap360(raw) + lon,
          );
          final wrapOnce = SkyCalculations.wrap360(raw + lon);
          if (wrapFirst != wrapOnce) found = true;
        }
      }
      expect(
        found,
        isTrue,
        reason: 'expected at least one sample where the wrap order matters',
      );
    });
  });

  group('horizontal coordinates', () {
    const decs = <double>[-89.9, -45.0, 0.0, 23.4392911, 89.9];
    const lats = <double>[-89.9, -33.8688, 0.0, 51.4778, 89.9];
    const has = <double>[-720.0, -180.0, -0.0001, 0.0, 179.9, 400.0];

    test('altitude matches the retired per-site formula', () {
      for (final dec in decs) {
        for (final lat in lats) {
          for (final ha in has) {
            expect(
              SkyCalculations.altitudeDegrees(
                hourAngleDegrees: ha,
                declinationDegrees: dec,
                latitudeDegrees: lat,
              ),
              equals(
                retiredAltitudeDegrees(
                  hourAngleDegrees: ha,
                  declinationDegrees: dec,
                  latitudeDegrees: lat,
                ),
              ),
              reason: 'altitude diverged at dec=$dec lat=$lat ha=$ha',
            );
          }
        }
      }
    });

    test('alt/az matches the retired SchedulerService / engine formula', () {
      const raHoursSamples = <double>[0.0, 5.5877, 18.6156, 23.9999];
      const lstSamples = <double>[0.0, 6.0, 13.37, 23.9999];
      for (final ra in raHoursSamples) {
        for (final dec in decs) {
          for (final lat in lats) {
            for (final lst in lstSamples) {
              final got = SkyCalculations.altAzDegrees(
                raHours: ra,
                decDegrees: dec,
                latitudeDegrees: lat,
                lstHours: lst,
              );
              final want = retiredAltAz(
                raHours: ra,
                decDegrees: dec,
                latitudeDegrees: lat,
                lstHours: lst,
              );
              expect(
                got.$1,
                equals(want.$1),
                reason: 'alt diverged ra=$ra dec=$dec lat=$lat lst=$lst',
              );
              expect(
                got.$2,
                equals(want.$2),
                reason: 'az diverged ra=$ra dec=$dec lat=$lat lst=$lst',
              );
            }
          }
        }
      }
    });

    test('azimuth is always in [0, 360)', () {
      for (final dec in decs) {
        for (final lat in lats) {
          final (_, az) = SkyCalculations.altAzDegrees(
            raHours: 3.25,
            decDegrees: dec,
            latitudeDegrees: lat,
            lstHours: 21.5,
          );
          expect(az, greaterThanOrEqualTo(0.0));
          expect(az, lessThan(360.0));
        }
      }
    });

    test('altitude at the pole from the pole is the latitude', () {
      // Dec +90 seen from lat +51.4778: altitude == latitude, any hour angle.
      for (final ha in has) {
        expect(
          SkyCalculations.altitudeDegrees(
            hourAngleDegrees: ha,
            declinationDegrees: 90.0,
            latitudeDegrees: 51.4778,
          ),
          closeTo(51.4778, 1e-12),
        );
      }
    });
  });

  group('angle wrapping', () {
    test('wrap360 lands in [0, 360)', () {
      for (final d in const [-720.0, -360.0, -0.5, 0.0, 359.9, 360.0, 1080.5]) {
        final w = SkyCalculations.wrap360(d);
        expect(w, greaterThanOrEqualTo(0.0));
        expect(w, lessThan(360.0));
      }
    });

    test('wrap180 lands in [-180, 180)', () {
      for (final d in const [-720.0, -180.0, -0.5, 0.0, 180.0, 359.9, 1080.5]) {
        final w = SkyCalculations.wrap180(d);
        expect(w, greaterThanOrEqualTo(-180.0));
        expect(w, lessThan(180.0));
      }
    });
  });
}
