/// Result models returned by [AstronomyCalculations].
///
/// Kept in their own library so the calculation facade stays readable; they are
/// re-exported from `astronomy_calculations.dart`, so every existing import
/// path still resolves these names.
library;

/// Twilight times container
class TwilightTimes {
  final DateTime? sunset;
  final DateTime? civilDusk;
  final DateTime? nauticalDusk;
  final DateTime? astronomicalDusk;
  final DateTime? astronomicalDawn;
  final DateTime? nauticalDawn;
  final DateTime? civilDawn;
  final DateTime? sunrise;

  const TwilightTimes({
    this.sunset,
    this.civilDusk,
    this.nauticalDusk,
    this.astronomicalDusk,
    this.astronomicalDawn,
    this.nauticalDawn,
    this.civilDawn,
    this.sunrise,
  });

  /// Get darkness period (astronomical dusk to dawn)
  Duration? get darknessDuration {
    if (astronomicalDusk != null && astronomicalDawn != null) {
      return astronomicalDawn!.difference(astronomicalDusk!);
    }
    return null;
  }
}

/// Moon times and phase container
class MoonTimes {
  final DateTime? moonrise;
  final DateTime? moonset;
  final double illumination;
  final String phaseName;

  const MoonTimes({
    this.moonrise,
    this.moonset,
    required this.illumination,
    required this.phaseName,
  });
}

/// Meridian-flip planning window for a target.
///
/// [transitTime] is the instant the target crosses the local meridian (hour
/// angle 0) — the moment a German equatorial mount must flip. [flipDeadline]
/// is the latest time tracking may continue past the meridian before the flip
/// is forced (equal to [transitTime] when no past-meridian limit is given).
class MeridianFlipWindow {
  final DateTime transitTime;
  final DateTime flipDeadline;
  final double? transitAltitude;

  const MeridianFlipWindow({
    required this.transitTime,
    required this.flipDeadline,
    this.transitAltitude,
  });
}

/// Object visibility information
class ObjectVisibility {
  final DateTime? riseTime;
  final DateTime? transitTime;
  final DateTime? setTime;
  final double? transitAltitude;
  final bool isCircumpolar;
  final bool neverRises;

  const ObjectVisibility({
    this.riseTime,
    this.transitTime,
    this.setTime,
    this.transitAltitude,
    this.isCircumpolar = false,
    this.neverRises = false,
  });

  /// Get duration object is above horizon
  Duration? get durationAboveHorizon {
    if (isCircumpolar) return const Duration(hours: 24);
    if (neverRises) return Duration.zero;
    if (riseTime != null && setTime != null) {
      return setTime!.difference(riseTime!);
    }
    return null;
  }
}
