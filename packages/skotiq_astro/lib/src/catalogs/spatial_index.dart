import 'dart:math' as math;
import '../celestial_object.dart';
import '../coordinate_system.dart';

/// Grid-based spatial index for fast viewport queries
///
/// Divides the celestial sphere into cells for efficient culling.
/// Instead of iterating through all 120k+ objects per frame,
/// we only query cells that overlap the current viewport.
class CelestialSpatialIndex<T extends CelestialObject> {
  /// Number of cells along the RA axis (0-24 hours)
  static const int raCells = 24;

  /// Number of cells along the Dec axis (-90 to +90 degrees)
  static const int decCells = 18;

  /// Grid storage: [raCell][decCell] -> list of objects.
  ///
  /// Built LAZILY on first cell query ([queryViewport]); the wide-field
  /// magnitude walk ([queryBrightestInViewport]) doesn't need it, so a
  /// freshly-loaded index serving the default wide view never pays the grid
  /// build cost on the UI thread at app open. Rebuilt on the next query after
  /// the object set changes.
  List<List<List<T>>>? _grid;

  /// All objects stored in the index
  final List<T> _allObjects = [];

  /// Lazily-built magnitude-sorted view (brightest first), used by
  /// [queryBrightestInViewport]. Invalidated whenever the object set changes.
  List<T>? _byMagnitude;

  CelestialSpatialIndex();

  /// Eagerly build the grid off the critical path.
  ///
  /// The grid is normally built lazily on the first cell query
  /// ([queryViewport]). Calling this from a deferred future after the index is
  /// constructed warms the grid so the first zoom past the wide-field threshold
  /// (~12 deg) doesn't pay the build cost on the UI thread mid-gesture.
  void warmGrid() => _ensureGrid();

  /// Build the grid from [_allObjects] on demand.
  void _ensureGrid() {
    if (_grid != null) return;
    final grid = List.generate(
      raCells,
      (_) => List.generate(decCells, (_) => <T>[]),
    );
    for (final obj in _allObjects) {
      grid[_raToCell(obj.coordinates.ra)][_decToCell(obj.coordinates.dec)].add(
        obj,
      );
    }
    _grid = grid;
  }

  /// Clear all objects from the index
  void clear() {
    _grid = null;
    _allObjects.clear();
    _byMagnitude = null;
  }

  /// Add a single object to the index
  void add(T object) {
    _allObjects.add(object);
    _grid = null;
    _byMagnitude = null;
  }

  /// Add multiple objects to the index
  void addAll(List<T> objects) {
    _allObjects.addAll(objects);
    _grid = null;
    _byMagnitude = null;
  }

  /// Add objects that are ALREADY sorted ascending by magnitude (brightest
  /// first), priming the magnitude-sorted view without an on-UI-thread re-sort.
  ///
  /// The loader isolate sorts the catalog once (off the UI thread), so the first
  /// [queryBrightestInViewport] at app open doesn't sort 100k+ objects on the UI
  /// thread (a measurable first-open hitch). The grid stays lazy.
  void addAllPreSortedByMagnitude(List<T> objectsBrightestFirst) {
    _allObjects.addAll(objectsBrightestFirst);
    _grid = null;
    _byMagnitude = objectsBrightestFirst;
  }

  /// Magnitude-walk length beyond which it is worth consulting the grid to see
  /// whether the cell query would touch fewer objects.
  ///
  /// Below this the walk is short enough that the comparison is not worth the
  /// cell-length reads, and the grid stays unbuilt: a freshly-loaded index
  /// serving the default wide view never pays the grid build on the UI thread.
  static const int _gridConsultThreshold = 8000;

  /// How much cheaper the grid path must look before it is chosen, to pay for
  /// its sort of the gathered candidates (the walk emits in magnitude order).
  static const int _gridPreferenceFactor = 3;

