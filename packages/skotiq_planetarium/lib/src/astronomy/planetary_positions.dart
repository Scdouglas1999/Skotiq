// ignore_for_file: unused_field

import 'dart:math' as math;

import 'astronomy_calculations.dart';

/// VSOP87 planetary position calculations
/// Implements truncated VSOP87D theory for computing heliocentric ecliptic coordinates
/// of the major planets (Mercury through Neptune) with sufficient accuracy for
/// visual display and planning purposes (~1 arcminute accuracy).
class PlanetaryPositions {
  PlanetaryPositions._();

  static const double _deg2rad = math.pi / 180;
  static const double _rad2deg = 180 / math.pi;
  static const double _j2000 = 2451545.0;
  static const double _au2km = 149597870.7;

  // Obliquity of ecliptic at J2000
  static const double _obliquityJ2000 = 23.439291111;

  /// Convert DateTime to Julian Date.
  ///
  /// Kept as a name on this class because the VSOP87 code and its callers read
  /// as one unit; the arithmetic is [AstronomyCalculations.julianDate].
  static double julianDate(DateTime dt) => AstronomyCalculations.julianDate(dt);

  /// Convert ecliptic to equatorial coordinates
  static (double ra, double dec) eclipticToEquatorial({
    required double lonDeg,
    required double latDeg,
    required double obliquityDeg,
  }) {
    final lon = lonDeg * _deg2rad;
    final lat = latDeg * _deg2rad;
    final eps = obliquityDeg * _deg2rad;

    final sinDec =
        math.sin(lat) * math.cos(eps) +
        math.cos(lat) * math.sin(eps) * math.sin(lon);
    final dec = math.asin(sinDec.clamp(-1.0, 1.0));

    final y = math.sin(lon) * math.cos(eps) - math.tan(lat) * math.sin(eps);
    final x = math.cos(lon);
    var ra = math.atan2(y, x) * _rad2deg;
    ra = ra % 360;
    if (ra < 0) ra += 360;

    return (ra, dec * _rad2deg);
  }

  /// Planet enumeration
  static const List<String> planetNames = [
    'Mercury',
    'Venus',
    'Mars',
    'Jupiter',
    'Saturn',
    'Uranus',
    'Neptune',
  ];

  /// Planet colors for rendering
  static const List<int> planetColors = [
    0xFFB0B0B0, // Mercury - gray
    0xFFFFE4B5, // Venus - pale yellow
    0xFFCD5C5C, // Mars - red-brown
    0xFFF4A460, // Jupiter - tan/orange
    0xFFDAA520, // Saturn - golden
    0xFF87CEEB, // Uranus - light blue
    0xFF4169E1, // Neptune - royal blue
  ];

  /// Get all planet positions for a given date
  /// Returns list of (name, ra, dec, magnitude, colorValue)
  static List<PlanetData> getAllPlanetPositions(DateTime dt) {
    final planets = <PlanetData>[];

    for (var i = 0; i < planetNames.length; i++) {
      final pos = getPlanetPosition(i, dt);
      if (pos != null) {
        planets.add(
          PlanetData(
            name: planetNames[i],
            ra: pos.$1,
            dec: pos.$2,
            magnitude: pos.$3,
            color: planetColors[i],
          ),
        );
      }
    }

    return planets;
  }

