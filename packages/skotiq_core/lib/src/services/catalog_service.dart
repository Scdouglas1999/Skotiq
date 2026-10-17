import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Catalog entry for stars or deep sky objects
class CatalogEntry {
  final String id;
  final String name;
  final double ra; // Right ascension in degrees
  final double dec; // Declination in degrees
  final double? magnitude;
  final String? type;
  final Map<String, dynamic>? metadata;

  const CatalogEntry({
    required this.id,
    required this.name,
    required this.ra,
    required this.dec,
    this.magnitude,
    this.type,
    this.metadata,
  });
}

/// Catalog service with streaming and pagination support
class CatalogService {
  static const int defaultPageSize = 100;
  static const int maxCacheSize = 1000;

  final String catalogPath;
  final Map<int, List<CatalogEntry>> _cache = {};
  int _totalEntries = 0;

  CatalogService(this.catalogPath);

  /// Stream catalog entries with pagination
  ///
  /// This avoids loading the entire catalog into memory at once.
  /// Perfect for large catalogs with millions of entries.
  Stream<List<CatalogEntry>> streamCatalogSearch({
    required String query,
    int pageSize = defaultPageSize,
    double? maxMagnitude,
    String? typeFilter,
  }) async* {
    final file = File(catalogPath);
    if (!await file.exists()) {
      throw FileSystemException('Catalog file not found', catalogPath);
    }

    int offset = 0;
    final queryLower = query.toLowerCase();
    final results = <CatalogEntry>[];

    // Stream file line by line to avoid loading everything into memory
    await for (final line
        in file
            .openRead()
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter())) {
      // Skip header
      if (offset == 0) {
        offset++;
        continue;
      }

      // Parse entry
      final entry = _parseEntry(line);
      if (entry == null) continue;

      // Apply filters
      if (maxMagnitude != null &&
          entry.magnitude != null &&
          entry.magnitude! > maxMagnitude) {
        continue;
      }

      if (typeFilter != null && entry.type != typeFilter) {
        continue;
      }

      // Check if matches query
      if (query.isEmpty ||
          entry.name.toLowerCase().contains(queryLower) ||
          entry.id.toLowerCase().contains(queryLower)) {
        results.add(entry);

        // Yield page when full
        if (results.length >= pageSize) {
          yield List.from(results);
          results.clear();
        }
      }
    }

    // Yield remaining results
    if (results.isNotEmpty) {
      yield results;
    }
  }

  /// Load catalog page by page
  ///
  /// More efficient than loading everything at once.
  /// Results are cached in memory up to maxCacheSize entries.
  Future<List<CatalogEntry>> loadPage({
    required int page,
    int pageSize = defaultPageSize,
    double? maxMagnitude,
    String? typeFilter,
  }) async {
    // Check cache first
    if (_cache.containsKey(page)) {
      return _cache[page]!;
    }

    final file = File(catalogPath);
    if (!await file.exists()) {
      throw FileSystemException('Catalog file not found', catalogPath);
    }

    final startIndex = page * pageSize;
    final endIndex = startIndex + pageSize;
    final results = <CatalogEntry>[];

    int currentIndex = 0;
    int lineNum = 0;

    // Read only the lines we need
    await for (final line
        in file
            .openRead()
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter())) {
      // Skip header
      if (lineNum == 0) {
        lineNum++;
        continue;
      }

      lineNum++;

      // Parse entry
      final entry = _parseEntry(line);
      if (entry == null) continue;

      // Apply filters
      if (maxMagnitude != null &&
          entry.magnitude != null &&
          entry.magnitude! > maxMagnitude) {
        continue;
      }

      if (typeFilter != null && entry.type != typeFilter) {
        continue;
      }

      // Check if in range
      if (currentIndex >= startIndex && currentIndex < endIndex) {
        results.add(entry);
      }

      currentIndex++;

      // Stop if we've read the page
      if (currentIndex >= endIndex) {
        break;
      }
    }

    // Cache results (with size limit)
    if (_cache.length < maxCacheSize ~/ pageSize) {
      _cache[page] = results;
    }

    return results;
  }

  /// Search catalog with pagination
  Future<List<CatalogEntry>> searchCatalog({
    required String query,
    required int offset,
    required int limit,
    double? maxMagnitude,
    String? typeFilter,
  }) async {
    if (limit <= 0) {
      return const [];
    }

    final results = <CatalogEntry>[];
    int remainingOffset = offset;

    await for (final page in streamCatalogSearch(
      query: query,
      pageSize: limit,
      maxMagnitude: maxMagnitude,
      typeFilter: typeFilter,
    )) {
      if (remainingOffset >= page.length) {
        remainingOffset -= page.length;
        continue;
      }

      results.addAll(page.skip(remainingOffset).take(limit - results.length));
      remainingOffset = 0;

      if (results.length >= limit) {
        break;
      }
    }

    return results;
  }

  /// Get total entry count (cached after first call)
  Future<int> getTotalCount() async {
    if (_totalEntries > 0) {
      return _totalEntries;
    }

    final file = File(catalogPath);
    if (!await file.exists()) {
      return 0;
    }

    // Count lines efficiently
    int count = 0;
    await for (final _
        in file
            .openRead()
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter())) {
      count++;
    }

    _totalEntries = count - 1; // Subtract header
    return _totalEntries;
  }

  /// Parse catalog entry from CSV line
  ///
  /// Override this method for different catalog formats
  CatalogEntry? _parseEntry(String line) {
    try {
      final parts = line.split(',');
      if (parts.isEmpty) return null;

      // Generic CSV parsing - override for specific catalogs
      return CatalogEntry(
        id: parts[0],
        name: parts.length > 1 ? parts[1] : parts[0],
        ra: parts.length > 2 ? double.tryParse(parts[2]) ?? 0 : 0,
        dec: parts.length > 3 ? double.tryParse(parts[3]) ?? 0 : 0,
        magnitude: parts.length > 4 ? double.tryParse(parts[4]) : null,
        type: parts.length > 5 ? parts[5] : null,
      );
    } catch (e) {
      return null;
    }
  }

  /// Clear cache
  void clearCache() {
    _cache.clear();
    _totalEntries = 0;
  }

  /// Dispose resources
  void dispose() {
    clearCache();
  }
}

