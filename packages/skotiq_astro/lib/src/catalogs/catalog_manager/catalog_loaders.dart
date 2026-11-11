part of '../catalog_manager.dart';

class HygCatalogLoader {
  final String filePath;
  List<HygStarData>? _cachedData;

  HygCatalogLoader(this.filePath);

  /// Load all stars from the catalog
  Future<List<HygStarData>> loadAll() async {
    if (_cachedData != null) return _cachedData!;

    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Star catalog not found', filePath);
    }

    final lines = await file.readAsLines();
    final stars = <HygStarData>[];
    var malformedLines = 0;

    // Skip header line
    for (var i = 1; i < lines.length; i++) {
      try {
        final star = HygStarData.fromCsvLine(lines[i]);
        stars.add(star);
      } catch (e) {
        // Skip malformed lines but count them
        malformedLines++;
      }
    }

    if (malformedLines > 0) {
      developer.log(
        '[Catalog] StarCatalogLoader: Skipped $malformedLines malformed lines',
        name: 'CatalogManager',
        level: 900,
      );
    }

    _cachedData = stars;
    return stars;
  }

  /// Load stars up to a magnitude limit
  Future<List<HygStarData>> loadByMagnitude(double maxMagnitude) async {
    final all = await loadAll();
    return all.where((s) => (s.magnitude ?? 99) <= maxMagnitude).toList();
  }

  /// Search stars by name
  Future<List<HygStarData>> search(String query) async {
    final all = await loadAll();
    final q = query.toLowerCase();
    final normalizedQuery = _normalizeCatalogSearchText(query);
    return all.where((s) {
      return _catalogTextMatches(s.name, q, normalizedQuery) ||
          _catalogTextMatches(s.catalogId, q, normalizedQuery) ||
          (s.hipId != null &&
              _catalogTextMatches('HIP${s.hipId}', q, normalizedQuery)) ||
          (s.hdId != null &&
              _catalogTextMatches('HD${s.hdId}', q, normalizedQuery));
    }).toList();
  }

  /// Find a star by HIP ID
  Future<HygStarData?> findByHipId(int hipId) async {
    final all = await loadAll();
    return all.where((s) => s.hipId == hipId).firstOrNull;
  }

  /// Get star count
  Future<int> get count async {
    final all = await loadAll();
    return all.length;
  }

  /// Search for stars near a given RA/Dec position
  /// Returns stars within radiusDegrees of the specified coordinates
  Future<List<HygStarData>> searchNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    final all = await loadAll();

    return all.where((star) {
        // Apply magnitude filter first (cheaper check)
        if (maxMagnitude != null && (star.magnitude ?? 99) > maxMagnitude) {
          return false;
        }

        // Calculate angular distance
        final distance = AstronomyCalculations.angularSeparation(
          ra1Deg: ra,
          dec1Deg: dec,
          ra2Deg: star.ra,
          dec2Deg: star.dec,
        );
        return distance <= radiusDegrees;
      }).toList()
      // Sort by magnitude (brightest first)
      ..sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));
  }

  /// Clear cache
  void clearCache() {
    _cachedData = null;
  }
}

// (End of HygCatalogLoader)
/// DSO catalog loader that reads from downloaded OpenNGC database
class OpenNgcCatalogLoader {
  final String filePath;
  List<OpenNgcData>? _cachedData;

  OpenNgcCatalogLoader(this.filePath);

  /// Load all DSOs from the catalog
  Future<List<OpenNgcData>> loadAll() async {
    if (_cachedData != null) return _cachedData!;

    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('DSO catalog not found', filePath);
    }

    final lines = await file.readAsLines();
    final dsos = <OpenNgcData>[];
    var malformedLines = 0;

    // Skip header line
    for (var i = 1; i < lines.length; i++) {
      try {
        final dso = OpenNgcData.fromCsvLine(lines[i]);
        // Skip non-existent and duplicate entries
        if (dso.type != 'NonEx' && dso.type != 'Dup') {
          dsos.add(dso);
        }
      } catch (e) {
        // Skip malformed lines but count them
        malformedLines++;
      }
    }

    if (malformedLines > 0) {
      developer.log(
        '[Catalog] DSOCatalogLoader: Skipped $malformedLines malformed lines',
        name: 'CatalogManager',
        level: 900,
      );
    }

    _cachedData = dsos;
    return dsos;
  }

  /// Load DSOs up to a magnitude limit
  Future<List<OpenNgcData>> loadByMagnitude(double maxMagnitude) async {
    final all = await loadAll();
    return all.where((d) => (d.magnitude ?? 99) <= maxMagnitude).toList();
  }

  /// Load only Messier objects
  Future<List<OpenNgcData>> loadMessier() async {
    final all = await loadAll();
    return all.where((d) => d.messier != null).toList();
  }

  /// Load DSOs by type
  Future<List<OpenNgcData>> loadByType(String type) async {
    final all = await loadAll();
    return all.where((d) => d.type == type).toList();
  }

  /// Search DSOs by name
  Future<List<OpenNgcData>> search(String query) async {
    final all = await loadAll();
    final q = query.toLowerCase();
    final normalizedQuery = _normalizeCatalogSearchText(query);
    return all.where((d) {
      return _catalogTextMatches(d.name, q, normalizedQuery) ||
          _catalogTextMatches(d.displayName, q, normalizedQuery) ||
          (d.messier != null &&
              _catalogTextMatches(d.messier!, q, normalizedQuery)) ||
          (d.ngcId != null &&
              _catalogTextMatches(d.ngcId!, q, normalizedQuery)) ||
          (d.commonNames != null &&
              _catalogTextMatches(d.commonNames!, q, normalizedQuery));
    }).toList();
  }

  /// Find a DSO by NGC/IC name
  Future<OpenNgcData?> findByName(String name) async {
    final all = await loadAll();
    final normalizedName = name.toUpperCase().replaceAll(' ', '');
    return all
        .where(
          (d) => d.name.toUpperCase().replaceAll(' ', '') == normalizedName,
        )
        .firstOrNull;
  }

  /// Get DSO count
  Future<int> get count async {
    final all = await loadAll();
    return all.length;
  }

  /// Search for DSOs near a given RA/Dec position
  /// Returns objects within radiusDegrees of the specified coordinates
  Future<List<OpenNgcData>> searchNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    final all = await loadAll();

    return all.where((dso) {
        // Apply magnitude filter first (cheaper check)
        if (maxMagnitude != null && (dso.magnitude ?? 99) > maxMagnitude) {
          return false;
        }

        // Calculate angular distance
        final distance = AstronomyCalculations.angularSeparation(
          ra1Deg: ra,
          dec1Deg: dec,
          ra2Deg: dso.ra,
          dec2Deg: dso.dec,
        );
        return distance <= radiusDegrees;
      }).toList()
      // Sort by magnitude (brightest first)
      ..sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));
  }

  /// Clear cache
  void clearCache() {
    _cachedData = null;
  }
}
