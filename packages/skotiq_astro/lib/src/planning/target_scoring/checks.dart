part of '../target_scoring.dart';

/// Quick helper methods for common checks
extension TargetCheckExtensions on TargetScoringService {
  /// Check if a target is currently observable (above horizon, reasonable
  /// altitude). When a [horizonMask] is configured the local skyline at the
  /// target's current azimuth raises the effective minimum altitude.
  bool isObservable(CelestialObject target, {double minAltitude = 15}) {
    final (alt, az) = AstronomyCalculations.objectAltAz(
      raDeg: target.coordinates.raDegrees,
      decDeg: target.coordinates.dec,
      dt: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );
    return alt >= _effectiveMinAltitude(minAltitude, az);
  }
}
