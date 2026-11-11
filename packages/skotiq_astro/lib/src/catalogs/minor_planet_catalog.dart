import 'dart:math' as math;
import '../astronomy/astronomy_calculations.dart';
import '../coordinate_system.dart';

/// Type of minor body
enum MinorBodyType {
  /// Asteroid (minor planet)
  asteroid,

  /// Comet
  comet,
}

/// Keplerian orbital elements for a minor body.
///
/// All angles in degrees, distances in AU, epoch as Julian Date.
class MinorBodyElements {
  /// Name (e.g., "1 Ceres", "C/2023 A3 (Tsuchinshan-ATLAS)")
  final String name;

  /// Common designation (e.g., "Ceres", "Vesta")
  final String? commonName;

  /// Body type
  final MinorBodyType type;

  /// Epoch of the elements as Julian Date
  final double epoch;

  /// Semi-major axis in AU (for elliptical orbits)
  final double semiMajorAxis;

  /// Eccentricity
  final double eccentricity;

  /// Inclination in degrees
  final double inclination;

  /// Longitude of ascending node in degrees
  final double longitudeOfNode;

  /// Argument of perihelion in degrees
  final double argumentOfPerihelion;

  /// Mean anomaly at epoch in degrees
  final double meanAnomaly;

  /// Absolute magnitude (H)
  final double absoluteMag;

  /// Slope parameter (G)
  final double slopeParam;

  /// Orbital period in days (computed from semi-major axis for asteroids)
  double get periodDays => 365.25 * math.pow(semiMajorAxis, 1.5);

  /// Perihelion distance in AU
  double get perihelionDistance => semiMajorAxis * (1 - eccentricity);

  /// Aphelion distance in AU
  double get aphelionDistance => semiMajorAxis * (1 + eccentricity);

  const MinorBodyElements({
    required this.name,
    this.commonName,
    required this.type,
    required this.epoch,
    required this.semiMajorAxis,
    required this.eccentricity,
    required this.inclination,
    required this.longitudeOfNode,
    required this.argumentOfPerihelion,
    required this.meanAnomaly,
    this.absoluteMag = 10.0,
    this.slopeParam = 0.15,
  });
}

/// Current computed position of a minor body.
class MinorBodyData {
  final MinorBodyElements elements;

  /// RA in hours (0-24)
  double ra;

  /// Dec in degrees (-90 to +90)
  double dec;

  /// Distance from Earth in AU
  double distanceAU;

  /// Distance from Sun in AU
  double heliocentricDistanceAU;

  /// Estimated visual magnitude
  double visualMag;

  /// Solar elongation in degrees
  double elongation;

  /// Phase angle in degrees
  double phaseAngle;

  String get name => elements.commonName ?? elements.name;
  MinorBodyType get type => elements.type;
  bool get isComet => elements.type == MinorBodyType.comet;

  CelestialCoordinate get coordinates => CelestialCoordinate(ra: ra, dec: dec);

  MinorBodyData({
    required this.elements,
    this.ra = 0,
    this.dec = 0,
    this.distanceAU = 0,
    this.heliocentricDistanceAU = 0,
    this.visualMag = 99,
    this.elongation = 0,
    this.phaseAngle = 0,
  });
}

/// Keplerian orbit propagator for minor bodies (asteroids and comets).
///
/// Solves Kepler's equation to convert orbital elements → heliocentric
/// cartesian → geocentric equatorial RA/Dec.
class KeplerianPropagator {
  KeplerianPropagator._();

  static const double _deg2rad = math.pi / 180;
  static const double _rad2deg = 180 / math.pi;
  static const double _j2000 = 2451545.0;

  // Obliquity of ecliptic at J2000 in radians
  static const double _obliquityRad = 23.439291111 * _deg2rad;