  /// Get position of a specific planet
  /// planetIndex: 0=Mercury, 1=Venus, 2=Mars, 3=Jupiter, 4=Saturn, 5=Uranus, 6=Neptune
  ///
  /// Returns (ra HOURS, dec degrees, magnitude) referred to the **J2000**
  /// equator and equinox — the same frame the star and DSO catalogues use, and
  /// therefore the frame every consumer of this method works in (the chart, the
  /// finder-chart export, tap identification, search results and the slew
  /// targets built from them).
  ///
  /// VSOP87D is a theory of DATE, so the series below produce an ecliptic
  /// position for the equinox of [dt]; the final step precesses that back to
  /// J2000. Skipping it drew the planets ~22 arcmin from the star background in
  /// 2026 — Jupiter two thirds of a Moon diameter off M44 — because the two
  /// families were being projected in different frames onto one chart.
  static (double ra, double dec, double magnitude)? getPlanetPosition(
    int planetIndex,
    DateTime dt,
  ) {
    final jd = julianDate(dt);
    final t = (jd - _j2000) / 365250; // Julian millennia from J2000

    // Get heliocentric ecliptic coordinates of planet
    final (planetLon, planetLat, planetR) = _heliocentricEcliptic(
      planetIndex,
      t,
    );
    if (planetLon == null || planetLat == null) return null;

    // Get heliocentric ecliptic coordinates of Earth
    final (earthLon, earthLat, earthR) = _earthHeliocentricEcliptic(t);

    // Convert to geocentric ecliptic
    final (geoLon, geoLat, distance) = _helioToGeocentric(
      planetLon: planetLon,
      planetLat: planetLat,
      planetR: planetR,
      earthLon: earthLon,
      earthLat: earthLat,
      earthR: earthR,
    );

    // Calculate obliquity for current date
    final tCenturies = (jd - _j2000) / 36525;
    final obliquity = _obliquityJ2000 - 0.0130042 * tCenturies;

    // Convert to equatorial coordinates of DATE (the obliquity above is of
    // date, matching the VSOP87D ecliptic these longitudes are referred to)...
    final (raOfDate, decOfDate) = eclipticToEquatorial(
      lonDeg: geoLon,
      latDeg: geoLat,
      obliquityDeg: obliquity,
    );

    // ...then back to J2000, the chart's one frame. See the doc comment.
    final (ra, dec) = AstronomyCalculations.precessFromDateToJ2000(
      raDeg: raOfDate,
      decDeg: decOfDate,
      dt: dt,
    );

    // Calculate visual magnitude
    final magnitude = _calculateMagnitude(
      planetIndex,
      planetR,
      distance,
      geoLon,
      earthLon,
    );

    return (ra / 15, dec, magnitude); // Convert RA to hours
  }

  /// Calculate heliocentric ecliptic coordinates for Earth
  static (double lon, double lat, double r) _earthHeliocentricEcliptic(
    double t,
  ) {
    // Earth's heliocentric coordinates using simplified VSOP87
    double l = 0, b = 0, r = 0;

    // Longitude terms (L0 + L1*t + L2*t^2 + ...)
    // L0 terms (main ones)
    l += 175347046.0 * math.cos(0.0);
    l += 3341656.0 * math.cos(4.6692568 + 6283.0758500 * t);
    l += 34894.0 * math.cos(4.6261 + 12566.1517 * t);
    l += 3497.0 * math.cos(2.7441 + 5753.3849 * t);
    l += 3418.0 * math.cos(2.8289 + 3.5231 * t);
    l += 3136.0 * math.cos(3.6277 + 77713.7715 * t);
    l += 2676.0 * math.cos(4.4181 + 7860.4194 * t);
    l += 2343.0 * math.cos(6.1352 + 3930.2097 * t);
    l += 1324.0 * math.cos(0.7425 + 11506.7698 * t);
    l += 1273.0 * math.cos(2.0371 + 529.6910 * t);
    l += 1199.0 * math.cos(1.1096 + 1577.3435 * t);

    // L1 terms
    l += t * 628331966747.0 * math.cos(0.0);
    l += t * 206059.0 * math.cos(2.678235 + 6283.075850 * t);
    l += t * 4303.0 * math.cos(2.6351 + 12566.1517 * t);

    // L2 terms
    l += t * t * 52919.0 * math.cos(0.0);
    l += t * t * 8720.0 * math.cos(1.0721 + 6283.0758 * t);

    l = l / 1e8; // Convert to radians
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // Latitude (B terms) - Earth's latitude is essentially 0
    b += 280.0 * math.cos(3.199 + 84334.662 * t);
    b += 102.0 * math.cos(5.422 + 5507.553 * t);
    b += 80.0 * math.cos(3.88 + 5223.69 * t);
    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // Radius vector (R terms)
    r += 100013989.0 * math.cos(0.0);
    r += 1670700.0 * math.cos(3.0984635 + 6283.0758500 * t);
    r += 13956.0 * math.cos(3.0552 + 12566.1517 * t);
    r += 3084.0 * math.cos(5.1985 + 77713.7715 * t);
    r += 1628.0 * math.cos(1.1739 + 5753.3849 * t);
    r += 1576.0 * math.cos(2.8469 + 7860.4194 * t);
    r += 925.0 * math.cos(5.453 + 11506.770 * t);
    r += 542.0 * math.cos(4.564 + 3930.210 * t);

    // R1 terms
    r += t * 103019.0 * math.cos(1.107490 + 6283.075850 * t);
    r += t * 1721.0 * math.cos(1.0644 + 12566.1517 * t);

    r = r / 1e8; // AU

    return (lonDeg, latDeg, r);
  }

