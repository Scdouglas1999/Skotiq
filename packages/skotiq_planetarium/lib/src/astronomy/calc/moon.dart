part of '../astronomy_calculations.dart';

(double ra, double dec, double distance) _moonPosition(DateTime dt) {
  final jd = _julianDate(dt);
  final t = (jd - _j2000) / 36525;

  // Moon's mean longitude
  var l0 = 218.3164477 + 481267.88123421 * t - 0.0015786 * t * t;
  l0 = l0 % 360;
  if (l0 < 0) l0 += 360;

  // Moon's mean anomaly
  var m = 134.9633964 + 477198.8675055 * t + 0.0087414 * t * t;
  m = m % 360;

  // Moon's mean elongation
  var d = 297.8501921 + 445267.1114034 * t - 0.0018819 * t * t;
  d = d % 360;

  // Moon's argument of latitude
  var f = 93.2720950 + 483202.0175233 * t - 0.0036539 * t * t;
  f = f % 360;

  // Sun's mean anomaly
  var mSun = 357.5291092 + 35999.0502909 * t;
  mSun = mSun % 360;

  // Convert to radians
  // Note: lRad not needed for simplified calculation
  final mRad = m * _deg2rad;
  final dRad = d * _deg2rad;
  final fRad = f * _deg2rad;
  final msRad = mSun * _deg2rad;

  // Longitude corrections (simplified)
  var lon = l0;
  lon += 6.289 * math.sin(mRad);
  lon += 1.274 * math.sin(2 * dRad - mRad);
  lon += 0.658 * math.sin(2 * dRad);
  lon += 0.214 * math.sin(2 * mRad);
  lon -= 0.186 * math.sin(msRad);
  lon -= 0.114 * math.sin(2 * fRad);

  // Latitude corrections (simplified)
  var lat = 0.0;
  lat += 5.128 * math.sin(fRad);
  lat += 0.281 * math.sin(mRad + fRad);
  lat += 0.278 * math.sin(mRad - fRad);
  lat += 0.173 * math.sin(2 * dRad - fRad);

  // Distance corrections (simplified)
  var r = 385000.56;
  r -= 20905.35 * math.cos(mRad);
  r -= 3699.11 * math.cos(2 * dRad - mRad);
  r -= 2955.97 * math.cos(2 * dRad);

  // Obliquity
  final eps = _obliquityJ2000 - 0.0130042 * t;

  // Convert to equatorial
  final (ra, dec) = _eclipticToEquatorial(
    lonDeg: lon,
    latDeg: lat,
    obliquityDeg: eps,
  );

  return (ra, dec, r);
}

double _moonIllumination(DateTime dt) {
  final (moonRa, moonDec, _) = _moonPosition(dt);
  final (sunRa, sunDec) = _sunPosition(dt);

  // Calculate elongation (angle between Moon and Sun)
  final moonRaRad = moonRa * _deg2rad;
  final moonDecRad = moonDec * _deg2rad;
  final sunRaRad = sunRa * _deg2rad;
  final sunDecRad = sunDec * _deg2rad;

  final cosE =
      math.sin(sunDecRad) * math.sin(moonDecRad) +
      math.cos(sunDecRad) *
          math.cos(moonDecRad) *
          math.cos(sunRaRad - moonRaRad);
  final elongation = math.acos(cosE.clamp(-1.0, 1.0));

  // Phase angle (simplified - assumes Moon at same distance as Sun)
  final phaseAngle = math.pi - elongation;

  // Illuminated fraction
  final illumination = (1 + math.cos(phaseAngle)) / 2 * 100;

  return illumination;
}

String _moonPhaseName(DateTime dt) {
  final illumination = _moonIllumination(dt);
  final (moonRa, _, _) = _moonPosition(dt);
  final (sunRa, _) = _sunPosition(dt);

  // Calculate phase angle for waxing/waning
  var phaseDiff = moonRa - sunRa;
  if (phaseDiff < 0) phaseDiff += 360;

  if (illumination < 3) {
    return 'New Moon';
  } else if (illumination < 47) {
    return phaseDiff < 180 ? 'Waxing Crescent' : 'Waning Crescent';
  } else if (illumination < 53) {
    return phaseDiff < 180 ? 'First Quarter' : 'Last Quarter';
  } else if (illumination < 97) {
    return phaseDiff < 180 ? 'Waxing Gibbous' : 'Waning Gibbous';
  } else {
    return 'Full Moon';
  }
}

double _moonAltitude({
  required DateTime dt,
  required double latitudeDeg,
  required double longitudeDeg,
  bool apparent = true,
}) {
  final (ra, dec, _) = _moonPosition(dt);
  final lst = _localSiderealTime(dt, longitudeDeg);
  final (trueAlt, _) = _equatorialToHorizontal(
    raDeg: ra,
    decDeg: dec,
    latitudeDeg: latitudeDeg,
    lstHours: lst,
  );
  return apparent ? _trueToApparentAltitude(trueAlt) : trueAlt;
}

MoonTimes _calculateMoonTimes({
  required DateTime date,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  // Similar algorithm to Sun but accounting for Moon's faster motion
  final localNoon = DateTime(date.year, date.month, date.day, 12);
  final searchStart = localNoon.subtract(const Duration(hours: 12));
  final searchEnd = localNoon.add(const Duration(hours: 36));

  DateTime? moonrise;
  DateTime? moonset;

  // Step through time in 30-minute increments
  var prevAlt = _moonAltitude(
    dt: searchStart,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  for (
    var t = searchStart;
    t.isBefore(searchEnd);
    t = t.add(const Duration(minutes: 30))
  ) {
    final alt = _moonAltitude(
      dt: t,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );

    if (prevAlt < 0 && alt >= 0 && moonrise == null) {
      // Moon is rising - refine with binary search
      moonrise = _refineMoonCrossing(
        t.subtract(const Duration(minutes: 30)),
        t,
        latitudeDeg,
        longitudeDeg,
        true,
      );
    } else if (prevAlt >= 0 && alt < 0 && moonset == null) {
      // Moon is setting - refine with binary search
      moonset = _refineMoonCrossing(
        t.subtract(const Duration(minutes: 30)),
        t,
        latitudeDeg,
        longitudeDeg,
        false,
      );
    }

    prevAlt = alt;

    if (moonrise != null && moonset != null) break;
  }

  return MoonTimes(
    moonrise: moonrise,
    moonset: moonset,
    illumination: _moonIllumination(localNoon),
    phaseName: _moonPhaseName(localNoon),
  );
}

DateTime _refineMoonCrossing(
  DateTime t1,
  DateTime t2,
  double lat,
  double lon,
  bool rising,
) {
  for (var i = 0; i < 20; i++) {
    final tMid = t1.add(
      Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2),
    );
    final alt = _moonAltitude(dt: tMid, latitudeDeg: lat, longitudeDeg: lon);

    if (alt.abs() < 0.01) return tMid;

    if (rising) {
      if (alt < 0) {
        t1 = tMid;
      } else {
        t2 = tMid;
      }
    } else {
      if (alt > 0) {
        t1 = tMid;
      } else {
        t2 = tMid;
      }
    }
  }
  return t1.add(Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2));
}
