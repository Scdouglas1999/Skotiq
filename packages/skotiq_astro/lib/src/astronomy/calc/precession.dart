part of '../astronomy_calculations.dart';

(double dPsiDeg, double dEpsDeg) _nutation(double jd) {
  final t = (jd - _j2000) / 36525;

  // Longitude of the ascending node of the Moon's mean orbit.
  final omega = (125.04452 - 1934.136261 * t) * _deg2rad;
  // Mean longitude of the Sun and the Moon.
  final lSun = (280.4665 + 36000.7698 * t) * _deg2rad;
  final lMoon = (218.3165 + 481267.8813 * t) * _deg2rad;

  // Nutation in longitude (arcseconds).
  final dPsiArcsec =
      -17.20 * math.sin(omega) -
      1.32 * math.sin(2 * lSun) -
      0.23 * math.sin(2 * lMoon) +
      0.21 * math.sin(2 * omega);

  // Nutation in obliquity (arcseconds).
  final dEpsArcsec =
      9.20 * math.cos(omega) +
      0.57 * math.cos(2 * lSun) +
      0.10 * math.cos(2 * lMoon) -
      0.09 * math.cos(2 * omega);

  return (dPsiArcsec / 3600.0, dEpsArcsec / 3600.0);
}

double _meanObliquity(double jd) {
  final t = (jd - _j2000) / 36525;
  // Coefficients in arcseconds, expressed about epsilon0 = 23°26'21.448".
  const eps0 = 23.0 + 26.0 / 60.0 + 21.448 / 3600.0;
  return eps0 - (46.8150 * t + 0.00059 * t * t - 0.001813 * t * t * t) / 3600.0;
}

(double raDeg, double decDeg) _precessFromJ2000ToDate({
  required double raDeg,
  required double decDeg,
  required DateTime dt,
}) {
  final jd = _julianDate(dt);
  final t = (jd - _j2000) / 36525;

  // IAU 1976 precession angles (arcseconds), accumulated since J2000.
  final zeta =
      (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) /
      3600.0 *
      _deg2rad;
  final z =
      (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) /
      3600.0 *
      _deg2rad;
  final theta =
      (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) /
      3600.0 *
      _deg2rad;

  final ra0 = raDeg * _deg2rad;
  final dec0 = decDeg * _deg2rad;

  // Precession rotation (Meeus eq. 21.4).
  final a = math.cos(dec0) * math.sin(ra0 + zeta);
  final b =
      math.cos(theta) * math.cos(dec0) * math.cos(ra0 + zeta) -
      math.sin(theta) * math.sin(dec0);
  final c =
      math.sin(theta) * math.cos(dec0) * math.cos(ra0 + zeta) +
      math.cos(theta) * math.sin(dec0);

  var raDate = math.atan2(a, b) + z;
  final decDate = math.asin(c.clamp(-1.0, 1.0));

  // Apply nutation (rotate by dPsi about the ecliptic pole, working in the
  // equatorial frame via the standard first-order correction).
  final (dPsi, dEps) = _nutation(jd);
  final eps = (_meanObliquity(jd) + dEps) * _deg2rad;
  final dPsiRad = dPsi * _deg2rad;
  final dEpsRad = dEps * _deg2rad;

  final dRa =
      (math.cos(eps) + math.sin(eps) * math.sin(raDate) * math.tan(decDate)) *
          dPsiRad -
      (math.cos(raDate) * math.tan(decDate)) * dEpsRad;
  final dDec =
      (math.sin(eps) * math.cos(raDate)) * dPsiRad + math.sin(raDate) * dEpsRad;

  raDate += dRa;
  var raOut = raDate * _rad2deg;
  raOut = raOut % 360;
  if (raOut < 0) raOut += 360;

  return (raOut, (decDate + dDec) * _rad2deg);
}

(double raDeg, double decDeg) _precessFromDateToJ2000({
  required double raDeg,
  required double decDeg,
  required DateTime dt,
}) {
  final jd = _julianDate(dt);
  final t = (jd - _j2000) / 36525;

  // Undo nutation. The forward correction is evaluated at the MEAN place, so
  // simply subtracting it evaluated at the apparent place leaves a
  // second-order residual — a few milliarcseconds, amplified by tan(dec) near
  // the pole. One fixed-point refinement (re-evaluate at the recovered mean
  // place) drives it below a microarcsecond, which is what makes this the
  // exact inverse of [precessFromJ2000ToDate] rather than an approximation
  // that quietly drifts.
  final (dPsi, dEps) = _nutation(jd);
  final eps = (_meanObliquity(jd) + dEps) * _deg2rad;
  final dPsiRad = dPsi * _deg2rad;
  final dEpsRad = dEps * _deg2rad;

  (double, double) nutationOffset(double ra, double dec) => (
    (math.cos(eps) + math.sin(eps) * math.sin(ra) * math.tan(dec)) * dPsiRad -
        (math.cos(ra) * math.tan(dec)) * dEpsRad,
    (math.sin(eps) * math.cos(ra)) * dPsiRad + math.sin(ra) * dEpsRad,
  );

  final raApp = raDeg * _deg2rad;
  final decApp = decDeg * _deg2rad;

  var (dRa, dDec) = nutationOffset(raApp, decApp);
  (dRa, dDec) = nutationOffset(raApp - dRa, decApp - dDec);

  final raDate = raApp - dRa;
  final decDate = decApp - dDec;

  // Same IAU 1976 angles as the forward transform.
  final zeta =
      (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) /
      3600.0 *
      _deg2rad;
  final z =
      (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) /
      3600.0 *
      _deg2rad;
  final theta =
      (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) /
      3600.0 *
      _deg2rad;

  // Meeus eq. 21.5 — the reverse rotation.
  final a = math.cos(decDate) * math.sin(raDate - z);
  final b =
      math.cos(theta) * math.cos(decDate) * math.cos(raDate - z) +
      math.sin(theta) * math.sin(decDate);
  final c =
      math.cos(theta) * math.sin(decDate) -
      math.sin(theta) * math.cos(decDate) * math.cos(raDate - z);

  var raOut = (math.atan2(a, b) - zeta) * _rad2deg;
  raOut = raOut % 360;
  if (raOut < 0) raOut += 360;

  return (raOut, math.asin(c.clamp(-1.0, 1.0)) * _rad2deg);
}
