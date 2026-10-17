import 'dart:math' as math;
import 'catalog_manager.dart';
import 'glade_plus_catalog.dart';
import 'hyperleda_catalog.dart';

/// Unified object type for annotation catalog
enum AnnotationObjectType {
  galaxy,
  nebula,
  planetaryNebula,
  openCluster,
  globularCluster,
  starCluster,
  hiiRegion,
  darkNebula,
  emissionNebula,
  reflectionNebula,
  supernovaRemnant,
  doubleStar,
  asterism,
  other,
}

/// Unified annotation object combining data from multiple catalogs
class AnnotationObject {
  final String id; // Unique ID for deduplication
  final String primaryName; // Best name to display
  final List<String> alternateNames; // Other catalog designations
  final double ra; // Right ascension in degrees
  final double dec; // Declination in degrees
  final AnnotationObjectType type;
  final double? magnitude;
  final double? majorAxis; // arcminutes
  final double? minorAxis; // arcminutes
  final double? positionAngle;
  final String? morphology;
  final String? constellation;
  final double? distance; // Mpc for galaxies, pc for others
  final double? redshift;
  final String source; // 'OpenNGC', 'HyperLEDA', or 'merged'

  const AnnotationObject({
    required this.id,
    required this.primaryName,
    this.alternateNames = const [],
    required this.ra,
    required this.dec,
    required this.type,
    this.magnitude,
    this.majorAxis,
    this.minorAxis,
    this.positionAngle,
    this.morphology,
    this.constellation,
    this.distance,
    this.redshift,
    required this.source,
  });

  /// Create from OpenNGC data
  factory AnnotationObject.fromOpenNgc(OpenNgcData dso) {
    final altNames = <String>[];
    if (dso.messier != null) altNames.add(dso.messier!);
    if (dso.commonNames != null) {
      altNames.addAll(dso.commonNames!.split(',').map((s) => s.trim()));
    }
    if (dso.ngcId != null) altNames.add(dso.ngcId!);

    return AnnotationObject(
      id: 'ngc_${dso.name}',
      primaryName: dso.displayName,
      alternateNames: altNames,
      ra: dso.ra,
      dec: dso.dec,
      type: _inferTypeFromOpenNgc(dso.type),
      magnitude: dso.magnitude,
      majorAxis: dso.majorAxis,
      minorAxis: dso.minorAxis,
      positionAngle: dso.positionAngle,
      constellation: dso.constellation,
      source: 'OpenNGC',
    );
  }

  /// Create from HyperLEDA data
  factory AnnotationObject.fromHyperLeda(HyperLedaData galaxy) {
    final altNames = <String>[];
    if (galaxy.name != null) {
      // Parse alternate names from the name field
      altNames.addAll(galaxy.name!.split(';').map((s) => s.trim()));
    }
    altNames.add('PGC ${galaxy.pgc}');

    return AnnotationObject(
      id: 'pgc_${galaxy.pgc}',
      primaryName: galaxy.displayName,
      alternateNames: altNames,
      ra: galaxy.ra,
      dec: galaxy.dec,
      type: AnnotationObjectType.galaxy,
      magnitude: galaxy.magnitude,
      majorAxis: galaxy.majorAxis,
      minorAxis: galaxy.minorAxis,
      positionAngle: galaxy.positionAngle,
      morphology: galaxy.morphology,
      distance: galaxy.distance,
      redshift: galaxy.redshift,
      source: 'HyperLEDA',
    );
  }

  /// Create from GLADE+ data
  factory AnnotationObject.fromGladePlus(GladePlusData galaxy) {
    return AnnotationObject(
      id: 'pgc_${galaxy.pgc}',
      primaryName: galaxy.displayName,
      alternateNames: const [],
      ra: galaxy.ra,
      dec: galaxy.dec,
      type: AnnotationObjectType.galaxy,
      magnitude: galaxy.magnitude,
      distance: galaxy.distance,
      redshift: galaxy.redshift,
      source: 'GLADE+',
    );
  }

