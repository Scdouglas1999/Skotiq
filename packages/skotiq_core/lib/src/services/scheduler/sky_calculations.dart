import 'dart:math' as math;

/// Pure astronomical helpers shared by the scheduler engine.
///
/// Altitude / azimuth / moon-position / great-circle separation already live
/// in `services/scheduler_service.dart` (the static scheduler). The dynamic
/// scheduler reuses those via composition and adds the twilight calculations
/// it needs, which the static service does not provide.

enum TwilightKind {
  civil, // sun -6°
  nautical, // sun -12°
  astronomical, // sun -18°
}

/// Sun altitude (degrees) corresponding to each twilight boundary.
const Map<TwilightKind, double> _twilightAltitudes = {
  TwilightKind.civil: -6.0,
  TwilightKind.nautical: -12.0,
  TwilightKind.astronomical: -18.0,
};

/// Result of computing twilight for a given local date and site.
///
/// `morningStart` is the instant the sun rises above the twilight altitude
/// (becoming brighter); `eveningEnd` is the instant the sun sinks below it
/// (becoming darker). Either field may be null when the sun never crosses
/// the threshold on that date (polar day/night).
class TwilightTimes {
  final TwilightKind kind;
  final DateTime? eveningEnd;
  final DateTime? morningStart;

  const TwilightTimes({
    required this.kind,
    required this.eveningEnd,
    required this.morningStart,
  });
}

/// Astronomical helpers wrapped in a small namespace.
class SkyCalculations {
  SkyCalculations._();

