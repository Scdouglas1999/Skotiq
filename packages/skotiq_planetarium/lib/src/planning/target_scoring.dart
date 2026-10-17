import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../astronomy/astronomy_calculations.dart';
import '../celestial_object.dart';
import 'weighted_score.dart';

import 'target_scoring/models.dart';

export 'target_scoring/models.dart';

part 'target_scoring/axis_scores.dart';
part 'target_scoring/warnings.dart';
part 'target_scoring/checks.dart';

/// Service for scoring and analyzing imaging targets
class TargetScoringService {
  final double latitude;
  final double longitude;
  final DateTime observationTime;
  final ScoringWeights weights;

  // Moon position (ra, dec in degrees)
  final (double ra, double dec)? moonPosition;
  final double moonIllumination;

  // Twilight info
  final TwilightTimes? twilight;

  /// Local skyline mask: minimum observable altitude at each azimuth. When
  /// supplied, visibility and "hours above minimum altitude" honor the
  /// obstruction profile instead of assuming a flat horizon. A target whose
  /// entire nightly track stays behind the skyline yields zero visible hours.
  final HorizonMask? horizonMask;

  const TargetScoringService({
    required this.latitude,
    required this.longitude,
    required this.observationTime,
    this.weights = const ScoringWeights(),
    this.moonPosition,
    this.moonIllumination = 0,
    this.twilight,
    this.horizonMask,
  });

  /// Effective minimum altitude at [azimuthDegrees]: the larger of the
  /// caller-requested floor and the local skyline obstruction at that bearing.
  double _effectiveMinAltitude(double requestedMin, double azimuthDegrees) {
    final mask = horizonMask;
    if (mask == null) return requestedMin;
    return math.max(requestedMin, mask(azimuthDegrees));
  }

