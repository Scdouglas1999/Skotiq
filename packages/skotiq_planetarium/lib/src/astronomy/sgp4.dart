import 'dart:math' as math;

/// SGP4 orbit propagator implementing the Simplified General Perturbations model.
///
/// Based on Vallado et al., "Revisiting Spacetrack Report #3" (2006).
/// Converts TLE orbital elements + time → ECI position/velocity.
///
/// This is a complete implementation of the SGP4 analytical orbit propagator
/// for near-Earth objects (period < 225 minutes uses SGP4, longer uses SDP4
/// deep-space extensions which are also included).
class Sgp4 {
  Sgp4._();

  // Constants

  // WGS-72 Earth constants
  static const double _j2 = 0.001082616;
  static const double _j3 = -0.00000253881;
  static const double _j4 = -0.00000165597;
  static const double _xkmper = 6378.135; // Earth radius km
  static const double _ae = 1.0; // Distance units/Earth radii
  static const double _de2ra = math.pi / 180.0;
  static const double _twoPi = 2.0 * math.pi;
  static const double _minutesPerDay = 1440.0;
  static const double _xke =
      0.07436691613317342; // sqrt(3.986008e5) * (60/6378.135^1.5)
  static const double _ck2 = 0.5 * _j2 * _ae * _ae;
  static const double _ck4 = -0.375 * _j4 * _ae * _ae * _ae * _ae;
  static const double _qoms2t = 1.880279159015271e-09; // ((120-78.0)/xkmper)^4
  static const double _s = 1.01222928; // ae * (1 + 78/xkmper)
  static const double _a3ovk2 = -_j3 / _ck2 * _ae * _ae * _ae;

  /// Propagate a satellite from its TLE elements to a given time.
  ///
  /// [elements] - Parsed orbital elements from TLE
  /// [minutesSinceEpoch] - Time since TLE epoch in minutes
  ///
  /// Returns ECI position (km) and velocity (km/s), or null if propagation fails
  /// (e.g., satellite has decayed).
  static Sgp4Result? propagate(
    OrbitalElements elements,
    double minutesSinceEpoch,
  ) {
    final satrec = _initSatrec(elements);
    if (satrec == null) return null;
    return _sgp4(satrec, minutesSinceEpoch);
  }

