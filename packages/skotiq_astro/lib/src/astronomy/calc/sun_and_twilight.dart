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

/// Geometric altitude and azimuth of the Sun's centre, degrees.
(double alt, double az) _sunAltAz({
  required DateTime dt,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final (ra, dec) = _sunPosition(dt);
  return _equatorialToHorizontal(
    raDeg: ra,
    decDeg: dec,
    latitudeDeg: latitudeDeg,
    lstHours: _localSiderealTime(dt, longitudeDeg),
  );
}

/// The Sun's apparent altitude on a ten-minute grid from a site's solar noon
/// to 30 hours later: the one scan every dusk and dawn of that night is read
/// from. Samples are computed on first use and shared between the events.
class _SunScan {
  static const Duration step = Duration(minutes: 10);
  static const int _sampleCount = 30 * 6 + 1;

  final DateTime start;
  final double latitudeDeg;
  final double longitudeDeg;
  final Float64List _altitudes = Float64List(_sampleCount)
    ..fillRange(0, _sampleCount, double.nan);

  _SunScan(this.start, this.latitudeDeg, this.longitudeDeg);

  double _altitudeAt(int i) {
    final cached = _altitudes[i];
    if (!cached.isNaN) return cached;
    return _altitudes[i] = _sunAltitude(
      dt: _timeAt(i),
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
  }

  DateTime _timeAt(int i) => start.add(step * i);

  /// First crossing of [targetAlt] in the requested direction between
  /// [fromHours] and [toHours] after [start], refined by bisection.
  ///
  /// Direction matters: a window can hold both a rise and a set (high
  /// latitudes, or a sunset that slips past local midnight), and comparing
  /// only its endpoint altitudes reads that as no crossing at all.
  DateTime? crossing({
    required double targetAlt,
    required bool rising,
    required int fromHours,
    required int toHours,
  }) {
    final first = fromHours * 6;
    final last = toHours * 6;
    var delta = _altitudeAt(first) - targetAlt;
    if (delta.abs() < 0.001) return _timeAt(first);

    for (var i = first; i < last; i++) {
      final nextDelta = _altitudeAt(i + 1) - targetAlt;
      if (nextDelta.abs() < 0.001) return _timeAt(i + 1);
      final crossesDown = delta > 0 && nextDelta < 0;
      final crossesUp = delta < 0 && nextDelta > 0;
      if ((rising && crossesUp) || (!rising && crossesDown)) {
        return _bisect(_timeAt(i), _timeAt(i + 1), targetAlt, rising);
      }
      delta = nextDelta;
    }
    // No crossing in the requested direction: the Sun never reaches the
    // target altitude this night (polar day or night).
    return null;
  }

  DateTime _bisect(DateTime lo, DateTime hi, double targetAlt, bool rising) {
    var t1 = lo;
    var t2 = hi;
    for (var i = 0; i < 50; i++) {
      final tMid = t1.add(
        Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2),
      );
      final alt = _sunAltitude(
        dt: tMid,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
      );
      if ((alt - targetAlt).abs() < 0.001) return tMid;
      if (rising == (alt < targetAlt)) {
        t1 = tMid;
      } else {
        t2 = tMid;
      }
    }
    return t1.add(
      Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2),
    );
  }
}

/// Mean solar noon at [longitudeDeg] on the calendar day of [date].
///
/// Only the calendar day of [date] is read. The result is an instant in the
/// same zone as a local `DateTime`, so the events derived from it print in the
/// host's local time.
DateTime _siteSolarNoonOfDate(DateTime date, double longitudeDeg) {
  final localNoon = DateTime(date.year, date.month, date.day, 12);
  final tzOffsetHours = localNoon.timeZoneOffset.inMinutes / 60.0;
  return localNoon.add(
    Duration(minutes: ((tzOffsetHours - longitudeDeg / 15.0) * 60).round()),
  );
}

/// Mean solar noon at [longitudeDeg] on whichever day puts it closest to
/// [instant]. Mean rather than apparent: the equation of time moves it by at
/// most ~16 minutes, which cannot move a crossing in or out of a window that
/// is half a day wide on either side.
DateTime _siteSolarNoonNearest(DateTime instant, double longitudeDeg) {
  final utc = instant.toUtc();
  final noonOffset = Duration(
    minutes: ((12.0 - longitudeDeg / 15.0) * 60).round(),
  );
  final day = DateTime.utc(utc.year, utc.month, utc.day);
  var nearest = day.add(noonOffset);
  for (final days in const [-1, 1]) {
    final candidate = day.add(Duration(days: days) + noonOffset);
    if (candidate.difference(utc).abs() < nearest.difference(utc).abs()) {
      nearest = candidate;
    }
  }
  return instant.isUtc ? nearest : nearest.toLocal();
}

/// Every dusk and dawn of the night that follows [siteSolarNoon].
///
/// The night is cut on the SITE's solar day, never the host's civil day. Cut
/// on the host's day, a site far from the host's timezone (a remote rig, or a
/// high-latitude site whose sunset slips past local midnight) gets events from
/// different solar days mixed into one "night": dusk before sunset, dawn after
/// sunrise, or a dawn earlier than its dusk.
///
/// Evening events are the first descending crossing in the 24 hours after
/// solar noon; morning events the first rising crossing between solar midnight
/// and 18 hours after it.
TwilightTimes _twilightTimesFromSolarNoon({
  required DateTime siteSolarNoon,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final scan = _SunScan(siteSolarNoon, latitudeDeg, longitudeDeg);
  DateTime? dusk(double alt) =>
      scan.crossing(targetAlt: alt, rising: false, fromHours: 0, toHours: 24);
  DateTime? dawn(double alt) =>
      scan.crossing(targetAlt: alt, rising: true, fromHours: 12, toHours: 30);

  // Geometric -0.8333 deg expressed on the apparent scale the scan runs on,
  // so refraction is not counted twice.
  final limb = _apparentLimb(_sunRiseSetAltitude);
  return TwilightTimes(
    sunset: dusk(limb),
    civilDusk: dusk(AstronomyCalculations.civilTwilightAngle),
    nauticalDusk: dusk(AstronomyCalculations.nauticalTwilightAngle),
    astronomicalDusk: dusk(AstronomyCalculations.astronomicalTwilightAngle),
    astronomicalDawn: dawn(AstronomyCalculations.astronomicalTwilightAngle),
    nauticalDawn: dawn(AstronomyCalculations.nauticalTwilightAngle),
    civilDawn: dawn(AstronomyCalculations.civilTwilightAngle),
    sunrise: dawn(limb),
  );
}

Duration? _darknessHours(TwilightTimes twilight) {
  if (twilight.astronomicalDusk != null && twilight.astronomicalDawn != null) {
    return twilight.astronomicalDawn!.difference(twilight.astronomicalDusk!);
  }
  return null;
}
