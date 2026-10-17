part of '../target_scoring.dart';

extension _TargetAxisScores on TargetScoringService {
  double _scoreAltitude(double altitude) {
    if (altitude < 0) return 0;
    if (altitude < 15) return altitude * 2; // 0-30 for 0-15°
    if (altitude < 30) return 30 + (altitude - 15) * 2; // 30-60 for 15-30°
    if (altitude < 60) return 60 + (altitude - 30) * 1.33; // 60-100 for 30-60°
    return 100; // Above 60° is perfect
  }

  double _scoreMoonDistance(double distance, double illumination) {
    // Moon distance matters more when moon is bright
    final moonFactor = (illumination / 100).clamp(0.0, 1.0);

    if (illumination < 10) {
      // New moon - distance doesn't matter much
      return 90 + (distance / 180) * 10;
    }

    // Scale by illumination
    final minGoodDist = 30 + (70 * moonFactor); // 30-100° depending on moon

    // The best achievable moon score falls as the moon brightens. Returning a
    // flat 100 for "far enough away" meant a FULL moon at 101° scored 100 while
    // a NEW moon at the same separation scored 95.6 — the factor literally
    // rewarded the worse night. Moonlight raises the sky background over the
    // whole hemisphere, so no separation earns a perfect moon score under a
    // bright moon.
    final bestAchievable = 100 - 22 * moonFactor;

    if (distance >= minGoodDist) return bestAchievable;
    if (distance < 10) return 10 * (1 - moonFactor * 0.8);

    return (distance / minGoodDist) * bestAchievable;
  }

  double _scoreTransitProximity(ObjectVisibility visibility, DateTime time) {
    if (visibility.neverRises) return 0;
    if (visibility.transitTime == null) return 50; // Unknown

    final minutesToTransit = visibility.transitTime!
        .difference(time)
        .inMinutes
        .abs();

    // Best score when close to transit (within 2 hours)
    if (minutesToTransit < 30) return 100;
    if (minutesToTransit < 60) return 90;
    if (minutesToTransit < 120) return 80;
    if (minutesToTransit < 240) return 60;
    if (minutesToTransit < 360) return 40;
    return 20;
  }

  double _scoreDarkness() {
    if (twilight == null) return 70; // Unknown

    // Best during astronomical darkness
    if (twilight!.astronomicalDusk != null &&
        twilight!.astronomicalDawn != null) {
      if (observationTime.isAfter(twilight!.astronomicalDusk!) &&
          observationTime.isBefore(twilight!.astronomicalDawn!)) {
        return 100; // Full darkness
      }
    }

    // During nautical twilight
    if (twilight!.nauticalDusk != null && twilight!.nauticalDawn != null) {
      if (observationTime.isAfter(twilight!.nauticalDusk!) &&
          observationTime.isBefore(twilight!.nauticalDawn!)) {
        return 70;
      }
    }

    // During civil twilight
    if (twilight!.civilDusk != null && twilight!.civilDawn != null) {
      if (observationTime.isAfter(twilight!.civilDusk!) &&
          observationTime.isBefore(twilight!.civilDawn!)) {
        return 40;
      }
    }

    // Daytime
    return 10;
  }

  double _scoreAirmass(double airmass) {
    if (airmass.isInfinite) return 0;
    if (airmass <= 1.0) return 100;
    if (airmass <= 1.5) return 90;
    if (airmass <= 2.0) return 70;
    if (airmass <= 2.5) return 50;
    if (airmass <= 3.0) return 30;
    return 10;
  }

  /// Score transit proximity relative to the night window.
  ///
  /// Targets whose transit falls during the night score highest, with a bonus
  /// for transits near the middle of the night. Targets whose transit is just
  /// outside the night window still score moderately.
  double _scoreTransitProximityForNight(
    ObjectVisibility visibility,
    DateTime nightStart,
    DateTime nightEnd,
  ) {
    if (visibility.neverRises) return 0;
    if (visibility.transitTime == null) return 50;

    final transitTime = visibility.transitTime!;
    final nightMid = nightStart.add(
      Duration(seconds: nightEnd.difference(nightStart).inSeconds ~/ 2),
    );
    final halfNightMinutes = nightEnd.difference(nightStart).inMinutes / 2;

    // Is transit during the night?
    if (transitTime.isAfter(nightStart) && transitTime.isBefore(nightEnd)) {
      // Transit is during the night - score based on how centered it is
      final offsetFromMid = transitTime.difference(nightMid).inMinutes.abs();
      if (halfNightMinutes <= 0) return 100;
      final centeredness =
          1.0 - (offsetFromMid / halfNightMinutes).clamp(0.0, 1.0);
      return 70 + centeredness * 30; // 70-100 for transits during the night
    }

    // Transit is outside the night - score based on proximity to the window
    final minutesToStart = transitTime.difference(nightStart).inMinutes.abs();
    final minutesToEnd = transitTime.difference(nightEnd).inMinutes.abs();
    final closestMinutes = minutesToStart < minutesToEnd
        ? minutesToStart
        : minutesToEnd;

    if (closestMinutes < 60) return 60;
    if (closestMinutes < 120) return 40;
    if (closestMinutes < 240) return 20;
    return 10;
  }

  /// Score based on available imaging hours during the night.
  ///
  /// Replaces the real-time darkness check with a measure of how much of the
  /// night the target is above minimum altitude -- more useful for planning.
  double _scoreImagingWindow(
    double hoursAboveMin,
    DateTime nightStart,
    DateTime nightEnd,
  ) {
    final nightHours = nightEnd.difference(nightStart).inMinutes / 60.0;
    if (nightHours <= 0) return 10;
    if (hoursAboveMin <= 0) return 0;

    final fraction = (hoursAboveMin / nightHours).clamp(0.0, 1.0);

    if (fraction >= 0.8) return 100; // Available most of the night
    if (fraction >= 0.6) return 90;
    if (fraction >= 0.4) return 75;
    if (fraction >= 0.2) return 55;
    return 30;
  }
}