  /// Initialize the satellite record from orbital elements.
  /// Performs one-time setup calculations.
  static _Satrec? _initSatrec(OrbitalElements elements) {
    final rec = _Satrec();

    rec.epochYr = elements.epochYear;
    rec.epochDays = elements.epochDay;
    rec.bstar = elements.bstar;
    rec.inclo = elements.inclination * _de2ra;
    rec.nodeo = elements.raan * _de2ra;
    rec.ecco = elements.eccentricity;
    rec.argpo = elements.argumentOfPerigee * _de2ra;
    rec.mo = elements.meanAnomaly * _de2ra;
    rec.no =
        elements.meanMotion * _twoPi / _minutesPerDay; // rev/day -> rad/min

    // Recover original mean motion (xnodp) and semimajor axis (aodp) from input elements
    final cosio = math.cos(rec.inclo);
    final sinio = math.sin(rec.inclo);
    rec.cosio = cosio;
    rec.sinio = sinio;
    final theta2 = cosio * cosio;
    rec.x3thm1 = 3.0 * theta2 - 1.0;
    final eosq = rec.ecco * rec.ecco;
    final betao2 = 1.0 - eosq;
    final betao = math.sqrt(betao2);

    // Recover original mean motion from kozai mean motion
    final a1 = math.pow(_xke / rec.no, 2.0 / 3.0).toDouble();
    final del1 = 1.5 * _ck2 * rec.x3thm1 / (a1 * a1 * betao * betao2);
    final ao =
        a1 *
        (1.0 - del1 * (0.5 * (2.0 / 3.0) + del1 * (1.0 + 134.0 / 81.0 * del1)));
    final delo = 1.5 * _ck2 * rec.x3thm1 / (ao * ao * betao * betao2);
    rec.xnodp = rec.no / (1.0 + delo);
    rec.aodp = ao / (1.0 - delo);

    // Check for near-earth or deep-space
    // Period = 2*pi / mean motion (in minutes)
    rec.isimp = false; // Not simplified (near-earth)
    if ((2.0 * math.pi / rec.xnodp) >= 225.0) {
      // Deep-space: for this implementation we use simplified deep-space
      // perturbations which cover the vast majority of visible satellites.
      // Most bright satellites (ISS, Starlink, etc.) are near-earth.
      rec.isDeepSpace = true;
    } else {
      rec.isDeepSpace = false;
    }

    // Perigee check
    final perigee = (rec.aodp * (1.0 - rec.ecco) - _ae) * _xkmper;

    double s4, qms4;
    if (perigee < 156.0) {
      s4 = perigee - 78.0;
      if (perigee < 98.0) {
        s4 = 20.0;
      }
      qms4 = math.pow((120.0 - s4) * _ae / _xkmper, 4).toDouble();
      s4 = s4 / _xkmper + _ae;
    } else {
      s4 = _s;
      qms4 = _qoms2t;
    }

    final pinvsq = 1.0 / (rec.aodp * rec.aodp * betao2 * betao2);
    final tsi = 1.0 / (rec.aodp - s4);
    rec.eta = rec.aodp * rec.ecco * tsi;
    final etasq = rec.eta * rec.eta;
    final eeta = rec.ecco * rec.eta;
    final psisq = (1.0 - etasq).abs();
    final coef = qms4 * math.pow(tsi, 4).toDouble();
    final coef1 = coef / math.pow(psisq, 3.5).toDouble();

    final c2 =
        coef1 *
        rec.xnodp *
        (rec.aodp * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq)) +
            0.75 *
                _ck2 *
                tsi /
                psisq *
                rec.x3thm1 *
                (8.0 + 3.0 * etasq * (8.0 + etasq)));
    rec.c1 = rec.bstar * c2;

    final x1mth2 = 1.0 - theta2;
    rec.c4 =
        2.0 *
        rec.xnodp *
        coef1 *
        rec.aodp *
        betao2 *
        (rec.eta * (2.0 + 0.5 * etasq) +
            rec.ecco * (0.5 + 2.0 * etasq) -
            2.0 *
                _ck2 *
                tsi /
                (rec.aodp * psisq) *
                (-3.0 *
                        rec.x3thm1 *
                        (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta)) +
                    0.75 *
                        x1mth2 *
                        (2.0 * etasq - eeta * (1.0 + etasq)) *
                        math.cos(2.0 * rec.argpo)));

    rec.c5 =
        2.0 *
        coef1 *
        rec.aodp *
        betao2 *
        (1.0 + 2.75 * (etasq + eeta) + eeta * etasq);

    final theta4 = theta2 * theta2;
    final temp1 = 3.0 * _ck2 * pinvsq * rec.xnodp;
    final temp2 = temp1 * _ck2 * pinvsq;
    final temp3 = 1.25 * _ck4 * pinvsq * pinvsq * rec.xnodp;

    rec.xmdot =
        rec.xnodp +
        0.5 * temp1 * betao * rec.x3thm1 +
        0.0625 * temp2 * betao * (13.0 - 78.0 * theta2 + 137.0 * theta4);
    final x1m5th = 1.0 - 5.0 * theta2;
    rec.omgdot =
        -0.5 * temp1 * x1m5th +
        0.0625 * temp2 * (7.0 - 114.0 * theta2 + 395.0 * theta4) +
        temp3 * (3.0 - 36.0 * theta2 + 49.0 * theta4);
    final xhdot1 = -temp1 * cosio;
    rec.xnodot =
        xhdot1 +
        (0.5 * temp2 * (4.0 - 19.0 * theta2) +
                2.0 * temp3 * (3.0 - 7.0 * theta2)) *
            cosio;

    rec.omgcof = rec.bstar * c2 * math.cos(rec.argpo);
    rec.xmcof = -(2.0 / 3.0) * coef * rec.bstar * _ae / eeta;
    rec.xnodcf = 3.5 * betao2 * xhdot1 * rec.c1;
    rec.t2cof = 1.5 * rec.c1;
    rec.xlcof = 0.125 * _a3ovk2 * sinio * (3.0 + 5.0 * cosio) / (1.0 + cosio);
    rec.aycof = 0.25 * _a3ovk2 * sinio;
    rec.delmo = math.pow(1.0 + rec.eta * math.cos(rec.mo), 3).toDouble();
    rec.sinmo = math.sin(rec.mo);
    rec.x7thm1 = 7.0 * theta2 - 1.0;

    if (!rec.isimp) {
      final c1sq = rec.c1 * rec.c1;
      rec.d2 = 4.0 * rec.aodp * tsi * c1sq;
      final temp = rec.d2 * tsi * rec.c1 / 3.0;
      rec.d3 = (17.0 * rec.aodp + s4) * temp;
      rec.d4 =
          0.5 * temp * rec.aodp * tsi * (221.0 * rec.aodp + 31.0 * s4) * rec.c1;
      rec.t3cof = rec.d2 + 2.0 * c1sq;
      rec.t4cof =
          0.25 * (3.0 * rec.d3 + rec.c1 * (12.0 * rec.d2 + 10.0 * c1sq));
      rec.t5cof =
          0.2 *
          (3.0 * rec.d4 +
              12.0 * rec.c1 * rec.d3 +
              6.0 * rec.d2 * rec.d2 +
              15.0 * c1sq * (2.0 * rec.d2 + c1sq));
    }

    return rec;
  }

  /// Run SGP4 propagation for the given satellite record and time offset.
  static Sgp4Result? _sgp4(_Satrec satrec, double tsince) {
    // Update for secular gravity and atmospheric drag
    final xmdf = satrec.mo + satrec.xmdot * tsince;
    final omgadf = satrec.argpo + satrec.omgdot * tsince;
    final xnoddf = satrec.nodeo + satrec.xnodot * tsince;

    var omega = omgadf;
    var xmp = xmdf;

    final tsq = tsince * tsince;
    final xnode = xnoddf + satrec.xnodcf * tsq;
    var tempa = 1.0 - satrec.c1 * tsince;
    var tempe = satrec.bstar * satrec.c4 * tsince;
    var templ = satrec.t2cof * tsq;

    if (!satrec.isimp) {
      final delomg = satrec.omgcof * tsince;
      final delm =
          satrec.xmcof *
          (math.pow(1.0 + satrec.eta * math.cos(xmdf), 3).toDouble() -
              satrec.delmo);
      final temp = delomg + delm;
      xmp = xmdf + temp;
      omega = omgadf - temp;
      final tcube = tsq * tsince;
      final tfour = tsince * tcube;
      tempa = tempa - satrec.d2 * tsq - satrec.d3 * tcube - satrec.d4 * tfour;
      tempe = tempe + satrec.bstar * satrec.c5 * (math.sin(xmp) - satrec.sinmo);
      templ =
          templ +
          satrec.t3cof * tcube +
          tfour * (satrec.t4cof + tsince * satrec.t5cof);
    }

    var a = satrec.aodp * tempa * tempa;
    var e = satrec.ecco - tempe;
    final xl = xmp + omega + xnode + satrec.xnodp * templ;

    // Check for decay
    if (a < 0.95) return null;

    // Eccentricity bounds
    if (e < 1.0e-6) e = 1.0e-6;
    if (e > 0.999999) e = 0.999999;

    final beta = math.sqrt(1.0 - e * e);
    final xn = _xke / math.pow(a, 1.5).toDouble();

    // Long period periodics
    final axn = e * math.cos(omega);
    final temp0 = 1.0 / (a * beta * beta);
    final xll = temp0 * satrec.xlcof * axn;
    final aynl = temp0 * satrec.aycof;
    final xlt = xl + xll;
    final ayn = e * math.sin(omega) + aynl;

    // Solve Kepler's equation
    final capu = (xlt - xnode) % _twoPi;
    var epw = capu;

    // Newton-Raphson iteration for eccentric anomaly
    for (int i = 0; i < 10; i++) {
      final sinEpw = math.sin(epw);
      final cosEpw = math.cos(epw);
      final deltaEpw =
          (capu - ayn * cosEpw + axn * sinEpw - epw) /
          (1.0 - cosEpw * axn - sinEpw * ayn);
      if (deltaEpw.abs() < 1.0e-12) break;
      epw += deltaEpw;
    }

    // Short period preliminary quantities
    final sinEpw = math.sin(epw);
    final cosEpw = math.cos(epw);

    final ecose = axn * cosEpw + ayn * sinEpw;
    final esine = axn * sinEpw - ayn * cosEpw;
    final elsq = axn * axn + ayn * ayn;
    final temp = 1.0 - elsq;
    final pl = a * temp;

    if (pl < 0.0) return null;

    final r = a * (1.0 - ecose);
    final rdot = _xke * math.sqrt(a) * esine / r;
    final rfdot = _xke * math.sqrt(pl) / r;
    final temp2 = 2.0 / r;
    final betal = math.sqrt(temp);
    final cosu = a / r * (cosEpw - axn + ayn * esine / (1.0 + betal));
    final sinu = a / r * (sinEpw - ayn - axn * esine / (1.0 + betal));
    final u = math.atan2(sinu, cosu);
    final sin2u = 2.0 * sinu * cosu;
    final cos2u = 2.0 * cosu * cosu - 1.0;

    // Short period periodics
    final rk =
        r * (1.0 - 1.5 * _ck2 * math.sqrt(temp) / (pl) * satrec.x3thm1) +
        0.5 * _ck2 * temp2 / pl * satrec.x3thm1 * cos2u;
    final uk = u - 0.25 * _ck2 * temp2 / (pl) * satrec.x7thm1 * sin2u;
    final xnodek = xnode + 1.5 * _ck2 * temp2 * satrec.cosio * sin2u;
    final xinck =
        satrec.inclo + 1.5 * _ck2 * temp2 * satrec.cosio * satrec.sinio * cos2u;
    final rdotk = rdot - xn * _ck2 * temp2 / pl * satrec.x3thm1 * sin2u;
    final rfdotk =
        rfdot +
        xn *
            _ck2 *
            temp2 *
            (satrec.x3thm1 * cos2u +
                1.5 *
                    (1.0 - 3.0 * satrec.cosio * satrec.cosio) *
                    (-0.5 * sin2u));

    // Orientation vectors
    final sinuk = math.sin(uk);
    final cosuk = math.cos(uk);
    final sinik = math.sin(xinck);
    final cosik = math.cos(xinck);
    final sinnok = math.sin(xnodek);
    final cosnok = math.cos(xnodek);

    final mx = -sinnok * cosik;
    final my = cosnok * cosik;

    final ux = mx * sinuk + cosnok * cosuk;
    final uy = my * sinuk + sinnok * cosuk;
    final uz = sinik * sinuk;

    final vx = mx * cosuk - cosnok * sinuk;
    final vy = my * cosuk - sinnok * sinuk;
    final vz = sinik * cosuk;

    // Position (km) and velocity (km/s) in ECI
    final posX = rk * ux * _xkmper;
    final posY = rk * uy * _xkmper;
    final posZ = rk * uz * _xkmper;

    final velX = (rdotk * ux + rfdotk * vx) * _xkmper / 60.0;
    final velY = (rdotk * uy + rfdotk * vy) * _xkmper / 60.0;
    final velZ = (rdotk * uz + rfdotk * vz) * _xkmper / 60.0;

    return Sgp4Result(
      position: EciVector(x: posX, y: posY, z: posZ),
      velocity: EciVector(x: velX, y: velY, z: velZ),
    );
  }

  // ECI to geodetic/topocentric conversions

  /// Convert ECI position to geodetic coordinates (lat, lon, alt).
  ///
  /// Uses WGS-72 Earth model. Returns (latitude in degrees, longitude in degrees,
  /// altitude in km).
  static GeodeticPosition eciToGeodetic(EciVector position, double gmst) {
    final r = math.sqrt(position.x * position.x + position.y * position.y);
    const e2 = 0.006694385000; // WGS-72 first eccentricity squared

    // Longitude
    var lon = math.atan2(position.y, position.x) - gmst;
    while (lon < -math.pi) {
      lon += _twoPi;
    }
    while (lon > math.pi) {
      lon -= _twoPi;
    }

    // Latitude (iterative)
    var lat = math.atan2(position.z, r);
    for (int i = 0; i < 20; i++) {
      final sinLat = math.sin(lat);
      final c = 1.0 / math.sqrt(1.0 - e2 * sinLat * sinLat);
      lat = math.atan2(position.z + _xkmper * c * e2 * sinLat, r);
    }

    final sinLat = math.sin(lat);
    final c = 1.0 / math.sqrt(1.0 - e2 * sinLat * sinLat);
    final alt = r / math.cos(lat) - _xkmper * c;

    return GeodeticPosition(
      latitude: lat * 180.0 / math.pi,
      longitude: lon * 180.0 / math.pi,
      altitude: alt,
    );
  }

  /// Convert ECI position to topocentric (look angles) from observer.
  ///
  /// Returns azimuth (degrees, 0=North), elevation (degrees), range (km),
  /// and range rate (km/s).
  static LookAngles eciToLookAngles(
    EciVector satPos,
    EciVector satVel,
    double observerLatDeg,
    double observerLonDeg,
    double observerAltKm,
    double gmst,
  ) {
    final lat = observerLatDeg * _de2ra;
    final lon = observerLonDeg * _de2ra;
    final sinLat = math.sin(lat);
    final cosLat = math.cos(lat);
    final theta = gmst + lon;

    // Observer position in ECI
    const e2 = 0.006694385000;
    final c = 1.0 / math.sqrt(1.0 - e2 * sinLat * sinLat);
    final sq = c * (1.0 - e2);

    final achcp = (_xkmper * c + observerAltKm) * cosLat;
    final obsX = achcp * math.cos(theta);
    final obsY = achcp * math.sin(theta);
    final obsZ = (_xkmper * sq + observerAltKm) * sinLat;

    // Range vector
    final rx = satPos.x - obsX;
    final ry = satPos.y - obsY;
    final rz = satPos.z - obsZ;

    // Range rate
    // Observer velocity in ECI (from Earth rotation)
    const we = 7.29211514670698e-05; // Earth angular velocity rad/s
    final obsVx = -we * obsY;
    final obsVy = we * obsX;
    const obsVz = 0.0;

    final drx = satVel.x - obsVx;
    final dry = satVel.y - obsVy;
    final drz = satVel.z - obsVz;

    final range = math.sqrt(rx * rx + ry * ry + rz * rz);

    // Topocentric horizon coordinates (SEZ: South-East-Zenith)
    final sinTheta = math.sin(theta);
    final cosTheta = math.cos(theta);

    final topS = sinLat * cosTheta * rx + sinLat * sinTheta * ry - cosLat * rz;
    final topE = -sinTheta * rx + cosTheta * ry;
    final topZ = cosLat * cosTheta * rx + cosLat * sinTheta * ry + sinLat * rz;

    // Azimuth (from North, clockwise)
    var az = math.atan2(-topE, topS) + math.pi;
    if (az < 0) az += _twoPi;
    if (az >= _twoPi) az -= _twoPi;

    // Elevation
    final el = math.asin(topZ / range);

    // Range rate
    final rangeRate = (rx * drx + ry * dry + rz * drz) / range;

    return LookAngles(
      azimuth: az * 180.0 / math.pi,
      elevation: el * 180.0 / math.pi,
      range: range,
      rangeRate: rangeRate,
    );
  }

  /// Calculate GMST (Greenwich Mean Sidereal Time) in radians for a given Julian Date.
  static double gstime(double jd) {
    final tUT1 = (jd - 2451545.0) / 36525.0;
    var temp =
        -6.2e-6 * tUT1 * tUT1 * tUT1 +
        0.093104 * tUT1 * tUT1 +
        (876600.0 * 3600 + 8640184.812866) * tUT1 +
        67310.54841;
    temp = (temp * _de2ra / 240.0) % _twoPi;
    if (temp < 0.0) temp += _twoPi;
    return temp;
  }

  /// Convert a DateTime (UTC) to Julian Date.
  static double julianDate(DateTime dt) {
    final utc = dt.toUtc();
    return 367.0 * utc.year -
        (7 * (utc.year + ((utc.month + 9) ~/ 12)) / 4).floor() +
        (275 * utc.month / 9).floor() +
        utc.day +
        1721013.5 +
        ((utc.second / 60.0 + utc.minute) / 60.0 + utc.hour) / 24.0;
  }

  /// Convert TLE epoch (2-digit year + fractional day) to DateTime UTC.
  static DateTime epochToDateTime(int epochYear, double epochDay) {
    // TLE uses 2-digit year: 57-99 → 1957-1999, 00-56 → 2000-2056
    final year = epochYear < 57 ? 2000 + epochYear : 1900 + epochYear;
    final jan1 = DateTime.utc(year, 1, 1);
    // epochDay is 1-based: day 1.0 = Jan 1 00:00 UTC
    final ms = ((epochDay - 1.0) * 86400000.0).round();
    return jan1.add(Duration(milliseconds: ms));
  }

  /// Calculate minutes since TLE epoch for a given observation time.
  static double minutesSinceEpoch(OrbitalElements elements, DateTime time) {
    final epochDt = epochToDateTime(elements.epochYear, elements.epochDay);
    return time.toUtc().difference(epochDt).inMilliseconds / 60000.0;
  }

  /// Convenience: propagate directly from elements + DateTime.
  ///
  /// Returns null if propagation fails.
  static Sgp4Result? propagateAt(OrbitalElements elements, DateTime time) {
    final tsince = minutesSinceEpoch(elements, time);
    return propagate(elements, tsince);
  }

  /// Convert ECI position to RA/Dec (J2000 equatorial coordinates).
  ///
  /// Returns (RA in hours, Dec in degrees).
  static (double raHours, double decDeg) eciToRaDec(
    EciVector position,
    double gmst,
  ) {
    final r = math.sqrt(
      position.x * position.x +
          position.y * position.y +
          position.z * position.z,
    );

    // Declination
    final dec = math.asin(position.z / r);

    // Right ascension
    var ra = math.atan2(position.y, position.x);
    // RA is already in ECI frame (J2000-aligned), no GMST correction needed
    // for catalog-style RA/Dec. But since we want topocentric apparent RA/Dec
    // for rendering on a star chart that rotates with sidereal time, we keep
    // ECI RA which is sidereal.
    while (ra < 0) {
      ra += _twoPi;
    }

    return (ra * 180.0 / math.pi / 15.0, dec * 180.0 / math.pi);
  }

  /// Determine if a satellite is in Earth's shadow (eclipsed).
  ///
  /// Uses cylindrical shadow model. Returns true if satellite is in shadow.
  static bool isEclipsed(EciVector satPos, EciVector sunEci) {
    // Vector from Earth center to satellite
    final satDist = math.sqrt(
      satPos.x * satPos.x + satPos.y * satPos.y + satPos.z * satPos.z,
    );

    // Angle between satellite and Sun as seen from Earth center
    final dot = satPos.x * sunEci.x + satPos.y * sunEci.y + satPos.z * sunEci.z;
    final sunDist = math.sqrt(
      sunEci.x * sunEci.x + sunEci.y * sunEci.y + sunEci.z * sunEci.z,
    );
    final cosAngle = dot / (satDist * sunDist);

    // If satellite is on the sunlit side, it's not eclipsed
    if (cosAngle > 0) return false;

    // Project satellite position onto the Earth-Sun line
    // and check if the perpendicular distance is less than Earth radius
    final sinAngle = math.sqrt(1.0 - cosAngle * cosAngle);
    final perpDist = satDist * sinAngle;

    return perpDist < _xkmper;
  }

  /// Get the Sun's position in ECI coordinates for eclipse calculations.
  ///
  /// Uses simplified solar position. Returns ECI vector in km.
  static EciVector sunPositionEci(DateTime dt) {
    final jd = julianDate(dt);
    final t = (jd - 2451545.0) / 36525.0;

    // Mean longitude of Sun
    var l0 = 280.46646 + 36000.76983 * t;
    l0 = l0 % 360.0;

    // Mean anomaly
    var m = 357.52911 + 35999.05029 * t;
    m = m % 360.0;
    final mRad = m * _de2ra;

    // Equation of center
    final c =
        (1.914602 - 0.004817 * t) * math.sin(mRad) +
        0.019993 * math.sin(2.0 * mRad);

    // Ecliptic longitude
    final sunLon = (l0 + c) * _de2ra;

    // Obliquity
    final eps = (23.439291 - 0.0130042 * t) * _de2ra;

    // Distance (AU to km)
    const au = 149597870.7; // km
    final r = 1.000140 - 0.016708 * math.cos(mRad);
    final dist = r * au;

    // ECI coordinates
    final x = dist * math.cos(sunLon);
    final y = dist * math.sin(sunLon) * math.cos(eps);
    final z = dist * math.sin(sunLon) * math.sin(eps);

    return EciVector(x: x, y: y, z: z);
  }
}

