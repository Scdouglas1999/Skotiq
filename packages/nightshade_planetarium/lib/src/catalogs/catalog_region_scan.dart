/// Region-scoped streaming scans for the large galaxy catalogs.
///
/// GLADE+ carries ~22 million rows and HyperLEDA ~3 million. Answering a
/// half-degree annotation query by loading either of them into memory first
/// froze the app: `File.readAsLines()` materialises every row as a Dart
/// `String` in one list, and the parse loop that follows is synchronous, so
/// once it starts no other microtask on that isolate ever runs again. On the
/// rig that presented as a total UI freeze with a multi-gigabyte working set
/// and a pinned core, with no log output, because the isolate never got back
/// to the code that logs.
///
/// These scans stream the file instead and keep only the rows inside the
/// requested cone, so peak memory is proportional to the answer rather than to
/// the catalog, and they run in a background isolate so the UI isolate is never
/// the one parsing.
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

/// Cone-and-magnitude test for one streaming catalog scan.
///
/// Holds only primitives so it can be sent to a background isolate.
class CatalogRegionFilter {
  /// Cone centre right ascension, degrees.
  final double ra;

  /// Cone centre declination, degrees.
  final double dec;

  /// Cone radius, degrees.
  final double radiusDegrees;

  /// Reject objects fainter than this magnitude. Objects with no magnitude are
  /// treated as magnitude 99 (the convention the catalog loaders already use),
  /// so they are rejected whenever a cutoff is given.
  final double? maxMagnitude;

  /// Backstop against an unbounded answer. A scan that reaches this many
  /// matches stops reading and says so; it exists so a caller that asks for an
  /// absurd radius degrades into a truncated answer instead of an OOM.
  final int maxResults;

  const CatalogRegionFilter({
    required this.ra,
    required this.dec,
    required this.radiusDegrees,
    this.maxMagnitude,
    this.maxResults = defaultMaxResults,
  });

  /// Generous relative to any real field of view (a half-degree cone of GLADE+
  /// holds a few thousand rows at most), so it never truncates a legitimate
  /// annotation query — it only bounds a pathological one.
  static const int defaultMaxResults = 50000;

  /// Squared angular distance in degrees, small-angle approximation with the
  /// RA axis compressed by cos(dec) — the same identity the catalog loaders
  /// used when they filtered an in-memory spatial index.
  double _distanceSquared(double objRa, double objDec) {
    final dRa = _wrappedRaDelta(objRa) * math.cos(dec * math.pi / 180);
    final dDec = objDec - dec;
    return dRa * dRa + dDec * dDec;
  }

  /// RA difference taking the 0h/24h seam into account, so a cone straddling
  /// RA 0 does not silently lose half its objects.
  double _wrappedRaDelta(double objRa) {
    var delta = (objRa - ra) % 360.0;
    if (delta > 180.0) {
      delta -= 360.0;
    } else if (delta < -180.0) {
      delta += 360.0;
    }
    return delta;
  }

  /// Whether this object belongs in the answer.
  bool accepts({
    required double objRa,
    required double objDec,
    required double? magnitude,
  }) {
    if (maxMagnitude != null && (magnitude ?? 99) > maxMagnitude!) {
      return false;
    }
    return _distanceSquared(objRa, objDec) <= radiusDegrees * radiusDegrees;
  }

  /// Distance ordering key, nearest the cone centre first.
  double sortKey(double objRa, double objDec) =>
      _distanceSquared(objRa, objDec);

  /// True angular separation from this cone's centre, degrees.
  ///
  /// The small-angle form above is fine for ranking inside one field but is not
  /// safe for deciding whether one cone encloses another, so containment uses
  /// the spherical identity instead.
  double separationDegrees(double objRa, double objDec) {
    const toRad = math.pi / 180;
    final cosSeparation =
        math.sin(dec * toRad) * math.sin(objDec * toRad) +
        math.cos(dec * toRad) *
            math.cos(objDec * toRad) *
            math.cos((objRa - ra) * toRad);
    return math.acos(cosSeparation.clamp(-1.0, 1.0)) / toRad;
  }

  /// Whether every object `other` could ask for is already inside this cone.
  ///
  /// Used to answer a query from a cached scan instead of re-reading the file.
  /// A cone with a magnitude cut cannot serve a request for something fainter.
  bool encloses(CatalogRegionFilter other) {
    if (maxMagnitude != null &&
        (other.maxMagnitude == null || other.maxMagnitude! > maxMagnitude!)) {
      return false;
    }
    return separationDegrees(other.ra, other.dec) + other.radiusDegrees <=
        radiusDegrees;
  }

