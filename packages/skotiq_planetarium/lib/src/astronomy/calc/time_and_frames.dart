part of '../astronomy_calculations.dart';

double _julianDate(DateTime dt, {bool includeMilliseconds = true}) {
  final utc = dt.toUtc();
  final y = utc.year;
  final m = utc.month;
  final d =
      utc.day +
      utc.hour / 24 +
      utc.minute / 1440 +
      utc.second / 86400 +
      (includeMilliseconds ? utc.millisecond / 86400000 : 0);

  final a = ((14 - m) / 12).floor();
  final y2 = y + 4800 - a;
  final m2 = m + 12 * a - 3;

  return d +
      ((153 * m2 + 2) / 5).floor() +
      365 * y2 +
      (y2 / 4).floor() -
      (y2 / 100).floor() +
      (y2 / 400).floor() -
      32045 -
      0.5;
}

DateTime _fromJulianDate(double jd) {
  final z = (jd + 0.5).floor();
  final f = jd + 0.5 - z;

  int a;
  if (z < 2299161) {
    a = z;
  } else {
    final alpha = ((z - 1867216.25) / 36524.25).floor();
    a = z + 1 + alpha - (alpha / 4).floor();
  }

  final b = a + 1524;
  final c = ((b - 122.1) / 365.25).floor();
  final d = (365.25 * c).floor();
  final e = ((b - d) / 30.6001).floor();

  final day = b - d - (30.6001 * e).floor();
  final month = e < 14 ? e - 1 : e - 13;
  final year = month > 2 ? c - 4716 : c - 4715;

  final hours = f * 24;
  final hour = hours.floor();
  final minutes = (hours - hour) * 60;
  final minute = minutes.floor();
  final seconds = (minutes - minute) * 60;
  final second = seconds.floor();
  final millisecond = ((seconds - second) * 1000).round();

  return DateTime.utc(year, month, day, hour, minute, second, millisecond);
}

double _modifiedJulianDate(DateTime dt) => _julianDate(dt) - 2400000.5;

double _greenwichMeanSiderealTime(DateTime dt) {
  final jd = _julianDate(dt);
  final t = (jd - _j2000) / 36525;

  var gmst =
      280.46061837 +
      360.98564736629 * (jd - _j2000) +
      0.000387933 * t * t -
      t * t * t / 38710000;

  gmst = gmst % 360;
  if (gmst < 0) gmst += 360;
  return gmst / 15; // Convert to hours
}

double _localSiderealTime(DateTime dt, double longitudeDeg) {
  final gmst = _greenwichMeanSiderealTime(dt);
  var lst = gmst + longitudeDeg / 15;
  lst = lst % 24;
  if (lst < 0) lst += 24;
  return lst;
}

double _atmosphericRefraction(double trueAltitudeDeg) {
  // No refraction for objects well below horizon
  if (trueAltitudeDeg < -2.0) return 0.0;

  // Bennett (1982) improved formula
  // R = 1.02 / tan(h + 10.3/(h + 5.11)) arcminutes
  final h = trueAltitudeDeg;
  final correctionArcmin = 1.02 / math.tan((h + 10.3 / (h + 5.11)) * _deg2rad);

  return correctionArcmin / 60.0; // Convert arcminutes to degrees
}

double _trueToApparentAltitude(double trueAltDeg) {
  return trueAltDeg + _atmosphericRefraction(trueAltDeg);
}

double _apparentToTrueAltitude(double apparentAltDeg) {
  if (apparentAltDeg < -2.0) return apparentAltDeg;

  // Iterative refinement
  var trueAlt = apparentAltDeg;
  for (var i = 0; i < 3; i++) {
    final refraction = _atmosphericRefraction(trueAlt);
    trueAlt = apparentAltDeg - refraction;
  }
  return trueAlt;
}

