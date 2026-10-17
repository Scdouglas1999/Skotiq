import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'catalog_region_scan.dart';

/// HyperLEDA catalog data for deep galaxy annotation
/// Contains ~3 million galaxies down to magnitude 20+
class HyperLedaData {
  final int pgc; // PGC number (unique identifier)
  final String? name; // Primary name (NGC, IC, UGC, etc.)
  final double ra; // Right ascension in degrees
  final double dec; // Declination in degrees
  final double? magnitude; // B-magnitude (visual)
  final double? majorAxis; // Major axis in arcminutes
  final double? minorAxis; // Minor axis in arcminutes
  final double? positionAngle; // Position angle in degrees
  final String? morphology; // Morphological type (e.g., Sb, E, Irr)
  final double? redshift; // Heliocentric velocity / c
  final double? distance; // Distance in Mpc (if available)

  const HyperLedaData({
    required this.pgc,
    this.name,
    required this.ra,
    required this.dec,
    this.magnitude,
    this.majorAxis,
    this.minorAxis,
    this.positionAngle,
    this.morphology,
    this.redshift,
    this.distance,
  });

  /// Parse a line from the HyperLEDA CSV export
  /// Expected format: pgc,objname,al2000,de2000,bt,logd25,logr25,pa,t,v,modbest
  factory HyperLedaData.fromCsvLine(String line) {
    final parts = _parseCsvLine(line);
    if (parts.length < 11) {
      throw const FormatException(
        'Invalid HyperLEDA line: insufficient columns',
      );
    }

    return HyperLedaData(
      pgc: int.tryParse(parts[0]) ?? 0,
      name: parts[1].isNotEmpty ? parts[1] : null,
      ra: double.tryParse(parts[2]) ?? 0.0,
      dec: double.tryParse(parts[3]) ?? 0.0,
      magnitude: double.tryParse(parts[4]),
      // logd25 is log10(D25) where D25 is major axis in 0.1 arcmin
      majorAxis: _parseLogD25(parts[5]),
      // logr25 is log10(D25/d25) - axis ratio
      minorAxis: _parseMinorAxis(parts[5], parts[6]),
      positionAngle: double.tryParse(parts[7]),
      morphology: _parseMorphology(parts[8]),
      redshift: _parseRedshift(parts[9]),
      distance: _parseDistance(parts[10]),
    );
  }

  static List<String> _parseCsvLine(String line) {
    final result = <String>[];
    var inQuotes = false;
    var current = StringBuffer();

    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        result.add(current.toString().trim());
        current = StringBuffer();
      } else {
        current.write(char);
      }
    }
    result.add(current.toString().trim());
    return result;
  }

  static double? _parseLogD25(String value) {
    final logD25 = double.tryParse(value);
    if (logD25 == null) return null;
    // Convert from log10(D25 in 0.1 arcmin) to arcmin
    return math.pow(10, logD25) * 0.1;
  }

  static double? _parseMinorAxis(String logD25Str, String logR25Str) {
    final logD25 = double.tryParse(logD25Str);
    final logR25 = double.tryParse(logR25Str);
    if (logD25 == null) return null;
    final majorAxis = math.pow(10, logD25) * 0.1;
    if (logR25 == null) return majorAxis; // Assume circular if no ratio
    final ratio = math.pow(10, logR25);
    return majorAxis / ratio;
  }

  static String? _parseMorphology(String value) {
    final t = double.tryParse(value);
    if (t == null) return null;
    // Convert numerical T-type to string morphology
    if (t < -5) return 'cE'; // Compact elliptical
    if (t < -3) return 'E'; // Elliptical
    if (t < -1) return 'S0'; // Lenticular
    if (t < 1) return 'Sa'; // Early spiral
    if (t < 3) return 'Sb'; // Intermediate spiral
    if (t < 5) return 'Sc'; // Late spiral
    if (t < 7) return 'Sd'; // Very late spiral
    if (t < 9) return 'Sm'; // Magellanic spiral
    return 'Irr'; // Irregular
  }

  static double? _parseRedshift(String value) {
    final v = double.tryParse(value);
    if (v == null) return null;
    // Convert heliocentric velocity (km/s) to redshift
    return v / 299792.458;
  }

  static double? _parseDistance(String value) {
    final modBest = double.tryParse(value);
    if (modBest == null) return null;
    // Convert distance modulus to distance in Mpc
    // m - M = 5 * log10(d) - 5
    // d = 10^((m-M+5)/5) parsecs = 10^((m-M+5)/5) / 1e6 Mpc
    return math.pow(10, (modBest + 5) / 5) / 1e6;
  }

  /// Get the display name for this object
  String get displayName => name ?? 'PGC $pgc';

  /// Get the catalog ID
  String get catalogId => 'PGC$pgc';

  /// Get size string
  String? get sizeString {
    if (majorAxis == null) return null;
    if (minorAxis != null && minorAxis != majorAxis) {
      return "${majorAxis!.toStringAsFixed(1)}' × ${minorAxis!.toStringAsFixed(1)}'";
    }
    return "${majorAxis!.toStringAsFixed(1)}'";
  }

  /// Get distance string
  String? get distanceString {
    if (distance != null) {
      if (distance! < 1) {
        return '${(distance! * 1000).toStringAsFixed(0)} kpc';
      }
      return '${distance!.toStringAsFixed(1)} Mpc';
    }
    if (redshift != null) {
      // Hubble distance approximation: d = cz/H0 where H0 ≈ 70 km/s/Mpc
      final hubbleDistance = redshift! * 299792.458 / 70;
      return '~${hubbleDistance.toStringAsFixed(0)} Mpc';
    }
    return null;
  }
}

