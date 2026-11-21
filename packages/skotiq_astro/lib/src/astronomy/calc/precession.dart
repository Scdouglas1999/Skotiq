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

/// Applies the exact orthogonal 3D nutation rotation
/// R_x(-(eps0 + dEps)) * R_z(dPsi) * R_x(eps0) when [inverse] is false, or its
/// exact transpose when [inverse] is true. Working in unit vectors avoids the
/// tan(dec) singularity at the celestial poles (dec = ±90°).
(double raRad, double decRad) _applyNutation3D({
  required double raRad,
  required double decRad,
  required double eps0Rad,
  required double dPsiRad,
  required double dEpsRad,
  required bool inverse,
}) {
  final cosDec = math.cos(decRad);
  final x0 = cosDec * math.cos(raRad);
  final y0 = cosDec * math.sin(raRad);
  final z0 = math.sin(decRad);

  final epsRad = eps0Rad + dEpsRad;
  final cosE0 = math.cos(eps0Rad);
  final sinE0 = math.sin(eps0Rad);
  final cosE = math.cos(epsRad);
  final sinE = math.sin(epsRad);
  final cosP = math.cos(dPsiRad);
  final sinP = math.sin(dPsiRad);

  final double xOut;
  final double yOut;
  final double zOut;
  if (!inverse) {
    // Mean equatorial -> mean ecliptic -> true ecliptic -> true equatorial
    final y1 = y0 * cosE0 + z0 * sinE0;
    final z1 = -y0 * sinE0 + z0 * cosE0;
    final x2 = x0 * cosP - y1 * sinP;
    final y2 = x0 * sinP + y1 * cosP;
    xOut = x2;
    yOut = y2 * cosE - z1 * sinE;
    zOut = y2 * sinE + z1 * cosE;
  } else {
    // True equatorial -> true ecliptic -> mean ecliptic -> mean equatorial
    final y2 = y0 * cosE + z0 * sinE;
    final z2 = -y0 * sinE + z0 * cosE;
    final x1 = x0 * cosP + y2 * sinP;
    final y1 = -x0 * sinP + y2 * cosP;
    xOut = x1;
    yOut = y1 * cosE0 - z2 * sinE0;
    zOut = y1 * sinE0 + z2 * cosE0;
  }

  return (math.atan2(yOut, xOut), math.asin(zOut.clamp(-1.0, 1.0)));
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

  final raMean = math.atan2(a, b) + z;
  final decMean = math.asin(c.clamp(-1.0, 1.0));

  final (dPsi, dEps) = _nutation(jd);
  final (raApp, decApp) = _applyNutation3D(
    raRad: raMean,
    decRad: decMean,
    eps0Rad: _meanObliquity(jd) * _deg2rad,
    dPsiRad: dPsi * _deg2rad,
    dEpsRad: dEps * _deg2rad,
    inverse: false,
  );

  var raOut = raApp * _rad2deg;
  raOut = raOut % 360;
  if (raOut < 0) raOut += 360;

  return (raOut, decApp * _rad2deg);
}

(double raDeg, double decDeg) _precessFromDateToJ2000({
  required double raDeg,
  required double decDeg,
  required DateTime dt,
}) {
  final jd = _julianDate(dt);
  final t = (jd - _j2000) / 36525;

  final (dPsi, dEps) = _nutation(jd);
  final (raDate, decDate) = _applyNutation3D(
    raRad: raDeg * _deg2rad,
    decRad: decDeg * _deg2rad,
    eps0Rad: _meanObliquity(jd) * _deg2rad,
    dPsiRad: dPsi * _deg2rad,
    dEpsRad: dEps * _deg2rad,
    inverse: true,
  );

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
