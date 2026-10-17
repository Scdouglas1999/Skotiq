// ignore_for_file: unused_field, unused_local_variable

import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sequence/sequence_models.dart';
import 'scheduler/sky_calculations.dart';

/// Provider for the scheduler service
final schedulerServiceProvider = Provider<SchedulerService>((ref) {
  return SchedulerService(ref);
});

/// Result of altitude calculation for a target
class AltitudeData {
  final String targetId;
  final String targetName;
  final double raHours;
  final double decDegrees;
  final DateTime transitTime;
  final double transitAltitude;
  final double currentAltitude;
  final bool isRising;
  final DateTime? riseTime;
  final DateTime? setTime;
  final double hoursAboveHorizon;

  AltitudeData({
    required this.targetId,
    required this.targetName,
    required this.raHours,
    required this.decDegrees,
    required this.transitTime,
    required this.transitAltitude,
    required this.currentAltitude,
    required this.isRising,
    this.riseTime,
    this.setTime,
    required this.hoursAboveHorizon,
  });
}

/// Optimization strategy for target ordering
enum OptimizationStrategy {
  transitTime, // Order by when targets cross meridian
  currentAltitude, // Order by current altitude (highest first for setting targets)
  risingFirst, // Image rising targets first
  settingFirst, // Image setting targets first
  priority, // Use user-defined priorities
}

/// Service for intelligent target scheduling
class SchedulerService {
  final Ref _ref;

  SchedulerService(this._ref);

  /// Calculate altitude for a celestial object at a given time
  ///
  /// Uses standard spherical astronomy formulas
  double calculateAltitude({
    required double raHours,
    required double decDegrees,
    required DateTime time,
    required double latitudeDegrees,
    required double longitudeDegrees,
  }) {
    final (alt, _) = calculateAltAz(
      raHours: raHours,
      decDegrees: decDegrees,
      time: time,
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
    );
    return alt;
  }

  /// Calculate both altitude and azimuth for a celestial object at a given time.
  /// Returns (altitude, azimuth) in degrees.
  (double altitude, double azimuth) calculateAltAz({
    required double raHours,
    required double decDegrees,
    required DateTime time,
    required double latitudeDegrees,
    required double longitudeDegrees,
  }) {
    return SkyCalculations.altAzDegrees(
      raHours: raHours,
      decDegrees: decDegrees,
      latitudeDegrees: latitudeDegrees,
      lstHours: _calculateLST(time, longitudeDegrees),
    );
  }

  /// Calculate Local Sidereal Time in hours.
  ///
  /// Delegates to [SkyCalculations.localSiderealTimeHours]: whole-second day
  /// fraction, GMST normalized to [0,360) before the longitude is added in
  /// hours.
  double _calculateLST(DateTime utcTime, double longitudeDegrees) =>
      SkyCalculations.localSiderealTimeHours(utcTime, longitudeDegrees);

  /// Calculate Julian Date from DateTime.
  ///
  /// Whole-second day fraction — the precision this service has always used,
  /// and what its moon-position goldens are pinned to.
  double _julianDate(DateTime dt) =>
      SkyCalculations.julianDate(dt, includeMilliseconds: false);