/// Star catalog service with HYG-specific parsing
class StarCatalogService extends CatalogService {
  StarCatalogService(super.catalogPath);

  @override
  CatalogEntry? _parseEntry(String line) {
    try {
      final parts = _parseCsvLine(line);
      if (parts.length < 14) return null;

      final id = parts[0];
      final hipId = parts.length > 1 ? parts[1] : '';
      final properName = parts.length > 6 ? parts[6] : '';
      final ra = double.tryParse(parts[7]) ?? 0;
      final dec = double.tryParse(parts[8]) ?? 0;
      final magnitude = double.tryParse(parts[13]);

      // Determine display name
      String name;
      if (properName.isNotEmpty) {
        name = properName;
      } else if (hipId.isNotEmpty) {
        name = 'HIP $hipId';
      } else {
        name = 'Star $id';
      }

      return CatalogEntry(
        id: id,
        name: name,
        ra: ra * 15, // Convert hours to degrees
        dec: dec,
        magnitude: magnitude,
        type: 'star',
        metadata: {'hipId': hipId, 'properName': properName},
      );
    } catch (e) {
      return null;
    }
  }

  List<String> _parseCsvLine(String line) {
    final parts = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        parts.add(buffer.toString().trim());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }

    parts.add(buffer.toString().trim());
    return parts;
  }
}

/// DSO catalog service with OpenNGC-specific parsing
class DsoCatalogService extends CatalogService {
  DsoCatalogService(super.catalogPath);

  @override
  CatalogEntry? _parseEntry(String line) {
    try {
      final parts = line.split(';');
      if (parts.isEmpty) return null;

      final name = parts[0];
      final type = parts.length > 1 ? parts[1] : '';
      final ra = _parseRa(parts.length > 2 ? parts[2] : '');
      final dec = _parseDec(parts.length > 3 ? parts[3] : '');
      final magnitude = parts.length > 9 ? double.tryParse(parts[9]) : null;
      final messier = parts.length > 18 && parts[18].isNotEmpty
          ? 'M${parts[18]}'
          : null;
      final commonNames = parts.length > 23 ? parts[23] : '';

      // Determine display name
      String displayName;
      if (messier != null) {
        displayName = messier;
      } else if (commonNames.isNotEmpty) {
        displayName = commonNames.split(',').first.trim();
      } else {
        displayName = name;
      }

      return CatalogEntry(
        id: name,
        name: displayName,
        ra: ra,
        dec: dec,
        magnitude: magnitude,
        type: type,
        metadata: {'messier': messier, 'commonNames': commonNames},
      );
    } catch (e) {
      return null;
    }
  }

  double _parseRa(String raStr) {
    if (raStr.isEmpty) return 0;
    final parts = raStr.split(':');
    if (parts.length != 3) return 0;
    final h = double.tryParse(parts[0]) ?? 0;
    final m = double.tryParse(parts[1]) ?? 0;
    final s = double.tryParse(parts[2]) ?? 0;
    return (h + m / 60 + s / 3600) * 15; // Convert to degrees
  }

  double _parseDec(String decStr) {
    if (decStr.isEmpty) return 0;
    final sign = decStr.startsWith('-') ? -1 : 1;
    final clean = decStr.replaceAll('+', '').replaceAll('-', '');
    final parts = clean.split(':');
    if (parts.length != 3) return 0;
    final d = double.tryParse(parts[0]) ?? 0;
    final m = double.tryParse(parts[1]) ?? 0;
    final s = double.tryParse(parts[2]) ?? 0;
    return sign * (d + m / 60 + s / 3600);
  }
}

/// Annotation catalog service for GLADE+ galaxies
class AnnotationCatalogService extends CatalogService {
  AnnotationCatalogService(super.catalogPath);

  @override
  CatalogEntry? _parseEntry(String line) {
    try {
      final parts = line.split(',');
      if (parts.length < 5) return null;

      final ra = double.tryParse(parts[0]) ?? 0;
      final dec = double.tryParse(parts[1]) ?? 0;
      final magnitude = double.tryParse(parts[2]);
      final redshift = double.tryParse(parts[3]);
      final pgc = parts[4];

      return CatalogEntry(
        id: 'PGC$pgc',
        name: 'PGC $pgc',
        ra: ra,
        dec: dec,
        magnitude: magnitude,
        type: 'galaxy',
        metadata: {'redshift': redshift, 'pgc': pgc},
      );
    } catch (e) {
      return null;
    }
  }
}
