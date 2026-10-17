import 'coordinate_system.dart';

/// Base class for celestial objects
abstract class CelestialObject {
  String get id;
  String get name;
  CelestialCoordinate get coordinates;
  double? get magnitude;
}

/// Star data
class Star implements CelestialObject {
  @override
  final String id;
  @override
  final String name;
  @override
  final CelestialCoordinate coordinates;
  @override
  final double? magnitude;
  final String? spectralType;
  final String? constellation;
  final double? colorIndex;
  final List<String> catalogIds;

  const Star({
    required this.id,
    required this.name,
    required this.coordinates,
    this.magnitude,
    this.spectralType,
    this.constellation,
    this.colorIndex,
    this.catalogIds = const [],
  });

  /// Get the star color based on color index (B-V)
  /// Returns a hex color value
  int getStarColor() {
    if (colorIndex == null) {
      return 0xFFFFFFFF; // White for unknown
    }

    final ci = colorIndex!;

    // Color index to RGB conversion (approximate)
    // Blue stars (B-V < -0.3): Blue-white
    // White stars (B-V ~ 0): White
    // Yellow stars (B-V ~ 0.5-0.8): Yellow
    // Orange stars (B-V ~ 1.0-1.4): Orange
    // Red stars (B-V > 1.4): Red

    if (ci < -0.3) {
      return 0xFFAABBFF; // Blue-white
    } else if (ci < 0.0) {
      return 0xFFCCDDFF; // Light blue-white
    } else if (ci < 0.3) {
      return 0xFFFFFFFF; // White
    } else if (ci < 0.6) {
      return 0xFFFFFFC8; // Pale yellow
    } else if (ci < 0.8) {
      return 0xFFFFFF80; // Yellow
    } else if (ci < 1.0) {
      return 0xFFFFDD60; // Yellow-orange
    } else if (ci < 1.4) {
      return 0xFFFFAA40; // Orange
    } else {
      return 0xFFFF6030; // Red-orange
    }
  }
}

/// What kind of solar-system body a [SolarSystemBody] is.
enum SolarSystemBodyKind {
  planet('Planet', 'planet'),
  minorBody('Minor body', 'minor_body'),
  satellite('Satellite', 'satellite');

  const SolarSystemBodyKind(this.displayName, this.storageKey);

  /// Shown to the user, e.g. in the object popup's Type row.
  final String displayName;

  /// Written to durable records (the observation log's `object_type`). An
  /// observing log is data the user keeps for years, so this is a stable
  /// snake_case token rather than the display string.
  final String storageKey;
}

/// A solar-system body — a major planet, a comet/asteroid, or an artificial
/// satellite — surfaced through the same [CelestialObject] channel as the
/// catalogues.
///
/// Extends [Star] deliberately. These bodies have always been *carried* as
/// `Star(id: 'PLANET_Jupiter')` and the whole app branches on `obj is Star` for
/// point sources (icons, popup layout, framing, slew); subclassing keeps every
/// one of those paths working while giving the surfaces that state a FACT about
/// the object — the popup's Type row, the observation log's `object_type`
/// column, the identifier chip — something true to say. Before this they said
/// "Star", and the observing log permanently recorded Jupiter as a star with
/// the internal token `PLANET_Jupiter` as its catalogue id.
class SolarSystemBody extends Star {
  final SolarSystemBodyKind kind;

  const SolarSystemBody({
    required super.id,
    required super.name,
    required super.coordinates,
    required this.kind,
    super.magnitude,
  });

  /// Human-facing designation for the identifier chip.
  ///
  /// The `PLANET_`/`MINORBODY_`/`SAT_` prefixed [id] is an internal join key,
  /// not something anyone would recognise on a chart, so the chip shows the
  /// kind instead.
  String get designation => kind.displayName;
}

/// Deep sky object types
/// Based on OpenNGC type codes
enum DsoType {
  /// Single star (often misidentified as DSO)
  star,

  /// Double or multiple star
  doubleStar,

  /// Stellar association
  association,

  /// Open cluster
  openCluster,

  /// Globular cluster
  globularCluster,

  /// Star cluster with nebulosity
  clusterWithNebulosity,

  /// Galaxy
  galaxy,

  /// Galaxy pair
  galaxyPair,

  /// Galaxy triplet
  galaxyTriplet,

  /// Galaxy group
  galaxyGroup,

  /// Planetary nebula
  planetaryNebula,

  /// HII ionized region
  hiiRegion,

  /// Dark nebula
  darkNebula,

  /// Emission nebula
  emissionNebula,

  /// Generic nebula
  nebula,

  /// Reflection nebula
  reflectionNebula,

  /// Supernova remnant
  supernova,

  /// Nova star
  nova,

  /// Star cloud
  starCloud,

  /// Asterism
  asterism,

  /// Other/Unknown type
  other,
}

