// ignore_for_file: unused_element

part of '../astronomy_calculations.dart';

(double ra, double dec) _sunPosition(DateTime dt) {
  final jd = _julianDate(dt);
  final t = (jd - _j2000) / 36525;

  // Mean longitude of the Sun
  var l0 = 280.46646 + 36000.76983 * t + 0.0003032 * t * t;
  l0 = l0 % 360;

  // Mean anomaly of the Sun
  var m = 357.52911 + 35999.05029 * t - 0.0001537 * t * t;
  m = m % 360;
  final mRad = m * _deg2rad;

  // Equation of center
  final c =
      (1.914602 - 0.004817 * t - 0.000014 * t * t) * math.sin(mRad) +
      (0.019993 - 0.000101 * t) * math.sin(2 * mRad) +
      0.000289 * math.sin(3 * mRad);

  // True longitude of the Sun
  final sunLon = l0 + c;

  // Obliquity of ecliptic
  final eps = _obliquityJ2000 - 0.0130042 * t;

  return _eclipticToEquatorial(lonDeg: sunLon, latDeg: 0, obliquityDeg: eps);
}

double _sunAltitude({
  required DateTime dt,
  required double latitudeDeg,
  required double longitudeDeg,
  bool apparent = true,
}) {
  final (ra, dec) = _sunPosition(dt);
  final lst = _localSiderealTime(dt, longitudeDeg);
  final (trueAlt, _) = _equatorialToHorizontal(
    raDeg: ra,
    decDeg: dec,
    latitudeDeg: latitudeDeg,
    lstHours: lst,
  );
  return apparent ? _trueToApparentAltitude(trueAlt) : trueAlt;
}

// Rise/set altitude adjustments (all in degrees, negative = below horizon)
/// Standard refraction at horizon: ~34 arcminutes
const double _refractionAtHorizon = -0.5667;

/// Sun rise/set altitude: -34' (refraction) - 16' (semi-diameter) = -50'
///
/// GEOMETRIC (unrefracted) altitude of the Sun's CENTRE, the USNO/NOAA
/// convention — the -34' term is the refraction allowance, it is not a value
/// to be compared against an already-refracted altitude. See [_apparentLimb].
const double _sunRiseSetAltitude = -0.8333;

/// Moon rise/set altitude: -34' (refraction) - 16' (semi-diameter) + 8' (parallax) ≈ -42'
///
/// Geometric, on the same footing as [_sunRiseSetAltitude].
const double _moonRiseSetAltitude = -0.7;

/// The APPARENT altitude a body shows when its GEOMETRIC centre altitude is
/// [geometricAltDeg].
///
/// Every crossing search in this file evaluates apparent altitude
/// ([sunAltitude] and `_apparentAltitudeOf` both add Sæmundsson refraction),
/// but [_sunRiseSetAltitude] / [_moonRiseSetAltitude] are geometric
/// conventions that already spend -34' on refraction. Comparing the two
/// directly counted refraction twice: sunset came out ~3.5 min late and
/// sunrise ~4.5 min early (symmetric, ~7.5 min of daylight invented), while
/// the twilight angles were unharmed only because [atmosphericRefraction] is
/// suppressed below -2°. Refraction is monotonic in altitude here, so
/// crossing `apparent == _apparentLimb(x)` is exactly crossing
/// `geometric == x` — which is what USNO/NOAA publish.
double _apparentLimb(double geometricAltDeg) =>
    _trueToApparentAltitude(geometricAltDeg);

/// Find time when sun crosses given altitude.
///
/// A coarse 10-minute scan first brackets the FIRST crossing in the
/// requested direction, then bisection refines inside that bracket.
/// Comparing only the window's endpoint altitudes cannot do this: matching
/// signs mean zero OR two crossings, so a window containing both a rise and
/// a set — high latitudes, or west-of-meridian timezones where sunset slips
/// past local midnight — reads as no crossing at all.
DateTime? _findSunAltitudeCrossing({
  required DateTime startTime,
  required DateTime endTime,
  required double targetAlt,
  required double latitudeDeg,
  required double longitudeDeg,
  required bool rising,
}) {
  const step = Duration(minutes: 10);
  double altAt(DateTime t) =>
      _sunAltitude(dt: t, latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg);

  var t = startTime;
  var delta = altAt(t) - targetAlt;
  if (delta.abs() < 0.001) return t;

  DateTime? bracketLo;
  DateTime? bracketHi;
  while (t.isBefore(endTime)) {
    var next = t.add(step);
    if (next.isAfter(endTime)) next = endTime;
    final nextDelta = altAt(next) - targetAlt;
    if (nextDelta.abs() < 0.001) return next;

    final crossesDown = delta > 0 && nextDelta < 0;
    final crossesUp = delta < 0 && nextDelta > 0;
    if ((rising && crossesUp) || (!rising && crossesDown)) {
      bracketLo = t;
      bracketHi = next;
      break;
    }
    t = next;
    delta = nextDelta;
  }
  if (bracketLo == null || bracketHi == null) {
    // No crossing in the requested direction — legitimately null at
    // polar latitudes (sun never reaches the target altitude tonight).
    return null;
  }

  var t1 = bracketLo;
  var t2 = bracketHi;
  for (var i = 0; i < 50; i++) {
    final tMid = t1.add(
      Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2),
    );
    final alt = altAt(tMid);

    if ((alt - targetAlt).abs() < 0.001) {
      return tMid;
    }

    if (rising) {
      if (alt < targetAlt) {
        t1 = tMid;
      } else {
        t2 = tMid;
      }
    } else {
      if (alt > targetAlt) {
        t1 = tMid;
      } else {
        t2 = tMid;
      }
    }
  }

  return t1.add(Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2));
}