  /// Compute the geocentric RA/Dec of a minor body at a given time.
  static MinorBodyData propagate(MinorBodyElements elements, DateTime time) {
    final jd = _julianDate(time.toUtc());
    final daysSinceEpoch = jd - elements.epoch;

    // Mean motion (degrees/day)
    final n = 360.0 / elements.periodDays;

    // Current mean anomaly
    var meanAnomaly = (elements.meanAnomaly + n * daysSinceEpoch) % 360.0;
    if (meanAnomaly < 0) meanAnomaly += 360.0;

    // Solve Kepler's equation: E - e*sin(E) = M
    final eccentricAnomaly = _solveKepler(
      meanAnomaly * _deg2rad,
      elements.eccentricity,
    );

    // True anomaly
    final e = elements.eccentricity;
    final sinE = math.sin(eccentricAnomaly);
    final cosE = math.cos(eccentricAnomaly);
    final trueAnomaly = math.atan2(math.sqrt(1 - e * e) * sinE, cosE - e);

    // Heliocentric distance
    final r = elements.semiMajorAxis * (1 - e * cosE);

    // Position in orbital plane
    final xOrb = r * math.cos(trueAnomaly);
    final yOrb = r * math.sin(trueAnomaly);

    // Convert to heliocentric ecliptic coordinates
    final omega = elements.argumentOfPerihelion * _deg2rad;
    final capitalOmega = elements.longitudeOfNode * _deg2rad;
    final i = elements.inclination * _deg2rad;

    final cosOmega = math.cos(omega);
    final sinOmega = math.sin(omega);
    final cosNode = math.cos(capitalOmega);
    final sinNode = math.sin(capitalOmega);
    final cosI = math.cos(i);
    final sinI = math.sin(i);

    // Heliocentric ecliptic cartesian
    final xEcl =
        xOrb * (cosOmega * cosNode - sinOmega * sinNode * cosI) -
        yOrb * (sinOmega * cosNode + cosOmega * sinNode * cosI);
    final yEcl =
        xOrb * (cosOmega * sinNode + sinOmega * cosNode * cosI) -
        yOrb * (sinOmega * sinNode - cosOmega * cosNode * cosI);
    final zEcl = xOrb * sinOmega * sinI + yOrb * cosOmega * sinI;

    // Compute Earth's heliocentric position (simplified)
    final (earthX, earthY, earthZ) = _earthPosition(jd);

    // Geocentric ecliptic
    final dxEcl = xEcl - earthX;
    final dyEcl = yEcl - earthY;
    final dzEcl = zEcl - earthZ;

    // Convert ecliptic to equatorial
    final cosEps = math.cos(_obliquityRad);
    final sinEps = math.sin(_obliquityRad);

    final xEq = dxEcl;
    final yEq = dyEcl * cosEps - dzEcl * sinEps;
    final zEq = dyEcl * sinEps + dzEcl * cosEps;

    // RA and Dec
    var ra = math.atan2(yEq, xEq) * _rad2deg;
    if (ra < 0) ra += 360.0;
    final raHours = ra / 15.0;

    final dist = math.sqrt(xEq * xEq + yEq * yEq + zEq * zEq);
    final dec = math.asin((zEq / dist).clamp(-1.0, 1.0)) * _rad2deg;

    // Solar elongation
    final sunX = -earthX;
    final sunY = -earthY;
    final sunZ = -earthZ;
    final sunDist = math.sqrt(sunX * sunX + sunY * sunY + sunZ * sunZ);
    final cosElong =
        (dxEcl * (-earthX) + dyEcl * (-earthY) + dzEcl * (-earthZ)) /
        (dist * sunDist);
    final elongation = math.acos(cosElong.clamp(-1.0, 1.0)) * _rad2deg;

    // Phase angle
    final cosPhase = (r * r + dist * dist - sunDist * sunDist) / (2 * r * dist);
    final phaseAngle = math.acos(cosPhase.clamp(-1.0, 1.0)) * _rad2deg;

    // Visual magnitude estimate
    double visualMag;
    if (elements.type == MinorBodyType.comet) {
      // Comet magnitude: m = H + 5*log10(delta) + 10*log10(r)
      visualMag = elements.absoluteMag + 5 * _log10(dist) + 10 * _log10(r);
    } else {
      // Asteroid HG system: m = H + 5*log10(r*delta) - 2.5*log10(phaseFunc)
      final phaseFunc = _asteroidPhaseFunctionHG(
        phaseAngle * _deg2rad,
        elements.slopeParam,
      );
      visualMag =
          elements.absoluteMag + 5 * _log10(r * dist) - 2.5 * _log10(phaseFunc);
    }

    return MinorBodyData(
      elements: elements,
      ra: raHours,
      dec: dec,
      distanceAU: dist,
      heliocentricDistanceAU: r,
      visualMag: visualMag,
      elongation: elongation,
      phaseAngle: phaseAngle,
    );
  }

