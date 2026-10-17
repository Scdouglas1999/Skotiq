import 'dart:math' as math;
import '../astronomy/astronomy_calculations.dart';
import '../coordinate_system.dart';
part 'variable_star_catalog/star_data_part1.dart';
part 'variable_star_catalog/star_data_part2.dart';
part 'variable_star_catalog/star_data.dart';

/// Type of variable star
enum VariableStarType {
  /// Mira-type long period pulsating (e.g., Mira, Chi Cygni)
  mira,

  /// Cepheid pulsating (e.g., Delta Cephei, Eta Aquilae)
  cepheid,

  /// RR Lyrae pulsating (e.g., RR Lyrae)
  rrLyrae,

  /// Eclipsing binary Algol-type (e.g., Algol, Beta Lyrae)
  eclipsingAlgol,

  /// Eclipsing binary Beta Lyrae type
  eclipsingBetaLyr,

  /// Eclipsing binary W UMa type
  eclipsingWUma,

  /// Semi-regular pulsating (e.g., Betelgeuse, Antares)
  semiRegular,

  /// Irregular variable (e.g., Mu Cephei)
  irregular,

  /// Delta Scuti type
  deltaScuti,

  /// Gamma Cassiopeiae (eruptive Be star)
  gammaCas,

  /// R Coronae Borealis (eruptive, fades)
  rCrB,

  /// Nova or recurrent nova
  nova,

  /// Dwarf nova / cataclysmic
  dwarfNova,

  /// RS Canum Venaticorum (chromospherically active)
  rsCVn,

  /// BY Draconis (spotted rotating)
  byDra,

  /// Slowly pulsating B star
  spb,

  /// Other/unclassified
  other,
}

extension VariableStarTypeExtension on VariableStarType {
  String get displayName {
    switch (this) {
      case VariableStarType.mira:
        return 'Mira (Long Period)';
      case VariableStarType.cepheid:
        return 'Cepheid';
      case VariableStarType.rrLyrae:
        return 'RR Lyrae';
      case VariableStarType.eclipsingAlgol:
        return 'Eclipsing (Algol)';
      case VariableStarType.eclipsingBetaLyr:
        return 'Eclipsing (Beta Lyrae)';
      case VariableStarType.eclipsingWUma:
        return 'Eclipsing (W UMa)';
      case VariableStarType.semiRegular:
        return 'Semi-Regular';
      case VariableStarType.irregular:
        return 'Irregular';
      case VariableStarType.deltaScuti:
        return 'Delta Scuti';
      case VariableStarType.gammaCas:
        return 'Gamma Cas (Be star)';
      case VariableStarType.rCrB:
        return 'R CrB (Fading)';
      case VariableStarType.nova:
        return 'Nova';
      case VariableStarType.dwarfNova:
        return 'Dwarf Nova';
      case VariableStarType.rsCVn:
        return 'RS CVn';
      case VariableStarType.byDra:
        return 'BY Dra';
      case VariableStarType.spb:
        return 'Slowly Pulsating B';
      case VariableStarType.other:
        return 'Variable';
    }
  }

  String get abbreviation {
    switch (this) {
      case VariableStarType.mira:
        return 'M';
      case VariableStarType.cepheid:
        return 'CEP';
      case VariableStarType.rrLyrae:
        return 'RR';
      case VariableStarType.eclipsingAlgol:
        return 'EA';
      case VariableStarType.eclipsingBetaLyr:
        return 'EB';
      case VariableStarType.eclipsingWUma:
        return 'EW';
      case VariableStarType.semiRegular:
        return 'SR';
      case VariableStarType.irregular:
        return 'L';
      case VariableStarType.deltaScuti:
        return 'DSCT';
      case VariableStarType.gammaCas:
        return 'GCAS';
      case VariableStarType.rCrB:
        return 'RCB';
      case VariableStarType.nova:
        return 'N';
      case VariableStarType.dwarfNova:
        return 'UG';
      case VariableStarType.rsCVn:
        return 'RS';
      case VariableStarType.byDra:
        return 'BY';
      case VariableStarType.spb:
        return 'SPB';
      case VariableStarType.other:
        return 'VAR';
    }
  }
}

/// Data for a single variable star.
class VariableStarData {
  /// Common name (e.g., "Mira", "Algol", "Delta Cephei")
  final String name;

  /// Bayer/Flamsteed designation (e.g., "omi Cet", "bet Per")
  final String? designation;

  /// Constellation abbreviation
  final String constellation;

  /// RA in hours (J2000)
  final double ra;

  /// Dec in degrees (J2000)
  final double dec;

  /// Variable star type
  final VariableStarType type;

