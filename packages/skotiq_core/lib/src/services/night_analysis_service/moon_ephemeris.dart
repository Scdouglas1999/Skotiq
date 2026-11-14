part of '../night_analysis_service.dart';

/// The Moon over a capture window, for the night-analysis detectors.
class _MoonEphemeris {
  /// Mean illumination over the window and whether the moon's altitude at
  /// [site] rises across it; null without a site, where the trend cannot be
  /// told (a few hours of longitude turn rising into setting).
  static ({double illumination, bool? altitudeRising})
  illuminationAndAltitudeTrend(
    DateTime start,
    DateTime end,
    LocationSettings? site,
  ) {
    final mid = DateTime.fromMillisecondsSinceEpoch(
      (start.millisecondsSinceEpoch + end.millisecondsSinceEpoch) ~/ 2,
      isUtc: true,
    );
    double altitudeAt(LocationSettings site, DateTime time) =>
        AstronomyCalculations.moonAltitude(
          dt: time,
          latitudeDeg: site.latitude,
          longitudeDeg: site.longitude,
          apparent: false,
        );
    return (
      illumination: AstronomyCalculations.moonIllumination(mid) / 100.0,
      altitudeRising: site == null
          ? null
          : altitudeAt(site, end) > altitudeAt(site, start),
    );
  }
}
