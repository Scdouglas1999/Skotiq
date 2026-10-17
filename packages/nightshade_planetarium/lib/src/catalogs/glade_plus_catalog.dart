import 'dart:isolate';

import 'catalog_region_scan.dart';

/// GLADE+ catalog data for deep galaxy annotation
/// Columns: RAJ2000, DEJ2000, Bmag, zhelio, PGC
class GladePlusData {
  final int pgc;
  final double ra; // degrees
  final double dec; // degrees
  final double? magnitude; // B magnitude
  final double? redshift; // derived from zhelio
  final double? distance; // Mpc (approximate, from zhelio)

  const GladePlusData({
    required this.pgc,
    required this.ra,
    required this.dec,
    this.magnitude,
    this.redshift,
    this.distance,
  });

  factory GladePlusData.fromCsvLine(String line) {
    final parts = _parseCsvLine(line);
    if (parts.length < 5) {
      throw const FormatException('Invalid GLADE+ line: insufficient columns');
    }

    final ra = double.tryParse(parts[0]) ?? 0.0;
    final dec = double.tryParse(parts[1]) ?? 0.0;
    final magnitude = double.tryParse(parts[2]);
    final velocity = double.tryParse(parts[3]);
    final redshift = _parseRedshift(velocity);
    final distance = _parseDistanceMpc(velocity);

    return GladePlusData(
      pgc: int.tryParse(parts[4]) ?? 0,
      ra: ra,
      dec: dec,
      magnitude: magnitude,
      redshift: redshift,
      distance: distance,
    );
  }

  static List<String> _parseCsvLine(String line) {
    // Downloaded GLADE+ rows are numeric and normally have no quoted cells.
    // Avoid allocating a StringBuffer and a one-character String per byte.
    if (!line.contains('"')) return line.split(',');
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

  static double? _parseRedshift(double? velocity) {
    if (velocity == null) return null;
    return velocity / 299792.458;
  }

  static double? _parseDistanceMpc(double? velocity) {
    if (velocity == null) return null;
    // Hubble distance approximation with H0 ≈ 70 km/s/Mpc
    return velocity / 70.0;
  }

  String get displayName => 'PGC $pgc';
}

/// GLADE+ catalog loader.
///
/// GLADE+ is ~22 million rows, so this loader never holds the catalog in
/// memory. Every query streams the file in a background isolate and keeps only
/// the rows inside the requested cone — see `catalog_region_scan.dart` for why
/// the previous load-everything-then-filter shape froze the app.
class GladePlusCatalogLoader {
  final String filePath;

  final CatalogRegionCache<GladePlusData> _cache =
      CatalogRegionCache<GladePlusData>();

  GladePlusCatalogLoader(this.filePath);

  /// Galaxies within `radiusDegrees` of the given centre, nearest first.
  ///
  /// Runs off the calling isolate, so a caller on the UI isolate stays
  /// responsive for the whole scan.
  Future<List<GladePlusData>> searchNearby({
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
    final scan = await Isolate.run(() => scanGladePlusRegion(path, cone));
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

  /// Drop the cached field, so a re-imported catalog file is re-read.
  void clearCache() => _cache.clear();
}

/// The streaming body of [GladePlusCatalogLoader.searchNearby].
///
/// Top-level so it can be handed to `Isolate.run` with only sendable state.
Future<CatalogRegionScan<GladePlusData>> scanGladePlusRegion(
  String filePath,
  CatalogRegionFilter filter,
) => scanCatalogRegion<GladePlusData>(
  filePath: filePath,
  filter: filter,
  parse: GladePlusData.fromCsvLine,
  positionOf: _positionOf,
  magnitudeOf: _magnitudeOf,
  catalogName: 'GLADE+',
);

({double ra, double dec}) _positionOf(GladePlusData galaxy) =>
    (ra: galaxy.ra, dec: galaxy.dec);

double? _magnitudeOf(GladePlusData galaxy) => galaxy.magnitude;