  /// A wider, magnitude-blind version of this cone, for caching.
  ///
  /// Scanning slightly wide and without a magnitude cut means the next frame's
  /// cone — the mount has drifted a little, and the pipeline's SNR-based
  /// cutoff moves frame to frame — is still enclosed, so it is answered from
  /// memory rather than by re-reading the catalog. The padded cone is still a
  /// field, not a sky: at a half-degree request this is under two degrees.
  CatalogRegionFilter padded() => CatalogRegionFilter(
    ra: ra,
    dec: dec,
    radiusDegrees: radiusDegrees * 1.5 + 0.1,
    maxResults: maxResults,
  );
}

/// Single-entry memo for a streaming region scan.
///
/// Consecutive annotation queries walk the same field, because the mount is
/// parked on a target. Without this, removing the whole-sky load would trade a
/// freeze for a background re-read of a multi-gigabyte catalog on every frame.
///
/// A truncated scan is never cached: it does not honestly represent its cone.
class CatalogRegionCache<T> {
  CatalogRegionFilter? _cachedCone;
  List<T>? _cachedObjects;

  /// The subset of a cached scan that satisfies `filter`, or null on a miss.
  List<T>? lookup(
    CatalogRegionFilter filter, {
    required ({double ra, double dec}) Function(T object) positionOf,
    required double? Function(T object) magnitudeOf,
  }) {
    final cone = _cachedCone;
    final objects = _cachedObjects;
    if (cone == null || objects == null || !cone.encloses(filter)) {
      return null;
    }

    final narrowed = objects.where((object) {
      final position = positionOf(object);
      return filter.accepts(
        objRa: position.ra,
        objDec: position.dec,
        magnitude: magnitudeOf(object),
      );
    }).toList();
    narrowed.sort((a, b) {
      final pa = positionOf(a);
      final pb = positionOf(b);
      return filter
          .sortKey(pa.ra, pa.dec)
          .compareTo(filter.sortKey(pb.ra, pb.dec));
    });
    return narrowed;
  }

  void store(CatalogRegionFilter cone, CatalogRegionScan<T> scan) {
    if (scan.truncated) {
      return;
    }
    _cachedCone = cone;
    _cachedObjects = scan.objects;
  }

  void clear() {
    _cachedCone = null;
    _cachedObjects = null;
  }
}

/// Outcome of one streaming scan: the rows that matched, plus what the scan had
/// to skip or cut short. The counts are reported rather than logged per row —
/// logging per malformed line across millions of rows is its own stall.
class CatalogRegionScan<T> {
  final List<T> objects;
  final int malformedRows;
  final bool truncated;

  const CatalogRegionScan({
    required this.objects,
    required this.malformedRows,
    required this.truncated,
  });
}

/// Stream `filePath` and keep only the rows `filter` accepts.
///
/// `parse` turns one CSV line into an object or throws; `positionOf` and
/// `magnitudeOf` read back the fields the filter needs. The first line is
/// treated as a header and skipped, matching the catalog files on disk.
///
/// Intended to be called inside `Isolate.run`, which is why it takes plain
/// functions rather than an object with state.
Future<CatalogRegionScan<T>> scanCatalogRegion<T>({
  required String filePath,
  required CatalogRegionFilter filter,
  required T Function(String line) parse,
  required ({double ra, double dec}) Function(T object) positionOf,
  required double? Function(T object) magnitudeOf,
  required String catalogName,
}) async {
  final file = File(filePath);
  if (!await file.exists()) {
    throw FileSystemException('$catalogName catalog not found', filePath);
  }

  final matches = <T>[];
  var malformedRows = 0;
  var truncated = false;
  var lineNumber = 0;

  final lines = file
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  // Consume each decoded chunk synchronously in the worker. Awaiting every
  // row adds millions of stream pause/resume cycles to a full GLADE+ scan.
  await lines.takeWhile((_) => !truncated).forEach((line) {
    lineNumber++;
    if (lineNumber == 1 || line.isEmpty) {
      return;
    }

    final T object;
    try {
      object = parse(line);
    } catch (_) {
      malformedRows++;
      return;
    }

    final position = positionOf(object);
    if (!filter.accepts(
      objRa: position.ra,
      objDec: position.dec,
      magnitude: magnitudeOf(object),
    )) {
      return;
    }

    matches.add(object);
    if (matches.length >= filter.maxResults) {
      truncated = true;
    }
  });

  matches.sort((a, b) {
    final pa = positionOf(a);
    final pb = positionOf(b);
    return filter
        .sortKey(pa.ra, pa.dec)
        .compareTo(filter.sortKey(pb.ra, pb.dec));
  });

  if (malformedRows > 0) {
    developer.log(
      '$catalogName region scan skipped $malformedRows malformed rows',
      name: 'CatalogRegionScan',
      level: 500,
    );
  }
  if (truncated) {
    developer.log(
      '$catalogName region scan stopped at ${filter.maxResults} matches for a '
      '${filter.radiusDegrees}deg cone; the answer is truncated',
      name: 'CatalogRegionScan',
      level: 900,
    );
  }

  return CatalogRegionScan<T>(
    objects: matches,
    malformedRows: malformedRows,
    truncated: truncated,
  );
}