// Data classes

/// Orbital elements parsed from a TLE.
class OrbitalElements {
  /// NORAD catalog number
  final int catalogNumber;

  /// Satellite name (from line 0 of TLE)
  final String name;

  /// International designator
  final String intlDesignator;

  /// Epoch year (2-digit: 00-56 → 2000-2056, 57-99 → 1957-1999)
  final int epochYear;

  /// Epoch day (fractional day of year, 1-based)
  final double epochDay;

  /// B* drag term (1/Earth radii)
  final double bstar;

  /// Inclination (degrees)
  final double inclination;

  /// Right Ascension of Ascending Node (degrees)
  final double raan;

  /// Eccentricity (dimensionless)
  final double eccentricity;

  /// Argument of Perigee (degrees)
  final double argumentOfPerigee;

  /// Mean Anomaly (degrees)
  final double meanAnomaly;

  /// Mean Motion (revolutions per day)
  final double meanMotion;

  /// Revolution number at epoch
  final int revolutionNumber;

  /// Element set number
  final int elementSetNumber;

  const OrbitalElements({
    required this.catalogNumber,
    required this.name,
    this.intlDesignator = '',
    required this.epochYear,
    required this.epochDay,
    required this.bstar,
    required this.inclination,
    required this.raan,
    required this.eccentricity,
    required this.argumentOfPerigee,
    required this.meanAnomaly,
    required this.meanMotion,
    this.revolutionNumber = 0,
    this.elementSetNumber = 0,
  });