/// HyperLEDA catalog loader with spatial indexing for fast coordinate queries
class HyperLedaCatalogLoader {
  final String filePath;
  List<HyperLedaData>? _cachedData;

  final CatalogRegionCache<HyperLedaData> _cache =
      CatalogRegionCache<HyperLedaData>();

  HyperLedaCatalogLoader(this.filePath);

  /// Load all galaxies from the catalog
  Future<List<HyperLedaData>> loadAll() async {
    if (_cachedData != null) return _cachedData!;

    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('HyperLEDA catalog not found', filePath);
    }

    final lines = await file.readAsLines();
    final galaxies = <HyperLedaData>[];

    // Skip header line
    for (var i = 1; i < lines.length; i++) {
      try {
        galaxies.add(HyperLedaData.fromCsvLine(lines[i]));
      } catch (e) {
        // HyperLEDA carries malformed rows from upstream exports; a single
        // bad line must not abort the load. FINE surfaces a systemic format
        // change in the dev console.
        developer.log(
          'HyperLEDA line $i parse failed; skipping: $e',
          name: 'HyperLedaCatalog',
          level: 500,
        );
      }
    }

    _cachedData = galaxies;
    return galaxies;
  }

  /// Load galaxies up to a magnitude limit
  Future<List<HyperLedaData>> loadByMagnitude(double maxMagnitude) async {
    final all = await loadAll();
    return all.where((g) => (g.magnitude ?? 99) <= maxMagnitude).toList();
  }

  /// Galaxies within `radiusDegrees` of the given centre, nearest first.
  ///
  /// HyperLEDA is ~3 million rows, so this streams the file in a background
  /// isolate and keeps only the rows inside the cone rather than loading the
  /// catalog to filter it — see `catalog_region_scan.dart`. The by-name
  /// helpers below still load the catalog, because a name lookup genuinely
  /// has to consider every row.
  Future<List<HyperLedaData>> searchNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
    int maxResults = CatalogRegionFilter.defaultMaxResults,
  }) async {
    final filter = CatalogRegionFilter(
      ra: ra,
      dec: dec,
      radiusDegrees: radiusDegrees,
      maxMagnitude: maxMagnitude,
      maxResults: maxResults,
    );

    final cached = _cache.lookup(
      filter,
      positionOf: _positionOf,
      magnitudeOf: _magnitudeOf,
    );
    if (cached != null) {
      return cached;
    }

    // Scan a little wide and magnitude-blind so the next frame's cone is
    // served from memory instead of re-reading the catalog.
    final cone = filter.padded();
    final path = filePath;
    final scan = await Isolate.run(() => scanHyperLedaRegion(path, cone));
    _cache.store(cone, scan);

    return _cache.lookup(
          filter,
          positionOf: _positionOf,
          magnitudeOf: _magnitudeOf,
        ) ??
        // The scan was truncated, so it is not cacheable and the padded cone
        // cannot be trusted to contain the request. Answer from what it found.
        scan.objects.where((object) {
          final position = _positionOf(object);
          return filter.accepts(
            objRa: position.ra,
            objDec: position.dec,
            magnitude: _magnitudeOf(object),
          );
        }).toList();
  }

  /// Search galaxies by name
  Future<List<HyperLedaData>> search(String query) async {
    final all = await loadAll();
    final q = query.toLowerCase();
    return all.where((g) {
      final name = g.displayName.toLowerCase();
      final pgc = g.catalogId.toLowerCase();
      return name.contains(q) || pgc.contains(q);
    }).toList();
  }

  /// Find a galaxy by PGC number
  Future<HyperLedaData?> findByPgc(int pgc) async {
    final all = await loadAll();
    return all.where((g) => g.pgc == pgc).firstOrNull;
  }

  /// Get galaxy count
  Future<int> get count async {
    final all = await loadAll();
    return all.length;
  }

  /// Drop everything cached — the scanned field and the whole-catalog list —
  /// so a re-imported catalog file is read afresh.
  void clearCache() {
    _cachedData = null;
    _cache.clear();
  }
}

/// The streaming body of [HyperLedaCatalogLoader.searchNearby].
///
/// Top-level so it can be handed to `Isolate.run` with only sendable state.
Future<CatalogRegionScan<HyperLedaData>> scanHyperLedaRegion(
  String filePath,
  CatalogRegionFilter filter,
) => scanCatalogRegion<HyperLedaData>(
  filePath: filePath,
  filter: filter,
  parse: HyperLedaData.fromCsvLine,
  positionOf: _positionOf,
  magnitudeOf: _magnitudeOf,
  catalogName: 'HyperLEDA',
);

({double ra, double dec}) _positionOf(HyperLedaData galaxy) =>
    (ra: galaxy.ra, dec: galaxy.dec);

double? _magnitudeOf(HyperLedaData galaxy) => galaxy.magnitude;
