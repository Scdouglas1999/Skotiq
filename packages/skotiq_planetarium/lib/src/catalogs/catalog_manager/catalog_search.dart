part of '../catalog_manager.dart';

extension CatalogManagerSearch on CatalogManager {
  Future<List<CatalogSearchResult>> _searchCatalogs(String query) async {
    if (!isInitialized) return [];

    final results = <CatalogSearchResult>[];
    final q = query.toLowerCase();
    final normalizedQuery = _normalizeCatalogSearchText(query);

    // Search DSO catalog if installed
    final dsoStatus = await getDsoCatalogStatus();
    if (dsoStatus.isInstalled) {
      try {
        final loader = _getDsoLoader(dsoStatus.installedPath!);
        final dsos = await loader.search(query);

        // Prioritize exact matches
        final exactMatches = dsos
            .where(
              (d) =>
                  _catalogTextEquals(d.name, q, normalizedQuery) ||
                  _catalogTextEquals(d.displayName, q, normalizedQuery) ||
                  (d.messier != null &&
                      _catalogTextEquals(d.messier!, q, normalizedQuery)) ||
                  (d.ngcId != null &&
                      _catalogTextEquals(d.ngcId!, q, normalizedQuery)),
            )
            .toList();

        final partialMatches = dsos
            .where((d) => !exactMatches.contains(d))
            .take(20)
            .toList(); // Limit partials

        results.addAll(
          exactMatches.map(
            (d) => CatalogSearchResult(
              name: d.displayName,
              catalogId: d.name, // NGC/IC ID
              ra: d.ra,
              dec: d.dec,
              type: d.typeDescription,
              magnitude: d.magnitude,
              constellation: d.constellation,
              size: d.sizeString,
            ),
          ),
        );

        results.addAll(
          partialMatches.map(
            (d) => CatalogSearchResult(
              name: d.displayName,
              catalogId: d.name,
              ra: d.ra,
              dec: d.dec,
              type: d.typeDescription,
              magnitude: d.magnitude,
              constellation: d.constellation,
              size: d.sizeString,
            ),
          ),
        );
      } catch (e) {
        developer.log(
          '[Catalog] DSO search error: $e',
          name: 'CatalogManager',
          level: 900,
        );
      }
    }

    // Search Star catalog if installed
    final starStatus = await getStarCatalogStatus();
    if (starStatus.isInstalled) {
      try {
        final loader = _getStarLoader(starStatus.installedPath!);
        final stars = await loader.search(query);

        final exactMatches = stars
            .where(
              (s) =>
                  _catalogTextEquals(s.name, q, normalizedQuery) ||
                  _catalogTextEquals(s.catalogId, q, normalizedQuery) ||
                  (s.hipId != null &&
                      _catalogTextEquals(
                        'HIP${s.hipId}',
                        q,
                        normalizedQuery,
                      )) ||
                  (s.hdId != null &&
                      _catalogTextEquals('HD${s.hdId}', q, normalizedQuery)),
            )
            .toList();

        final partialMatches = stars
            .where((s) => !exactMatches.contains(s))
            .take(20)
            .toList();

        results.addAll(
          [...exactMatches, ...partialMatches]
              .take(20)
              .map(
                (s) => CatalogSearchResult(
                  name: s.name,
                  catalogId: s.catalogId,
                  ra: s.ra,
                  dec: s.dec,
                  type: 'Star',
                  magnitude: s.magnitude,
                  constellation: s.constellation,
                ),
              ),
        );
      } catch (e) {
        developer.log(
          '[Catalog] Star search error: $e',
          name: 'CatalogManager',
          level: 900,
        );
      }
    }

    return results;
  }

  Future<List<OpenNgcData>> _searchDsoCatalogNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    if (!isInitialized) return [];

    final dsoStatus = await getDsoCatalogStatus();
    if (!dsoStatus.isInstalled) return [];

    try {
      final loader = _getDsoLoader(dsoStatus.installedPath!);
      return await loader.searchNearby(
        ra: ra,
        dec: dec,
        radiusDegrees: radiusDegrees,
        maxMagnitude: maxMagnitude,
      );
    } catch (e) {
      developer.log(
        '[Catalog] DSO searchNearby error: $e',
        name: 'CatalogManager',
        level: 900,
      );
      return [];
    }
  }

  Future<List<HygStarData>> _searchStarCatalogNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    if (!isInitialized) return [];

    final starStatus = await getStarCatalogStatus();
    if (!starStatus.isInstalled) return [];

    try {
      final loader = _getStarLoader(starStatus.installedPath!);
      return await loader.searchNearby(
        ra: ra,
        dec: dec,
        radiusDegrees: radiusDegrees,
        maxMagnitude: maxMagnitude,
      );
    } catch (e) {
      developer.log(
        '[Catalog] Star searchNearby error: $e',
        name: 'CatalogManager',
        level: 900,
      );
      return [];
    }
  }
}
