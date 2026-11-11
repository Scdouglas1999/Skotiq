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

  /// Convert to Alt/Az for given location and time
  HorizontalCoordinate toHorizontal({
    required double latitude,
    required double longitude,
    required DateTime time,
  }) {
    // Calculate Local Sidereal Time
    final jd = _julianDate(time);
    final lst = _localSiderealTime(jd, longitude);

    // Hour angle
    final ha = (lst - ra) * 15 * math.pi / 180;

    // Convert to horizontal
    final latRad = latitude * math.pi / 180;

    final sinAlt =
        math.sin(decRadians) * math.sin(latRad) +
        math.cos(decRadians) * math.cos(latRad) * math.cos(ha);
    final alt = math.asin(sinAlt.clamp(-1.0, 1.0));

    final y = -math.sin(ha) * math.cos(decRadians);
    final x =
        math.sin(decRadians) * math.cos(latRad) -
        math.cos(decRadians) * math.sin(latRad) * math.cos(ha);
    var az = math.atan2(y, x);
    if (az < 0) az += 2 * math.pi;

    return HorizontalCoordinate(
      altitude: alt * 180 / math.pi,
      azimuth: az * 180 / math.pi,
    );
  }

  /// NOT [AstronomyCalculations.julianDate], and deliberately not re-pointed
  /// at it during the astronomy consolidation.
  ///
  /// This copy omits both the `.toUtc()` normalization and the trailing
  /// `- 0.5` that turns a noon-based day number into a Julian Date, so it
  /// returns JD + 0.5. Half a day is 180.49° of GMST — about 12 sidereal
  /// hours — so switching it to the shared function would move every
  /// altitude/azimuth this class produces, not round them. `coordinate_system_test.dart`
  /// asserts the +0.5 value and says the offset "cancels out in
  /// toHorizontal()", which it does not: the GMST polynomial is a function of
  /// JD, not of a JD difference.
  ///
  /// That is a behaviour question, not a duplication question, and the
  /// release-pass rule is that behaviour changes are reproduced in the running
  /// app before they are made. Recorded in
  /// `reports/release-pass/impl/c2-astronomy-sidereal.md` and left alone here.
  double _julianDate(DateTime dt) {
    final y = dt.year;
    final m = dt.month;
    final d = dt.day + dt.hour / 24 + dt.minute / 1440 + dt.second / 86400;

    final a = ((14 - m) / 12).floor();
    final y2 = y + 4800 - a;
    final m2 = m + 12 * a - 3;

    return d +
        ((153 * m2 + 2) / 5).floor() +
        365 * y2 +
        (y2 / 4).floor() -
        (y2 / 100).floor() +
        (y2 / 400).floor() -
        32045;
  }

  double _localSiderealTime(double jd, double longitude) {
    final t = (jd - 2451545.0) / 36525;
    var lst =
        280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        t * t * t / 38710000;
    lst = lst + longitude;
    lst = lst % 360;
    if (lst < 0) lst += 360;
    return lst / 15; // Convert to hours
  }

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

/// Horizontal coordinate (Alt/Az)
class HorizontalCoordinate {
  /// Altitude in degrees (0 = horizon, 90 = zenith)
  final double altitude;

  /// Azimuth in degrees (0 = North, 90 = East)
  final double azimuth;

  const HorizontalCoordinate({required this.altitude, required this.azimuth});

  bool get isAboveHorizon => altitude > 0;

  @override
  String toString() =>
      'Alt: ${altitude.toStringAsFixed(1)}°, Az: ${azimuth.toStringAsFixed(1)}°';
}
