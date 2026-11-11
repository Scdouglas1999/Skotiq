import 'dart:math' as math;

import 'astronomy/astronomy_calculations.dart';
import 'format/coordinate_format.dart';

/// Great-circle separation between two catalog positions.
///
/// The one place in the package that turns a pair of [CelestialCoordinate]s
/// into an angle. RA is in DEGREES here — a hand-rolled copy taking RA in
/// hours reads correctly and is wrong by 15x.
extension CelestialSeparation on CelestialCoordinate {
  /// Angular distance to [other], in degrees.
  double separationDegrees(CelestialCoordinate other) =>
      AstronomyCalculations.angularSeparation(
        ra1Deg: raDegrees,
        dec1Deg: dec,
        ra2Deg: other.raDegrees,
        dec2Deg: other.dec,
      );
}

/// Celestial coordinate in RA/Dec (J2000)
class CelestialCoordinate {
  /// Right Ascension in hours (0-24)
  final double ra;

  /// Declination in degrees (-90 to +90)
  final double dec;

  const CelestialCoordinate({required this.ra, required this.dec});

  /// Build from a right ascension expressed in DEGREES (0-360).
  ///
  /// Use this wherever the source data is published in degrees so the unit is
  /// stated at the point of definition — [ra] itself is hours, and passing a
  /// degree value to the default constructor silently multiplies every derived
  /// position by 15.
  const CelestialCoordinate.fromDegrees({
    required double raDegrees,
    required double decDegrees,
  }) : ra = raDegrees / 15,
       dec = decDegrees;

  /// RA in degrees
  double get raDegrees => ra * 15;

  /// RA in radians
  double get raRadians => raDegrees * math.pi / 180;

  /// Dec in radians
  double get decRadians => dec * math.pi / 180;

  @override
  String toString() =>
      'RA: ${CoordinateFormat.raReadout(ra)}, '
      'Dec: ${CoordinateFormat.decReadout(dec)}';
}
