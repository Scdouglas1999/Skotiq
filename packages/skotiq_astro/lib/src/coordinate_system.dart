import 'dart:math' as math;

import 'astronomy/astronomy_calculations.dart';

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
  String toString() => 'RA: ${formatRA()}, Dec: ${formatDec()}';

  /// Format RA as hours, minutes, seconds string
  String formatRA({bool compact = false}) {
    final h = ra.floor();
    final m = ((ra - h) * 60).floor();
    final s = ((ra - h - m / 60) * 3600);
    if (compact) {
      return '${h.toString().padLeft(2, '0')}h${m.toString().padLeft(2, '0')}m';
    }
    return '${h}h ${m}m ${s.toStringAsFixed(1)}s';
  }

  /// Format Dec as degrees, arcminutes, arcseconds string
  String formatDec({bool compact = false}) {
    final sign = dec >= 0 ? '+' : '-';
    final d = dec.abs().floor();
    final m = ((dec.abs() - d) * 60).floor();
    final s = ((dec.abs() - d - m / 60) * 3600);
    if (compact) {
      return "$sign${d.toString().padLeft(2, '0')}°${m.toString().padLeft(2, '0')}'";
    }
    return "$sign$d° $m' ${s.toStringAsFixed(1)}\"";
  }

  /// Get RA in HMS format suitable for sequencer/equipment
  String get raHms => formatRA();

  /// Get Dec in DMS format suitable for sequencer/equipment
  String get decDms => formatDec();

  /// Get short form for display (e.g., "12h 30m, +45° 15'")
  String get shortForm =>
      '${formatRA(compact: true)}, ${formatDec(compact: true)}';
}