  /// Returns up to [maxResults] of the BRIGHTEST objects with magnitude
  /// `<= maxMagnitude` that fall within the viewport region (same generous
  /// 1.5×-FOV bounds as [queryViewport]), brightest-first.
  ///
  /// This walks a magnitude-sorted view and stops as soon as [maxResults] are
  /// collected or the magnitude limit is passed. At wide fields — where the
  /// region can contain tens of thousands of stars but the renderer only draws
  /// the brightest few thousand — this avoids gathering and full-sorting the
  /// whole region every frame (the dominant per-frame pan cost). The result is
  /// identical to taking the brightest [maxResults] of [queryViewportFiltered].
  List<T> queryBrightestInViewport(
    double centerRA,
    double centerDec,
    double fovDegrees, {
    required double maxMagnitude,
    required int maxResults,
    double aspectRatio = 1.0,
  }) {
    if (maxResults <= 0 || _allObjects.isEmpty) return const [];

    var sorted = _byMagnitude;
    if (sorted == null) {
      sorted = List<T>.of(_allObjects)
        ..sort((a, b) => (a.magnitude ?? 99.0).compareTo(b.magnitude ?? 99.0));
      _byMagnitude = sorted;
    }

    // Pick the cheaper strategy by how many objects each would actually touch,
    // rather than by a fixed FOV threshold.
    //
    // The magnitude walk scans the magnitude-sorted list and stops once it
    // passes [maxMagnitude], so it touches exactly the number of objects at or
    // brighter than the limit. That is cheap while the limit bites — but the
    // FOV-adaptive limit reaches the catalogue's own depth at every field below
    // ~30 deg, and then nothing terminates the walk and it scans the whole
    // catalogue on every pan and zoom frame. A fixed FOV threshold cannot see
    // that, which is why the choice is made on objects touched.
    //
    // The grid path instead touches only the objects in the cells overlapping
    // the query region, so it scales with sky area.
    final magWalkCandidates = _countAtOrBrighterThan(sorted, maxMagnitude);
    if (magWalkCandidates > _gridConsultThreshold) {
      _ensureGrid();
      final gridCandidates = _countViewportCellObjects(
        centerRA,
        centerDec,
        fovDegrees,
        aspectRatio: aspectRatio,
      );
      if (gridCandidates * _gridPreferenceFactor < magWalkCandidates) {
        final candidates = queryViewport(
          centerRA,
          centerDec,
          fovDegrees,
          aspectRatio: aspectRatio,
        );
        final filtered = <T>[];
        for (final o in candidates) {
          if ((o.magnitude ?? 99.0) <= maxMagnitude) filtered.add(o);
        }
        filtered.sort(
          (a, b) => (a.magnitude ?? 99.0).compareTo(b.magnitude ?? 99.0),
        );
        return filtered.length > maxResults
            ? filtered.sublist(0, maxResults)
            : filtered;
      }
    }

    // Region bounds match queryViewport (1.5x FOV margin, aspect-corrected).
    final (raFov, decFov) = _extents(fovDegrees, aspectRatio);
    final decRangeHalf = decFov / 2;
    final minDec = (centerDec - decRangeHalf).clamp(-90.0, 90.0);
    final maxDec = (centerDec + decRangeHalf).clamp(-90.0, 90.0);
    final cosDec = math.cos(centerDec.abs() * math.pi / 180);
    final raRangeHalf = cosDec > 0.1
        ? (raFov / 15 / cosDec).clamp(0.0, 12.0) / 2
        : 12.0;
    final raWrapsWholeSky = raRangeHalf >= 12.0;

    final results = <T>[];
    for (final obj in sorted) {
      final mag = obj.magnitude ?? 99.0;
      if (mag > maxMagnitude) break; // remaining are fainter — done
      final c = obj.coordinates;
      if (c.dec < minDec || c.dec > maxDec) continue;
      if (!raWrapsWholeSky) {
        var dRa = (c.ra - centerRA).abs();
        if (dRa > 12) dRa = 24 - dRa; // RA wraparound at 0h/24h
        if (dRa > raRangeHalf) continue;
      }
      results.add(obj);
      if (results.length >= maxResults) break;
    }
    return results;
  }