  /// Calculate heliocentric ecliptic coordinates for a planet
  static (double? lon, double? lat, double r) _heliocentricEcliptic(
    int planetIndex,
    double t,
  ) {
    switch (planetIndex) {
      case 0:
        return _mercuryPosition(t);
      case 1:
        return _venusPosition(t);
      case 2:
        return _marsPosition(t);
      case 3:
        return _jupiterPosition(t);
      case 4:
        return _saturnPosition(t);
      case 5:
        return _uranusPosition(t);
      case 6:
        return _neptunePosition(t);
      default:
        return (null, null, 0);
    }
  }

  /// Mercury heliocentric position
  static (double lon, double lat, double r) _mercuryPosition(double t) {
    double l = 0, b = 0, r = 0;

    // L0 terms
    l += 440250710.0 * math.cos(0.0);
    l += 40989415.0 * math.cos(1.48302034 + 26087.90314157 * t);
    l += 5046294.0 * math.cos(4.4778549 + 52175.8062831 * t);
    l += 855347.0 * math.cos(1.165203 + 78263.709425 * t);
    l += 165590.0 * math.cos(4.119692 + 104351.612566 * t);
    l += 34562.0 * math.cos(0.77931 + 130439.51571 * t);
    l += 7583.0 * math.cos(3.7135 + 156527.4188 * t);

    // L1 terms
    l += t * 2608814706223.0 * math.cos(0.0);
    l += t * 1126008.0 * math.cos(6.2170397 + 26087.9031416 * t);
    l += t * 303471.0 * math.cos(3.055655 + 52175.806283 * t);
    l += t * 80538.0 * math.cos(6.10455 + 78263.70942 * t);

    // L2 terms
    l += t * t * 53050.0 * math.cos(0.0);
    l += t * t * 16904.0 * math.cos(4.69072 + 26087.90314 * t);
    l += t * t * 7397.0 * math.cos(1.3474 + 52175.8063 * t);

    l = l / 1e8;
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // B terms
    b += 11737529.0 * math.cos(1.98357499 + 26087.90314157 * t);
    b += 2388077.0 * math.cos(5.0373896 + 52175.8062831 * t);
    b += 1222840.0 * math.cos(3.1415927);
    b += 543252.0 * math.cos(1.796444 + 78263.709425 * t);
    b += 129779.0 * math.cos(4.832325 + 104351.612566 * t);
    b += 31867.0 * math.cos(1.58088 + 130439.51571 * t);

    b += t * 429151.0 * math.cos(3.501698 + 26087.903142 * t);
    b += t * 146234.0 * math.cos(3.141593);
    b += t * 22675.0 * math.cos(0.01515 + 52175.80628 * t);

    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // R terms
    r += 39528272.0 * math.cos(0.0);
    r += 7834132.0 * math.cos(6.1923372 + 26087.9031416 * t);
    r += 795526.0 * math.cos(2.959897 + 52175.806283 * t);
    r += 121282.0 * math.cos(6.010642 + 78263.709425 * t);
    r += 21922.0 * math.cos(2.77820 + 104351.61257 * t);
    r += 4354.0 * math.cos(5.8289 + 130439.5157 * t);

    r += t * 217348.0 * math.cos(4.656172 + 26087.903142 * t);
    r += t * 44142.0 * math.cos(1.42386 + 52175.80628 * t);
    r += t * 10094.0 * math.cos(4.47466 + 78263.70942 * t);

    r = r / 1e8;

    return (lonDeg, latDeg, r);
  }

