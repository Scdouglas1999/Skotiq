import 'dart:developer' as developer;
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';
import 'catalog.dart';
import 'catalog_manager.dart';
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

/// Star catalog that loads from the HYG database file
///
/// The HYG database contains ~120,000 stars compiled from:
/// - Hipparcos Catalog (high precision astrometry)
/// - Yale Bright Star Catalog (bright stars with names)
/// - Gliese Catalog of Nearby Stars
class HygStarCatalog extends Catalog<Star> {
  final String? catalogPath;
  final double magnitudeLimit;

  List<Star>? _cachedStars;
  Future<List<Star>>? _inFlight;
  StarCatalogLoadOutcome _outcome = StarCatalogLoadOutcome.notLoaded;
  Object? _loadError;

  /// Create a star catalog
  ///
  /// [catalogPath] - Path to the HYG CSV file, or null to use CatalogManager
  /// [magnitudeLimit] - Maximum magnitude to load (fainter stars have higher values)
  HygStarCatalog({this.catalogPath, this.magnitudeLimit = 15.0});

  @override
  String get name => 'HYG Database';

  /// Check if catalog data is available
  Future<bool> get isAvailable async {
    final path = catalogPath ?? CatalogManager.instance.starCatalogPath;
    return File(path).exists();
  }

  /// Get the number of loaded stars
  int get starCount => _cachedStars?.length ?? 0;

  /// How the last [loadObjects] resolved.
  StarCatalogLoadOutcome get loadOutcome => _outcome;

  /// The error that made [loadOutcome] [StarCatalogLoadOutcome.parseFailed],
  /// for surfaces that can show the user why their catalog was rejected.
  Object? get loadError => _loadError;

  /// Whether the last [loadObjects] served the built-in [_fallbackBrightStars]
  /// list instead of a real catalog.
  ///
  /// That list is a handful of naked-eye stars — enough to prove the renderer
  /// works, nowhere near a usable sky — so the UI must say so rather than let
  /// it pass for the real catalog. True for both failing outcomes; read
  /// [loadOutcome] to tell "not installed" from "will not parse".
  bool get isUsingFallback =>
      _outcome == StarCatalogLoadOutcome.fileMissing ||
      _outcome == StarCatalogLoadOutcome.parseFailed;

  /// Number of stars in the built-in fallback list.
  static int get fallbackStarCount => _fallbackBrightStars.length;

  @override
  Future<List<Star>> loadObjects() async {
    final cached = _cachedStars;
    if (cached != null) return cached;
    // One shared future so concurrent callers cannot race the cache.
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final load = _load();
    _inFlight = load;
    try {
      return await load;
    } finally {
      _inFlight = null;
    }
  }

  Future<List<Star>> _load() async {
    final path = catalogPath ?? CatalogManager.instance.starCatalogPath;
    final file = File(path);

    if (!await file.exists()) {
      _outcome = StarCatalogLoadOutcome.fileMissing;
      _loadError = null;
      return _cachedStars = _fallbackBrightStars;
    }

    try {
      final stars = await compute(
        _loadStarsInIsolate,
        _LoadStarsArgs(path, magnitudeLimit),
      );
      _outcome = StarCatalogLoadOutcome.loaded;
      _loadError = null;
      return _cachedStars = stars;
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
      return _cachedStars = _fallbackBrightStars;
    }
  }

  @override
  Future<Star?> findById(String id) async {
    final stars = await loadObjects();
    final normalizedId = id.toUpperCase().replaceAll(' ', '');

    return stars.where((s) {
      if (s.id.toUpperCase().replaceAll(' ', '') == normalizedId) return true;
      return s.catalogIds.any(
        (c) => c.toUpperCase().replaceAll(' ', '') == normalizedId,
      );
    }).firstOrNull;
  }

  @override
  Future<List<Star>> search(String query) async {
    final q = query.toLowerCase();
    final stars = await loadObjects();

    return stars
        .where(
          (s) =>
              s.name.toLowerCase().contains(q) ||
              s.id.toLowerCase().contains(q) ||
              (s.constellation?.toLowerCase().contains(q) ?? false) ||
              s.catalogIds.any((c) => c.toLowerCase().contains(q)),
        )
        .toList();
  }

  /// Get stars within [radiusDegrees] of [center] (cone search).
  ///
  /// [center] is a [CelestialCoordinate], so its RA is HOURS; the radius is
  /// degrees. Both sides of the comparison are taken to degrees, with the RA
  /// separation narrowed by cos(dec) and wrapped across 0h/24h, so the cone is
  /// a real angular cone rather than a rectangle in mixed units.
  Future<List<Star>> getStarsNear(
    CelestialCoordinate center,
    double radiusDegrees, {
    double? maxMagnitude,
  }) async {
    final stars = await loadObjects();
    final cosDec = math.cos(center.decRadians).abs().clamp(0.05, 1.0);
    final radiusSq = radiusDegrees * radiusDegrees;

    return stars.where((s) {
      if (maxMagnitude != null && (s.magnitude ?? 99) > maxMagnitude) {
        return false;
      }

      var dRaDeg = (s.coordinates.raDegrees - center.raDegrees).abs();
      if (dRaDeg > 180) dRaDeg = 360 - dRaDeg;
      final dxDeg = dRaDeg * cosDec;
      final dyDeg = s.coordinates.dec - center.dec;

      return dxDeg * dxDeg + dyDeg * dyDeg <= radiusSq;
    }).toList();
  }

  /// Clear the cache, so the next [loadObjects] re-reads the catalog file.
  void clearCache() {
    _cachedStars = null;
    _outcome = StarCatalogLoadOutcome.notLoaded;
    _loadError = null;
  }
}

class _LoadStarsArgs {
  final String path;
  final double magnitudeLimit;

  _LoadStarsArgs(this.path, this.magnitudeLimit);
}

/// One parsed HYG row: the [Star] plus the multiple-star bookkeeping that
/// [_nameComponentStars] needs and [Star] has no field for.
///
/// [named] is false when the row carried no proper name, Bayer letter or
/// Flamsteed number, so the star's name is currently just its catalogue id.
typedef _HygRow = ({
  Star star,
  int hygId,
  int comp,
  int compPrimary,
  bool named,
});
