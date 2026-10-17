import 'dart:math' as math;

/// A point being matched, in pixel coordinates.
typedef MatchPoint = ({double x, double y});

/// Greedy nearest-neighbour pairing, bucketed so it does not scan every
/// candidate for every source.
///
/// For each point in [sources] — already in the caller's priority order — this
/// returns the index of the nearest still-unclaimed point in [candidates]
/// within [maxDistance], or null when nothing is in range. A candidate is
/// claimed by its entry in [candidateKeys], so two candidates that share a key
/// (coincident catalog rows) cannot both be matched.
///
/// Why bucketed: star-to-catalog matching used to compare every detected star
/// against every catalog star in the field. On a rich frame that is
/// sources x candidates work — a 4,300-star frame against a degree-wide
/// catalog cone is hundreds of millions of distance tests, single-threaded and
/// silent, which presents as the app freezing rather than as slow science. A
/// match has to lie within [maxDistance], so with cells that size only the
/// nine cells around a source can hold a candidate: same answer, for
/// O(sources + candidates) work.
List<int?> matchNearestUnclaimed({
  required List<MatchPoint> sources,
  required List<MatchPoint> candidates,
  required List<String> candidateKeys,
  required double maxDistance,
}) {
  if (candidateKeys.length != candidates.length) {
    throw ArgumentError(
      'candidateKeys (${candidateKeys.length}) must be parallel to '
      'candidates (${candidates.length})',
    );
  }

  final matches = List<int?>.filled(sources.length, null);
  if (candidates.isEmpty || sources.isEmpty || !(maxDistance > 0)) {
    return matches;
  }

  final cellSize = math.max(maxDistance, 1e-6);
  final grid = <(int, int), List<int>>{};
  for (var i = 0; i < candidates.length; i++) {
    final key = (
      (candidates[i].x / cellSize).floor(),
      (candidates[i].y / cellSize).floor(),
    );
    grid.putIfAbsent(key, () => <int>[]).add(i);
  }

  final claimed = <String>{};
  final nearby = <int>[];
  for (var s = 0; s < sources.length; s++) {
    final source = sources[s];
    final col = (source.x / cellSize).floor();
    final row = (source.y / cellSize).floor();

    nearby.clear();
    for (var dc = -1; dc <= 1; dc++) {
      for (var dr = -1; dr <= 1; dr++) {
        final cell = grid[(col + dc, row + dr)];
        if (cell != null) {
          nearby.addAll(cell);
        }
      }
    }
    if (nearby.isEmpty) continue;
    // Ascending index is the order a full scan would have visited them in, so
    // an exact distance tie resolves to the same candidate either way.
    nearby.sort();

    int? best;
    var bestDistance = maxDistance;
    for (final index in nearby) {
      if (claimed.contains(candidateKeys[index])) continue;
      final dx = source.x - candidates[index].x;
      final dy = source.y - candidates[index].y;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance <= bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    if (best != null) {
      claimed.add(candidateKeys[best]);
      matches[s] = best;
    }
  }

  return matches;
}