  /// Venus heliocentric position
  static (double lon, double lat, double r) _venusPosition(double t) {
    double l = 0, b = 0, r = 0;

    // L0 terms
    l += 317614667.0 * math.cos(0.0);
    l += 1353968.0 * math.cos(5.5931332 + 10213.2855462 * t);
    l += 89892.0 * math.cos(5.30650 + 20426.57109 * t);
    l += 5477.0 * math.cos(4.4163 + 7860.4194 * t);
    l += 3456.0 * math.cos(2.6996 + 11790.6291 * t);
    l += 2372.0 * math.cos(2.9938 + 3930.2097 * t);
    l += 1664.0 * math.cos(4.2502 + 1577.3435 * t);
    l += 1438.0 * math.cos(4.1575 + 9683.5946 * t);

    // L1 terms
    l += t * 1021352943053.0 * math.cos(0.0);
    l += t * 95708.0 * math.cos(2.46424 + 10213.28555 * t);
    l += t * 14445.0 * math.cos(0.51625 + 20426.57109 * t);

    // L2 terms
    l += t * t * 54127.0 * math.cos(0.0);
    l += t * t * 3891.0 * math.cos(0.3451 + 10213.2855 * t);
    l += t * t * 1338.0 * math.cos(2.0201 + 20426.5711 * t);

    l = l / 1e8;
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // B terms
    b += 5923638.0 * math.cos(0.2670278 + 10213.2855462 * t);
    b += 40108.0 * math.cos(1.14737 + 20426.57109 * t);
    b += 32815.0 * math.cos(3.14159);
    b += 1011.0 * math.cos(1.0895 + 30639.8566 * t);

    b += t * 513348.0 * math.cos(1.803643 + 10213.285546 * t);
    b += t * 4380.0 * math.cos(3.3862 + 20426.5711 * t);
    b += t * 199.0 * math.cos(0.0);

    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // R terms
    r += 72334821.0 * math.cos(0.0);
    r += 489824.0 * math.cos(4.021518 + 10213.285546 * t);
    r += 1658.0 * math.cos(4.9021 + 20426.5711 * t);
    r += 1632.0 * math.cos(2.8455 + 7860.4194 * t);
    r += 1378.0 * math.cos(1.1285 + 11790.6291 * t);
    r += 498.0 * math.cos(2.587 + 9683.595 * t);

    r += t * 34551.0 * math.cos(0.89199 + 10213.28555 * t);
    r += t * 234.0 * math.cos(1.772 + 20426.571 * t);

    r = r / 1e8;

    return (lonDeg, latDeg, r);
  }

  /// Mars heliocentric position
  static (double lon, double lat, double r) _marsPosition(double t) {
    double l = 0, b = 0, r = 0;

    // L0 terms
    l += 620347712.0 * math.cos(0.0);
    l += 18656368.0 * math.cos(5.05037100 + 3340.61242670 * t);
    l += 1108217.0 * math.cos(5.4009984 + 6681.2248534 * t);
    l += 91798.0 * math.cos(5.75479 + 10021.83728 * t);
    l += 27745.0 * math.cos(5.97050 + 3.52312 * t);
    l += 12316.0 * math.cos(0.84956 + 2810.92146 * t);
    l += 10610.0 * math.cos(2.93959 + 2281.23050 * t);
    l += 8927.0 * math.cos(4.1570 + 0.0173 * t);
    l += 8716.0 * math.cos(6.1101 + 13362.4497 * t);

    // L1 terms
    l += t * 334085627474.0 * math.cos(0.0);
    l += t * 1458227.0 * math.cos(3.6042605 + 3340.6124267 * t);
    l += t * 164901.0 * math.cos(3.926313 + 6681.224853 * t);
    l += t * 19963.0 * math.cos(4.26594 + 10021.83728 * t);
    l += t * 3452.0 * math.cos(4.7321 + 3.5231 * t);

    // L2 terms
    l += t * t * 58016.0 * math.cos(2.04979 + 3340.61243 * t);
    l += t * t * 54188.0 * math.cos(0.0);
    l += t * t * 13908.0 * math.cos(2.45742 + 6681.22485 * t);
    l += t * t * 2465.0 * math.cos(2.8000 + 10021.8373 * t);

    l = l / 1e8;
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // B terms
    b += 3197135.0 * math.cos(3.7683204 + 3340.6124267 * t);
    b += 298033.0 * math.cos(4.106170 + 6681.224853 * t);
    b += 289105.0 * math.cos(0.0);
    b += 31366.0 * math.cos(4.44651 + 10021.83728 * t);
    b += 3484.0 * math.cos(4.7881 + 13362.4497 * t);

    b += t * 350069.0 * math.cos(5.368478 + 3340.612427 * t);
    b += t * 14116.0 * math.cos(3.14159);
    b += t * 9671.0 * math.cos(5.4788 + 6681.2249 * t);

    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // R terms
    r += 153033488.0 * math.cos(0.0);
    r += 14184953.0 * math.cos(3.47971284 + 3340.61242670 * t);
    r += 660776.0 * math.cos(3.817834 + 6681.224853 * t);
    r += 46179.0 * math.cos(4.15595 + 10021.83728 * t);
    r += 8110.0 * math.cos(5.5596 + 2810.9215 * t);
    r += 7485.0 * math.cos(1.7724 + 5621.8429 * t);
    r += 5523.0 * math.cos(1.3644 + 2281.2305 * t);

    r += t * 1107433.0 * math.cos(2.0325052 + 3340.6124267 * t);
    r += t * 103176.0 * math.cos(2.370718 + 6681.224853 * t);
    r += t * 12877.0 * math.cos(0.0);
    r += t * 10816.0 * math.cos(2.70888 + 10021.83728 * t);

    r = r / 1e8;

    return (lonDeg, latDeg, r);
  }

