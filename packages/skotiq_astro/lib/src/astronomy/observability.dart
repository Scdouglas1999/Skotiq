/// How observable a target is *right now*, folding both its altitude and how
/// bright the sky is at the observing site.
///
/// Altitude alone is not observability. Grading on altitude alone is how the
/// object popup came to badge a target "Excellent" at 11:52 local with the Sun
/// 63 deg above the horizon, on the same screen where the app's own dashboard
/// said "Dark in 10h 36m". A confident green pill on an unobservable target is
/// exactly the kind of reassuring fabrication this product must not ship, so
/// daylight and twilight outrank altitude here.
enum ObservabilityGrade {
  /// Sun above the horizon: nothing faint is reachable, whatever the altitude.
  daylight,

  /// Sun between 0 and -12 deg (civil / nautical twilight): the sky is still
  /// too bright for deep-sky work.
  twilight,

  /// Below the horizon (or below the observer's effective horizon).
  belowHorizon,

  /// Above the horizon but low enough that airmass and local obstructions
  /// dominate.
  low,

  /// Comfortably up.
  good,

  /// High, dark, and clear of the horizon.
  excellent;

  /// Short label for a badge/pill.
  String get label => switch (this) {
    ObservabilityGrade.daylight => 'Daylight',
    ObservabilityGrade.twilight => 'Twilight',
    ObservabilityGrade.belowHorizon => 'Below Horizon',
    ObservabilityGrade.low => 'Low',
    ObservabilityGrade.good => 'Good',
    ObservabilityGrade.excellent => 'Excellent',
  };

  /// True when the target cannot usefully be imaged at this instant.
  bool get isBlocked =>
      this == ObservabilityGrade.daylight ||
      this == ObservabilityGrade.belowHorizon;

  /// True when the sky itself (not the target) is the limiting factor.
  bool get isSkyTooBright =>
      this == ObservabilityGrade.daylight ||
      this == ObservabilityGrade.twilight;
}

/// Grade a target from its altitude and the Sun's altitude, both in degrees.
///
/// [sunAltitudeDeg] may be null when the observing site is unknown, in which
/// case the grade falls back to altitude alone rather than inventing a sky
/// brightness.
ObservabilityGrade gradeObservability({
  required double altitudeDeg,
  double? sunAltitudeDeg,
  double horizonDeg = 0,
}) {
  if (altitudeDeg <= horizonDeg) return ObservabilityGrade.belowHorizon;
  if (sunAltitudeDeg != null) {
    if (sunAltitudeDeg >= 0) return ObservabilityGrade.daylight;
    // Nautical twilight (-12 deg) is the conventional floor for deep-sky work;
    // astronomical twilight (-18) is where it is genuinely dark, but grading
    // -12..-18 as "twilight" would flag most of a usable summer night.
    if (sunAltitudeDeg >= -12) return ObservabilityGrade.twilight;
  }
  if (altitudeDeg > 30) return ObservabilityGrade.excellent;
  if (altitudeDeg > 15) return ObservabilityGrade.good;
  return ObservabilityGrade.low;
}