  /// Compute the next time the target falls to (or below) [horizonDeg].
  ///
  /// This is the canonical "time-to-set" helper used by the Run Dashboard
  /// and the planetarium altitude card so both surfaces agree to the
  /// second. The math is a Newton-style binary search on the analytical
  /// rise/set hour-angle equation:
  ///
  ///   * Closed-form hour-angle: `cos(H) = (sin(alt) - sin(δ)sin(φ)) /
  ///     (cos(δ)cos(φ))`. The sidereal rotation of Earth (one solar day ≈
  ///     0.9972 sidereal day) converts the hour-angle delta to a wall-clock
  ///     delta directly, with no probing.
  ///   * Circumpolar / never-rises detection up-front, so the caller gets
  ///     `null` (never sets) or `Duration.zero` (already below) without a
  ///     12 h timeout.
  ///
  /// Returns:
  ///   * `null` if the target never sets above [horizonDeg] within 24 h
  ///     (circumpolar relative to the chosen horizon) — UI should render
  ///     this as "—" / "never sets".
  ///   * `Duration.zero` if the target is already at/below the horizon.
  ///   * Otherwise: the wall-clock duration from [now] to the next time
  ///     the target's altitude crosses [horizonDeg] downward.
  Duration? nextSetTime({
    required double raHours,
    required double decDegrees,
    required DateTime now,
    required double latitudeDegrees,
    required double longitudeDegrees,
    double horizonDeg = 0.0,
  }) {
    final dec = decDegrees * math.pi / 180.0;
    final lat = latitudeDegrees * math.pi / 180.0;
    final alt = horizonDeg * math.pi / 180.0;

    final cosDec = math.cos(dec);
    final cosLat = math.cos(lat);
    final denominator = cosDec * cosLat;

    // Polar / equator degeneracies: when either latitude or declination
    // pins the daily altitude to a single value, fall back to the simple
    // "above-or-below" check.
    if (denominator.abs() < 1e-12) {
      final fixedAlt = math.asin(math.sin(dec) * math.sin(lat));
      return fixedAlt >= alt ? null : Duration.zero;
    }

    final cosH0 = (math.sin(alt) - math.sin(dec) * math.sin(lat)) / denominator;
    if (cosH0 <= -1.0) {
      // Circumpolar: never crosses the horizon downward.
      return null;
    }
    if (cosH0 >= 1.0) {
      // Never rises above the horizon.
      return Duration.zero;
    }

    // Hour angle at horizon crossing (degrees, then to sidereal hours).
    final h0Deg = math.acos(cosH0) * 180.0 / math.pi;
    final h0SiderealHours = h0Deg / 15.0;

    // Current hour angle (sidereal hours, normalised to [-12, +12]).
    final lst = _calculateLST(now, longitudeDegrees);
    var haHours = lst - raHours;
    while (haHours > 12.0) {
      haHours -= 24.0;
    }
    while (haHours < -12.0) {
      haHours += 24.0;
    }

    // Setting happens when HA reaches +h0SiderealHours; if we're already
    // past that, the target is below the horizon. Return zero so the UI
    // can render "set" rather than waiting another sidereal day.
    if (haHours >= h0SiderealHours) {
      // Verify with a direct altitude check — a target whose HA wraps
      // beyond +h0 is below the horizon now.
      final currentAlt = calculateAltitude(
        raHours: raHours,
        decDegrees: decDegrees,
        time: now,
        latitudeDegrees: latitudeDegrees,
        longitudeDegrees: longitudeDegrees,
      );
      if (currentAlt <= horizonDeg) return Duration.zero;
      // Otherwise fall through and treat as a full sidereal day away.
      haHours -= 24.0;
    }

    final siderealHoursToSet = h0SiderealHours - haHours;
    // Convert sidereal hours to solar (mean) hours.
    final solarHoursToSet = siderealHoursToSet * 0.9972695663;
    final seconds = (solarHoursToSet * 3600).round();
    if (seconds <= 0) return Duration.zero;
    return Duration(seconds: seconds);
  }

  /// Calculate transit time for a target
  DateTime calculateTransitTime({
    required double raHours,
    required DateTime date,
    required double longitudeDegrees,
  }) {
    // Transit occurs when hour angle = 0, i.e., LST = RA
    // We need to find the time when this occurs

    // Start at midnight UTC on the given date
    final midnight = DateTime.utc(date.year, date.month, date.day);

    // Calculate LST at midnight
    final lstMidnight = _calculateLST(midnight, longitudeDegrees);

    // Time until transit in sidereal hours
    double hoursUntilTransit = raHours - lstMidnight;
    if (hoursUntilTransit < 0) hoursUntilTransit += 24.0;
    if (hoursUntilTransit > 24) hoursUntilTransit -= 24.0;

    // Convert sidereal time to solar time (sidereal day is ~23h 56m 4s)
    final solarHours = hoursUntilTransit * 0.9972695663;

    return midnight.add(
      Duration(
        hours: solarHours.floor(),
        minutes: ((solarHours % 1) * 60).floor(),
        seconds: (((solarHours * 60) % 1) * 60).floor(),
      ),
    );
  }

  /// Get altitude data for all targets in the sequence
  List<AltitudeData> calculateTargetAltitudes({
    required List<TargetHeaderNode> targets,
    required DateTime observationTime,
    required double latitudeDegrees,
    required double longitudeDegrees,
    double minAltitude = 0.0,
  }) {
    final results = <AltitudeData>[];

    for (final target in targets) {
      final currentAlt = calculateAltitude(
        raHours: target.raHours,
        decDegrees: target.decDegrees,
        time: observationTime,
        latitudeDegrees: latitudeDegrees,
        longitudeDegrees: longitudeDegrees,
      );

      // Check altitude 10 minutes later to determine if rising or setting
      final futureAlt = calculateAltitude(
        raHours: target.raHours,
        decDegrees: target.decDegrees,
        time: observationTime.add(const Duration(minutes: 10)),
        latitudeDegrees: latitudeDegrees,
        longitudeDegrees: longitudeDegrees,
      );

      final isRising = futureAlt > currentAlt;

      final transitTime = calculateTransitTime(
        raHours: target.raHours,
        date: observationTime,
        longitudeDegrees: longitudeDegrees,
      );

      final transitAlt = calculateAltitude(
        raHours: target.raHours,
        decDegrees: target.decDegrees,
        time: transitTime,
        latitudeDegrees: latitudeDegrees,
        longitudeDegrees: longitudeDegrees,
      );

      // Calculate approximate rise/set times and hours above horizon
      final hoursAbove = _calculateHoursAboveHorizon(
        decDegrees: target.decDegrees,
        latitudeDegrees: latitudeDegrees,
        minAltitude: minAltitude,
      );

      results.add(
        AltitudeData(
          targetId: target.id,
          targetName: target.targetName,
          raHours: target.raHours,
          decDegrees: target.decDegrees,
          transitTime: transitTime,
          transitAltitude: transitAlt,
          currentAltitude: currentAlt,
          isRising: isRising,
          hoursAboveHorizon: hoursAbove,
        ),
      );
    }

    return results;
  }

