part of '../scheduler_engine.dart';

extension on SchedulerEngine {
  (double altitude, double azimuth) _calculateAltAz({
    required double raHours,
    required double decDegrees,
    required DateTime time,
  }) {
    return SkyCalculations.altAzDegrees(
      raHours: raHours,
      decDegrees: decDegrees,
      latitudeDegrees: _site.latitudeDegrees,
      lstHours: _localSiderealTime(time),
    );
  }

  /// Meeus low-precision lunar ephemeris, matching the established static
  /// scheduler (`scheduler_service.dart`) so unit-tested moon-illumination
  /// behaviour stays in sync.
  _MoonPosition _moonPosition(DateTime time) {
    // Whole-second day fraction, matching `scheduler_service.dart`.
    final jd = SkyCalculations.julianDate(time, includeMilliseconds: false);
    final t = (jd - 2451545.0) / 36525.0;
    final l = (218.3164477 + 481267.88123421 * t) % 360.0;
    final dEl = (297.8501921 + 445267.1114034 * t) % 360.0;
    final mp = (134.9633964 + 477198.8675055 * t) % 360.0;
    final mpRad = mp * math.pi / 180.0;
    final dRad = dEl * math.pi / 180.0;
    final lambda = l + 6.289 * math.sin(mpRad);
    final lambdaRad = lambda * math.pi / 180.0;
    final beta = 5.128 * math.sin(mpRad);
    final betaRad = beta * math.pi / 180.0;
    const epsilon = 23.439;
    const epsRad = epsilon * math.pi / 180.0;
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
    return _MoonPosition(
      raHours: raHours,
      decDegrees: dec * 180.0 / math.pi,
      illumination: illumination,
    );
  }

  double _angularSeparation({
    required double ra1Hours,
    required double dec1Degrees,
    required double ra2Hours,
    required double dec2Degrees,
  }) {
    final ra1 = ra1Hours * 15.0 * math.pi / 180.0;
    final ra2 = ra2Hours * 15.0 * math.pi / 180.0;
    final dec1 = dec1Degrees * math.pi / 180.0;
    final dec2 = dec2Degrees * math.pi / 180.0;
    final cosSep =
        math.sin(dec1) * math.sin(dec2) +
        math.cos(dec1) * math.cos(dec2) * math.cos(ra1 - ra2);
    return math.acos(cosSep.clamp(-1.0, 1.0)) * 180.0 / math.pi;
  }
}

class _MoonPosition {
  final double raHours;
  final double decDegrees;
  final double illumination;
  const _MoonPosition({
    required this.raHours,
    required this.decDegrees,
    required this.illumination,
  });
}
