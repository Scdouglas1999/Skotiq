part of '../constellation_data.dart';

/// A boundary polygon vertex (RA in hours, Dec in degrees, J2000)
class BoundaryVertex {
  final double ra;
  final double dec;
  const BoundaryVertex(this.ra, this.dec);
}

/// Constellation boundary data with point-in-polygon lookup.
/// Boundaries are simplified IAU constellation boundaries (J2000 epoch).
/// Each boundary is a closed polygon of RA/Dec vertices.
class ConstellationBoundaries {
  /// Get boundary vertices for a given constellation abbreviation.
  static List<BoundaryVertex>? getBoundary(String abbreviation) {
    return _boundaries[abbreviation];
  }

  /// Get all boundary data.
  static Map<String, List<BoundaryVertex>> get all => _boundaries;

  /// Determine which constellation contains the given RA/Dec coordinate.
  /// Uses ray-casting point-in-polygon algorithm adapted for spherical coords.
  /// Returns the IAU abbreviation, or null if not found.
  static String? getConstellationAtCoordinate(double ra, double dec) {
    for (final entry in _boundaries.entries) {
      if (_pointInPolygon(ra, dec, entry.value)) {
        return entry.key;
      }
    }
    return null;
  }

  /// Ray-casting algorithm for point-in-polygon on the RA/Dec sphere.
  /// RA is in hours (0-24), Dec in degrees (-90 to +90).
  /// Handles RA wraparound at the 0h/24h boundary.
  static bool _pointInPolygon(
    double ra,
    double dec,
    List<BoundaryVertex> polygon,
  ) {
    if (polygon.length < 3) return false;

    // Convert RA to degrees for the algorithm (0-360)
    final testRa = ra * 15.0;
    final testDec = dec;

    var inside = false;
    var j = polygon.length - 1;

    for (var i = 0; i < polygon.length; i++) {
      final iRa = polygon[i].ra * 15.0;
      final iDec = polygon[i].dec;
      final jRa = polygon[j].ra * 15.0;
      final jDec = polygon[j].dec;

      // Handle RA wraparound: if edge spans more than 180 degrees,
      // it wraps around the 0/360 boundary
      var effectiveIRa = iRa;
      var effectiveJRa = jRa;
      var effectiveTestRa = testRa;

      if ((effectiveIRa - effectiveJRa).abs() > 180) {
        // Wraparound case: shift coordinates so the edge doesn't cross 0/360
        if (effectiveIRa < 180) effectiveIRa += 360;
        if (effectiveJRa < 180) effectiveJRa += 360;
        if (effectiveTestRa < 180) effectiveTestRa += 360;
      }

      if (((iDec > testDec) != (jDec > testDec)) &&
          (effectiveTestRa <
              (effectiveJRa - effectiveIRa) * (testDec - iDec) / (jDec - iDec) +
                  effectiveIRa)) {
        inside = !inside;
      }
      j = i;
    }

    return inside;
  }

