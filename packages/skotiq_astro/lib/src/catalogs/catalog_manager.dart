import 'dart:async';
import 'dart:developer' as developer;

import '../celestial_object.dart';
import '../coordinate_system.dart';
import 'catalog_installer.dart';
import 'catalog_name_search.dart';
import 'open_ngc_catalog.dart';
import 'sky_catalog.dart';
import 'star_catalog.dart';

/// The installed catalogs of this process: the files ([CatalogInstaller]) and
/// the one parsed copy of each that every consumer reads (planetarium, name
/// search, annotation, planning).
class CatalogManager extends CatalogInstaller {
  static CatalogManager? _instance;
  static CatalogManager get instance => _instance ??= CatalogManager._();

  CatalogManager._();

  HygStarCatalog? _stars;
  OpenNgcDsoCatalog? _dsos;
  final _changes = StreamController<SkyCatalog>.broadcast();

  /// Fires after a catalog's file was installed, replaced or removed. The
  /// readers below have already been replaced when it does.
  Stream<SkyCatalog> get changes => _changes.stream;

  /// The star catalog reader for the installed file.
  HygStarCatalog get stars =>
      _stars ??= HygStarCatalog(_pathOrNone(SkyCatalog.stars));

  /// The deep-sky catalog reader for the installed file.
  OpenNgcDsoCatalog get dsos =>
      _dsos ??= OpenNgcDsoCatalog(_pathOrNone(SkyCatalog.dso));

  /// Empty before [initialize]: loading from a reader with no path throws,
  /// without touching the disk.
  String _pathOrNone(SkyCatalog catalog) =>
      isInitialized ? pathOf(catalog) : '';

  @override
  Future<void> initialize(String catalogDirectory) async {
    await super.initialize(catalogDirectory);
    SkyCatalog.values.forEach(catalogChanged);
    // Parse both catalogs now, off this isolate, so the first search or sky
    // view finds them ready.
    unawaited(_prewarm());
  }

  Future<void> _prewarm() async {
    try {
      await Future.wait([dsos.load(), stars.load()]);
    } catch (e) {
      developer.log(
        '[Catalog] pre-warm failed: $e',
        name: 'CatalogManager',
        level: 800,
      );
    }
  }

  @override
  void catalogChanged(SkyCatalog catalog) {
    switch (catalog) {
      case SkyCatalog.stars:
        _stars = null;
      case SkyCatalog.dso:
        _dsos = null;
      case SkyCatalog.annotation:
        break;
    }
    if (!_changes.isClosed) _changes.add(catalog);
  }

  @override
  void dispose() {
    _changes.close();
    super.dispose();
  }

  /// Search the installed deep-sky and star catalogs by name or designation.
  ///
  /// Deep-sky objects first: every exact match, then up to 20 partial ones.
  /// Then up to 20 stars, exact matches first. Within each group the brighter
  /// object comes first. Nothing here touches the disk once the catalogs are
  /// parsed, and the scan yields to the event loop as it goes.
  Future<List<CatalogSearchResult>> search(String text) async {
    if (!isInitialized) return [];
    final query = CatalogNameQuery(text);
    final results = <CatalogSearchResult>[];

    try {
      final catalog = dsos;
      final objects = await catalog.load();
      final (exact, partial) = await _match(query, await catalog.nameKeys());
      for (final i in [...exact, ...partial]) {
        final d = objects[i];
        results.add(
          CatalogSearchResult(
            name: d.name,
            catalogId: d.id,
            ra: d.coordinates.raDegrees,
            dec: d.coordinates.dec,
            type: d.type.displayName,
            magnitude: d.magnitude,
            constellation: d.constellation,
            size: d.sizeString,
          ),
        );
      }
    } catch (e) {
      developer.log(
        '[Catalog] DSO search error: $e',
        name: 'CatalogManager',
        level: 900,
      );
    }

    final catalog = stars;
    final objects = await catalog.load();
    // The built-in bright-star list is for drawing a sky, not a catalog to
    // search: its name keys are empty.
    final (exact, partial) = await _match(query, await catalog.nameKeys());
    for (final i in [...exact, ...partial].take(20)) {
      final s = objects[i];
      results.add(
        CatalogSearchResult(
          name: s.name,
          catalogId: s.id,
          ra: s.coordinates.raDegrees,
          dec: s.coordinates.dec,
          type: 'Star',
          magnitude: s.magnitude,
          constellation: s.constellation,
        ),
      );
    }
    return results;
  }

  /// Indices of the objects whose names match [query]: every exact match and
  /// the first 20 partial ones, in catalog (brightest first) order.
  static Future<(List<int> exact, List<int> partial)> _match(
    CatalogNameQuery query,
    CatalogNameKeys keys,
  ) async {
    const partialLimit = 20;
    // About 2 ms of matching between yields, so a search typed into a field
    // never holds a frame.
    const slice = 16384;
    final exact = <int>[];
    final partial = <int>[];
    final count = keys.lower.length;
    for (var start = 0; start < count; start += slice) {
      if (start > 0) await Future<void>.delayed(Duration.zero);
      final end = start + slice < count ? start + slice : count;
      for (var i = start; i < end; i++) {
        if (!query.matches(keys, i)) continue;
        if (query.equals(keys, i)) {
          exact.add(i);
        } else if (partial.length < partialLimit) {
          partial.add(i);
        }
      }
    }
    return (exact, partial);
  }

  /// Installed deep-sky objects within [radiusDegrees] of ([ra], [dec]), both
  /// in degrees, brightest first. Empty when the catalog is not installed.
  Future<List<DeepSkyObject>> searchDsoNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    if (!isInitialized) return [];
    return dsos.near(
      raDegrees: ra,
      decDegrees: dec,
      radiusDegrees: radiusDegrees,
      maxMagnitude: maxMagnitude,
    );
  }

  /// Installed stars within [radiusDegrees] of ([ra], [dec]), both in
  /// degrees, brightest first. Empty when the catalog is not installed (the
  /// built-in bright-star list is for drawing a sky, not for identifying
  /// what is in a frame).
  Future<List<Star>> searchStarsNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    if (!isInitialized) return [];
    final catalog = stars;
    final found = await catalog.getStarsNear(
      CelestialCoordinate(ra: ra / 15.0, dec: dec),
      radiusDegrees,
      maxMagnitude: maxMagnitude,
    );
    return catalog.isUsingFallback ? [] : found;
  }
}