  /// Jupiter heliocentric position
  static (double lon, double lat, double r) _jupiterPosition(double t) {
    double l = 0, b = 0, r = 0;

    // L0 terms
    l += 59954691.0 * math.cos(0.0);
    l += 9695899.0 * math.cos(5.0619179 + 529.6909651 * t);
    l += 573610.0 * math.cos(1.444062 + 7.113547 * t);
    l += 306389.0 * math.cos(5.417347 + 1059.381930 * t);
    l += 97178.0 * math.cos(4.14265 + 632.78374 * t);
    l += 72903.0 * math.cos(3.64043 + 522.57742 * t);
    l += 64264.0 * math.cos(3.41145 + 103.09277 * t);
    l += 39806.0 * math.cos(2.29377 + 419.48464 * t);
    l += 38858.0 * math.cos(1.27232 + 316.39187 * t);

    // L1 terms
    l += t * 52993480757.0 * math.cos(0.0);
    l += t * 489741.0 * math.cos(4.220667 + 529.690965 * t);
    l += t * 228919.0 * math.cos(6.026475 + 7.113547 * t);
    l += t * 27655.0 * math.cos(4.57266 + 1059.38193 * t);
    l += t * 20721.0 * math.cos(5.45939 + 522.57742 * t);
    l += t * 12106.0 * math.cos(0.16986 + 536.80451 * t);

    // L2 terms
    l += t * t * 47234.0 * math.cos(4.32148 + 7.11355 * t);
    l += t * t * 38966.0 * math.cos(0.0);
    l += t * t * 30629.0 * math.cos(2.93021 + 529.69097 * t);
    l += t * t * 3189.0 * math.cos(1.0550 + 522.5774 * t);

    l = l / 1e8;
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // B terms
    b += 2268616.0 * math.cos(3.5585261 + 529.6909651 * t);
    b += 110090.0 * math.cos(0.0);
    b += 109972.0 * math.cos(3.908093 + 1059.381930 * t);
    b += 8101.0 * math.cos(3.6051 + 522.5774 * t);
    b += 6438.0 * math.cos(0.3063 + 536.8045 * t);

    b += t * 177352.0 * math.cos(5.701665 + 529.690965 * t);
    b += t * 3230.0 * math.cos(5.7794 + 1059.3819 * t);
    b += t * 3081.0 * math.cos(5.4746 + 522.5774 * t);

    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // R terms
    r += 520887429.0 * math.cos(0.0);
    r += 25209327.0 * math.cos(3.49108640 + 529.69096509 * t);
    r += 610600.0 * math.cos(3.841154 + 1059.381930 * t);
    r += 282029.0 * math.cos(2.574199 + 632.783739 * t);
    r += 187647.0 * math.cos(2.075904 + 522.577418 * t);
    r += 86793.0 * math.cos(0.71001 + 419.48464 * t);
    r += 72063.0 * math.cos(0.21466 + 536.80451 * t);
    r += 65517.0 * math.cos(5.97996 + 316.39187 * t);

    r += t * 1271802.0 * math.cos(2.6493751 + 529.6909651 * t);
    r += t * 61662.0 * math.cos(3.00076 + 1059.38193 * t);
    r += t * 53444.0 * math.cos(3.89718 + 522.57742 * t);
    r += t * 41390.0 * math.cos(0.0);

    r = r / 1e8;

    return (lonDeg, latDeg, r);
  }

