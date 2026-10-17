import '../../celestial_object.dart';
import '../weighted_score.dart';

/// Minimum observable altitude (degrees) at a given compass azimuth, as
/// imposed by the local skyline (trees, buildings, hills).
///
/// Returns 0 for an unobstructed direction. The planetarium package owns this
/// lightweight contract so the scorer does not need to depend on the app's
/// concrete horizon-profile model — callers adapt their profile to this shape.
typedef HorizonMask = double Function(double azimuthDegrees);

/// Scoring criteria weights for target prioritization
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

  /// Build the ordered five-axis [WeightedFactor] list for the shared
  /// [WeightedScore] aggregator. Factor ORDER (altitude, moonDistance,
  /// transitProximity, darkness, airmass) is the pinned cross-language
  /// contract — it matches the Rust `scoring::ScoringWeights` field order and
  /// the `TargetSchedulerNode` field order. Callers pass the five `0..100`
  /// axis scores in the same order.
  List<WeightedFactor> factors({
    required double altitudeScore,
    required double moonDistanceScore,
    required double transitProximityScore,
    required double darknessScore,
    required double airmassScore,
  }) {
    return [
      WeightedFactor(
        name: 'altitude',
        value: altitudeScore,
        weight: altitudeWeight,
      ),
      WeightedFactor(
        name: 'moonDistance',
        value: moonDistanceScore,
        weight: moonDistanceWeight,
      ),
      WeightedFactor(
        name: 'transitProximity',
        value: transitProximityScore,
        weight: transitProximityWeight,
      ),
      WeightedFactor(
        name: 'darkness',
        value: darknessScore,
        weight: darknessWeight,
      ),
      WeightedFactor(
        name: 'airmass',
        value: airmassScore,
        weight: airmassWeight,
      ),
    ];
  }
}

/// Result of scoring a target
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

/// Target visibility information
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

  /// Peak altitude during the night window (populated by scoreTargetForNight)
  final double? peakAltitude;

  /// Azimuth at peak altitude during the night (populated by scoreTargetForNight)
  final double? peakAzimuth;

  /// Time when peak altitude occurs during the night (populated by scoreTargetForNight)
  final DateTime? peakAltitudeTime;

  /// Hours the target is above minimum imaging altitude during the night
  final double? hoursAboveMinAlt;

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
  });
}

/// Warning types for targets
enum WarningType {
  lowAltitude,
  highAirmass,
  moonProximity,
  settingSoon,
  notYetRisen,
  belowHorizon,
  twilight,
}

/// Warning severity levels
enum WarningSeverity { info, caution, warning, critical }

/// A warning about target conditions
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
