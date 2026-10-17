part of '../night_analysis_service.dart';

/// Self-contained low-precision lunar ephemeris (Meeus), copied from
/// `SchedulerService.calculateMoonPosition` + the scheduler's alt/az conversion
/// so [NightAnalysisService] depends on neither the scheduler engine (its moon
/// API is private) nor a live site. Illumination uses the same
/// `(1 - cos(D)) / 2` phase approximation as the rest of the codebase.
class _MoonEphemeris {
  /// Mean illumination over the window and whether the moon's altitude is
  /// rising across it. Altitude is computed at a nominal mid-northern-latitude
  /// observer because `captured_images` / the session row carry no site
  /// lat/long in this layer; the *rising/setting* trend is robust to that
  /// choice for the "is the moon coming up?" question the detector asks.
  static ({double illumination, bool altitudeRising})
  illuminationAndAltitudeTrend(DateTime start, DateTime end) {
    const latDeg = 40.0; // nominal mid-northern site
    const lonDeg = 0.0;
    final mid = DateTime.fromMillisecondsSinceEpoch(
      (start.millisecondsSinceEpoch + end.millisecondsSinceEpoch) ~/ 2,
      isUtc: true,
    );
    final pos = _moonPosition(mid);
    final altStart = _altitude(
      raHours: pos.raHours,
      decDeg: pos.decDeg,
      time: start,
      latDeg: latDeg,
      lonDeg: lonDeg,
    );
    final altEnd = _altitude(
      raHours: _moonPosition(end).raHours,
      decDeg: _moonPosition(end).decDeg,
      time: end,
      latDeg: latDeg,
      lonDeg: lonDeg,
    );
    return (illumination: pos.illumination, altitudeRising: altEnd > altStart);
  }

  static ({double raHours, double decDeg, double illumination}) _moonPosition(
    DateTime time,
  ) {
    final jd = _julianDate(time);
    final t = (jd - 2451545.0) / 36525.0;
    final l = (218.3164477 + 481267.88123421 * t) % 360.0;
    final d = (297.8501921 + 445267.1114034 * t) % 360.0;
    final mp = (134.9633964 + 477198.8675055 * t) % 360.0;
    final dRad = d * math.pi / 180.0;
    final mpRad = mp * math.pi / 180.0;
    final lambda = l + 6.289 * math.sin(mpRad);
    final lambdaRad = lambda * math.pi / 180.0;
    final beta = 5.128 * math.sin(mpRad);
    final betaRad = beta * math.pi / 180.0;
    const epsRad = 23.439 * math.pi / 180.0;
    final ra = math.atan2(
      math.sin(lambdaRad) * math.cos(epsRad) -
          math.tan(betaRad) * math.sin(epsRad),
      math.cos(lambdaRad),
    );
    final dec = math.asin(
      math.sin(betaRad) * math.cos(epsRad) +
          math.cos(betaRad) * math.sin(epsRad) * math.sin(lambdaRad),
    );
    var raHours = (ra * 180.0 / math.pi) / 15.0;
    if (raHours < 0) raHours += 24.0;
    final illumination = (1.0 - math.cos(dRad)) / 2.0;
    return (
      raHours: raHours,
      decDeg: dec * 180.0 / math.pi,
      illumination: illumination,
    );
  }

  static double _altitude({
    required double raHours,
    required double decDeg,
    required DateTime time,
    required double latDeg,
    required double lonDeg,
  }) {
    final lst = _localSiderealTime(time, lonDeg);
    return SkyCalculations.altitudeDegrees(
      hourAngleDegrees: (lst - raHours) * 15.0,
      declinationDegrees: decDeg,
      latitudeDegrees: latDeg,
    );
  }

  /// Whole-second day fraction, GMST wrapped into [0,360) before the site
  /// longitude is added in hours — the arithmetic this service carried
  /// inline, now shared with the schedulers that use the same convention.
  static double _localSiderealTime(DateTime time, double lonDeg) =>
      SkyCalculations.localSiderealTimeHours(time, lonDeg);

  static double _julianDate(DateTime dt) =>
      SkyCalculations.julianDate(dt, includeMilliseconds: false);
}
