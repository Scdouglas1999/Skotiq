import 'dart:developer' as developer;
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import '../astronomy/astronomy_calculations.dart';
import '../util/csv_line.dart';
import '../util/isolate_run.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';
import 'catalog_name_search.dart';
import 'constellation_names.dart';

part 'star_catalog/hyg_parser.dart';
part 'star_catalog/constellation_genitives.dart';
part 'star_catalog/fallback_bright_stars.dart';

/// How the last [HygStarCatalog.loadObjects] resolved.
///
/// The two failing outcomes both serve the built-in bright-star list, but they
/// need different words in front of the user: a missing file is fixed by
/// installing the catalog, a file that will not parse is fixed by replacing a
/// corrupt one.
enum StarCatalogLoadOutcome {
  /// Not loaded yet.
  notLoaded,

  /// The real catalog file was read.
  loaded,

  /// No catalog file is installed.
  fileMissing,

  /// A catalog file exists but could not be read or parsed.
  parseFailed,
}

/// The reader for the HYG star database file (about 120,000 stars compiled
/// from Hipparcos, the Yale Bright Star Catalog and Gliese).
///
/// One instance per installed file, owned by the catalog manager, so the CSV
/// is parsed once (in a background isolate) and every consumer shares the
/// list.
class HygStarCatalog {
  /// Path of the HYG CSV file.
  final String path;

  List<Star>? _stars;
  CatalogNameKeys _nameKeys = CatalogNameKeys.empty;
  Future<List<Star>>? _inFlight;
  StarCatalogLoadOutcome _outcome = StarCatalogLoadOutcome.notLoaded;
  Object? _loadError;

  HygStarCatalog(this.path);

  /// How the last [load] resolved.
  StarCatalogLoadOutcome get loadOutcome => _outcome;

  /// The error that made [loadOutcome] [StarCatalogLoadOutcome.parseFailed],
  /// for surfaces that can show the user why their catalog was rejected.
  Object? get loadError => _loadError;

  /// Whether the last [load] served the built-in [_fallbackBrightStars] list
  /// instead of a real catalog.
  ///
  /// That list is a handful of naked-eye stars: enough to prove the renderer
  /// works, nowhere near a usable sky, so the UI must say so. True for both
  /// failing outcomes; read [loadOutcome] to tell "not installed" from "will
  /// not parse".
  bool get isUsingFallback =>
      _outcome == StarCatalogLoadOutcome.fileMissing ||
      _outcome == StarCatalogLoadOutcome.parseFailed;

  static int get fallbackStarCount => _fallbackBrightStars.length;

  /// Every star in the file, brightest first; the built-in bright-star list
  /// when the file is missing or will not parse.
  Future<List<Star>> load() async {
    final cached = _stars;
    if (cached != null) return cached;
    // One shared future so concurrent callers cannot race the cache.
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  /// Search names parallel to [load]'s list; empty when the fallback list is
  /// being served.
  Future<CatalogNameKeys> nameKeys() async {
    await load();
    return _nameKeys;
  }

  Future<List<Star>> _load() async {
    if (path.isEmpty) {
      throw StateError(
        'CatalogManager not initialized. Call initialize() first.',
      );
    }
    if (!await File(path).exists()) {
      // Not cached: a catalog copied into place later is picked up by the
      // next load.
      _outcome = StarCatalogLoadOutcome.fileMissing;
      _loadError = null;
      return _fallbackBrightStars;
    }

    try {
      final loaded = await runInIsolate(_loadStarsInIsolate, path);
      _outcome = StarCatalogLoadOutcome.loaded;
      _loadError = null;
      _nameKeys = loaded.nameKeys;
      return _stars = loaded.stars;
    } catch (e) {
      // A catalog file that will not parse is a broken install, not an empty
      // sky: serve the built-in list, record why, and cache it so the failing
      // parse is not re-run on every rebuild.
      developer.log(
        '[Catalog] Error loading stars in isolate: $e',
        name: 'StarCatalog',
        level: 1000,
        error: e,
      );
      _outcome = StarCatalogLoadOutcome.parseFailed;
      _loadError = e;
      return _stars = _fallbackBrightStars;
    }
  }

  /// Stars no fainter than [maxMagnitude], brightest first.
  Future<List<Star>> brighterThan(double maxMagnitude) async {
    final stars = await load();
    // The list is magnitude-sorted, so this is a prefix.
    var lo = 0, hi = stars.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if ((stars[mid].magnitude ?? 99) <= maxMagnitude) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == stars.length ? stars : stars.sublist(0, lo);
  }

  /// Stars within [radiusDegrees] of [center] on the sky, brightest first.
  /// [center]'s RA is hours, as in every [CelestialCoordinate].
  Future<List<Star>> getStarsNear(
    CelestialCoordinate center,
    double radiusDegrees, {
    double? maxMagnitude,
  }) async {
    final stars = await load();
    final sorted = _outcome == StarCatalogLoadOutcome.loaded;
    final centerRaDeg = center.raDegrees;
    final found = <Star>[];
    for (final s in stars) {
      if (maxMagnitude != null && (s.magnitude ?? 99) > maxMagnitude) {
        // The parsed catalog is magnitude-sorted: nothing after this star is
        // bright enough. The fallback list is in no particular order.
        if (sorted) break;
        continue;
      }
      if ((s.coordinates.dec - center.dec).abs() > radiusDegrees) continue;
      final separation = AstronomyCalculations.angularSeparation(
        ra1Deg: centerRaDeg,
        dec1Deg: center.dec,
        ra2Deg: s.coordinates.raDegrees,
        dec2Deg: s.coordinates.dec,
      );
      if (separation <= radiusDegrees) found.add(s);
    }
    return found;
  }
}

/// One parsed HYG row: the [Star] plus the multiple-star bookkeeping that
/// [_nameComponentStars] needs and [Star] has no field for.
///
/// [named] is false when the row carried no proper name, Bayer letter or
/// Flamsteed number, so the star's name is currently just its catalogue id.
/// [proper] is true when the name is the row's proper name ("Vega").
typedef _HygRow = ({
  Star star,
  int hygId,
  int comp,
  int compPrimary,
  bool named,
  bool proper,
});