  /// Saturn heliocentric position
  static (double lon, double lat, double r) _saturnPosition(double t) {
    double l = 0, b = 0, r = 0;

    // L0 terms
    l += 87401354.0 * math.cos(0.0);
    l += 11107660.0 * math.cos(3.96205090 + 213.29909544 * t);
    l += 1414151.0 * math.cos(4.5858152 + 7.1135470 * t);
    l += 398379.0 * math.cos(0.521120 + 206.185548 * t);
    l += 350769.0 * math.cos(3.303299 + 426.598191 * t);
    l += 206816.0 * math.cos(0.246584 + 103.092774 * t);
    l += 79271.0 * math.cos(3.84007 + 220.41264 * t);
    l += 23990.0 * math.cos(4.66977 + 110.20632 * t);
    l += 16574.0 * math.cos(0.43719 + 419.48464 * t);

    // L1 terms
    l += t * 21354295596.0 * math.cos(0.0);
    l += t * 1296855.0 * math.cos(1.8282054 + 213.2990954 * t);
    l += t * 564348.0 * math.cos(2.885001 + 7.113547 * t);
    l += t * 107679.0 * math.cos(2.277699 + 206.185548 * t);
    l += t * 98323.0 * math.cos(1.08070 + 426.59819 * t);
    l += t * 40255.0 * math.cos(2.04128 + 220.41264 * t);

    // L2 terms
    l += t * t * 116441.0 * math.cos(1.179879 + 7.113547 * t);
    l += t * t * 91921.0 * math.cos(0.07425 + 213.29910 * t);
    l += t * t * 90592.0 * math.cos(0.0);
    l += t * t * 15277.0 * math.cos(4.06492 + 206.18555 * t);
    l += t * t * 10631.0 * math.cos(0.25778 + 220.41264 * t);

    l = l / 1e8;
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // B terms
    b += 4330678.0 * math.cos(3.6028443 + 213.2990954 * t);
    b += 240348.0 * math.cos(2.852385 + 426.598191 * t);
    b += 84746.0 * math.cos(0.0);
    b += 34116.0 * math.cos(0.57297 + 206.18555 * t);
    b += 30863.0 * math.cos(3.48442 + 220.41264 * t);

    b += t * 397555.0 * math.cos(5.332900 + 213.299095 * t);
    b += t * 49479.0 * math.cos(3.14159);
    b += t * 18572.0 * math.cos(6.09919 + 426.59819 * t);

    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // R terms
    r += 955758136.0 * math.cos(0.0);
    r += 52921382.0 * math.cos(2.39226220 + 213.29909544 * t);
    r += 1873680.0 * math.cos(5.2354961 + 206.1855484 * t);
    r += 1464664.0 * math.cos(1.6476305 + 426.5981909 * t);
    r += 821891.0 * math.cos(5.935200 + 316.391870 * t);
    r += 547507.0 * math.cos(5.015326 + 103.092774 * t);
    r += 371684.0 * math.cos(2.271148 + 220.412642 * t);

    r += t * 6182981.0 * math.cos(0.2584352 + 213.2990954 * t);
    r += t * 506578.0 * math.cos(0.711147 + 206.185548 * t);
    r += t * 341394.0 * math.cos(5.796358 + 426.598191 * t);
    r += t * 188491.0 * math.cos(0.47216 + 220.41264 * t);
    r += t * 186262.0 * math.cos(3.141593);

    r = r / 1e8;

    return (lonDeg, latDeg, r);
  }