  /// Score a single target
  TargetScore scoreTarget(CelestialObject target) {
    final coord = target.coordinates;
    final raDeg = coord.raDegrees;
    final decDeg = coord.dec;

    // Calculate current position
    final (alt, az) = AstronomyCalculations.objectAltAz(
      raDeg: raDeg,
      decDeg: decDeg,
      dt: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Calculate visibility
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raDeg,
      decDeg: decDeg,
      // The night containing [observationTime]; its calendar day is already
      // tomorrow once the clock passes midnight.
      date: AstronomyCalculations.nightDateOf(observationTime),
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Calculate airmass
    final airmass = AstronomyCalculations.airmass(alt);

    // Calculate moon distance
    double moonDist = 180;
    if (moonPosition != null) {
      moonDist = AstronomyCalculations.angularSeparation(
        ra1Deg: raDeg,
        dec1Deg: decDeg,
        ra2Deg: moonPosition!.$1,
        dec2Deg: moonPosition!.$2,
      );
    }

    // Create visibility info
    final visibilityInfo = TargetVisibilityInfo(
      currentAltitude: alt,
      currentAzimuth: az,
      transitAltitude: visibility.transitAltitude,
      riseTime: visibility.riseTime,
      transitTime: visibility.transitTime,
      setTime: visibility.setTime,
      isCircumpolar: visibility.isCircumpolar,
      neverRises: visibility.neverRises,
      airmass: airmass,
      moonDistance: moonDist,
    );

    // Calculate individual scores (0-100)
    final altScore = _scoreAltitude(alt);
    final moonScore = _scoreMoonDistance(moonDist, moonIllumination);
    final transitScore = _scoreTransitProximity(visibility, observationTime);
    final darknessScore = _scoreDarkness();
    final airmassScore = _scoreAirmass(airmass);

    // Generate warnings
    final warnings = _generateWarnings(
      alt: alt,
      airmass: airmass,
      moonDist: moonDist,
      visibility: visibility,
    );

    // Weighted total via the shared aggregation contract. NORMALIZED mode is
    // `Σ(axis*weight) / Σ(weight)`.
    final totalScore = WeightedScore.total(
      weights.factors(
        altitudeScore: altScore,
        moonDistanceScore: moonScore,
        transitProximityScore: transitScore,
        darknessScore: darknessScore,
        airmassScore: airmassScore,
      ),
      mode: WeightedScoreMode.normalized,
    );

    return TargetScore(
      target: target,
      totalScore: totalScore,
      altitudeScore: altScore,
      moonDistanceScore: moonScore,
      transitProximityScore: transitScore,
      darknessScore: darknessScore,
      airmassScore: airmassScore,
      warnings: warnings,
      visibility: visibilityInfo,
    );
  }

  /// Score a target based on the entire night window rather than a single moment.
  ///
  /// Samples the target's position at 15-minute intervals throughout the night
  /// (from [nightStart] to [nightEnd]) and scores based on peak conditions:
  /// - Altitude score uses the peak altitude during the night
  /// - Airmass score uses the best (lowest) airmass during the night
  /// - Transit proximity scores whether transit falls within the night window
  /// - Darkness score is replaced by imaging window duration
  /// - Moon distance is evaluated at the time of peak altitude
  ///
  /// Targets that never rise above [minAltitude] during the night receive a
  /// total score of 0.
  TargetScore scoreTargetForNight({
    required CelestialObject target,
    required DateTime nightStart,
    required DateTime nightEnd,
    double minAltitude = 0,
  }) {
    final coord = target.coordinates;
    final raDeg = coord.raDegrees;
    final decDeg = coord.dec;

    // Calculate current position (for display purposes)
    final (currentAlt, currentAz) = AstronomyCalculations.objectAltAz(
      raDeg: raDeg,
      decDeg: decDeg,
      dt: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Sample positions throughout the night at 15-minute intervals
    const sampleInterval = Duration(minutes: 15);

    // Peak among samples that clear the (skyline-aware) minimum altitude.
    double observablePeakAlt = -90;
    double observablePeakAz = 0;
    DateTime? observablePeakTime;
    // Overall highest sample, used only as a diagnostic fallback when the
    // target never becomes observable (e.g. always behind a hill).
    double overallPeakAlt = -90;
    double overallPeakAz = 0;
    DateTime overallPeakTime = nightStart;

    double bestAirmass = double.infinity;
    int samplesAboveMin = 0;
    int totalSamples = 0;
    // First sample of the night that is actually usable. This — not
    // `visibility.riseTime` — is what "the target is not available yet" means
    // to an operator, because it accounts for the minimum altitude and the
    // local skyline, and it can only ever name an instant inside the night.
    DateTime? firstObservableTime;

    var sampleTime = nightStart;
    while (!sampleTime.isAfter(nightEnd)) {
      final (alt, az) = AstronomyCalculations.objectAltAz(
        raDeg: raDeg,
        decDeg: decDeg,
        dt: sampleTime,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );
      final am = AstronomyCalculations.airmass(alt);

      if (alt > overallPeakAlt) {
        overallPeakAlt = alt;
        overallPeakAz = az;
        overallPeakTime = sampleTime;
      }

      // A sample only counts as observable if it clears BOTH the requested
      // minimum altitude and the local skyline at its azimuth.
      final effectiveMin = _effectiveMinAltitude(minAltitude, az);
      if (alt >= effectiveMin) {
        samplesAboveMin++;
        firstObservableTime ??= sampleTime;
        if (alt > observablePeakAlt) {
          observablePeakAlt = alt;
          observablePeakAz = az;
          observablePeakTime = sampleTime;
        }
        if (am < bestAirmass) {
          bestAirmass = am;
        }
      }
      totalSamples++;

      sampleTime = sampleTime.add(sampleInterval);
    }

    // Report the observable peak when the target clears the horizon at any
    // point; otherwise fall back to the overall highest point for diagnostics.
    final bool everObservable = samplesAboveMin > 0;
    final double peakAlt = everObservable ? observablePeakAlt : overallPeakAlt;
    final double peakAz = everObservable ? observablePeakAz : overallPeakAz;
    final DateTime peakTime = everObservable
        ? observablePeakTime!
        : overallPeakTime;

    final hoursAboveMin = totalSamples > 0
        ? (samplesAboveMin * sampleInterval.inMinutes / 60.0)
        : 0.0;

    // Calculate visibility (rise/transit/set) relative to the night's midpoint
    final nightMid = nightStart.add(
      Duration(seconds: nightEnd.difference(nightStart).inSeconds ~/ 2),
    );
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raDeg,
      decDeg: decDeg,
      // nightMid usually lands after midnight, so its calendar day names the
      // day the night ENDS, not the night itself.
      date: AstronomyCalculations.nightDateOf(nightMid),
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Moon distance at peak altitude time
    double moonDist = 180;
    if (moonPosition != null) {
      moonDist = AstronomyCalculations.angularSeparation(
        ra1Deg: raDeg,
        dec1Deg: decDeg,
        ra2Deg: moonPosition!.$1,
        dec2Deg: moonPosition!.$2,
      );
    }

    // Current airmass (for display)
    final currentAirmass = AstronomyCalculations.airmass(currentAlt);

    // Create visibility info with both current and peak data
    final visibilityInfo = TargetVisibilityInfo(
      currentAltitude: currentAlt,
      currentAzimuth: currentAz,
      transitAltitude: visibility.transitAltitude,
      riseTime: visibility.riseTime,
      transitTime: visibility.transitTime,
      setTime: visibility.setTime,
      isCircumpolar: visibility.isCircumpolar,
      neverRises: visibility.neverRises,
      airmass: currentAirmass,
      moonDistance: moonDist,
      peakAltitude: peakAlt,
      peakAzimuth: peakAz,
      peakAltitudeTime: peakTime,
      hoursAboveMinAlt: hoursAboveMin,
    );

    // Calculate individual scores based on night conditions
    final altScore = _scoreAltitude(peakAlt);
    final moonScore = _scoreMoonDistance(moonDist, moonIllumination);
    final transitScore = _scoreTransitProximityForNight(
      visibility,
      nightStart,
      nightEnd,
    );
    final darknessScore = _scoreImagingWindow(
      hoursAboveMin,
      nightStart,
      nightEnd,
    );
    final airmassScore = _scoreAirmass(bestAirmass);

    // Generate warnings based on night conditions
    final warnings = _generateNightWarnings(
      peakAlt: peakAlt,
      bestAirmass: bestAirmass,
      moonDist: moonDist,
      visibility: visibility,
      hoursAboveMin: hoursAboveMin,
      nightStart: nightStart,
      nightEnd: nightEnd,
      firstObservableTime: firstObservableTime,
    );

    // Weighted total via the shared aggregation contract (NORMALIZED).
    final totalScore = WeightedScore.total(
      weights.factors(
        altitudeScore: altScore,
        moonDistanceScore: moonScore,
        transitProximityScore: transitScore,
        darknessScore: darknessScore,
        airmassScore: airmassScore,
      ),
      mode: WeightedScoreMode.normalized,
    );

    return TargetScore(
      target: target,
      totalScore: totalScore,
      altitudeScore: altScore,
      moonDistanceScore: moonScore,
      transitProximityScore: transitScore,
      darknessScore: darknessScore,
      airmassScore: airmassScore,
      warnings: warnings,
      visibility: visibilityInfo,
    );
  }

  /// Score multiple targets and return sorted by score
  List<TargetScore> scoreTargets(List<CelestialObject> targets) {
    final scores = targets.map((t) => scoreTarget(t)).toList();
    scores.sort((a, b) => b.totalScore.compareTo(a.totalScore));
    return scores;
  }

  /// Test-only seam exposing the private altitude piecewise so the
  /// Rust<->Dart parity test can drive the REAL production scorer (not a
  /// re-implementation that can never disagree with itself). Behaviour is
  /// unchanged in production — nothing else calls this.
  @visibleForTesting
  double debugScoreAltitude(double altitude) => _scoreAltitude(altitude);

  /// Test-only seam for the moon factor, for the same reason as
  /// [debugScoreAltitude]: the parity canary has to cover the moon factor too,
  /// or the Rust twin (`scheduling/scoring.rs::score_moon_distance`) can
  /// diverge unseen. Whichever scorer runs, a full moon must never beat a new
  /// moon at the same separation.
  @visibleForTesting
  double debugScoreMoonDistance(double distance, double illumination) =>
      _scoreMoonDistance(distance, illumination);
}