  /// Period in days (null if irregular or unknown)
  final double? periodDays;

  /// Maximum brightness magnitude (brightest)
  final double magMax;

  /// Minimum brightness magnitude (faintest)
  final double magMin;

  /// Spectral type
  final String? spectralType;

  CelestialCoordinate get coordinates => CelestialCoordinate(ra: ra, dec: dec);

  /// Magnitude range
  double get magRange => magMin - magMax;

  /// Estimate current visual magnitude based on a simple sinusoidal model.
  /// This is approximate — real light curves are asymmetric — but useful for display.
  double estimateMagnitude(DateTime time) {
    if (periodDays == null || periodDays! <= 0) {
      // No period: return midpoint
      return (magMax + magMin) / 2;
    }

    // Use Julian Date for phase calculation
    final jd = _julianDate(time);
    // Use J2000 epoch as reference for phase
    const j2000 = 2451545.0;
    final phase = ((jd - j2000) / periodDays!) % 1.0;

    // Different light curve shapes by type
    switch (type) {
      case VariableStarType.eclipsingAlgol:
        // Algol-type: mostly at max, brief dips
        // Eclipse around phase 0, roughly 10% of period
        const eclipseWidth = 0.1;
        if (phase < eclipseWidth || phase > (1.0 - eclipseWidth)) {
          final eclipsePhase = phase < 0.5 ? phase : (1.0 - phase);
          final depth = math.cos(eclipsePhase / eclipseWidth * math.pi);
          return magMax + (magMin - magMax) * (1.0 + depth) / 2;
        }
        return magMax;

      case VariableStarType.mira:
        // Mira-type: asymmetric — fast rise, slow decline
        // Rise takes ~35% of period, decline ~65%
        double lightPhase;
        if (phase < 0.35) {
          // Rising (minimum to maximum)
          lightPhase = phase / 0.35;
        } else {
          // Declining (maximum to minimum)
          lightPhase = 1.0 - (phase - 0.35) / 0.65;
        }
        return magMin - (magMin - magMax) * lightPhase;

      case VariableStarType.cepheid:
        // Cepheid: fast rise, slower decline (sawtooth-ish)
        double lightPhase;
        if (phase < 0.3) {
          lightPhase = phase / 0.3;
        } else {
          lightPhase = 1.0 - (phase - 0.3) / 0.7;
        }
        return magMin - (magMin - magMax) * lightPhase;

      default:
        // Sinusoidal approximation
        final sinPhase = math.sin(phase * 2 * math.pi);
        return (magMax + magMin) / 2 - (magMin - magMax) / 2 * sinPhase;
    }
  }

  /// Whole-second day fraction — this catalog's phase epochs have never
  /// carried the sub-second term, and [AstronomyCalculations.julianDate]
  /// reproduces that exactly when told to drop it.
  static double _julianDate(DateTime dt) =>
      AstronomyCalculations.julianDate(dt, includeMilliseconds: false);

  const VariableStarData({
    required this.name,
    this.designation,
    required this.constellation,
    required this.ra,
    required this.dec,
    required this.type,
    this.periodDays,
    required this.magMax,
    required this.magMin,
    this.spectralType,
  });
}

/// Catalog of prominent variable stars.
///
/// Contains a curated list of ~200 well-known variable stars covering all major types:
/// Mira long-period, Cepheids, eclipsing binaries, semi-regulars, RR Lyrae, and more.
/// Data sourced from the AAVSO Variable Star Index (VSX) and GCVS.
class VariableStarCatalog {
  VariableStarCatalog._();

  /// All variable stars in the catalog.
  static const List<VariableStarData> stars = variableStarCatalogStars;

  /// Get variable stars brighter than a given magnitude limit (at maximum).
  static List<VariableStarData> getBrighterThan(double magLimit) {
    return stars.where((s) => s.magMax <= magLimit).toList();
  }

  /// Get variable stars of a specific type.
  static List<VariableStarData> getByType(VariableStarType type) {
    return stars.where((s) => s.type == type).toList();
  }

  /// Get variable stars in a specific constellation.
  static List<VariableStarData> getByConstellation(String constellation) {
    return stars
        .where(
          (s) => s.constellation.toLowerCase() == constellation.toLowerCase(),
        )
        .toList();
  }

  /// Search variable stars by name.
  static List<VariableStarData> search(String query) {
    final lower = query.toLowerCase();
    return stars.where((s) {
      return s.name.toLowerCase().contains(lower) ||
          (s.designation?.toLowerCase().contains(lower) ?? false) ||
          s.constellation.toLowerCase().contains(lower);
    }).toList();
  }
}