  /// Number of entries in the magnitude-sorted [sorted] list at or brighter
  /// than [maxMagnitude] — i.e. exactly how far the magnitude walk would run.
  /// Binary search, so this costs ~17 comparisons on a 120k catalogue.
  static int _countAtOrBrighterThan<E extends CelestialObject>(
    List<E> sorted,
    double maxMagnitude,
  ) {
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if ((sorted[mid].magnitude ?? 99.0) <= maxMagnitude) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Total objects held by the grid cells overlapping the query region — what
  /// the cell path would gather, without gathering it. Requires the grid.
  int _countViewportCellObjects(
    double centerRA,
    double centerDec,
    double fovDegrees, {
    double aspectRatio = 1.0,
  }) {
    final grid = _grid;
    if (grid == null) return _allObjects.length;

    // Same region bounds queryViewport uses (1.5x FOV margin, aspect-corrected).
    final (raFov, decFov) = _extents(fovDegrees, aspectRatio);
    final decRangeHalf = decFov / 2;
    final minDec = (centerDec - decRangeHalf).clamp(-90.0, 90.0);
    final maxDec = (centerDec + decRangeHalf).clamp(-90.0, 90.0);
    final cosDec = math.cos(centerDec.abs() * math.pi / 180);
    final raRangeHours = cosDec > 0.1
        ? (raFov / 15 / cosDec).clamp(0.0, 12.0)
        : 12.0;
    final minRA = centerRA - raRangeHours / 2;
    final maxRA = centerRA + raRangeHours / 2;

    final startDecCell = _decToCell(minDec);
    final endDecCell = _decToCell(maxDec);

    var total = 0;
    void countCellRange(int startCell, int endCell) {
      for (var r = startCell; r <= endCell; r++) {
        for (var d = startDecCell; d <= endDecCell; d++) {
          total += grid[r][d].length;
        }
      }
    }

    final startRaCell = _raToCell(minRA);
    final endRaCell = _raToCell(maxRA);
    if (maxRA > 24.0 || minRA < 0.0) {
      // Region crosses the 0h/24h seam: two contiguous cell runs.
      countCellRange(startRaCell, raCells - 1);
      countCellRange(0, endRaCell);
    } else {
      countCellRange(startRaCell, endRaCell);
    }
    return total;
  }

  /// Angular extents (degrees) the query region must span, given the view's
  /// short-axis [fovDegrees] and the canvas [aspectRatio] (width / height).
  ///
  /// [fovDegrees] describes the SHORT axis of the canvas, so the long axis
  /// subtends that much again multiplied by the aspect ratio: the region must
  /// span the view's own extents, or a wide window is served star data for a
  /// square patch and objects pop in and out at the region boundary while
  /// panning. The 1.5x factor is the margin that keeps objects whose glow or
  /// label spills in from just outside the frame.
  static (double raFov, double decFov) _extents(
    double fovDegrees,
    double aspectRatio,
  ) {
    final a = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : 1.0;
    final wide = a >= 1.0 ? a : 1.0;
    final tall = a < 1.0 ? 1.0 / a : 1.0;
    return (fovDegrees * 1.5 * wide, fovDegrees * 1.5 * tall);
  }

  /// Get all objects in the index
  List<T> get all => _allObjects;

  /// Get total number of indexed objects
  int get length => _allObjects.length;

  /// Query objects within a viewport defined by center and field of view
  ///
  /// [centerRA] - Right ascension of viewport center in hours (0-24)
  /// [centerDec] - Declination of viewport center in degrees (-90 to +90)
  /// [fovDegrees] - Field of view in degrees
  /// [maxResults] - Optional limit on number of results
  List<T> queryViewport(
    double centerRA,
    double centerDec,
    double fovDegrees, {
    int? maxResults,
    double aspectRatio = 1.0,
  }) {
    _ensureGrid();
    // Calculate the RA and Dec ranges that might be visible.
    // Use a generous margin (1.5x FOV) to avoid clipping objects at viewport edges
    // — the stereographic projection shows objects beyond the nominal FOV circle.
    final (raFov, decFov) = _extents(fovDegrees, aspectRatio);
    final decRangeHalf = decFov / 2;
    final minDec = (centerDec - decRangeHalf).clamp(-90.0, 90.0);
    final maxDec = (centerDec + decRangeHalf).clamp(-90.0, 90.0);

    // RA range expands near poles due to spherical geometry
    // At dec=90, all RA values are at the same point
    final cosDec = math.cos(centerDec.abs() * math.pi / 180);
    final raRangeHours = cosDec > 0.1
        ? (raFov / 15 / cosDec).clamp(0.0, 12.0)
        : 12.0;

    final minRA = centerRA - raRangeHours / 2;
    final maxRA = centerRA + raRangeHours / 2;

    final results = <T>[];

    // Calculate cell ranges
    final startDecCell = _decToCell(minDec);
    final endDecCell = _decToCell(maxDec);

    // Handle RA wraparound (e.g., viewport spanning 23h to 1h)
    // Iterate over a contiguous range of cell indices (inclusive).
    void addCellRange(int startCell, int endCell) {
      for (var r = startCell; r <= endCell; r++) {
        for (var d = startDecCell; d <= endDecCell; d++) {
          if (maxResults != null && results.length >= maxResults) return;
          results.addAll(_grid![r][d]);
        }
      }
    }

    final startRaCell = _raToCell(minRA);
    final endRaCell = _raToCell(maxRA);

    if (maxRA > 24.0 || minRA < 0.0) {
      // Wraparound case: the RA range crosses the 0h/24h boundary.
      // We need to query two contiguous cell ranges:
      //   1) From the start cell up to the last cell (raCells - 1)
      //   2) From cell 0 up to the end cell
      // Because _raToCell normalizes into [0, raCells-1], after
      // wraparound startRaCell > endRaCell.
      if (startRaCell <= endRaCell) {
        // Edge case: the wraparound range is so wide it covers all cells,
        // or rounding made start <= end. Query the full range.
        addCellRange(startRaCell, endRaCell);
      } else {
        // Normal wraparound: startRaCell is in the high-RA region,
        // endRaCell is in the low-RA region.
        addCellRange(startRaCell, raCells - 1);
        addCellRange(0, endRaCell);
      }
    } else {
      addCellRange(startRaCell, endRaCell);
    }

    // Apply maxResults limit if specified
    if (maxResults != null && results.length > maxResults) {
      return results.sublist(0, maxResults);
    }

    return results;
  }

  /// Query objects within a cone search (centered at coordinates with radius)
  ///
  /// More accurate than queryViewport but slightly slower
  List<T> queryCone(
    CelestialCoordinate center,
    double radiusDegrees, {
    int? maxResults,
  }) {
    // First get candidates from spatial index
    final candidates = queryViewport(
      center.ra,
      center.dec,
      radiusDegrees * 2,
      maxResults: maxResults != null ? maxResults * 2 : null,
    );

    // Filter by actual angular distance
    final results = <T>[];
    for (final obj in candidates) {
      if (maxResults != null && results.length >= maxResults) break;
      final distance = center.separationDegrees(obj.coordinates);
      if (distance <= radiusDegrees) {
        results.add(obj);
      }
    }

    return results;
  }

  /// Query objects within a magnitude range
  List<T> queryByMagnitude(double maxMagnitude, {int? maxResults}) {
    final results = <T>[];
    for (final obj in _allObjects) {
      if (maxResults != null && results.length >= maxResults) break;
      final mag = obj.magnitude;
      if (mag != null && mag <= maxMagnitude) {
        results.add(obj);
      }
    }
    return results;
  }

  /// Convert RA (hours, 0-24) to cell index
  int _raToCell(double ra) {
    final normalizedRA = ra < 0 ? ra + 24 : (ra >= 24 ? ra - 24 : ra);
    return (normalizedRA / 24 * raCells).floor().clamp(0, raCells - 1);
  }

  /// Convert Dec (degrees, -90 to +90) to cell index
  int _decToCell(double dec) {
    return ((dec + 90) / 180 * decCells).floor().clamp(0, decCells - 1);
  }
}

/// Specialized spatial index for stars with magnitude-based filtering
class StarSpatialIndex extends CelestialSpatialIndex<Star> {
  /// Query stars within viewport, filtered by magnitude
  List<Star> queryViewportFiltered(
    double centerRA,
    double centerDec,
    double fovDegrees, {
    required double maxMagnitude,
    int? maxResults,
  }) {
    final candidates = queryViewport(centerRA, centerDec, fovDegrees);

    final results = <Star>[];
    for (final star in candidates) {
      if (maxResults != null && results.length >= maxResults) break;
      final mag = star.magnitude ?? 99;
      if (mag <= maxMagnitude) {
        results.add(star);
      }
    }

    // Sort by magnitude (brightest first) for consistent rendering
    results.sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));

    return results;
  }
}

/// Specialized spatial index for DSOs with magnitude and size filtering
class DsoSpatialIndex extends CelestialSpatialIndex<DeepSkyObject> {
  /// Query DSOs within viewport, filtered by magnitude
  List<DeepSkyObject> queryViewportFiltered(
    double centerRA,
    double centerDec,
    double fovDegrees, {
    required double maxMagnitude,
    int? maxResults,
  }) {
    final candidates = queryViewport(centerRA, centerDec, fovDegrees);

    final results = <DeepSkyObject>[];
    for (final dso in candidates) {
      if (maxResults != null && results.length >= maxResults) break;
      final mag = dso.magnitude ?? 99;
      if (mag <= maxMagnitude) {
        results.add(dso);
      }
    }

    // Sort by magnitude (brightest first)
    results.sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));

    return results;
  }

  /// Query DSOs by type
  List<DeepSkyObject> queryByType(DsoType type, {int? maxResults}) {
    final results = <DeepSkyObject>[];
    for (final dso in all) {
      if (maxResults != null && results.length >= maxResults) break;
      if (dso.type == type) {
        results.add(dso);
      }
    }
    return results;
  }
}