  /// Julian Date for the given DateTime (converted to UTC first).
  ///
  /// Meeus' Gregorian form. This is the one Julian Date every scheduler,
  /// planner, DAO and co-imaging surface in `skotiq_core` uses.
  ///
  /// [includeMilliseconds] selects the day fraction, and it is a numeric
  /// choice rather than a style knob:
  ///
  /// * `true` (default) — `day + h/24 + m/1440 + s/86400 + ms/86400000`.
  /// * `false` — stops at whole seconds, which is what the scheduler and the
  ///   lunar ephemeris use.
  ///
  /// The two differ by up to 999 ms / 86 400 000 ≈ 1.2e-8 d — astronomically
  /// nothing, but not bit-identical, and the scheduler's numbers are pinned by
  /// golden tests. With `includeMilliseconds` false the sub-second term is a
  /// literal `0`, and `x + 0` is exact for every finite double.
  static double julianDate(DateTime dt, {bool includeMilliseconds = true}) {
    final utc = dt.toUtc();
    int y = utc.year;
    int m = utc.month;
    final d =
        utc.day +
        utc.hour / 24.0 +
        utc.minute / 1440.0 +
        utc.second / 86400.0 +
        (includeMilliseconds ? utc.millisecond / 86400000.0 : 0);

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

  /// Greenwich Mean Sidereal Time in DEGREES for [jd], **unnormalized**.
  ///
  /// The IAU polynomial `280.46061837 + 360.98564736629·(JD−J2000) +
  /// 0.000387933·T² − T³/38710000` — the literal that was retyped in nine
  /// files. Only the polynomial is shared: the callers do not agree on how
  /// they wrap it (some normalize GMST to [0,360) before adding the site
  /// longitude, some add first and wrap once; some end in hours, some in
  /// degrees). Those compositions are one line each and, because GMST for a
  /// modern date is ~3.4e6 degrees, wrapping in a different order moves the
  /// result by ~1e-9° — invisible on the sky but not bit-identical. So the
  /// wrap stays at each call site, where it is already pinned by that site's
  /// own tests, and the part they genuinely share lives here.
  static double gmstDegreesRaw(double jd) {
    final t = (jd - 2451545.0) / 36525.0;
    return 280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        t * t * t / 38710000.0;
  }

  /// Normalize an angle into `[0, 360)`.
  static double wrap360(double degrees) => _wrap360(degrees);

  /// Normalize an angle into `[-180, 180)`.
  static double wrap180(double degrees) => _wrap180(degrees);

  /// Geometric altitude in degrees from an hour angle.
  ///
  /// `asin(sin δ · sin φ + cos δ · cos φ · cos H)` — the formula that was
  /// retyped in `targets_dao`, `night_analysis_service`,
  /// `forecast_planning_service`, `scheduler_service` and the scheduler
  /// engine's helpers. The hour angle is taken in degrees and is NOT wrapped
  /// here: the callers disagree about whether they wrap it (and `cos` of an
  /// unwrapped angle is not bit-identical to `cos` of its wrapped twin), so
  /// each caller keeps the hour angle it already computed.
  static double altitudeDegrees({
    required double hourAngleDegrees,
    required double declinationDegrees,
    required double latitudeDegrees,
  }) {
    final dec = declinationDegrees * math.pi / 180.0;
    final lat = latitudeDegrees * math.pi / 180.0;
    final ha = hourAngleDegrees * math.pi / 180.0;
    final sinAlt =
        math.sin(dec) * math.sin(lat) +
        math.cos(dec) * math.cos(lat) * math.cos(ha);
    return math.asin(sinAlt.clamp(-1.0, 1.0)) * 180.0 / math.pi;
  }

  /// Altitude and azimuth in degrees for an equatorial position, given the
  /// site latitude and the local sidereal time in hours.
  ///
  /// Azimuth is measured east of north. This is the exact body that
  /// `SchedulerService.calculateAltAz` and the scheduler engine's
  /// `_calculateAltAz` each carried; note the azimuth numerator carries the
  /// `cos δ` factor, which [sunAltAz] does not — mathematically the same
  /// angle, not the same doubles, so the two are kept apart deliberately.
  static (double altitude, double azimuth) altAzDegrees({
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

  /// Local Sidereal Time in hours [0, 24) for `time` (treated as UTC) at the
  /// given observer longitude (degrees, east positive).
  ///
  /// The single shared implementation behind both the dynamic scheduler engine
  /// and the standalone meridian-flip monitor. The day fraction is built from
  /// day/hour/minute/second WITHOUT the sub-second term, which is what the
  /// scheduler's golden-pinned numbers assume.
  static double localSiderealTimeHours(DateTime time, double longitudeDegrees) {
    final jd = julianDate(time, includeMilliseconds: false);
    var gmst = gmstDegreesRaw(jd);
    gmst = gmst % 360.0;
    if (gmst < 0) gmst += 360.0;
    var lst = gmst / 15.0 + longitudeDegrees / 15.0;
    while (lst < 0) {
      lst += 24.0;
    }
    while (lst >= 24.0) {
      lst -= 24.0;
    }
    return lst;
  }

  /// Mount hour angle in hours, normalized to (-12, +12].
  ///
  /// HA = LST - RA, where positive HA means the target is west of the
  /// meridian (i.e., already crossed). Both arguments are in hours.
  static double hourAngleHours(double raHours, double lstHours) {
    var ha = lstHours - raHours;
    while (ha > 12.0) {
      ha -= 24.0;
    }
    while (ha <= -12.0) {
      ha += 24.0;
    }
    return ha;
  }

  /// NREL Solar Position Algorithm (Reda & Andreas, 2003), simplified
  /// implementation accurate to <0.01° in solar position. Returns the
  /// sun's apparent (alt, az) in degrees at `time` for the given site.
  ///
  /// The full SPA paper performs nutation and aberration to arc-second
  /// precision; for twilight-boundary use (1-minute precision) we keep
  /// the higher-order corrections but skip the full nutation series.
  static (double altitude, double azimuth) sunAltAz({
    required DateTime time,
    required double latitudeDegrees,
    required double longitudeDegrees,
  }) {
    final jd = julianDate(time);
    final t = (jd - 2451545.0) / 36525.0;

    // Mean longitude (deg).
    var l0 = 280.46646 + t * (36000.76983 + t * 0.0003032);
    l0 = _wrap360(l0);

    // Mean anomaly (deg).
    var m = 357.52911 + t * (35999.05029 - 0.0001537 * t);
    m = _wrap360(m);
    final mRad = _deg2rad(m);

    // Equation of center (deg).
    final c =
        (1.914602 - t * (0.004817 + 0.000014 * t)) * math.sin(mRad) +
        (0.019993 - 0.000101 * t) * math.sin(2 * mRad) +
        0.000289 * math.sin(3 * mRad);

    // True longitude / apparent longitude (deg). Approximate aberration
    // by subtracting 0.00569° + 0.00478°·sin(omega).
    final trueLon = l0 + c;
    final omegaDeg = 125.04 - 1934.136 * t;
    final apparentLon =
        trueLon - 0.00569 - 0.00478 * math.sin(_deg2rad(omegaDeg));
    final apparentLonRad = _deg2rad(apparentLon);

    // Mean obliquity of ecliptic (deg) with nutation correction.
    final seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813));
    final meanObliquity = 23.0 + (26.0 + (seconds / 60.0)) / 60.0;
    final obliquity = meanObliquity + 0.00256 * math.cos(_deg2rad(omegaDeg));
    final obliquityRad = _deg2rad(obliquity);

    // Right ascension (rad), declination (rad).
    final ra = math.atan2(
      math.cos(obliquityRad) * math.sin(apparentLonRad),
      math.cos(apparentLonRad),
    );
    final dec = math.asin(math.sin(obliquityRad) * math.sin(apparentLonRad));

    // Greenwich mean sidereal time (deg) at time.
    final gmst = _wrap360(gmstDegreesRaw(jd));

    // Local sidereal time, then local hour angle.
    final lst = _wrap360(gmst + longitudeDegrees);
    final raDeg = _wrap360(_rad2deg(ra));
    final hourAngleDeg = _wrap180(lst - raDeg);
    final haRad = _deg2rad(hourAngleDeg);

    final latRad = _deg2rad(latitudeDegrees);
    final sinAlt =
        math.sin(latRad) * math.sin(dec) +
        math.cos(latRad) * math.cos(dec) * math.cos(haRad);
    final altRad = math.asin(sinAlt.clamp(-1.0, 1.0));

    // Azimuth measured east of north.
    final y = -math.sin(haRad);
    final x =
        math.tan(dec) * math.cos(latRad) - math.sin(latRad) * math.cos(haRad);
    var az = math.atan2(y, x);
    if (az < 0) az += 2 * math.pi;

    return (_rad2deg(altRad), _rad2deg(az));
  }

  /// Find evening end (sun sinks below `targetAltitude`) and morning start
  /// (sun climbs back above it) for the night nearest `noonLocal`. Uses
  /// 1-minute sampling with bisection refinement over the 24 hours from the
  /// site's own solar noon, so dusk is always found before dawn.
  ///
  /// The window is anchored at the SITE's noon, not the caller's: `noonLocal`
  /// only names which night is wanted. Anchoring on the caller's clock made a
  /// host in one timezone start the search in the middle of a site's night in
  /// another, find the morning crossing first, and return a dawn EARLIER than
  /// its dusk — which every consumer reads as "no astronomical darkness".
  ///
  /// Returns nulls when the sun does not cross the threshold (polar
  /// regions in summer / winter).
  static TwilightTimes computeTwilight({
    required DateTime noonLocal,
    required double latitudeDegrees,
    required double longitudeDegrees,
    required TwilightKind kind,
  }) {
    final targetAlt = _twilightAltitudes[kind]!;
    final searchStart = _solarNoonUtcNearest(
      noonLocal.toUtc(),
      longitudeDegrees,
    );
    final searchEnd = searchStart.add(const Duration(hours: 24));

    DateTime? eveningEnd;
    DateTime? morningStart;

    // Sample every minute over 24h, looking for sign changes.
    DateTime prevT = searchStart;
    var (prevAlt, _) = sunAltAz(
      time: prevT,
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
    );
    for (var minute = 1; minute <= 24 * 60; minute++) {
      final t = searchStart.add(Duration(minutes: minute));
      final (alt, _) = sunAltAz(
        time: t,
        latitudeDegrees: latitudeDegrees,
        longitudeDegrees: longitudeDegrees,
      );
      // Descending crossing -> evening end.
      if (prevAlt > targetAlt && alt <= targetAlt && eveningEnd == null) {
        eveningEnd = _bisectCrossing(
          t0: prevT,
          t1: t,
          alt0: prevAlt,
          targetAlt: targetAlt,
          latitudeDegrees: latitudeDegrees,
          longitudeDegrees: longitudeDegrees,
        );
      }
      // Ascending crossing -> morning start.
      if (prevAlt < targetAlt && alt >= targetAlt && morningStart == null) {
        morningStart = _bisectCrossing(
          t0: prevT,
          t1: t,
          alt0: prevAlt,
          targetAlt: targetAlt,
          latitudeDegrees: latitudeDegrees,
          longitudeDegrees: longitudeDegrees,
        );
      }
      prevAlt = alt;
      prevT = t;
      if (eveningEnd != null && morningStart != null && t.isAfter(searchEnd)) {
        break;
      }
    }

    return TwilightTimes(
      kind: kind,
      eveningEnd: eveningEnd,
      morningStart: morningStart,
    );
  }

  /// Mean solar noon at [longitudeDegrees], on whichever day puts it closest
  /// to [anchorUtc]. Mean rather than apparent solar noon: the equation of
  /// time shifts this by at most ~16 minutes, which cannot move a twilight
  /// crossing in or out of a window that is half a day wide on either side.
  static DateTime _solarNoonUtcNearest(
    DateTime anchorUtc,
    double longitudeDegrees,
  ) {
    final noonOffset = Duration(
      minutes: ((12.0 - longitudeDegrees / 15.0) * 60).round(),
    );
    final anchorDay = DateTime.utc(
      anchorUtc.year,
      anchorUtc.month,
      anchorUtc.day,
    );
    var nearest = anchorDay.add(noonOffset);
    for (final days in const [-1, 1]) {
      final candidate = anchorDay.add(Duration(days: days) + noonOffset);
      if (candidate.difference(anchorUtc).abs() <
          nearest.difference(anchorUtc).abs()) {
        nearest = candidate;
      }
    }
    return nearest;
  }

  static DateTime _bisectCrossing({
    required DateTime t0,
    required DateTime t1,
    required double alt0,
    required double targetAlt,
    required double latitudeDegrees,
    required double longitudeDegrees,
  }) {
    var lo = t0;
    var hi = t1;
    var loAlt = alt0;
    while (hi.difference(lo).inSeconds > 30) {
      final mid = lo.add(Duration(seconds: hi.difference(lo).inSeconds ~/ 2));
      final (midAlt, _) = sunAltAz(
        time: mid,
        latitudeDegrees: latitudeDegrees,
        longitudeDegrees: longitudeDegrees,
      );
      final loSign = (loAlt - targetAlt).sign;
      final midSign = (midAlt - targetAlt).sign;
      if (loSign == midSign) {
        lo = mid;
        loAlt = midAlt;
      } else {
        hi = mid;
      }
    }
    return lo.add(Duration(seconds: hi.difference(lo).inSeconds ~/ 2));
  }

  /// Convenience: hours of darkness available between now and morning
  /// astronomical twilight (or evening end if night hasn't started).
  /// Returns 0 if the sun is up and the night has not yet begun, or if
  /// astronomical night never occurs at this site.
  static Duration darknessRemaining({
    required DateTime now,
    required double latitudeDegrees,
    required double longitudeDegrees,
  }) {
    final localNoon = DateTime(now.year, now.month, now.day, 12).toUtc();
    final tonight = computeTwilight(
      noonLocal: localNoon,
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
      kind: TwilightKind.astronomical,
    );
    final end = tonight.morningStart;
    if (end == null) return Duration.zero;
    final delta = end.difference(now.toUtc());
    if (delta.isNegative) return Duration.zero;
    return delta;
  }

  static double _wrap360(double d) {
    var v = d % 360.0;
    if (v < 0) v += 360.0;
    return v;
  }

  static double _wrap180(double d) {
    var v = ((d + 180.0) % 360.0) - 180.0;
    if (v < -180.0) v += 360.0;
    return v;
  }

  static double _deg2rad(double d) => d * math.pi / 180.0;
  static double _rad2deg(double r) => r * 180.0 / math.pi;
}