/// Extensions for DsoType
extension DsoTypeExtension on DsoType {
  /// Get display name for the type
  String get displayName {
    switch (this) {
      case DsoType.star:
        return 'Star';
      case DsoType.doubleStar:
        return 'Double Star';
      case DsoType.association:
        return 'Association';
      case DsoType.openCluster:
        return 'Open Cluster';
      case DsoType.globularCluster:
        return 'Globular Cluster';
      case DsoType.clusterWithNebulosity:
        return 'Cluster + Nebula';
      case DsoType.galaxy:
        return 'Galaxy';
      case DsoType.galaxyPair:
        return 'Galaxy Pair';
      case DsoType.galaxyTriplet:
        return 'Galaxy Triplet';
      case DsoType.galaxyGroup:
        return 'Galaxy Group';
      case DsoType.planetaryNebula:
        return 'Planetary Nebula';
      case DsoType.hiiRegion:
        return 'HII Region';
      case DsoType.darkNebula:
        return 'Dark Nebula';
      case DsoType.emissionNebula:
        return 'Emission Nebula';
      case DsoType.nebula:
        return 'Nebula';
      case DsoType.reflectionNebula:
        return 'Reflection Nebula';
      case DsoType.supernova:
        return 'Supernova Remnant';
      case DsoType.nova:
        return 'Nova';
      case DsoType.starCloud:
        return 'Star Cloud';
      case DsoType.asterism:
        return 'Asterism';
      case DsoType.other:
        return 'Other';
    }
  }

  /// Get abbreviated name
  String get abbreviation {
    switch (this) {
      case DsoType.star:
        return '*';
      case DsoType.doubleStar:
        return '**';
      case DsoType.association:
        return 'Ass';
      case DsoType.openCluster:
        return 'OC';
      case DsoType.globularCluster:
        return 'GC';
      case DsoType.clusterWithNebulosity:
        return 'C+N';
      case DsoType.galaxy:
        return 'Gx';
      case DsoType.galaxyPair:
        return 'GxP';
      case DsoType.galaxyTriplet:
        return 'Gx3';
      case DsoType.galaxyGroup:
        return 'GxG';
      case DsoType.planetaryNebula:
        return 'PN';
      case DsoType.hiiRegion:
        return 'HII';
      case DsoType.darkNebula:
        return 'Dk';
      case DsoType.emissionNebula:
        return 'Em';
      case DsoType.nebula:
        return 'Nb';
      case DsoType.reflectionNebula:
        return 'Rf';
      case DsoType.supernova:
        return 'SNR';
      case DsoType.nova:
        return 'Nov';
      case DsoType.starCloud:
        return 'SC';
      case DsoType.asterism:
        return 'Ast';
      case DsoType.other:
        return '?';
    }
  }

  /// Check if this is a cluster type
  bool get isCluster =>
      this == DsoType.openCluster ||
      this == DsoType.globularCluster ||
      this == DsoType.clusterWithNebulosity;

  /// Check if this is a galaxy type
  bool get isGalaxy =>
      this == DsoType.galaxy ||
      this == DsoType.galaxyPair ||
      this == DsoType.galaxyTriplet ||
      this == DsoType.galaxyGroup;

  /// Check if this is a nebula type
  bool get isNebula =>
      this == DsoType.nebula ||
      this == DsoType.emissionNebula ||
      this == DsoType.reflectionNebula ||
      this == DsoType.planetaryNebula ||
      this == DsoType.darkNebula ||
      this == DsoType.hiiRegion ||
      this == DsoType.supernova;
}

/// Deep sky object data
class DeepSkyObject implements CelestialObject {
  @override
  final String id;
  @override
  final String name;
  @override
  final CelestialCoordinate coordinates;
  @override
  final double? magnitude;
  final DsoType type;
  final double? sizeArcMin;
  final double? minorAxisArcMin;
  final double? positionAngle;
  final String? constellation;
  final List<String> catalogIds;

  /// Comma-separated common names from the catalog (e.g. "Andromeda Galaxy,Great Andromeda Nebula")
  final String? commonNames;

  const DeepSkyObject({
    required this.id,
    required this.name,
    required this.coordinates,
    required this.type,
    this.magnitude,
    this.sizeArcMin,
    this.minorAxisArcMin,
    this.positionAngle,
    this.constellation,
    this.catalogIds = const [],
    this.commonNames,
  });

  /// Get size string for display
  String? get sizeString {
    if (sizeArcMin == null) return null;

    if (minorAxisArcMin != null && minorAxisArcMin != sizeArcMin) {
      return "${sizeArcMin!.toStringAsFixed(1)}' × ${minorAxisArcMin!.toStringAsFixed(1)}'";
    }
    return "${sizeArcMin!.toStringAsFixed(1)}'";
  }

  /// Check if this is a Messier object
  bool get isMessier =>
      catalogIds.any(
        (c) => c.startsWith('M') && RegExp(r'^M\d+$').hasMatch(c),
      ) ||
      (name.startsWith('M') && RegExp(r'^M\d+$').hasMatch(name));

  /// Get Messier number if applicable
  String? get messierNumber {
    for (final c in catalogIds) {
      if (c.startsWith('M') && RegExp(r'^M\d+$').hasMatch(c)) {
        return c;
      }
    }
    if (name.startsWith('M') && RegExp(r'^M\d+$').hasMatch(name)) {
      return name;
    }
    return null;
  }

  /// Get NGC/IC designation
  String? get ngcIcDesignation {
    if (id.startsWith('NGC') || id.startsWith('IC')) {
      return id;
    }
    for (final c in catalogIds) {
      if (c.startsWith('NGC') || c.startsWith('IC')) {
        return c;
      }
    }
    return null;
  }
}
