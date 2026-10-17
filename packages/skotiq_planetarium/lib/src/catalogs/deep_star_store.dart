import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as path;

import '../celestial_object.dart';
import 'deep_star_tile.dart';

/// Read side of the installed deep-star tier: loads NSDT tiles on demand,
/// keeps a small LRU of decoded tiles, and answers brightest-in-viewport
/// queries with the same region semantics as the HYG spatial index.
///
/// Decoded tiles cache their `Star` instances, so repeated queries at the
/// same pose return identical object identities — which the painter's
/// per-pose projection cache relies on.
class DeepStarTileStore {
  /// Directory containing `manifest.json` and the tile files.
  final String directory;

  /// Maximum number of decoded tiles kept in memory. A tile is one
  /// 15 deg x 10 deg cell; a deep-zoom viewport touches a handful, so a small
  /// cap bounds memory while panning stays warm.
  final int maxCachedTiles;

  DeepStarManifest? _manifest;
  final LinkedHashMap<String, List<Star>> _cache = LinkedHashMap();
  final Map<String, Future<List<Star>>> _inFlight = {};

  /// Tiles that exist in the manifest, keyed "ra_dec" for O(1) membership.
  final Map<String, DeepStarManifestTile> _tilesByKey = {};

  DeepStarTileStore({required this.directory, this.maxCachedTiles = 32});

  /// The installed manifest, or null when the tier is not installed.
  DeepStarManifest? get manifest => _manifest;

  /// Number of decoded tiles currently cached (for tests/diagnostics).
  int get cachedTileCount => _cache.length;

  static String _key(int raBand, int decBand) => '${raBand}_$decBand';

  /// Load (or reload) the local manifest. Returns true when a valid
  /// manifest is present.
  Future<bool> loadManifest() async {
    final file = File(path.join(directory, 'manifest.json'));
    if (!await file.exists()) {
      _manifest = null;
      _tilesByKey.clear();
      return false;
    }
    try {
      final manifest = DeepStarManifest.decodeJson(await file.readAsString());
      _manifest = manifest;
      _tilesByKey.clear();
      for (final t in manifest.tiles) {
        _tilesByKey[_key(t.raBand, t.decBand)] = t;
      }
      _cache.clear();
      return true;
    } catch (e) {
      developer.log(
        '[DeepStar] Failed to read manifest: $e',
        name: 'DeepStarTileStore',
        level: 900,
        error: e,
      );
      _manifest = null;
      _tilesByKey.clear();
      return false;
    }
  }

  /// Drop all decoded tiles (e.g. after a re-download).
  void clearCache() => _cache.clear();

  Future<List<Star>> _loadTile(DeepStarManifestTile entry) {
    final key = _key(entry.raBand, entry.decBand);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // re-insert as most recently used
      return Future.value(cached);
    }
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;

    final future = () async {
      try {
        final file = File(path.join(directory, entry.file));
        if (!await file.exists()) return const <Star>[];
        final tile = DeepStarTile.decode(await file.readAsBytes());
        return tile.toStars();
      } catch (e) {
        developer.log(
          '[DeepStar] Failed to load tile ${entry.file}: $e',
          name: 'DeepStarTileStore',
          level: 900,
          error: e,
        );
        return const <Star>[];
      }
    }();
    _inFlight[key] = future;
    return future.then((stars) {
      _inFlight.remove(key);
      _cache[key] = stars;
      while (_cache.length > maxCachedTiles) {
        _cache.remove(_cache.keys.first); // evict least recently used
      }
      return stars;
    });
  }

  /// Returns up to [maxResults] of the brightest deep-tier stars inside the
  /// viewport with `minMagnitude < mag <= maxMagnitude`, brightest first.
  ///
  /// [minMagnitude] is the HYG hand-off: stars at or above the bundled
  /// catalog's depth are excluded so the two tiers never double-draw.
  Future<List<Star>> queryBrightest(
    double centerRaHours,
    double centerDecDeg,
    double fovDegrees, {
    required double maxMagnitude,
    required int maxResults,
    double minMagnitude = double.negativeInfinity,
    double aspectRatio = 1.0,
  }) async {
    if (_manifest == null || maxResults <= 0 || maxMagnitude <= minMagnitude) {
      return const [];
    }

    final region = ViewportRegion.compute(
      centerRaHours,
      centerDecDeg,
      fovDegrees,
      aspectRatio: aspectRatio,
    );
    final keys = DeepStarTileScheme.tilesForViewport(
      centerRaHours,
      centerDecDeg,
      fovDegrees,
    );

    final lists = <List<Star>>[];
    for (final (ra, dec) in keys) {
      final entry = _tilesByKey[_key(ra, dec)];
      if (entry == null || entry.starCount == 0) continue;
      final stars = await _loadTile(entry);
      if (stars.isNotEmpty) lists.add(stars);
    }
    if (lists.isEmpty) return const [];

    // K-way merge across magnitude-sorted tile lists, filtering to the exact
    // region box, until the result cap or the magnitude limit is reached.
    final cursors = List<int>.filled(lists.length, 0);
    final results = <Star>[];
    while (results.length < maxResults) {
      var bestList = -1;
      var bestMag = double.infinity;
      for (var i = 0; i < lists.length; i++) {
        final c = cursors[i];
        if (c >= lists[i].length) continue;
        final mag = lists[i][c].magnitude ?? 99.0;
        if (mag < bestMag) {
          bestMag = mag;
          bestList = i;
        }
      }
      if (bestList < 0 || bestMag > maxMagnitude) break;
      final star = lists[bestList][cursors[bestList]++];
      if (bestMag <= minMagnitude) continue;
      final c = star.coordinates;
      if (!region.contains(c.ra, c.dec)) continue;
      results.add(star);
    }
    return results;
  }
}