  /// Merge two objects (prefer OpenNGC for metadata, HyperLEDA for coordinates)
  factory AnnotationObject.merged(AnnotationObject ngc, AnnotationObject leda) {
    final allNames = <String>{
      ngc.primaryName,
      ...ngc.alternateNames,
      leda.primaryName,
      ...leda.alternateNames,
    };

    // Use Messier or NGC name as primary if available
    String primaryName = ngc.primaryName;
    if (ngc.primaryName.startsWith('M')) {
      primaryName = ngc.primaryName;
    } else if (leda.primaryName.startsWith('NGC') ||
        leda.primaryName.startsWith('IC')) {
      primaryName = leda.primaryName;
    }
    allNames.remove(primaryName);

    return AnnotationObject(
      id: ngc.id, // Keep NGC ID for merged objects
      primaryName: primaryName,
      alternateNames: allNames.toList(),
      ra: leda.ra, // HyperLEDA often has more precise coordinates
      dec: leda.dec,
      type: ngc.type, // OpenNGC has better type classification
      magnitude: ngc.magnitude ?? leda.magnitude,
      majorAxis: ngc.majorAxis ?? leda.majorAxis,
      minorAxis: ngc.minorAxis ?? leda.minorAxis,
      positionAngle: ngc.positionAngle ?? leda.positionAngle,
      morphology: leda.morphology ?? ngc.morphology,
      constellation: ngc.constellation,
      distance: leda.distance,
      redshift: leda.redshift,
      source: 'merged',
    );
  }

  static AnnotationObjectType _inferTypeFromOpenNgc(String typeCode) {
    switch (typeCode) {
      case 'G':
      case 'GPair':
      case 'GTrpl':
      case 'GGroup':
        return AnnotationObjectType.galaxy;
      case 'PN':
        return AnnotationObjectType.planetaryNebula;
      case 'OCl':
        return AnnotationObjectType.openCluster;
      case 'GCl':
        return AnnotationObjectType.globularCluster;
      case 'Cl+N':
        return AnnotationObjectType.starCluster;
      case 'HII':
        return AnnotationObjectType.hiiRegion;
      case 'DrkN':
        return AnnotationObjectType.darkNebula;
      case 'EmN':
        return AnnotationObjectType.emissionNebula;
      case 'RfN':
        return AnnotationObjectType.reflectionNebula;
      case 'Neb':
        return AnnotationObjectType.nebula;
      case 'SNR':
        return AnnotationObjectType.supernovaRemnant;
      case '**':
        return AnnotationObjectType.doubleStar;
      case '*Ass':
        return AnnotationObjectType.asterism;
      default:
        return AnnotationObjectType.other;
    }
  }

  /// Get object type description
  String get typeDescription {
    switch (type) {
      case AnnotationObjectType.galaxy:
        return morphology != null ? '$morphology Galaxy' : 'Galaxy';
      case AnnotationObjectType.nebula:
        return 'Nebula';
      case AnnotationObjectType.planetaryNebula:
        return 'Planetary Nebula';
      case AnnotationObjectType.openCluster:
        return 'Open Cluster';
      case AnnotationObjectType.globularCluster:
        return 'Globular Cluster';
      case AnnotationObjectType.starCluster:
        return 'Star Cluster';
      case AnnotationObjectType.hiiRegion:
        return 'HII Region';
      case AnnotationObjectType.darkNebula:
        return 'Dark Nebula';
      case AnnotationObjectType.emissionNebula:
        return 'Emission Nebula';
      case AnnotationObjectType.reflectionNebula:
        return 'Reflection Nebula';
      case AnnotationObjectType.supernovaRemnant:
        return 'Supernova Remnant';
      case AnnotationObjectType.doubleStar:
        return 'Double Star';
      case AnnotationObjectType.asterism:
        return 'Asterism';
      case AnnotationObjectType.other:
        return 'Deep Sky Object';
    }
  }

  /// Get size string
  String? get sizeString {
    if (majorAxis == null) return null;
    if (minorAxis != null && (minorAxis! - majorAxis!).abs() > 0.1) {
      return "${majorAxis!.toStringAsFixed(1)}' × ${minorAxis!.toStringAsFixed(1)}'";
    }
    return "${majorAxis!.toStringAsFixed(1)}'";
  }

  /// Get distance string
  String? get distanceString {
    if (distance == null) return null;
    if (type == AnnotationObjectType.galaxy) {
      if (distance! < 1) {
        return '${(distance! * 1000).toStringAsFixed(0)} kpc';
      }
      return '${distance!.toStringAsFixed(1)} Mpc';
    }
    // For other objects, assume distance is in parsecs
    if (distance! < 1000) {
      return '${distance!.toStringAsFixed(0)} pc';
    }
    return '${(distance! / 1000).toStringAsFixed(1)} kpc';
  }
}

/// Unified annotation catalog combining HyperLEDA and OpenNGC
class AnnotationCatalog {
  final OpenNgcCatalogLoader? _ngcLoader;
  final HyperLedaCatalogLoader? _ledaLoader;
  final GladePlusCatalogLoader? _gladeLoader;