  /// Solve Kepler's equation E - e*sin(E) = M using Newton-Raphson iteration.
  static double _solveKepler(double M, double e) {
    // Initial guess
    var E = M + e * math.sin(M);

    // Newton-Raphson iteration (typically converges in 3-5 iterations)
    for (int iter = 0; iter < 30; iter++) {
      final dE = (E - e * math.sin(E) - M) / (1 - e * math.cos(E));
      E -= dE;
      if (dE.abs() < 1e-12) break;
    }
    return E;
  }

  /// Compute approximate Earth heliocentric ecliptic position.
  /// Uses a simplified model (sufficient for minor body positioning).
  static (double x, double y, double z) _earthPosition(double jd) {
    final T = (jd - _j2000) / 36525.0;

    // Mean longitude (degrees)
    final L = (100.46646 + 36000.76983 * T + 0.0003032 * T * T) % 360;
    // Mean anomaly (degrees)
    final M = (357.52911 + 35999.05029 * T - 0.0001537 * T * T) % 360;
    // Eccentricity
    final e = 0.016708634 - 0.000042037 * T;

    final mRad = M * _deg2rad;

    // Equation of center
    final C =
        (1.9146 - 0.004817 * T) * math.sin(mRad) +
        0.019993 * math.sin(2 * mRad) +
        0.000290 * math.sin(3 * mRad);

    // Sun's true longitude
    final trueLon = (L + C) * _deg2rad;

    // Sun-Earth distance
    final v = (M + C) * _deg2rad;
    final R = 1.000001018 * (1 - e * e) / (1 + e * math.cos(v));

    // Earth's heliocentric ecliptic position (opposite of Sun's)
    // Sun is at trueLon from Earth, so Earth is at trueLon + pi from Sun
    final earthLon = trueLon + math.pi;
    final x = R * math.cos(earthLon);
    final y = R * math.sin(earthLon);
    const z = 0.0; // Earth's ecliptic latitude is ~0

    return (x, y, z);
  }

  /// HG phase function for asteroids.
  static double _asteroidPhaseFunctionHG(double phaseRad, double G) {
    final phi1 = math.exp(-3.33 * math.pow(math.tan(phaseRad / 2), 0.63));
    final phi2 = math.exp(-1.87 * math.pow(math.tan(phaseRad / 2), 1.22));
    return (1 - G) * phi1 + G * phi2;
  }

  static double _log10(double x) => math.log(x) / math.ln10;

  /// The sole caller already hands this a UTC instant, so routing through
  /// [AstronomyCalculations.julianDate] (which normalizes with `toUtc()`)
  /// returns the identical double the private copy did.
  static double _julianDate(DateTime dt) =>
      AstronomyCalculations.julianDate(dt);

  /// Batch compute positions for multiple minor bodies.
  static List<MinorBodyData> computePositions({
    required List<MinorBodyElements> elements,
    required DateTime time,
  }) {
    return elements.map((e) => propagate(e, time)).toList();
  }
}

/// Catalog of bright minor planets and notable comets.
///
/// Orbital elements are from MPC (Minor Planet Center) osculating elements.
/// Epoch: 2024 Jan 1.0 TT (JD 2460310.5) for asteroids.
class MinorPlanetCatalog {
  MinorPlanetCatalog._();

  /// Epoch for embedded asteroid elements: 2024 Jan 1.0 TT
  static const double _defaultEpoch = 2460310.5;

