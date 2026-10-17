import 'dart:math' as math;
import '../coordinate_system.dart';

/// Milky Way data and calculations for rendering the galactic band
class MilkyWayData {
  MilkyWayData._();

  static const double _deg2rad = math.pi / 180;
  static const double _rad2deg = 180 / math.pi;

  /// Galactic North Pole in equatorial coordinates (J2000)
  /// RA: 12h 51m 26.28s = 192.8595 degrees
  /// Dec: +27° 7' 41.7" = 27.1283 degrees
  static const double galacticNorthPoleRA = 192.8595;
  static const double galacticNorthPoleDec = 27.1283;

  /// Galactic center direction (Sagittarius A*)
  /// RA: 17h 45m 40.04s = 266.4168 degrees
  /// Dec: -29° 0' 28.1" = -29.0078 degrees
  static const double galacticCenterRA = 266.4168;
  static const double galacticCenterDec = -29.0078;

  /// Longitude of ascending node of galactic plane on celestial equator
  static const double galacticAscendingNode = 32.9319;

  /// Convert equatorial coordinates to galactic coordinates
  /// Returns (l, b) in degrees where l is galactic longitude, b is galactic latitude
  static (double l, double b) equatorialToGalactic(
    double raDeg,
    double decDeg,
  ) {
    final ra = raDeg * _deg2rad;
    final dec = decDeg * _deg2rad;
    const raGNP = galacticNorthPoleRA * _deg2rad;
    const decGNP = galacticNorthPoleDec * _deg2rad;
    const l0 = galacticAscendingNode * _deg2rad;

    // Calculate galactic latitude
    final sinB =
        math.sin(decGNP) * math.sin(dec) +
        math.cos(decGNP) * math.cos(dec) * math.cos(ra - raGNP);
    final b = math.asin(sinB.clamp(-1.0, 1.0));

    // Calculate galactic longitude
    final y = math.cos(dec) * math.sin(ra - raGNP);
    final x =
        math.cos(decGNP) * math.sin(dec) -
        math.sin(decGNP) * math.cos(dec) * math.cos(ra - raGNP);
    var l = l0 - math.atan2(y, x);

    // Normalize to 0-360
    l = l * _rad2deg;
    l = l % 360;
    if (l < 0) l += 360;

    return (l, b * _rad2deg);
  }

  /// Convert galactic coordinates to equatorial coordinates
  /// Returns (ra, dec) in degrees
  static (double ra, double dec) galacticToEquatorial(
    double lDeg,
    double bDeg,
  ) {
    final l = lDeg * _deg2rad;
    final b = bDeg * _deg2rad;
    const l0 = galacticAscendingNode * _deg2rad;
    const decGNP = galacticNorthPoleDec * _deg2rad;
    const raGNP = galacticNorthPoleRA * _deg2rad;

    // Calculate declination
    final sinDec =
        math.sin(decGNP) * math.sin(b) +
        math.cos(decGNP) * math.cos(b) * math.cos(l0 - l);
    final dec = math.asin(sinDec.clamp(-1.0, 1.0));

    // Calculate right ascension
    final y = math.cos(b) * math.sin(l0 - l);
    final x =
        math.cos(decGNP) * math.sin(b) -
        math.sin(decGNP) * math.cos(b) * math.cos(l0 - l);
    var ra = raGNP + math.atan2(y, x);

    // Normalize to 0-360
    ra = ra * _rad2deg;
    ra = ra % 360;
    if (ra < 0) ra += 360;

    return (ra, dec * _rad2deg);
  }