(double alt, double az) _equatorialToHorizontal({
  required double raDeg,
  required double decDeg,
  required double latitudeDeg,
  required double lstHours,
}) {
  // Hour angle in degrees
  final ha = (lstHours * 15 - raDeg) * _deg2rad;
  final dec = decDeg * _deg2rad;
  final lat = latitudeDeg * _deg2rad;

  // Calculate altitude
  final sinAlt =
      math.sin(dec) * math.sin(lat) +
      math.cos(dec) * math.cos(lat) * math.cos(ha);
  final alt = math.asin(sinAlt.clamp(-1.0, 1.0));

  // Calculate azimuth with atan2 to stay finite at zenith/nadir and
  // near the poles, where acos-based forms divide by cos(alt) * cos(lat).
  final y = -math.sin(ha) * math.cos(dec);
  final x =
      math.sin(dec) * math.cos(lat) -
      math.cos(dec) * math.sin(lat) * math.cos(ha);
  var az = math.atan2(y, x);
  if (az < 0) az += 2 * math.pi;

  return (alt * _rad2deg, az * _rad2deg);
}

(double ra, double dec) _horizontalToEquatorial({
  required double altDeg,
  required double azDeg,
  required double latitudeDeg,
  required double lstHours,
}) {
  final alt = altDeg * _deg2rad;
  final az = azDeg * _deg2rad;
  final lat = latitudeDeg * _deg2rad;

  // Calculate declination
  final sinDec =
      math.sin(alt) * math.sin(lat) +
      math.cos(alt) * math.cos(lat) * math.cos(az);
  final dec = math.asin(sinDec.clamp(-1.0, 1.0));

  // Calculate hour angle with atan2 so azimuths near zenith/nadir do not
  // produce NaN from tiny denominators.
  final y = -math.sin(az) * math.cos(alt);
  final x =
      math.sin(alt) * math.cos(lat) -
      math.cos(alt) * math.sin(lat) * math.cos(az);
  final ha = math.atan2(y, x);

  // Convert to RA, normalizing to [0, 360).
  var ra = lstHours * 15 - ha * _rad2deg;
  ra = ra % 360;
  if (ra < 0) ra += 360;

  return (ra, dec * _rad2deg);
}

(double ra, double dec) _eclipticToEquatorial({
  required double lonDeg,
  required double latDeg,
  required double obliquityDeg,
}) {
  final lon = lonDeg * _deg2rad;
  final lat = latDeg * _deg2rad;
  final eps = obliquityDeg * _deg2rad;

  final sinDec =
      math.sin(lat) * math.cos(eps) +
      math.cos(lat) * math.sin(eps) * math.sin(lon);
  final dec = math.asin(sinDec.clamp(-1.0, 1.0));

  final y = math.sin(lon) * math.cos(eps) - math.tan(lat) * math.sin(eps);
  final x = math.cos(lon);
  var ra = math.atan2(y, x) * _rad2deg;
  ra = ra % 360; // Ensure proper modulo
  if (ra < 0) ra += 360;

  return (ra, dec * _rad2deg);
}

(double ra, double dec) _galacticToEquatorial({
  required double lonDeg,
  required double latDeg,
}) {
  // IAU galactic pole and ascending node constants (J2000)
  const double alphaGP = 192.85948; // RA of north galactic pole (degrees)
  const double deltaGP = 27.12825; // Dec of north galactic pole (degrees)
  const double lOmega = 32.93192; // Galactic longitude of ascending node

  final l = lonDeg * _deg2rad;
  final b = latDeg * _deg2rad;
  const dGP = deltaGP * _deg2rad;
  const lO = lOmega * _deg2rad;

  // Declination
  final sinDec =
      math.sin(b) * math.sin(dGP) +
      math.cos(b) * math.cos(dGP) * math.sin(l - lO);
  final dec = math.asin(sinDec.clamp(-1.0, 1.0));

  // Right ascension
  final y = math.cos(b) * math.cos(l - lO);
  final x =
      math.sin(b) * math.cos(dGP) -
      math.cos(b) * math.sin(dGP) * math.sin(l - lO);
  var ra = math.atan2(y, x) * _rad2deg + alphaGP;
  ra = ra % 360;
  if (ra < 0) ra += 360;

  return (ra, dec * _rad2deg);
}