  AnnotationCatalog({
    OpenNgcCatalogLoader? ngcLoader,
    HyperLedaCatalogLoader? ledaLoader,
    GladePlusCatalogLoader? gladeLoader,
  }) : _ngcLoader = ngcLoader,
       _ledaLoader = ledaLoader,
       _gladeLoader = gladeLoader;

  /// Check if catalog is available
  bool get isAvailable =>
      _ngcLoader != null || _ledaLoader != null || _gladeLoader != null;

  /// Objects within `radiusDegrees` of the given centre, brightest first.
  ///
  /// Each backing catalog is asked for that region only. The large galaxy
  /// catalogs stream their files in a background isolate
  /// (`catalog_region_scan.dart`), so peak memory is proportional to the
  /// answer rather than to the catalog, and the caller's isolate never parses.
  ///
  /// The previous shape loaded and merged every catalog in full before
  /// filtering. With GLADE+ installed (~22M rows) that meant a synchronous
  /// multi-gigabyte parse on whichever isolate asked first — on the UI isolate
  /// it never yielded again, which is how a solved frame froze the app.
  Future<List<AnnotationObject>> searchNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
    Set<AnnotationObjectType>? typeFilter,
  }) async {
    // Merge order is priority order: OpenNGC carries the better names and
    // sizes for bright objects, so it lands first and the galaxy catalogs
    // enrich its entries rather than displacing them.
    final ordered = <AnnotationObject>[];
    final indexByPosition = <String, int>{};

    void merge(AnnotationObject object) {
      final key = _positionKey(object);
      final existing = indexByPosition[key];
      if (existing == null) {
        indexByPosition[key] = ordered.length;
        ordered.add(object);
        return;
      }
      ordered[existing] = AnnotationObject.merged(ordered[existing], object);
    }

    if (_ngcLoader != null) {
      final dsos = await _ngcLoader.searchNearby(
        ra: ra,
        dec: dec,
        radiusDegrees: radiusDegrees,
        maxMagnitude: maxMagnitude,
      );
      for (final dso in dsos) {
        merge(AnnotationObject.fromOpenNgc(dso));
      }
    }

    if (_ledaLoader != null) {
      final galaxies = await _ledaLoader.searchNearby(
        ra: ra,
        dec: dec,
        radiusDegrees: radiusDegrees,
        maxMagnitude: maxMagnitude,
      );
      for (final galaxy in galaxies) {
        merge(AnnotationObject.fromHyperLeda(galaxy));
      }
    }

    if (_gladeLoader != null) {
      final galaxies = await _gladeLoader.searchNearby(
        ra: ra,
        dec: dec,
        radiusDegrees: radiusDegrees,
        maxMagnitude: maxMagnitude,
      );
      for (final galaxy in galaxies) {
        merge(AnnotationObject.fromGladePlus(galaxy));
      }
    }

    final results = typeFilter == null
        ? ordered
        : ordered.where((obj) => typeFilter.contains(obj.type)).toList();
    results.sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));
    return results;
  }

  /// Deduplication key: position rounded to 0.01 deg (~36 arcsec), the
  /// tolerance the merged catalogs were assembled with. Keyed through a map so
  /// merging a colliding row is O(1) — it used to be `List.indexOf`, an O(n)
  /// scan of the growing list per collision.
  String _positionKey(AnnotationObject object) =>
      '${object.ra.toStringAsFixed(2)},${object.dec.toStringAsFixed(2)}';

  /// Find the closest object to given coordinates
  Future<AnnotationObject?> findClosest({
    required double ra,
    required double dec,
    double maxRadiusDegrees = 0.5,
    double? maxMagnitude,
  }) async {
    final nearby = await searchNearby(
      ra: ra,
      dec: dec,
      radiusDegrees: maxRadiusDegrees,
      maxMagnitude: maxMagnitude,
    );

    if (nearby.isEmpty) return null;

    // Find closest by angular distance
    AnnotationObject? closest;
    double minDistSq = double.infinity;

    for (final obj in nearby) {
      final dRa = (obj.ra - ra) * math.cos(dec * math.pi / 180);
      final dDec = obj.dec - dec;
      final distSq = dRa * dRa + dDec * dDec;

      if (distSq < minDistSq) {
        minDistSq = distSq;
        closest = obj;
      }
    }

    return closest;
  }

  /// Drop whatever the backing loaders have cached.
  void clearCache() {
    _ngcLoader?.clearCache();
    _ledaLoader?.clearCache();
    _gladeLoader?.clearCache();
  }
}