  /// Brightest asteroids with their orbital elements.
  static const List<MinorBodyElements> asteroids = [
    MinorBodyElements(
      name: '1 Ceres',
      commonName: 'Ceres',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.7670,
      eccentricity: 0.0760,
      inclination: 10.594,
      longitudeOfNode: 80.394,
      argumentOfPerihelion: 73.597,
      meanAnomaly: 60.070,
      absoluteMag: 3.34,
      slopeParam: 0.12,
    ),
    MinorBodyElements(
      name: '2 Pallas',
      commonName: 'Pallas',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.7724,
      eccentricity: 0.2313,
      inclination: 34.832,
      longitudeOfNode: 173.027,
      argumentOfPerihelion: 309.921,
      meanAnomaly: 266.020,
      absoluteMag: 4.13,
      slopeParam: 0.11,
    ),
    MinorBodyElements(
      name: '3 Juno',
      commonName: 'Juno',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.6694,
      eccentricity: 0.2562,
      inclination: 12.981,
      longitudeOfNode: 169.852,
      argumentOfPerihelion: 248.066,
      meanAnomaly: 165.230,
      absoluteMag: 5.33,
      slopeParam: 0.32,
    ),
    MinorBodyElements(
      name: '4 Vesta',
      commonName: 'Vesta',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.3615,
      eccentricity: 0.0887,
      inclination: 7.141,
      longitudeOfNode: 103.809,
      argumentOfPerihelion: 150.729,
      meanAnomaly: 20.864,
      absoluteMag: 3.20,
      slopeParam: 0.32,
    ),
    MinorBodyElements(
      name: '5 Astraea',
      commonName: 'Astraea',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.5741,
      eccentricity: 0.1914,
      inclination: 5.369,
      longitudeOfNode: 141.579,
      argumentOfPerihelion: 358.839,
      meanAnomaly: 211.720,
      absoluteMag: 6.85,
      slopeParam: 0.15,
    ),
    MinorBodyElements(
      name: '6 Hebe',
      commonName: 'Hebe',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.4254,
      eccentricity: 0.2030,
      inclination: 14.767,
      longitudeOfNode: 138.754,
      argumentOfPerihelion: 239.619,
      meanAnomaly: 88.340,
      absoluteMag: 5.71,
      slopeParam: 0.24,
    ),
    MinorBodyElements(
      name: '7 Iris',
      commonName: 'Iris',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.3857,
      eccentricity: 0.2310,
      inclination: 5.529,
      longitudeOfNode: 259.566,
      argumentOfPerihelion: 145.442,
      meanAnomaly: 321.460,
      absoluteMag: 5.51,
      slopeParam: 0.15,
    ),
    MinorBodyElements(
      name: '8 Flora',
      commonName: 'Flora',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.2016,
      eccentricity: 0.1564,
      inclination: 5.887,
      longitudeOfNode: 110.917,
      argumentOfPerihelion: 285.448,
      meanAnomaly: 198.890,
      absoluteMag: 6.49,
      slopeParam: 0.28,
    ),
    MinorBodyElements(
      name: '9 Metis',
      commonName: 'Metis',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.3866,
      eccentricity: 0.1230,
      inclination: 5.576,
      longitudeOfNode: 68.921,
      argumentOfPerihelion: 5.492,
      meanAnomaly: 113.570,
      absoluteMag: 6.28,
      slopeParam: 0.17,
    ),
    MinorBodyElements(
      name: '10 Hygiea',
      commonName: 'Hygiea',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 3.1416,
      eccentricity: 0.1122,
      inclination: 3.831,
      longitudeOfNode: 283.201,
      argumentOfPerihelion: 312.164,
      meanAnomaly: 242.490,
      absoluteMag: 5.43,
      slopeParam: 0.15,
    ),
    MinorBodyElements(
      name: '15 Eunomia',
      commonName: 'Eunomia',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.6434,
      eccentricity: 0.1863,
      inclination: 11.737,
      longitudeOfNode: 292.894,
      argumentOfPerihelion: 97.907,
      meanAnomaly: 337.210,
      absoluteMag: 5.28,
      slopeParam: 0.23,
    ),
    MinorBodyElements(
      name: '16 Psyche',
      commonName: 'Psyche',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.9231,
      eccentricity: 0.1340,
      inclination: 3.095,
      longitudeOfNode: 150.301,
      argumentOfPerihelion: 228.172,
      meanAnomaly: 182.600,
      absoluteMag: 5.90,
      slopeParam: 0.20,
    ),
    MinorBodyElements(
      name: '18 Melpomene',
      commonName: 'Melpomene',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.2960,
      eccentricity: 0.2178,
      inclination: 10.131,
      longitudeOfNode: 150.438,
      argumentOfPerihelion: 228.065,
      meanAnomaly: 150.780,
      absoluteMag: 6.51,
      slopeParam: 0.22,
    ),
    MinorBodyElements(
      name: '19 Fortuna',
      commonName: 'Fortuna',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.4420,
      eccentricity: 0.1577,
      inclination: 1.573,
      longitudeOfNode: 211.243,
      argumentOfPerihelion: 182.092,
      meanAnomaly: 125.460,
      absoluteMag: 7.13,
      slopeParam: 0.10,
    ),
    MinorBodyElements(
      name: '20 Massalia',
      commonName: 'Massalia',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.4085,
      eccentricity: 0.1430,
      inclination: 0.707,
      longitudeOfNode: 206.299,
      argumentOfPerihelion: 256.553,
      meanAnomaly: 310.490,
      absoluteMag: 6.50,
      slopeParam: 0.25,
    ),
    MinorBodyElements(
      name: '29 Amphitrite',
      commonName: 'Amphitrite',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.5546,
      eccentricity: 0.0721,
      inclination: 6.082,
      longitudeOfNode: 356.365,
      argumentOfPerihelion: 63.366,
      meanAnomaly: 79.420,
      absoluteMag: 5.85,
      slopeParam: 0.20,
    ),
    MinorBodyElements(
      name: '44 Nysa',
      commonName: 'Nysa',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.4234,
      eccentricity: 0.1500,
      inclination: 3.706,
      longitudeOfNode: 131.517,
      argumentOfPerihelion: 343.104,
      meanAnomaly: 266.180,
      absoluteMag: 7.03,
      slopeParam: 0.46,
    ),
    MinorBodyElements(
      name: '433 Eros',
      commonName: 'Eros',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 1.4581,
      eccentricity: 0.2229,
      inclination: 10.829,
      longitudeOfNode: 304.319,
      argumentOfPerihelion: 178.820,
      meanAnomaly: 145.350,
      absoluteMag: 11.16,
      slopeParam: 0.46,
    ),
    MinorBodyElements(
      name: '532 Herculina',
      commonName: 'Herculina',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 2.7722,
      eccentricity: 0.1763,
      inclination: 16.292,
      longitudeOfNode: 107.573,
      argumentOfPerihelion: 76.226,
      meanAnomaly: 203.470,
      absoluteMag: 5.80,
      slopeParam: 0.15,
    ),
    MinorBodyElements(
      name: '704 Interamnia',
      commonName: 'Interamnia',
      type: MinorBodyType.asteroid,
      epoch: _defaultEpoch,
      semiMajorAxis: 3.0595,
      eccentricity: 0.1534,
      inclination: 17.296,
      longitudeOfNode: 280.288,
      argumentOfPerihelion: 95.934,
      meanAnomaly: 151.740,
      absoluteMag: 5.94,
      slopeParam: 0.07,
    ),
  ];