  /// Uranus heliocentric position
  static (double lon, double lat, double r) _uranusPosition(double t) {
    double l = 0, b = 0, r = 0;

    // L0 terms
    l += 548129294.0 * math.cos(0.0);
    l += 9260408.0 * math.cos(0.8910642 + 74.7815986 * t);
    l += 1504248.0 * math.cos(3.6271926 + 1.4844727 * t);
    l += 365982.0 * math.cos(1.899622 + 73.297126 * t);
    l += 272328.0 * math.cos(3.358237 + 149.563197 * t);
    l += 70328.0 * math.cos(5.39254 + 63.73590 * t);
    l += 68893.0 * math.cos(6.09292 + 76.26607 * t);
    l += 61999.0 * math.cos(2.26952 + 2.96895 * t);

    // L1 terms
    l += t * 7502543122.0 * math.cos(0.0);
    l += t * 154458.0 * math.cos(5.242017 + 74.781599 * t);
    l += t * 24456.0 * math.cos(1.71256 + 1.48447 * t);
    l += t * 9258.0 * math.cos(0.4284 + 11.0457 * t);

    // L2 terms
    l += t * t * 53033.0 * math.cos(0.0);
    l += t * t * 2358.0 * math.cos(2.2601 + 74.7816 * t);
    l += t * t * 769.0 * math.cos(4.526 + 11.046 * t);

    l = l / 1e8;
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // B terms
    b += 1346278.0 * math.cos(2.6187781 + 74.7815986 * t);
    b += 62341.0 * math.cos(5.08111 + 149.56320 * t);
    b += 61601.0 * math.cos(3.14159);
    b += 9964.0 * math.cos(1.6160 + 76.2661 * t);
    b += 9926.0 * math.cos(0.5763 + 73.2971 * t);

    b += t * 206366.0 * math.cos(4.123943 + 74.781599 * t);
    b += t * 4825.0 * math.cos(3.1416);
    b += t * 4439.0 * math.cos(0.5205 + 149.5632 * t);

    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // R terms
    r += 1921264848.0 * math.cos(0.0);
    r += 88784984.0 * math.cos(5.60377527 + 74.78159857 * t);
    r += 3440836.0 * math.cos(0.3283610 + 73.2971259 * t);
    r += 2055653.0 * math.cos(1.7829517 + 149.5631971 * t);
    r += 649322.0 * math.cos(4.522473 + 76.266071 * t);
    r += 602248.0 * math.cos(3.860038 + 63.735898 * t);
    r += 496404.0 * math.cos(1.401399 + 454.909367 * t);

    r += t * 1479896.0 * math.cos(3.6719405 + 74.7815986 * t);
    r += t * 71212.0 * math.cos(6.22601 + 63.73590 * t);
    r += t * 68627.0 * math.cos(6.13411 + 149.56320 * t);
    r += t * 46620.0 * math.cos(3.14159);

    r = r / 1e8;

    return (lonDeg, latDeg, r);
  }

  /// Neptune heliocentric position
  static (double lon, double lat, double r) _neptunePosition(double t) {
    double l = 0, b = 0, r = 0;

    // L0 terms
    l += 531188633.0 * math.cos(0.0);
    l += 1798476.0 * math.cos(2.9010127 + 38.1330356 * t);
    l += 1019728.0 * math.cos(0.4858092 + 1.4844727 * t);
    l += 124532.0 * math.cos(4.830081 + 36.648563 * t);
    l += 42064.0 * math.cos(5.41055 + 2.96895 * t);
    l += 37715.0 * math.cos(6.09222 + 35.16409 * t);
    l += 33785.0 * math.cos(1.24489 + 76.26607 * t);

    // L1 terms
    l += t * 3837687717.0 * math.cos(0.0);
    l += t * 16604.0 * math.cos(4.86319 + 1.48447 * t);
    l += t * 15807.0 * math.cos(2.27923 + 38.13304 * t);

    // L2 terms
    l += t * t * 53893.0 * math.cos(0.0);
    l += t * t * 296.0 * math.cos(1.855 + 38.133 * t);

    l = l / 1e8;
    var lonDeg = l * _rad2deg;
    lonDeg = lonDeg % 360;
    if (lonDeg < 0) lonDeg += 360;

    // B terms
    b += 3088623.0 * math.cos(1.4410437 + 38.1330356 * t);
    b += 27780.0 * math.cos(5.91272 + 76.26607 * t);
    b += 27624.0 * math.cos(0.0);
    b += 15448.0 * math.cos(3.50877 + 39.61751 * t);
    b += 15355.0 * math.cos(2.52124 + 36.64856 * t);

    b += t * 227279.0 * math.cos(3.807931 + 38.133036 * t);
    b += t * 1803.0 * math.cos(1.9758 + 76.2661 * t);
    b += t * 1433.0 * math.cos(3.1416);

    b = b / 1e8;
    final latDeg = b * _rad2deg;

    // R terms
    r += 3007013206.0 * math.cos(0.0);
    r += 27062259.0 * math.cos(1.32999459 + 38.13303564 * t);
    r += 1691764.0 * math.cos(3.2518614 + 36.6485629 * t);
    r += 807831.0 * math.cos(5.185928 + 1.484473 * t);
    r += 537761.0 * math.cos(4.521139 + 35.164090 * t);
    r += 495726.0 * math.cos(1.571057 + 491.557929 * t);
    r += 274572.0 * math.cos(1.845523 + 175.166060 * t);

    r += t * 236339.0 * math.cos(0.704980 + 38.133036 * t);
    r += t * 13220.0 * math.cos(3.32015 + 1.48447 * t);
    r += t * 8622.0 * math.cos(6.2163 + 35.1641 * t);

    r = r / 1e8;

    return (lonDeg, latDeg, r);
  }

