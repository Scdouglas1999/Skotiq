part of '../night_analysis_service.dart';

/// The Moon over a capture window, for the night-analysis detectors.
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
    double altitudeAt(DateTime time) => AstronomyCalculations.moonAltitude(
      dt: time,
      latitudeDeg: latDeg,
      longitudeDeg: lonDeg,
      apparent: false,
    );
    return (
      illumination: AstronomyCalculations.moonIllumination(mid) / 100.0,
      altitudeRising: altitudeAt(end) > altitudeAt(start),
    );
  }
}