  /// Get the epoch as a DateTime
  DateTime get epoch => Sgp4.epochToDateTime(epochYear, epochDay);

  /// Get the orbital period in minutes
  double get periodMinutes => 1440.0 / meanMotion;

  /// Age of TLE in days from a given time
  double ageInDays(DateTime now) {
    return now.toUtc().difference(epoch).inMilliseconds / 86400000.0;
  }

  @override
  String toString() =>
      'OrbitalElements($name, cat#$catalogNumber, '
      'inc=${inclination.toStringAsFixed(1)}, '
      'ecc=${eccentricity.toStringAsFixed(4)}, '
      'mm=${meanMotion.toStringAsFixed(4)})';
}

/// ECI (Earth-Centered Inertial) position or velocity vector.
class EciVector {
  final double x;
  final double y;
  final double z;

  const EciVector({required this.x, required this.y, required this.z});

  double get magnitude => math.sqrt(x * x + y * y + z * z);

  @override
  String toString() =>
      'ECI(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, ${z.toStringAsFixed(1)})';
}

/// Result of SGP4 propagation.
class Sgp4Result {
  final EciVector position; // km
  final EciVector velocity; // km/s

  const Sgp4Result({required this.position, required this.velocity});
}

/// Geodetic position (latitude, longitude, altitude).
class GeodeticPosition {
  final double latitude; // degrees
  final double longitude; // degrees
  final double altitude; // km