  /// Calculate hours above minimum altitude
  double _calculateHoursAboveHorizon({
    required double decDegrees,
    required double latitudeDegrees,
    required double minAltitude,
  }) {
    // Use spherical trig to calculate hour angle at horizon
    final dec = decDegrees * math.pi / 180.0;
    final lat = latitudeDegrees * math.pi / 180.0;
    final alt = minAltitude * math.pi / 180.0;

    final sinThreshold = math.sin(alt);
    final center = math.sin(dec) * math.sin(lat);
    final amplitude = (math.cos(dec) * math.cos(lat)).abs();
    final minSinAltitude = center - amplitude;
    final maxSinAltitude = center + amplitude;

    if (maxSinAltitude < sinThreshold) {
      return 0.0;
    }
    if (minSinAltitude >= sinThreshold) {
      return 24.0;
    }

    final denominator = math.cos(dec) * math.cos(lat);
    if (denominator.abs() < 1e-12) {
      return center >= sinThreshold ? 24.0 : 0.0;
    }

    // cos(H) = (sin(alt) - sin(dec) * sin(lat)) / (cos(dec) * cos(lat))
    final cosH = (sinThreshold - center) / denominator;

    if (cosH <= -1.0) {
      // Circumpolar - always visible
      return 24.0;
    } else if (cosH >= 1.0) {
      // Never rises above minimum altitude
      return 0.0;
    }

    // Hour angle at rise/set
    final hourAngle =
        math.acos(cosH) * 180.0 / math.pi / 15.0; // Convert to hours
    return hourAngle * 2.0; // Total hours above horizon
  }

  /// Optimize target order based on selected strategy
  List<TargetHeaderNode> optimizeTargetOrder({
    required List<TargetHeaderNode> targets,
    required OptimizationStrategy strategy,
    required DateTime observationTime,
    required double latitudeDegrees,
    required double longitudeDegrees,
    double minAltitude = 30.0,
  }) {
    if (targets.isEmpty) return [];

    final altitudeData = calculateTargetAltitudes(
      targets: targets,
      observationTime: observationTime,
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
      minAltitude: minAltitude,
    );

    // Create a map for quick lookup
    final dataMap = <String, AltitudeData>{};
    for (final data in altitudeData) {
      dataMap[data.targetId] = data;
    }

    final sortedTargets = List<TargetHeaderNode>.from(targets);
    final inputOrder = <String, int>{
      for (final (index, target) in targets.indexed) target.id: index,
    };

    switch (strategy) {
      case OptimizationStrategy.transitTime:
        // Sort by transit time (earliest first)
        sortedTargets.sort((a, b) {
          final dataA = dataMap[a.id]!;
          final dataB = dataMap[b.id]!;
          return dataA.transitTime.compareTo(dataB.transitTime);
        });
        break;

      case OptimizationStrategy.currentAltitude:
        // Sort by current altitude (highest first for setting, lowest first for rising)
        sortedTargets.sort((a, b) {
          final dataA = dataMap[a.id]!;
          final dataB = dataMap[b.id]!;

          // Setting targets should be imaged first (higher altitude first)
          if (!dataA.isRising && !dataB.isRising) {
            return dataB.currentAltitude.compareTo(dataA.currentAltitude);
          }
          // Rising targets can wait (lower altitude first, as they're getting higher)
          if (dataA.isRising && dataB.isRising) {
            return dataA.currentAltitude.compareTo(dataB.currentAltitude);
          }
          // Setting targets before rising targets
          if (!dataA.isRising) return -1;
          return 1;
        });
        break;

      case OptimizationStrategy.risingFirst:
        // Image rising targets first
        sortedTargets.sort((a, b) {
          final dataA = dataMap[a.id]!;
          final dataB = dataMap[b.id]!;
          if (dataA.isRising == dataB.isRising) {
            // Within same category, sort by altitude
            return dataA.currentAltitude.compareTo(dataB.currentAltitude);
          }
          return dataA.isRising ? -1 : 1;
        });
        break;

      case OptimizationStrategy.settingFirst:
        // Image setting targets first (they're going below horizon)
        sortedTargets.sort((a, b) {
          final dataA = dataMap[a.id]!;
          final dataB = dataMap[b.id]!;
          if (dataA.isRising == dataB.isRising) {
            // Within same category, setting: highest first; rising: lowest first
            if (!dataA.isRising) {
              return dataB.currentAltitude.compareTo(dataA.currentAltitude);
            }
            return dataA.currentAltitude.compareTo(dataB.currentAltitude);
          }
          return dataA.isRising ? 1 : -1;
        });
        break;

      case OptimizationStrategy.priority:
        // Higher numeric values are more important throughout the scheduler.
        // Keep the caller's order for equal priorities so optimization does
        // not shuffle otherwise-equivalent targets unpredictably.
        sortedTargets.sort((a, b) {
          final byPriority = b.priority.compareTo(a.priority);
          if (byPriority != 0) return byPriority;
          return inputOrder[a.id]!.compareTo(inputOrder[b.id]!);
        });
        break;
    }

    return sortedTargets;
  }