TwilightTimes _calculateTwilightTimes({
  required DateTime date,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  // Anchor the search on the SITE's solar noon, not the machine's
  // civil noon. Each event below is found independently as "first
  // crossing in its window" — if the windows were cut on the machine's
  // civil day, a site far from the machine's timezone (remote/headless
  // rig, or simply a high-latitude site where sunset slips past local
  // midnight) gets events from different solar days mixed into one
  // "night" (dusk before sunset, dawn after sunrise). Anchoring on the
  // site's solar day keeps every event on the same night for any
  // machine-TZ/site combination.
  final localNoon = DateTime(date.year, date.month, date.day, 12);
  final tzOffsetHours = localNoon.timeZoneOffset.inMinutes / 60.0;
  final siteSolarNoon = localNoon.add(
    Duration(minutes: ((tzOffsetHours - longitudeDeg / 15.0) * 60).round()),
  );

  // Evening events: first DESCENDING crossing after the site's solar
  // noon. Morning events: first RISING crossing after the site's solar
  // midnight. The generous spans are safe because the direction-aware
  // bracketing in [_findSunAltitudeCrossing] cannot latch onto the
  // wrong crossing.
  final eveningStart = siteSolarNoon;
  final eveningEnd = siteSolarNoon.add(const Duration(hours: 24));
  final morningStart = siteSolarNoon.subtract(const Duration(hours: 12));
  final morningEnd = siteSolarNoon.add(const Duration(hours: 6));

  return TwilightTimes(
    sunset: _findSunAltitudeCrossing(
      startTime: eveningStart,
      endTime: eveningEnd,
      // Geometric -0.8333° expressed on the apparent scale the search
      // runs on, so refraction is not counted twice.
      targetAlt: _apparentLimb(_sunRiseSetAltitude),
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: false,
    ),
    civilDusk: _findSunAltitudeCrossing(
      startTime: eveningStart,
      endTime: eveningEnd,
      targetAlt: AstronomyCalculations.civilTwilightAngle,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: false,
    ),
    nauticalDusk: _findSunAltitudeCrossing(
      startTime: eveningStart,
      endTime: eveningEnd,
      targetAlt: AstronomyCalculations.nauticalTwilightAngle,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: false,
    ),
    astronomicalDusk: _findSunAltitudeCrossing(
      startTime: eveningStart,
      endTime: eveningEnd,
      targetAlt: AstronomyCalculations.astronomicalTwilightAngle,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: false,
    ),
    astronomicalDawn: _findSunAltitudeCrossing(
      startTime: morningStart.add(const Duration(hours: 24)),
      endTime: morningEnd.add(const Duration(hours: 24)),
      targetAlt: AstronomyCalculations.astronomicalTwilightAngle,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: true,
    ),
    nauticalDawn: _findSunAltitudeCrossing(
      startTime: morningStart.add(const Duration(hours: 24)),
      endTime: morningEnd.add(const Duration(hours: 24)),
      targetAlt: AstronomyCalculations.nauticalTwilightAngle,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: true,
    ),
    civilDawn: _findSunAltitudeCrossing(
      startTime: morningStart.add(const Duration(hours: 24)),
      endTime: morningEnd.add(const Duration(hours: 24)),
      targetAlt: AstronomyCalculations.civilTwilightAngle,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: true,
    ),
    sunrise: _findSunAltitudeCrossing(
      startTime: morningStart.add(const Duration(hours: 24)),
      endTime: morningEnd.add(const Duration(hours: 24)),
      // Geometric -0.8333° expressed on the apparent scale the search
      // runs on, so refraction is not counted twice.
      targetAlt: _apparentLimb(_sunRiseSetAltitude),
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      rising: true,
    ),
  );
}

Duration? _darknessHours(TwilightTimes twilight) {
  if (twilight.astronomicalDusk != null && twilight.astronomicalDawn != null) {
    return twilight.astronomicalDawn!.difference(twilight.astronomicalDusk!);
  }
  return null;
}