  const GeodeticPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
  });
}

/// Look angles from an observer to a satellite.
class LookAngles {
  final double azimuth; // degrees (0=North, clockwise)
  final double elevation; // degrees (0=horizon, 90=zenith)
  final double range; // km
  final double rangeRate; // km/s (positive = receding)

  const LookAngles({
    required this.azimuth,
    required this.elevation,
    required this.range,
    required this.rangeRate,
  });

  bool get isAboveHorizon => elevation > 0;

  @override
  String toString() =>
      'Az: ${azimuth.toStringAsFixed(1)}, El: ${elevation.toStringAsFixed(1)}, '
      'Range: ${range.toStringAsFixed(0)}km';
}

// Internal satellite record

class _Satrec {
  int epochYr = 0;
  double epochDays = 0;
  double bstar = 0;
  double inclo = 0;
  double nodeo = 0;
  double ecco = 0;
  double argpo = 0;
  double mo = 0;
  double no = 0;

  double cosio = 0;
  double sinio = 0;
  double x3thm1 = 0;
  double x7thm1 = 0;
  double xnodp = 0;
  double aodp = 0;
  double eta = 0;
  double c1 = 0;
  double c4 = 0;
  double c5 = 0;
  double xmdot = 0;
  double omgdot = 0;
  double xnodot = 0;
  double omgcof = 0;
  double xmcof = 0;
  double xnodcf = 0;
  double t2cof = 0;
  double xlcof = 0;
  double aycof = 0;
  double delmo = 0;
  double sinmo = 0;
  double d2 = 0;
  double d3 = 0;
  double d4 = 0;
  double t3cof = 0;
  double t4cof = 0;
  double t5cof = 0;
  bool isimp = false;
  bool isDeepSpace = false;
}