  /// Calculate moon position (simplified)
  ({double raHours, double decDegrees, double illumination})
  calculateMoonPosition(DateTime time) {
    // Simplified lunar ephemeris
    final jd = _julianDate(time);
    final t = (jd - 2451545.0) / 36525.0;

    // Mean longitude of moon
    final l = (218.3164477 + 481267.88123421 * t) % 360.0;

    // Mean elongation of moon
    final d = (297.8501921 + 445267.1114034 * t) % 360.0;

    // Sun's mean anomaly
    final m = (357.5291092 + 35999.0502909 * t) % 360.0;

    // Moon's mean anomaly
    final mp = (134.9633964 + 477198.8675055 * t) % 360.0;

    // Simplified calculation for RA and Dec
    final lRad = l * math.pi / 180.0;
    final dRad = d * math.pi / 180.0;
    final mpRad = mp * math.pi / 180.0;

    // Approximate ecliptic longitude
    final lambda = l + 6.289 * math.sin(mpRad);
    final lambdaRad = lambda * math.pi / 180.0;

    // Ecliptic latitude (simplified)
    final beta = 5.128 * math.sin(mpRad);
    final betaRad = beta * math.pi / 180.0;

    // Obliquity of ecliptic
    const epsilon = 23.439;
    const epsRad = epsilon * math.pi / 180.0;

    // Convert to equatorial coordinates
    final ra = math.atan2(
      math.sin(lambdaRad) * math.cos(epsRad) -
          math.tan(betaRad) * math.sin(epsRad),
      math.cos(lambdaRad),
    );
    final dec = math.asin(
      math.sin(betaRad) * math.cos(epsRad) +
          math.cos(betaRad) * math.sin(epsRad) * math.sin(lambdaRad),
    );

    // Convert RA to hours (0-24)
    var raHours = (ra * 180.0 / math.pi) / 15.0;
    if (raHours < 0) raHours += 24.0;

    // Calculate illumination (simplified, based on phase angle)
    final illumination = (1.0 - math.cos(dRad)) / 2.0;

    return (
      raHours: raHours,
      decDegrees: dec * 180.0 / math.pi,
      illumination: illumination,
    );
  }

  /// Calculate angular separation between two celestial objects
  double calculateSeparation({
    required double ra1Hours,
    required double dec1Degrees,
    required double ra2Hours,
    required double dec2Degrees,
  }) {
    final ra1 = ra1Hours * 15.0 * math.pi / 180.0;
    final ra2 = ra2Hours * 15.0 * math.pi / 180.0;
    final dec1 = dec1Degrees * math.pi / 180.0;
    final dec2 = dec2Degrees * math.pi / 180.0;

    // Haversine formula
    final cosSep =
        math.sin(dec1) * math.sin(dec2) +
        math.cos(dec1) * math.cos(dec2) * math.cos(ra1 - ra2);

    return math.acos(cosSep.clamp(-1.0, 1.0)) * 180.0 / math.pi;
  }

  /// Check if target is too close to moon
  bool isNearMoon({
    required double targetRaHours,
    required double targetDecDegrees,
    required DateTime time,
    double minSeparationDegrees = 30.0,
  }) {
    final moon = calculateMoonPosition(time);
    final separation = calculateSeparation(
      ra1Hours: targetRaHours,
      dec1Degrees: targetDecDegrees,
      ra2Hours: moon.raHours,
      dec2Degrees: moon.decDegrees,
    );
    return separation < minSeparationDegrees;
  }
}
