import '../../celestial_object.dart';

/// The weight of each axis of the target score.
class ScoringWeights {
  final double altitudeWeight;
  final double moonDistanceWeight;
  final double transitProximityWeight;
  final double darknessWeight;
  final double airmassWeight;

  const ScoringWeights({
    this.altitudeWeight = 0.25,
    this.moonDistanceWeight = 0.25,
    this.transitProximityWeight = 0.20,
    this.darknessWeight = 0.15,
    this.airmassWeight = 0.15,
  });
}

class TargetScore {
  final CelestialObject target;
  final double totalScore; // 0-100
  final double altitudeScore;
  final double moonDistanceScore;
  final double transitProximityScore;
  final double darknessScore;
  final double airmassScore;
  final List<TargetWarning> warnings;
  final TargetVisibilityInfo visibility;

  const TargetScore({
    required this.target,
    required this.totalScore,
    required this.altitudeScore,
    required this.moonDistanceScore,
    required this.transitProximityScore,
    required this.darknessScore,
    required this.airmassScore,
    required this.warnings,
    required this.visibility,
  });
}

class TargetVisibilityInfo {
  final double currentAltitude;
  final double currentAzimuth;
  final double? transitAltitude;
  final DateTime? riseTime;
  final DateTime? transitTime;
  final DateTime? setTime;
  final bool isCircumpolar;
  final bool neverRises;
  final double airmass;
  final double moonDistance;

  /// Peak altitude during the night window (night scores only)
  final double? peakAltitude;

  /// Azimuth at peak altitude during the night (night scores only)
  final double? peakAzimuth;

  /// Time when peak altitude occurs during the night (night scores only)
  final DateTime? peakAltitudeTime;

  /// Hours the target is above the altitude floor during the night
  final double? hoursAboveMinAlt;

  /// The first moment of the night the target is above the floor (night
  /// scores only).
  final DateTime? firstUsableTime;

  /// The lowest airmass the target reaches above the floor during the night;
  /// null when it never clears it (night scores only).
  final double? bestAirmass;

  const TargetVisibilityInfo({
    required this.currentAltitude,
    required this.currentAzimuth,
    this.transitAltitude,
    this.riseTime,
    this.transitTime,
    this.setTime,
    this.isCircumpolar = false,
    this.neverRises = false,
    required this.airmass,
    required this.moonDistance,
    this.peakAltitude,
    this.peakAzimuth,
    this.peakAltitudeTime,
    this.hoursAboveMinAlt,
    this.firstUsableTime,
    this.bestAirmass,
  });
}

enum WarningType {
  lowAltitude,
  highAirmass,
  moonProximity,
  settingSoon,
  notYetRisen,
  belowHorizon,
  twilight,
}

enum WarningSeverity { info, caution, warning, critical }

class TargetWarning {
  final WarningType type;
  final WarningSeverity severity;
  final String message;
  final String? suggestion;

  const TargetWarning({
    required this.type,
    required this.severity,
    required this.message,
    this.suggestion,
  });
}
