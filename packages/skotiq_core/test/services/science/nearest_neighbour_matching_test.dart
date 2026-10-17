import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Star-to-catalog matching must not be quadratic in a rich field.
///
/// The science lane compared every detected star against every projected
/// catalog star. On the rig's 4,341-star frame against a degree-wide catalog
/// cone that is hundreds of millions of distance tests on one isolate, with
/// nothing logged while it runs — a silent freeze, on exactly the frames a
/// successful plate solve unlocks.
///
/// The bucketed matcher must give the SAME answer as the full scan it
/// replaced, so the first group pins equivalence against a brute-force
/// reference and the second pins the cost.
void main() {
  /// The full scan, as it was written before bucketing.
  List<int?> bruteForce({
    required List<MatchPoint> sources,
    required List<MatchPoint> candidates,
    required List<String> candidateKeys,
    required double maxDistance,
  }) {
    final matches = List<int?>.filled(sources.length, null);
    final claimed = <String>{};
    for (var s = 0; s < sources.length; s++) {
      int? best;
      var bestDistance = maxDistance;
      for (var c = 0; c < candidates.length; c++) {
        if (claimed.contains(candidateKeys[c])) continue;
        final dx = sources[s].x - candidates[c].x;
        final dy = sources[s].y - candidates[c].y;
        final distance = math.sqrt(dx * dx + dy * dy);
        if (distance <= bestDistance) {
          bestDistance = distance;
          best = c;
        }
      }
      if (best != null) {
        claimed.add(candidateKeys[best]);
        matches[s] = best;
      }
    }
    return matches;
  }

  group('equivalence with the full scan', () {
    test('agrees on 40 randomised fields', () {
      final random = math.Random(20260913);
      for (var trial = 0; trial < 40; trial++) {
        final sources = <MatchPoint>[];
        final candidates = <MatchPoint>[];
        final keys = <String>[];
        for (var i = 0; i < 120; i++) {
          sources.add((
            x: random.nextDouble() * 200,
            y: random.nextDouble() * 200,
          ));
        }
        for (var i = 0; i < 160; i++) {
          final x = random.nextDouble() * 200;
          final y = random.nextDouble() * 200;
          candidates.add((x: x, y: y));
          // Deliberately collide some keys: two coincident catalog rows must
          // not both be claimed.
          keys.add('key_${i % 150}');
        }
        final maxDistance = 1.0 + random.nextDouble() * 6.0;

        expect(
          matchNearestUnclaimed(
            sources: sources,
            candidates: candidates,
            candidateKeys: keys,
            maxDistance: maxDistance,
          ),
          bruteForce(
            sources: sources,
            candidates: candidates,
            candidateKeys: keys,
            maxDistance: maxDistance,
          ),
          reason: 'trial $trial diverged from the full scan',
        );
      }
    });

    test('matches a candidate exactly on the radius, as the scan did', () {
      expect(
        matchNearestUnclaimed(
          sources: const [(x: 0.0, y: 0.0)],
          candidates: const [(x: 5.0, y: 0.0)],
          candidateKeys: const ['a'],
          maxDistance: 5.0,
        ),
        [0],
      );
      expect(
        matchNearestUnclaimed(
          sources: const [(x: 0.0, y: 0.0)],
          candidates: const [(x: 5.001, y: 0.0)],
          candidateKeys: const ['a'],
          maxDistance: 5.0,
        ),
        [null],
      );
    });

    test('a claimed candidate is not matched twice', () {
      expect(
        matchNearestUnclaimed(
          sources: const [(x: 0.0, y: 0.0), (x: 0.5, y: 0.0)],
          candidates: const [(x: 0.1, y: 0.0)],
          candidateKeys: const ['shared'],
          maxDistance: 2.0,
        ),
        [0, null],
      );
    });

    test('two candidates sharing a key cannot both be claimed', () {
      expect(
        matchNearestUnclaimed(
          sources: const [(x: 0.0, y: 0.0), (x: 10.0, y: 0.0)],
          candidates: const [(x: 0.1, y: 0.0), (x: 10.1, y: 0.0)],
          candidateKeys: const ['same', 'same'],
          maxDistance: 1.0,
        ),
        [0, null],
      );
    });

    test('handles negative coordinates across the cell origin', () {
      expect(
        matchNearestUnclaimed(
          sources: const [(x: -0.2, y: -0.2)],
          candidates: const [(x: 0.2, y: 0.2)],
          candidateKeys: const ['a'],
          maxDistance: 1.0,
        ),
        [0],
      );
    });

    test('returns no matches for empty or degenerate input', () {
      expect(
        matchNearestUnclaimed(
          sources: const [(x: 0.0, y: 0.0)],
          candidates: const [],
          candidateKeys: const [],
          maxDistance: 5.0,
        ),
        [null],
      );
      expect(
        matchNearestUnclaimed(
          sources: const [],
          candidates: const [(x: 0.0, y: 0.0)],
          candidateKeys: const ['a'],
          maxDistance: 5.0,
        ),
        isEmpty,
      );
      expect(
        matchNearestUnclaimed(
          sources: const [(x: 0.0, y: 0.0)],
          candidates: const [(x: 0.0, y: 0.0)],
          candidateKeys: const ['a'],
          maxDistance: 0.0,
        ),
        [null],
      );
    });

    test('rejects candidate keys that are not parallel to the candidates', () {
      expect(
        () => matchNearestUnclaimed(
          sources: const [],
          candidates: const [(x: 0.0, y: 0.0)],
          candidateKeys: const [],
          maxDistance: 1.0,
        ),
        throwsArgumentError,
      );
    });
  });

  test('a rich field matches in linear time, not quadratic', () {
    // The rig's frame: 4,341 detections against a catalog cone of comparable
    // density over a 4656x3520 frame. The full scan is ~2x10^8 distance tests
    // here and took minutes; bucketed it is milliseconds.
    final random = math.Random(4341);
    final sources = <MatchPoint>[];
    final candidates = <MatchPoint>[];
    final keys = <String>[];
    for (var i = 0; i < 4341; i++) {
      sources.add((
        x: random.nextDouble() * 4656,
        y: random.nextDouble() * 3520,
      ));
    }
    for (var i = 0; i < 50000; i++) {
      candidates.add((
        x: random.nextDouble() * 4656,
        y: random.nextDouble() * 3520,
      ));
      keys.add('c$i');
    }

    final started = DateTime.now();
    final matched = matchNearestUnclaimed(
      sources: sources,
      candidates: candidates,
      candidateKeys: keys,
      maxDistance: 10.0,
    );
    final elapsed = DateTime.now().difference(started);

    expect(matched, hasLength(4341));
    expect(
      matched.whereType<int>(),
      isNotEmpty,
      reason: 'the fixture should produce real matches',
    );
    expect(
      elapsed.inSeconds,
      lessThan(5),
      reason: 'matching went quadratic again (${elapsed.inMilliseconds} ms)',
    );
  });
}
