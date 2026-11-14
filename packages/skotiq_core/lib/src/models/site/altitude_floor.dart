import 'dart:math' as math;

import 'package:skotiq_astro/skotiq_astro.dart' show AstronomyCalculations;

import 'site_horizon_profile.dart';

/// How high a target must stand at this site to be imaged: the one rule.
///
/// When the operator has set a horizon for the property, that horizon is the
/// floor, direction by direction. Otherwise the floor is the minimum altitude
/// setting, the same in every direction. Obstructions the runs learned at the
/// site raise the floor where they are in either case. Both settings stay
/// stored; only which one is in force follows the horizon.
class AltitudeFloor {
  const AltitudeFloor({required this.horizon, required this.minimumDeg});

  /// The site's horizon with the learned obstructions merged in; null before
  /// the settings have loaded.
  final SiteHorizonProfile? horizon;

  /// The minimum altitude setting, in force when no horizon is set.
  final double minimumDeg;

  /// Whether the operator's own horizon is in force rather than the minimum
  /// altitude.
  bool get followsHorizon => horizon?.hasOwnHorizon ?? false;

  /// The floor in degrees toward [azimuthDeg].
  double atAzimuth(double azimuthDeg) {
    final horizonDeg = horizon?.altitudeAtAzimuth(azimuthDeg) ?? 0.0;
    return followsHorizon ? horizonDeg : math.max(minimumDeg, horizonDeg);
  }

  /// Samples for the native scheduler and altitude loops, including the
  /// learned obstruction edges that a regular grid could smooth away.
  List<({double azimuth, double altitude})> denseSamples() {
    final samples = [
      for (final sample
          in horizon?.denseSamples() ?? const [(azimuth: 0.0, altitude: 0.0)])
        (azimuth: sample.azimuth, altitude: atAzimuth(sample.azimuth)),
    ];
    if (samples.every((sample) => sample.altitude == samples.first.altitude)) {
      return [samples.first];
    }
    return samples;
  }

  /// Whether a target at [altitudeDeg] toward [azimuthDeg] clears the floor.
  bool clears(double altitudeDeg, double azimuthDeg) =>
      altitudeDeg >= atAzimuth(azimuthDeg);

  /// The floor in the direction a target at [raHours]/[decDeg] stands at
  /// [at], for a step that holds one number (a target's "wait until it is
  /// this high").
  double forTarget({
    required double raHours,
    required double decDeg,
    required double latitudeDeg,
    required double longitudeDeg,
    required DateTime at,
  }) {
    final (_, az) = AstronomyCalculations.objectAltAz(
      raDeg: raHours * 15.0,
      decDeg: decDeg,
      dt: at,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
    return atAzimuth(az);
  }

  /// The lowest the floor goes in any direction, for a reader that knows no
  /// direction (a whole night's estimate): it never refuses a target for a
  /// direction it may not be in.
  double get lowestDeg {
    final h = horizon;
    if (h == null || h.isFlat) return minimumDeg;
    var lowest = double.infinity;
    for (final s in h.denseSamples()) {
      lowest = math.min(lowest, atAzimuth(s.azimuth));
    }
    return lowest.isFinite ? lowest : minimumDeg;
  }

  /// How long until a target at [raDeg]/[decDeg] sinks below the floor in the
  /// direction it is then in, from [now]: [Duration.zero] when it is already
  /// below, null when it does not sink within a day (as
  /// [AstronomyCalculations.timeUntilBelow] answers for a flat floor).
  Duration? timeUntilBelow({
    required double raDeg,
    required double decDeg,
    required DateTime now,
    required double latitudeDeg,
    required double longitudeDeg,
  }) {
    final h = horizon;
    if (h == null || h.isFlat) {
      return AstronomyCalculations.timeUntilBelow(
        raDeg: raDeg,
        decDeg: decDeg,
        now: now,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
        horizonDeg: minimumDeg,
      );
    }
    bool above(DateTime t) {
      final (alt, az) = AstronomyCalculations.objectAltAz(
        raDeg: raDeg,
        decDeg: decDeg,
        dt: t,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
      );
      return clears(alt, az);
    }

    if (!above(now)) return Duration.zero;
    for (var minute = 1; minute <= 24 * 60; minute++) {
      if (!above(now.add(Duration(minutes: minute)))) {
        return Duration(minutes: minute);
      }
    }
    return null;
  }
}