  /// Get Milky Way intensity at a given galactic latitude
  /// Returns 0.0-1.0 intensity value
  /// The Milky Way is brightest along the galactic plane (b=0)
  /// and has enhanced regions in Sagittarius (galactic center)
  static double getIntensity(double lDeg, double bDeg) {
    // Base intensity falls off with galactic latitude
    // Using a Gaussian-like profile
    final absB = bDeg.abs();

    // Core band (|b| < 8 degrees)
    if (absB < 8) {
      var intensity = 1.0 - (absB / 8) * 0.3; // 0.7-1.0 in core

      // Enhanced brightness near galactic center (Sagittarius)
      // l=0 is galactic center direction
      final distFromCenter = _angularDistanceOnPlane(lDeg, 0);
      if (distFromCenter < 60) {
        // Sagittarius region
        intensity *= 1.0 + (1 - distFromCenter / 60) * 0.5;
      }

      // Enhanced brightness in Cygnus (l~80)
      final distFromCygnus = _angularDistanceOnPlane(lDeg, 80);
      if (distFromCygnus < 30) {
        intensity *= 1.0 + (1 - distFromCygnus / 30) * 0.2;
      }

      // Dark rift effect near galactic center
      if (distFromCenter < 45 && absB < 3) {
        // Patchy dark clouds
        final patchPhase = math.sin(lDeg * 0.1) * math.cos(bDeg * 0.5);
        intensity *= 0.7 + patchPhase * 0.15;
      }

      return intensity.clamp(0.0, 1.0);
    }

    // Outer halo (8-20 degrees) - fades out
    if (absB < 20) {
      return (1 - (absB - 8) / 12) * 0.7;
    }

    // Very faint halo (20-30 degrees)
    if (absB < 30) {
      return (1 - (absB - 20) / 10) * 0.15;
    }

    return 0.0;
  }

  /// Calculate angular distance along the galactic plane
  static double _angularDistanceOnPlane(double l1, double l2) {
    var diff = (l1 - l2).abs();
    if (diff > 180) diff = 360 - diff;
    return diff;
  }

  /// Generate a list of points along the galactic plane for rendering
  /// Returns list of (ra, dec, intensity) tuples
  static List<MilkyWayPoint> generateMilkyWayPoints({
    int longitudeSteps = 72, // Every 5 degrees
    int latitudeSteps = 13, // -30 to +30 degrees
  }) {
    final points = <MilkyWayPoint>[];

    for (var li = 0; li < longitudeSteps; li++) {
      final l = (li * 360.0 / longitudeSteps);

      for (var bi = 0; bi < latitudeSteps; bi++) {
        final b = -30.0 + (bi * 60.0 / (latitudeSteps - 1));
        final intensity = getIntensity(l, b);

        if (intensity > 0.05) {
          final (ra, dec) = galacticToEquatorial(l, b);
          points.add(
            MilkyWayPoint(
              ra: ra / 15, // Convert to hours
              dec: dec,
              intensity: intensity,
              galacticLon: l,
              galacticLat: b,
            ),
          );
        }
      }
    }

    return points;
  }

  /// Get coordinates of notable Milky Way features for labeling
  static List<MilkyWayFeature> getNotableFeatures() {
    return const [
      MilkyWayFeature(
        name: 'Galactic Center',
        ra: 266.4168 / 15, // 17h 45m
        dec: -29.0078,
        description: 'Center of the Milky Way (Sagittarius A*)',
      ),
      MilkyWayFeature(
        name: 'Cygnus Star Cloud',
        ra: 307.0 / 15, // ~20h 28m
        dec: 42.0,
        description: 'Bright star cloud in Cygnus',
      ),
      MilkyWayFeature(
        name: 'Scutum Star Cloud',
        ra: 278.0 / 15, // ~18h 32m
        dec: -6.0,
        description: 'Dense star cloud in Scutum',
      ),
      MilkyWayFeature(
        name: 'Great Rift',
        ra: 290.0 / 15, // ~19h 20m
        dec: 20.0,
        description: 'Dark dust lane obscuring stars',
      ),
    ];
  }
}

/// A point on the Milky Way band
class MilkyWayPoint {
  final double ra; // Hours
  final double dec; // Degrees
  final double intensity; // 0.0-1.0
  final double galacticLon;
  final double galacticLat;

  const MilkyWayPoint({
    required this.ra,
    required this.dec,
    required this.intensity,
    required this.galacticLon,
    required this.galacticLat,
  });

  CelestialCoordinate get coordinates => CelestialCoordinate(ra: ra, dec: dec);
}

/// A notable feature in the Milky Way
class MilkyWayFeature {
  final String name;
  final double ra; // Hours
  final double dec; // Degrees
  final String description;

  const MilkyWayFeature({
    required this.name,
    required this.ra,
    required this.dec,
    required this.description,
  });

  CelestialCoordinate get coordinates => CelestialCoordinate(ra: ra, dec: dec);
}
