/// Result models returned by [AstronomyCalculations].
///
/// Kept in their own library so the calculation facade stays readable; they are
/// re-exported from `astronomy_calculations.dart`, so every existing import
/// path still resolves these names.
library;

/// The three twilight boundaries, by how far the Sun is below the horizon.
enum TwilightKind {
  civil(-6.0),
  nautical(-12.0),
  astronomical(-18.0);

  const TwilightKind(this.sunAltitudeDeg);

  /// Sun altitude at the boundary, degrees.
  final double sunAltitudeDeg;
}

/// Sunset, the three dusks, the three dawns and sunrise of one night.
///
/// A field is null when the Sun never crosses that altitude on that night
/// (polar day or night, or a summer night with no astronomical darkness).
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

  /// When the Sun sinks below the [kind] boundary in the evening.
  DateTime? dusk(TwilightKind kind) => switch (kind) {
    TwilightKind.civil => civilDusk,
    TwilightKind.nautical => nauticalDusk,
    TwilightKind.astronomical => astronomicalDusk,
  };

  /// When the Sun climbs back above the [kind] boundary in the morning.
  DateTime? dawn(TwilightKind kind) => switch (kind) {
    TwilightKind.civil => civilDawn,
    TwilightKind.nautical => nauticalDawn,
    TwilightKind.astronomical => astronomicalDawn,
  };

  /// Get darkness period (astronomical dusk to dawn)
  Duration? get darknessDuration {
    if (astronomicalDusk != null && astronomicalDawn != null) {
      return astronomicalDawn!.difference(astronomicalDusk!);
    }
    return null;
  }
}

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

  Duration? get durationAboveHorizon {
    if (isCircumpolar) return const Duration(hours: 24);
    if (neverRises) return Duration.zero;
    if (riseTime != null && setTime != null) {
      return setTime!.difference(riseTime!);
    }
    return null;
  }
}
