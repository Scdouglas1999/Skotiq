import 'dart:math' as math;

import 'package:skotiq_astro/skotiq_astro.dart';

import 'site_horizon_profile.dart';

/// How high a target must stand at this site to be imaged: the one rule.
///
/// When the operator has set a horizon for the property, that horizon is the
/// floor, direction by direction, and the minimum altitude is not applied.
/// Otherwise the floor is the minimum altitude setting, the same in every
/// direction. Obstructions the runs learned at the site raise the floor where
/// they are in either case. Both settings stay stored; only which one is in
/// force follows the horizon.
///
/// Everything that asks "is this target high enough" or "when does it clear
/// or leave the floor tonight" asks here, and the run receives [toWire] in
/// its configuration, where the native `AltitudeFloor` answers the same
/// questions. Both answer `test_fixtures/altitude_floor/cases.json`.
class AltitudeFloor {
  const AltitudeFloor({
    required this.horizon,
    required this.minimumDeg,
    this.targetMinimumDeg,
  });

  /// The site's horizon with the learned obstructions merged in; null before
  /// the settings have loaded.
  final SiteHorizonProfile? horizon;

  /// The minimum altitude setting, in force when no horizon is set.
  final double minimumDeg;

  /// What one target must clear on top of the site's floor, when the operator
  /// gave that target a minimum of its own.
  final double? targetMinimumDeg;

  /// Whether the operator's own horizon is in force rather than the minimum
  /// altitude.
  bool get followsHorizon => horizon?.hasOwnHorizon ?? false;

  /// Whether the floor is the same in every direction.
  bool get isFlat => horizon?.isFlat ?? true;

  /// This floor for a target that carries a minimum of its own: the target
  /// must clear both.
  AltitudeFloor forTargetMinimum(double? degrees) => degrees == null
      ? this
      : AltitudeFloor(
          horizon: horizon,
          minimumDeg: minimumDeg,
          targetMinimumDeg: degrees,
        );

  /// The floor in degrees toward [azimuthDeg].
  double atAzimuth(double azimuthDeg) {
    final horizonDeg = horizon?.altitudeAtAzimuth(azimuthDeg) ?? 0.0;
    final site = followsHorizon ? horizonDeg : math.max(minimumDeg, horizonDeg);
    final own = targetMinimumDeg;
    return own == null ? site : math.max(site, own);
  }

  /// The floor by azimuth, including the learned obstruction edges that a
  /// regular grid could smooth away. One sample when it is flat.
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

  /// The floor as the run configuration and the native scheduler read it.
  Map<String, Object?> toWire() => {
    'samples': [
      for (final sample in denseSamples())
        {'az': sample.azimuth, 'alt': sample.altitude},
    ],
  };

  /// Whether a point at [altitudeDeg] toward [azimuthDeg] clears the floor.
  bool clears(double altitudeDeg, double azimuthDeg) =>
      altitudeDeg >= atAzimuth(azimuthDeg);

  /// The floor as samples, for a background isolate or a package that
  /// cannot see this class.
  AltitudeFloorSamples asSamples() {
    final samples = denseSamples();
    return AltitudeFloorSamples(
      [for (final sample in samples) sample.azimuth],
      [for (final sample in samples) sample.altitude],
    );
  }

  /// Whether a target at [raDeg]/[decDeg] (J2000) is above the floor in the
  /// direction it stands at [at].
  bool isAbove({
    required double raDeg,
    required double decDeg,
    required DateTime at,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => targetIsAboveFloor(
    atAzimuth,
    raDeg: raDeg,
    decDeg: decDeg,
    at: at,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// The first time in [from]..[until] that the target is above the floor:
  /// [from] itself when it already is, null when it stays below.
  DateTime? risesAbove({
    required double raDeg,
    required double decDeg,
    required DateTime from,
    required DateTime until,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => firstTimeAgainstFloor(
    atAzimuth,
    raDeg: raDeg,
    decDeg: decDeg,
    from: from,
    until: until,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    above: true,
  );

  /// The first time in [from]..[until] that the target is below the floor:
  /// [from] itself when it already is, null when it stays above.
  DateTime? setsBelow({
    required double raDeg,
    required double decDeg,
    required DateTime from,
    required DateTime until,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => firstTimeAgainstFloor(
    atAzimuth,
    raDeg: raDeg,
    decDeg: decDeg,
    from: from,
    until: until,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    above: false,
  );

  /// The longest stretch within [from]..[until] that the target stays above
  /// the floor. Null when it never clears the floor in that span.
  ({DateTime start, DateTime end})? windowAbove({
    required double raDeg,
    required double decDeg,
    required DateTime from,
    required DateTime until,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => longestWindowAboveFloor(
    atAzimuth,
    raDeg: raDeg,
    decDeg: decDeg,
    from: from,
    until: until,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// When the target clears and leaves the floor in the 24 hours centered on
  /// [center], with its transit.
  ObjectVisibility visibilityAround({
    required double raDeg,
    required double decDeg,
    required DateTime center,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => objectVisibilityAboveFloor(
    atAzimuth,
    raDeg: raDeg,
    decDeg: decDeg,
    center: center,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

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
    if (isFlat) {
      return AstronomyCalculations.timeUntilBelow(
        raDeg: raDeg,
        decDeg: decDeg,
        now: now,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
        horizonDeg: atAzimuth(0),
      );
    }
    return setsBelow(
      raDeg: raDeg,
      decDeg: decDeg,
      from: now,
      until: now.add(const Duration(days: 1)),
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    )?.difference(now);
  }
}