  /// Convert heliocentric to geocentric coordinates
  static (double lon, double lat, double distance) _helioToGeocentric({
    required double planetLon,
    required double planetLat,
    required double planetR,
    required double earthLon,
    required double earthLat,
    required double earthR,
  }) {
    // Convert to radians
    final pLon = planetLon * _deg2rad;
    final pLat = planetLat * _deg2rad;
    final eLon = earthLon * _deg2rad;
    final eLat = earthLat * _deg2rad;

    // Convert to rectangular heliocentric coordinates
    final xp = planetR * math.cos(pLat) * math.cos(pLon);
    final yp = planetR * math.cos(pLat) * math.sin(pLon);
    final zp = planetR * math.sin(pLat);

    final xe = earthR * math.cos(eLat) * math.cos(eLon);
    final ye = earthR * math.cos(eLat) * math.sin(eLon);
    final ze = earthR * math.sin(eLat);

    // Geocentric rectangular coordinates
    final x = xp - xe;
    final y = yp - ye;
    final z = zp - ze;

    // Convert to geocentric ecliptic coordinates
    final distance = math.sqrt(x * x + y * y + z * z);
    var geoLon = math.atan2(y, x) * _rad2deg;
    geoLon = geoLon % 360;
    if (geoLon < 0) geoLon += 360;
    final geoLat = math.asin(z / distance) * _rad2deg;

    return (geoLon, geoLat, distance);
  }

  /// Calculate visual magnitude of a planet
  static double _calculateMagnitude(
    int planetIndex,
    double sunDist,
    double earthDist,
    double geoLon,
    double earthLon,
  ) {
    // Base magnitude at 1 AU from Sun and Earth, at 0° phase angle
    const baseMagnitudes = [
      -0.42, // Mercury
      -4.40, // Venus
      -1.52, // Mars
      -9.40, // Jupiter
      -8.88, // Saturn
      -7.19, // Uranus
      -6.87, // Neptune
    ];

    // Phase angle approximation
    var phaseAngle = (geoLon - earthLon).abs();
    if (phaseAngle > 180) phaseAngle = 360 - phaseAngle;
    final phaseRad = phaseAngle * _deg2rad;

    // Illuminated fraction (Lambert's law approximation)
    final illum = (1 + math.cos(phaseRad)) / 2;

    // Distance correction: m = m0 + 5*log10(r*d)
    final distCorrection = 5 * math.log(sunDist * earthDist) / math.ln10;

    // Phase correction (simplified)
    var phaseCorrection = 0.0;
    if (planetIndex <= 1) {
      // Mercury and Venus (inner planets) have strong phase effects
      phaseCorrection = -2.5 * math.log(illum.clamp(0.01, 1.0)) / math.ln10;
    } else if (planetIndex == 2) {
      // Mars has moderate phase effects
      phaseCorrection = 0.016 * phaseAngle;
    }
    // Outer planets have negligible phase effects

    return baseMagnitudes[planetIndex] + distCorrection + phaseCorrection;
  }
}

/// Planet data for rendering
class PlanetData {
  final String name;
  final double ra; // Right ascension in hours
  final double dec; // Declination in degrees
  final double magnitude;
  final int color; // ARGB color value

  const PlanetData({
    required this.name,
    required this.ra,
    required this.dec,
    required this.magnitude,
    required this.color,
  });
}