  // Simplified IAU constellation boundary polygons (J2000 epoch).
  // Vertices are (RA hours, Dec degrees). Polygons are closed (last vertex connects to first).
  // These are simplified versions with key vertices along the boundary.
  static final Map<String, List<BoundaryVertex>> _boundaries = {
    'And': [
      const BoundaryVertex(23.5583, 53.1681),
      const BoundaryVertex(23.6675, 46.5314),
      const BoundaryVertex(23.5000, 43.9581),
      const BoundaryVertex(23.5000, 36.7500),
      const BoundaryVertex(1.5667, 36.7500),
      const BoundaryVertex(1.6833, 36.2500),
      const BoundaryVertex(2.0583, 33.2500),
      const BoundaryVertex(2.3917, 33.2500),
      const BoundaryVertex(2.5750, 37.2500),
      const BoundaryVertex(1.3333, 48.0000),
      const BoundaryVertex(0.1417, 48.0000),
      const BoundaryVertex(0.0000, 48.0000),
      const BoundaryVertex(23.5583, 48.0000),
      const BoundaryVertex(23.5583, 53.1681),
    ],
    'Ant': [
      const BoundaryVertex(9.4500, -24.5000),
      const BoundaryVertex(11.0583, -24.5000),
      const BoundaryVertex(11.0583, -35.5833),
      const BoundaryVertex(9.4500, -35.5833),
      const BoundaryVertex(9.4500, -24.5000),
    ],
    'Aps': [
      const BoundaryVertex(13.8333, -67.5000),
      const BoundaryVertex(18.4583, -67.5000),
      const BoundaryVertex(18.4583, -75.0000),
      const BoundaryVertex(16.4167, -75.0000),
      const BoundaryVertex(13.8333, -75.0000),
      const BoundaryVertex(13.8333, -83.1200),
      const BoundaryVertex(14.1667, -83.1200),
      const BoundaryVertex(18.0000, -82.0000),
      const BoundaryVertex(18.4583, -75.0000),
      const BoundaryVertex(13.8333, -67.5000),
    ],
    'Aqr': [
      const BoundaryVertex(20.6417, 2.0000),
      const BoundaryVertex(20.8750, -2.0000),
      const BoundaryVertex(21.0417, -2.0000),
      const BoundaryVertex(22.8583, -2.0000),
      const BoundaryVertex(23.8333, -6.0000),
      const BoundaryVertex(23.8333, -24.8250),
      const BoundaryVertex(22.0000, -24.8250),
      const BoundaryVertex(20.6417, -24.8250),
      const BoundaryVertex(20.6417, 2.0000),
    ],
    'Aql': [
      const BoundaryVertex(18.5833, 18.0000),
      const BoundaryVertex(20.6417, 18.0000),
      const BoundaryVertex(20.6417, 2.0000),
      const BoundaryVertex(20.0000, -2.0000),
      const BoundaryVertex(18.5833, -12.0333),
      const BoundaryVertex(18.2417, -12.0333),
      const BoundaryVertex(18.5833, 0.0000),
      const BoundaryVertex(18.5833, 18.0000),
    ],
    'Ara': [
      const BoundaryVertex(16.5833, -45.5000),
      const BoundaryVertex(18.0417, -45.5000),
      const BoundaryVertex(18.0417, -56.5000),
      const BoundaryVertex(17.5000, -60.0000),
      const BoundaryVertex(16.5833, -60.0000),
      const BoundaryVertex(16.5833, -56.5000),
      const BoundaryVertex(16.5833, -45.5000),
    ],
    'Ari': [
      const BoundaryVertex(1.4667, 10.0000),
      const BoundaryVertex(3.5000, 10.0000),
      const BoundaryVertex(3.5000, 31.2222),
      const BoundaryVertex(1.4667, 31.2222),
      const BoundaryVertex(1.4667, 10.0000),
    ],
    'Aur': [
      const BoundaryVertex(4.9667, 56.1667),
      const BoundaryVertex(7.0333, 56.1667),
      const BoundaryVertex(7.0333, 44.5000),
      const BoundaryVertex(6.1083, 28.0000),
      const BoundaryVertex(4.9667, 28.0000),
      const BoundaryVertex(4.9667, 36.7500),
      const BoundaryVertex(4.9667, 56.1667),
    ],
    'Boo': [
      const BoundaryVertex(13.5000, 8.0000),
      const BoundaryVertex(15.7500, 8.0000),
      const BoundaryVertex(15.7500, 25.5000),
      const BoundaryVertex(15.4917, 40.0000),
      const BoundaryVertex(15.0750, 52.5000),
      const BoundaryVertex(13.5000, 52.5000),
      const BoundaryVertex(13.5000, 8.0000),
    ],
    'Cae': [
      const BoundaryVertex(4.5167, -27.0000),
      const BoundaryVertex(5.0583, -27.0000),
      const BoundaryVertex(5.0583, -49.0000),
      const BoundaryVertex(4.5167, -49.0000),
      const BoundaryVertex(4.5167, -27.0000),
    ],
    'Cam': [
      const BoundaryVertex(3.1583, 53.0000),
      const BoundaryVertex(7.0000, 53.0000),
      const BoundaryVertex(7.0000, 60.0000),
      const BoundaryVertex(8.4167, 60.0000),
      const BoundaryVertex(8.4167, 68.0000),
      const BoundaryVertex(5.0000, 77.0000),
      const BoundaryVertex(3.1583, 77.0000),
      const BoundaryVertex(3.1583, 53.0000),
    ],
    'Cnc': [
      const BoundaryVertex(7.8917, 7.0000),
      const BoundaryVertex(9.3583, 7.0000),
      const BoundaryVertex(9.3583, 33.1417),
      const BoundaryVertex(7.8917, 33.1417),
      const BoundaryVertex(7.8917, 7.0000),
    ],
    'CVn': [
      const BoundaryVertex(12.0583, 28.0000),
      const BoundaryVertex(14.0750, 28.0000),
      const BoundaryVertex(14.0750, 52.3611),
      const BoundaryVertex(12.0583, 52.3611),
      const BoundaryVertex(12.0583, 28.0000),
    ],
    'CMa': [
      const BoundaryVertex(6.0000, -11.0000),
      const BoundaryVertex(7.3667, -11.0000),
      const BoundaryVertex(7.3667, -33.2500),
      const BoundaryVertex(6.0000, -33.2500),
      const BoundaryVertex(6.0000, -11.0000),
    ],
    'CMi': [
      const BoundaryVertex(7.0583, 0.0000),
      const BoundaryVertex(8.1750, 0.0000),
      const BoundaryVertex(8.1750, 13.2222),
      const BoundaryVertex(7.0583, 13.2222),
      const BoundaryVertex(7.0583, 0.0000),
    ],
    'Cap': [
      const BoundaryVertex(20.0667, -8.0000),
      const BoundaryVertex(21.6667, -8.0000),
      const BoundaryVertex(21.6667, -28.0000),
      const BoundaryVertex(20.0667, -28.0000),
      const BoundaryVertex(20.0667, -8.0000),
    ],
    'Car': [
      const BoundaryVertex(6.0250, -51.0000),
      const BoundaryVertex(11.2500, -51.0000),
      const BoundaryVertex(11.2500, -64.0000),
      const BoundaryVertex(9.0333, -75.0000),
      const BoundaryVertex(6.0250, -75.0000),
      const BoundaryVertex(6.0250, -51.0000),
    ],
    'Cas': [
      const BoundaryVertex(22.5667, 46.0000),
      const BoundaryVertex(3.4167, 46.0000),
      const BoundaryVertex(3.4167, 52.0000),
      const BoundaryVertex(3.1583, 59.0000),
      const BoundaryVertex(0.0000, 59.0000),
      const BoundaryVertex(23.5833, 59.0000),
      const BoundaryVertex(22.8667, 68.0000),
      const BoundaryVertex(0.3333, 68.0000),
      const BoundaryVertex(0.0000, 59.0000),
      const BoundaryVertex(22.5667, 46.0000),
    ],
    'Cen': [
      const BoundaryVertex(11.0500, -35.0000),
      const BoundaryVertex(15.1667, -35.0000),
      const BoundaryVertex(15.1667, -55.0000),
      const BoundaryVertex(14.9167, -64.0000),
      const BoundaryVertex(11.8333, -64.0000),
      const BoundaryVertex(11.0500, -55.0000),
      const BoundaryVertex(11.0500, -35.0000),
    ],
    'Cep': [
      const BoundaryVertex(20.1667, 61.0000),
      const BoundaryVertex(8.0000, 61.0000),
      const BoundaryVertex(8.0000, 68.0000),
      const BoundaryVertex(6.1000, 75.5000),
      const BoundaryVertex(0.0000, 80.0000),
      const BoundaryVertex(20.1667, 80.0000),
      const BoundaryVertex(23.5833, 75.0000),
      const BoundaryVertex(22.8667, 68.0000),
      const BoundaryVertex(20.1667, 61.0000),
    ],
    'Cet': [
      const BoundaryVertex(23.8333, -6.0000),
      const BoundaryVertex(1.4667, -6.0000),
      const BoundaryVertex(1.4667, 10.0000),
      const BoundaryVertex(3.3667, 10.0000),
      const BoundaryVertex(3.3667, -0.5000),
      const BoundaryVertex(2.7333, -0.5000),
      const BoundaryVertex(2.1000, -24.8333),
      const BoundaryVertex(23.8333, -24.8333),
      const BoundaryVertex(23.8333, -6.0000),
    ],
    'Cha': [
      const BoundaryVertex(7.6667, -75.0000),
      const BoundaryVertex(13.8333, -75.0000),
      const BoundaryVertex(13.8333, -83.1200),
      const BoundaryVertex(7.6667, -83.1200),
      const BoundaryVertex(7.6667, -75.0000),
    ],
    'Cir': [
      const BoundaryVertex(13.5000, -55.0000),
      const BoundaryVertex(15.5833, -55.0000),
      const BoundaryVertex(15.5833, -67.5000),
      const BoundaryVertex(13.5000, -67.5000),
      const BoundaryVertex(13.5000, -55.0000),
    ],
    'Col': [
      const BoundaryVertex(5.0583, -27.0000),
      const BoundaryVertex(6.5833, -27.0000),
      const BoundaryVertex(6.5833, -43.0000),
      const BoundaryVertex(5.0583, -43.0000),
      const BoundaryVertex(5.0583, -27.0000),
    ],
    'Com': [
      const BoundaryVertex(11.8667, 14.0000),
      const BoundaryVertex(13.5000, 14.0000),
      const BoundaryVertex(13.5000, 28.0000),
      const BoundaryVertex(11.8667, 33.3056),
      const BoundaryVertex(11.8667, 14.0000),
    ],
    'CrA': [
      const BoundaryVertex(17.5000, -37.0000),
      const BoundaryVertex(19.1833, -37.0000),
      const BoundaryVertex(19.1833, -45.5000),
      const BoundaryVertex(17.5000, -45.5000),
      const BoundaryVertex(17.5000, -37.0000),
    ],
    'CrB': [
      const BoundaryVertex(15.2333, 26.0000),
      const BoundaryVertex(16.3667, 26.0000),
      const BoundaryVertex(16.3667, 39.7167),
      const BoundaryVertex(15.2333, 39.7167),
      const BoundaryVertex(15.2333, 26.0000),
    ],
    'Crv': [
      const BoundaryVertex(11.8333, -11.0000),
      const BoundaryVertex(12.5833, -11.0000),
      const BoundaryVertex(12.5833, -24.5000),
      const BoundaryVertex(11.8333, -24.5000),
      const BoundaryVertex(11.8333, -11.0000),
    ],
    'Crt': [
      const BoundaryVertex(10.7500, -6.6667),
      const BoundaryVertex(11.8333, -6.6667),
      const BoundaryVertex(11.8333, -24.5000),
      const BoundaryVertex(10.7500, -24.5000),
      const BoundaryVertex(10.7500, -6.6667),
    ],
    'Cru': [
      const BoundaryVertex(11.8333, -55.6833),
      const BoundaryVertex(12.7917, -55.6833),
      const BoundaryVertex(12.7917, -64.0000),
      const BoundaryVertex(11.8333, -64.0000),
      const BoundaryVertex(11.8333, -55.6833),
    ],
    'Cyg': [
      const BoundaryVertex(19.1083, 28.0000),
      const BoundaryVertex(21.7333, 28.0000),
      const BoundaryVertex(21.7333, 44.0000),
      const BoundaryVertex(21.1000, 47.0000),
      const BoundaryVertex(21.1000, 55.0000),
      const BoundaryVertex(19.4000, 61.0000),
      const BoundaryVertex(19.1083, 55.0000),
      const BoundaryVertex(19.1083, 28.0000),
    ],
    'Del': [
      const BoundaryVertex(20.1417, 2.0000),
      const BoundaryVertex(21.0833, 2.0000),
      const BoundaryVertex(21.0833, 21.0000),
      const BoundaryVertex(20.1417, 21.0000),
      const BoundaryVertex(20.1417, 2.0000),
    ],
    'Dor': [
      const BoundaryVertex(3.8667, -49.0000),
      const BoundaryVertex(6.5833, -49.0000),
      const BoundaryVertex(6.5833, -69.0000),
      const BoundaryVertex(4.4500, -69.0000),
      const BoundaryVertex(3.8667, -57.0000),
      const BoundaryVertex(3.8667, -49.0000),
    ],
    'Dra': [
      const BoundaryVertex(9.0333, 54.0000),
      const BoundaryVertex(14.0000, 54.0000),
      const BoundaryVertex(15.0750, 54.0000),
      const BoundaryVertex(15.6667, 60.0000),
      const BoundaryVertex(17.5000, 55.0000),
      const BoundaryVertex(18.4583, 50.0000),
      const BoundaryVertex(20.1667, 61.0000),
      const BoundaryVertex(20.1667, 73.5000),
      const BoundaryVertex(15.6667, 80.0000),
      const BoundaryVertex(9.0333, 73.5000),
      const BoundaryVertex(9.0333, 54.0000),
    ],
    'Equ': [
      const BoundaryVertex(20.8750, 2.0000),
      const BoundaryVertex(21.4583, 2.0000),
      const BoundaryVertex(21.4583, 13.0000),
      const BoundaryVertex(20.8750, 13.0000),
      const BoundaryVertex(20.8750, 2.0000),
    ],
    'Eri': [
      const BoundaryVertex(1.3917, -57.5000),
      const BoundaryVertex(5.1333, -11.0000),
      const BoundaryVertex(3.7500, -11.0000),
      const BoundaryVertex(3.3667, -0.5000),
      const BoundaryVertex(2.1000, -24.8333),
      const BoundaryVertex(1.3917, -39.5833),
      const BoundaryVertex(1.3917, -57.5000),
    ],
    'For': [
      const BoundaryVertex(1.7667, -24.0000),
      const BoundaryVertex(3.8667, -24.0000),
      const BoundaryVertex(3.8667, -39.5833),
      const BoundaryVertex(1.7667, -39.5833),
      const BoundaryVertex(1.7667, -24.0000),
    ],
    'Gem': [
      const BoundaryVertex(6.0000, 10.0000),
      const BoundaryVertex(8.1250, 10.0000),
      const BoundaryVertex(8.1250, 33.5000),
      const BoundaryVertex(6.0000, 35.0000),
      const BoundaryVertex(6.0000, 10.0000),
    ],
    'Gru': [
      const BoundaryVertex(21.3333, -37.0000),
      const BoundaryVertex(23.4500, -37.0000),
      const BoundaryVertex(23.4500, -57.0000),
      const BoundaryVertex(21.3333, -57.0000),
      const BoundaryVertex(21.3333, -37.0000),
    ],
    'Her': [
      const BoundaryVertex(15.8167, 4.0000),
      const BoundaryVertex(18.5833, 4.0000),
      const BoundaryVertex(18.5833, 28.5000),
      const BoundaryVertex(18.0000, 30.0000),
      const BoundaryVertex(17.5000, 37.0000),
      const BoundaryVertex(17.5000, 51.0000),
      const BoundaryVertex(15.8167, 51.0000),
      const BoundaryVertex(15.8167, 4.0000),
    ],
    'Hor': [
      const BoundaryVertex(2.3667, -40.0000),
      const BoundaryVertex(4.3333, -40.0000),
      const BoundaryVertex(4.3333, -67.0000),
      const BoundaryVertex(2.3667, -67.0000),
      const BoundaryVertex(2.3667, -40.0000),
    ],
    'Hya': [
      const BoundaryVertex(8.1083, -7.0000),
      const BoundaryVertex(14.5250, -7.0000),
      const BoundaryVertex(14.5250, -35.0000),
      const BoundaryVertex(8.1083, -35.0000),
      const BoundaryVertex(8.1083, -7.0000),
    ],
    'Hyi': [
      const BoundaryVertex(23.3333, -58.0000),
      const BoundaryVertex(4.3667, -58.0000),
      const BoundaryVertex(4.3667, -82.0000),
      const BoundaryVertex(0.0000, -82.0000),
      const BoundaryVertex(23.3333, -75.0000),
      const BoundaryVertex(23.3333, -58.0000),
    ],
    'Ind': [
      const BoundaryVertex(20.2833, -45.0000),
      const BoundaryVertex(21.3333, -45.0000),
      const BoundaryVertex(23.4500, -45.0000),
      const BoundaryVertex(23.4500, -57.0000),
      const BoundaryVertex(21.3333, -57.0000),
      const BoundaryVertex(20.2833, -57.0000),
      const BoundaryVertex(20.2833, -75.0000),
      const BoundaryVertex(20.2833, -45.0000),
    ],
    'Lac': [
      const BoundaryVertex(22.0000, 35.0000),
      const BoundaryVertex(22.8667, 35.0000),
      const BoundaryVertex(22.8667, 56.0000),
      const BoundaryVertex(22.0000, 56.0000),
      const BoundaryVertex(22.0000, 35.0000),
    ],
    'Leo': [
      const BoundaryVertex(9.3583, 7.0000),
      const BoundaryVertex(11.8667, 7.0000),
      const BoundaryVertex(11.8667, 33.3056),
      const BoundaryVertex(9.3583, 33.3056),
      const BoundaryVertex(9.3583, 7.0000),
    ],
    'LMi': [
      const BoundaryVertex(9.3583, 33.3056),
      const BoundaryVertex(11.0667, 33.3056),
      const BoundaryVertex(11.0667, 42.0000),
      const BoundaryVertex(9.3583, 42.0000),
      const BoundaryVertex(9.3583, 33.3056),
    ],
    'Lep': [
      const BoundaryVertex(4.9250, -11.0000),
      const BoundaryVertex(6.2083, -11.0000),
      const BoundaryVertex(6.2083, -27.2833),
      const BoundaryVertex(4.9250, -27.2833),
      const BoundaryVertex(4.9250, -11.0000),
    ],
    'Lib': [
      const BoundaryVertex(14.3583, -0.5000),
      const BoundaryVertex(16.0250, -0.5000),
      const BoundaryVertex(16.0250, -30.0000),
      const BoundaryVertex(14.3583, -30.0000),
      const BoundaryVertex(14.3583, -0.5000),
    ],
    'Lup': [
      const BoundaryVertex(14.1667, -33.0000),
      const BoundaryVertex(16.5833, -33.0000),
      const BoundaryVertex(16.5833, -55.0000),
      const BoundaryVertex(14.1667, -55.0000),
      const BoundaryVertex(14.1667, -33.0000),
    ],
    'Lyn': [
      const BoundaryVertex(6.3083, 42.0000),
      const BoundaryVertex(9.3583, 42.0000),
      const BoundaryVertex(9.3583, 59.0000),
      const BoundaryVertex(6.3083, 59.0000),
      const BoundaryVertex(6.3083, 42.0000),
    ],
    'Lyr': [
      const BoundaryVertex(18.3083, 26.0000),
      const BoundaryVertex(19.4000, 26.0000),
      const BoundaryVertex(19.4000, 47.7139),
      const BoundaryVertex(18.3083, 47.7139),
      const BoundaryVertex(18.3083, 26.0000),
    ],
    'Men': [
      const BoundaryVertex(3.5000, -70.0000),
      const BoundaryVertex(7.6667, -70.0000),
      const BoundaryVertex(7.6667, -85.2611),
      const BoundaryVertex(3.5000, -85.2611),
      const BoundaryVertex(3.5000, -70.0000),
    ],
    'Mic': [
      const BoundaryVertex(20.4583, -27.0000),
      const BoundaryVertex(21.4667, -27.0000),
      const BoundaryVertex(21.4667, -45.0000),
      const BoundaryVertex(20.4583, -45.0000),
      const BoundaryVertex(20.4583, -27.0000),
    ],
    'Mon': [
      const BoundaryVertex(5.8333, -11.0000),
      const BoundaryVertex(8.0833, -11.0000),
      const BoundaryVertex(8.0833, 12.0000),
      const BoundaryVertex(5.8333, 12.0000),
      const BoundaryVertex(5.8333, -11.0000),
    ],
    'Mus': [
      const BoundaryVertex(11.3000, -64.0000),
      const BoundaryVertex(13.8333, -64.0000),
      const BoundaryVertex(13.8333, -75.0000),
      const BoundaryVertex(11.3000, -75.0000),
      const BoundaryVertex(11.3000, -64.0000),
    ],
    'Nor': [
      const BoundaryVertex(15.7333, -42.0000),
      const BoundaryVertex(16.5833, -42.0000),
      const BoundaryVertex(16.5833, -55.0000),
      const BoundaryVertex(15.7333, -55.0000),
      const BoundaryVertex(15.7333, -42.0000),
    ],
    'Oct': [
      const BoundaryVertex(0.0000, -82.0000),
      const BoundaryVertex(24.0000, -82.0000),
      const BoundaryVertex(24.0000, -90.0000),
      const BoundaryVertex(0.0000, -90.0000),
      const BoundaryVertex(0.0000, -82.0000),
    ],
    'Oph': [
      const BoundaryVertex(16.0250, -8.0000),
      const BoundaryVertex(18.0333, -8.0000),
      const BoundaryVertex(18.0333, 2.5000),
      const BoundaryVertex(17.8333, 4.0000),
      const BoundaryVertex(17.5000, 10.0000),
      const BoundaryVertex(17.5000, 14.0000),
      const BoundaryVertex(16.5333, 14.0000),
      const BoundaryVertex(16.0250, -8.0000),
    ],
    'Ori': [
      const BoundaryVertex(4.5000, -11.0000),
      const BoundaryVertex(6.4000, -11.0000),
      const BoundaryVertex(6.4000, 22.8750),
      const BoundaryVertex(4.5000, 22.8750),
      const BoundaryVertex(4.5000, -11.0000),
    ],
    'Pav': [
      const BoundaryVertex(18.1667, -57.0000),
      const BoundaryVertex(21.4667, -57.0000),
      const BoundaryVertex(21.4667, -75.0000),
      const BoundaryVertex(18.1667, -75.0000),
      const BoundaryVertex(18.1667, -57.0000),
    ],
    'Peg': [
      const BoundaryVertex(21.1250, 2.0000),
      const BoundaryVertex(0.1417, 2.0000),
      const BoundaryVertex(0.1417, 36.7500),
      const BoundaryVertex(23.5000, 36.7500),
      const BoundaryVertex(23.5000, 28.0000),
      const BoundaryVertex(21.7333, 28.0000),
      const BoundaryVertex(21.1250, 2.0000),
    ],
    'Per': [
      const BoundaryVertex(1.6583, 24.0000),
      const BoundaryVertex(4.5000, 24.0000),
      const BoundaryVertex(4.5000, 35.0000),
      const BoundaryVertex(4.5000, 59.0000),
      const BoundaryVertex(1.6583, 59.0000),
      const BoundaryVertex(1.6583, 24.0000),
    ],
    'Phe': [
      const BoundaryVertex(23.4500, -40.0000),
      const BoundaryVertex(2.1667, -40.0000),
      const BoundaryVertex(2.1667, -57.0000),
      const BoundaryVertex(23.4500, -57.0000),
      const BoundaryVertex(23.4500, -40.0000),
    ],
    'Pic': [
      const BoundaryVertex(4.5333, -43.0000),
      const BoundaryVertex(6.8500, -43.0000),
      const BoundaryVertex(6.8500, -64.0000),
      const BoundaryVertex(4.5333, -64.0000),
      const BoundaryVertex(4.5333, -43.0000),
    ],
    'Psc': [
      const BoundaryVertex(22.8583, -2.0000),
      const BoundaryVertex(2.0583, -2.0000),
      const BoundaryVertex(2.0583, 33.2500),
      const BoundaryVertex(0.1417, 33.2500),
      const BoundaryVertex(0.1417, 2.0000),
      const BoundaryVertex(23.8333, 2.0000),
      const BoundaryVertex(22.8583, -2.0000),
    ],
    'PsA': [
      const BoundaryVertex(21.4500, -25.0000),
      const BoundaryVertex(23.0583, -25.0000),
      const BoundaryVertex(23.0583, -37.0000),
      const BoundaryVertex(21.4500, -37.0000),
      const BoundaryVertex(21.4500, -25.0000),
    ],
    'Pup': [
      const BoundaryVertex(6.0250, -37.0000),
      const BoundaryVertex(8.4583, -37.0000),
      const BoundaryVertex(8.4583, -51.0000),
      const BoundaryVertex(6.0250, -51.0000),
      const BoundaryVertex(6.0250, -37.0000),
    ],
    'Pyx': [
      const BoundaryVertex(8.4583, -17.0000),
      const BoundaryVertex(9.4500, -17.0000),
      const BoundaryVertex(9.4500, -37.0000),
      const BoundaryVertex(8.4583, -37.0000),
      const BoundaryVertex(8.4583, -17.0000),
    ],
    'Ret': [
      const BoundaryVertex(3.3333, -53.0000),
      const BoundaryVertex(4.6000, -53.0000),
      const BoundaryVertex(4.6000, -67.0000),
      const BoundaryVertex(3.3333, -67.0000),
      const BoundaryVertex(3.3333, -53.0000),
    ],
    'Sge': [
      const BoundaryVertex(19.0417, 16.0000),
      const BoundaryVertex(20.1417, 16.0000),
      const BoundaryVertex(20.1417, 21.0000),
      const BoundaryVertex(19.0417, 21.0000),
      const BoundaryVertex(19.0417, 16.0000),
    ],
    'Sgr': [
      const BoundaryVertex(17.7500, -12.0333),
      const BoundaryVertex(20.4583, -12.0333),
      const BoundaryVertex(20.4583, -27.0000),
      const BoundaryVertex(20.0667, -27.0000),
      const BoundaryVertex(20.0667, -37.0000),
      const BoundaryVertex(18.7500, -45.5000),
      const BoundaryVertex(17.7500, -45.5000),
      const BoundaryVertex(17.7500, -12.0333),
    ],
    'Sco': [
      const BoundaryVertex(15.7500, -8.0000),
      const BoundaryVertex(17.8333, -8.0000),
      const BoundaryVertex(17.8333, -30.0000),
      const BoundaryVertex(17.5000, -37.0000),
      const BoundaryVertex(16.5833, -45.5000),
      const BoundaryVertex(15.7500, -45.5000),
      const BoundaryVertex(15.7500, -8.0000),
    ],
    'Scl': [
      const BoundaryVertex(23.0583, -25.0000),
      const BoundaryVertex(1.6583, -25.0000),
      const BoundaryVertex(1.6583, -39.5833),
      const BoundaryVertex(23.0583, -39.5833),
      const BoundaryVertex(23.0583, -25.0000),
    ],
    'Sct': [
      const BoundaryVertex(18.2417, -4.0000),
      const BoundaryVertex(18.9917, -4.0000),
      const BoundaryVertex(18.9917, -16.0000),
      const BoundaryVertex(18.2417, -16.0000),
      const BoundaryVertex(18.2417, -4.0000),
    ],
    'Ser': [
      // Serpens Caput
      const BoundaryVertex(15.0000, 0.0000),
      const BoundaryVertex(16.0833, 0.0000),
      const BoundaryVertex(16.0833, 25.5000),
      const BoundaryVertex(15.0000, 25.5000),
      const BoundaryVertex(15.0000, 0.0000),
    ],
    'Sex': [
      const BoundaryVertex(9.8750, -11.0000),
      const BoundaryVertex(10.5167, -11.0000),
      const BoundaryVertex(10.5167, 6.4333),
      const BoundaryVertex(9.8750, 6.4333),
      const BoundaryVertex(9.8750, -11.0000),
    ],
    'Tau': [
      const BoundaryVertex(3.3667, 0.0000),
      const BoundaryVertex(5.9833, 0.0000),
      const BoundaryVertex(5.9833, 31.1000),
      const BoundaryVertex(3.3667, 31.1000),
      const BoundaryVertex(3.3667, 0.0000),
    ],
    'Tel': [
      const BoundaryVertex(18.1667, -45.5000),
      const BoundaryVertex(20.2833, -45.5000),
      const BoundaryVertex(20.2833, -57.0000),
      const BoundaryVertex(18.1667, -57.0000),
      const BoundaryVertex(18.1667, -45.5000),
    ],
    'Tri': [
      const BoundaryVertex(1.5583, 25.5000),
      const BoundaryVertex(2.5417, 25.5000),
      const BoundaryVertex(2.5417, 37.3472),
      const BoundaryVertex(1.5583, 37.3472),
      const BoundaryVertex(1.5583, 25.5000),
    ],
    'TrA': [
      const BoundaryVertex(14.9167, -60.0000),
      const BoundaryVertex(17.0000, -60.0000),
      const BoundaryVertex(17.0000, -70.0000),
      const BoundaryVertex(14.9167, -70.0000),
      const BoundaryVertex(14.9167, -60.0000),
    ],
    'Tuc': [
      const BoundaryVertex(22.1667, -57.0000),
      const BoundaryVertex(1.3250, -57.0000),
      const BoundaryVertex(1.3250, -75.0000),
      const BoundaryVertex(23.3333, -75.0000),
      const BoundaryVertex(22.1667, -67.0000),
      const BoundaryVertex(22.1667, -57.0000),
    ],
    'UMa': [
      const BoundaryVertex(8.0833, 28.5000),
      const BoundaryVertex(14.5000, 28.5000),
      const BoundaryVertex(14.5000, 47.0000),
      const BoundaryVertex(14.0333, 54.0000),
      const BoundaryVertex(9.0333, 73.0000),
      const BoundaryVertex(8.0833, 73.0000),
      const BoundaryVertex(8.0833, 28.5000),
    ],
    'UMi': [
      const BoundaryVertex(0.0000, 66.0000),
      const BoundaryVertex(24.0000, 66.0000),
      const BoundaryVertex(24.0000, 90.0000),
      const BoundaryVertex(0.0000, 90.0000),
      const BoundaryVertex(0.0000, 66.0000),
    ],
    'Vel': [
      const BoundaryVertex(8.0583, -37.0000),
      const BoundaryVertex(11.0583, -37.0000),
      const BoundaryVertex(11.0583, -57.0000),
      const BoundaryVertex(8.0583, -57.0000),
      const BoundaryVertex(8.0583, -37.0000),
    ],
    'Vir': [
      const BoundaryVertex(11.8333, 0.0000),
      const BoundaryVertex(15.0000, 0.0000),
      const BoundaryVertex(15.0000, 14.0000),
      const BoundaryVertex(14.0333, 14.0000),
      const BoundaryVertex(12.0583, 14.0000),
      const BoundaryVertex(11.8333, 0.0000),
    ],
    'Vol': [
      const BoundaryVertex(6.5833, -64.0000),
      const BoundaryVertex(9.0333, -64.0000),
      const BoundaryVertex(9.0333, -75.0000),
      const BoundaryVertex(6.5833, -75.0000),
      const BoundaryVertex(6.5833, -64.0000),
    ],
    'Vul': [
      const BoundaryVertex(19.2167, 19.1667),
      const BoundaryVertex(21.4500, 19.1667),
      const BoundaryVertex(21.4500, 29.5000),
      const BoundaryVertex(19.2167, 29.5000),
      const BoundaryVertex(19.2167, 19.1667),
    ],
  };
}