  /// Notable comets (periodically updated with current apparitions).
  /// Elements represent recent osculating elements.
  static const List<MinorBodyElements> comets = [
    MinorBodyElements(
      name: '1P/Halley',
      commonName: 'Halley',
      type: MinorBodyType.comet,
      epoch: 2446467.4,
      semiMajorAxis: 17.8341,
      eccentricity: 0.96714,
      inclination: 162.263,
      longitudeOfNode: 58.420,
      argumentOfPerihelion: 111.332,
      meanAnomaly: 0.0,
      absoluteMag: 5.5,
    ),
    MinorBodyElements(
      name: '2P/Encke',
      commonName: 'Encke',
      type: MinorBodyType.comet,
      epoch: 2460226.5,
      semiMajorAxis: 2.2151,
      eccentricity: 0.84833,
      inclination: 11.781,
      longitudeOfNode: 334.568,
      argumentOfPerihelion: 186.546,
      meanAnomaly: 255.100,
      absoluteMag: 11.0,
    ),
    MinorBodyElements(
      name: '67P/Churyumov-Gerasimenko',
      commonName: 'Churyumov-Gerasimenko',
      type: MinorBodyType.comet,
      epoch: 2457257.5,
      semiMajorAxis: 3.4630,
      eccentricity: 0.64102,
      inclination: 7.040,
      longitudeOfNode: 50.147,
      argumentOfPerihelion: 12.780,
      meanAnomaly: 0.0,
      absoluteMag: 9.0,
    ),
    MinorBodyElements(
      name: '46P/Wirtanen',
      commonName: 'Wirtanen',
      type: MinorBodyType.comet,
      epoch: 2458469.5,
      semiMajorAxis: 3.0924,
      eccentricity: 0.65884,
      inclination: 11.747,
      longitudeOfNode: 82.158,
      argumentOfPerihelion: 356.341,
      meanAnomaly: 0.0,
      absoluteMag: 6.5,
    ),
    MinorBodyElements(
      name: '29P/Schwassmann-Wachmann 1',
      commonName: 'Schwassmann-Wachmann 1',
      type: MinorBodyType.comet,
      epoch: 2460310.5,
      semiMajorAxis: 5.9837,
      eccentricity: 0.04390,
      inclination: 9.391,
      longitudeOfNode: 312.697,
      argumentOfPerihelion: 49.873,
      meanAnomaly: 318.790,
      absoluteMag: 5.0,
    ),
  ];

  /// All minor bodies (asteroids + comets).
  static List<MinorBodyElements> get all => [...asteroids, ...comets];
}
