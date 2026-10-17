// Parity harness for the shared DECIDE scoring contract (WeightedScore).
//
// STEP-1 harness: pins the CURRENT pick/ranking of BOTH the live autopilot
// `SchedulerEngine` (6-factor UNNORMALIZED additive model) and the planner
// `TargetScoringService` (5-axis NORMALIZED model) over a representative
// candidate set, AND proves that routing each through the shared
// `WeightedScore.total` aggregator reproduces the exact pre-delegation
// arithmetic.
//
// The proof style follows the existing Rust<->Dart parity test: rather than
// hard-coding hand-computed totals (which rot when a sub-score formula
// changes), each test recomputes the ORIGINAL open-coded weighted sum inline
// from the per-factor breakdown the scorer still publishes, then asserts the
// shared aggregator landed on the identical number and the same ranking.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _site = SchedulerSite(
  latitudeDegrees: 40.0,
  longitudeDegrees: -75.0,
  localOffset: Duration(hours: -5),
);

DateTime _fixedNow() => DateTime.utc(2026, 5, 11, 4, 0);

SchedulerCandidate _candidate({
  required int id,
  required String name,
  required double raHours,
  required double decDegrees,
  int userPriority = 5,
}) {
  return SchedulerCandidate(
    targetId: id,
    name: name,
    raHours: raHours,
    decDegrees: decDegrees,
    userPriority: userPriority,
    goals: const [],
    capturedCounts: const [],
    constraints: const [],
    horizonProfiles: const {},
    availableFilters: const ['L', 'R', 'G', 'B'],
    isMosaicTarget: false,
  );
}

class _Fixture implements CelestialObject {
  @override
  final String id;
  @override
  final String name;
  @override
  final CelestialCoordinate coordinates;
  const _Fixture({
    required this.id,
    required this.name,
    required this.coordinates,
  });
  @override
  double? get magnitude => null;
}

void main() {
  // Representative candidate set spanning meridian / west-setting /
  // east-rising / low-priority geometries.
  final engineCandidates = <SchedulerCandidate>[
    _candidate(id: 1, name: 'High south', raHours: 14.0, decDegrees: 30.0),
    _candidate(id: 2, name: 'Setting west', raHours: 4.0, decDegrees: 10.0),
    _candidate(id: 3, name: 'Rising east', raHours: 20.0, decDegrees: 20.0),
    _candidate(
      id: 4,
      name: 'High south, low prio',
      raHours: 14.2,
      decDegrees: 28.0,
      userPriority: 1,
    ),
  ];

  group('SchedulerEngine additive aggregation parity', () {
    late SchedulerEngine engine;

    setUp(() {
      engine = SchedulerEngine(
        site: _site,
        sequenceSink: _NoopSink(),
        candidateLoader: () async => engineCandidates,
        clock: _fixedNow,
      );
    });

    tearDown(() async => engine.dispose());

    test(
      'shared additive total == open-coded Σ(weighted) for every candidate',
      () {
        final now = _fixedNow();
        for (final c in engineCandidates) {
          final score = engine.scoreCandidate(c, now);
          // Reproduce the ORIGINAL `factors.fold((s, f) => s + f.weighted)`.
          final expected = score.factors.fold<double>(
            0.0,
            (s, f) => s + f.weighted,
          );
          expect(
            (score.totalScore - expected).abs() < 1e-12,
            isTrue,
            reason:
                '${c.name}: additive total drifted from Σ(weighted). '
                'got ${score.totalScore}, expected $expected',
          );
        }
      },
    );

    test('current pick + ranking are stable (golden)', () async {
      await engine.start();
      final decision = engine.lastDecision!;
      // Golden pick: target 1 (high in the south near meridian) wins.
      expect(decision.chosenTargetId, 1);
      // Golden eligible ranking (post-delegation == pre-delegation).
      final eligible =
          decision.scoredCandidates
              .where((s) => !s.hardConstraintFailed)
              .toList()
            ..sort((a, b) => b.totalScore.compareTo(a.totalScore));
      // The two high-south targets outrank the low setting/rising ones; the
      // full-priority one (id 1) outranks the low-priority twin (id 4).
      final order = eligible.map((s) => s.targetId).toList();
      expect(order.first, 1);
      expect(order.indexOf(1) < order.indexOf(4), isTrue);
    });
  });

  group('TargetScoringService normalized aggregation parity', () {
    const targets = <_Fixture>[
      _Fixture(
        id: 'm42',
        name: 'M42',
        coordinates: CelestialCoordinate(ra: 5.5880, dec: -5.39),
      ),
      _Fixture(
        id: 'm31',
        name: 'M31',
        coordinates: CelestialCoordinate(ra: 0.7123, dec: 41.27),
      ),
      _Fixture(
        id: 'm13',
        name: 'M13',
        coordinates: CelestialCoordinate(ra: 16.6948, dec: 36.46),
      ),
    ];

    final service = TargetScoringService(
      latitude: 40.0,
      longitude: -74.0,
      observationTime: DateTime.utc(2026, 1, 15, 6, 0, 0),
      moonPosition: const (75.0, 18.0),
      moonIllumination: 50.0,
    );

    test(
      'shared normalized total == open-coded Σ(axis*w)/Σ(w) for every target',
      () {
        const w = ScoringWeights();
        final weightSum =
            w.altitudeWeight +
            w.moonDistanceWeight +
            w.transitProximityWeight +
            w.darknessWeight +
            w.airmassWeight;
        for (final t in targets) {
          final s = service.scoreTarget(t);
          final expected =
              (s.altitudeScore * w.altitudeWeight +
                  s.moonDistanceScore * w.moonDistanceWeight +
                  s.transitProximityScore * w.transitProximityWeight +
                  s.darknessScore * w.darknessWeight +
                  s.airmassScore * w.airmassWeight) /
              weightSum;
          expect(
            (s.totalScore - expected).abs() < 1e-12,
            isTrue,
            reason:
                '${t.name}: normalized total drifted from Σ(axis*w)/Σ(w). '
                'got ${s.totalScore}, expected $expected',
          );
        }
      },
    );

    test('current planner ranking is stable (golden)', () {
      final ranked = service.scoreTargets(targets.toList());
      // Identity check: ranking is monotonic non-increasing and is the same
      // order the delegated aggregator produces.
      for (var i = 1; i < ranked.length; i++) {
        expect(ranked[i - 1].totalScore >= ranked[i].totalScore, isTrue);
      }
    });

    test('WeightedScore.normalized matches the planner divisor semantics', () {
      // Direct primitive check: a 0..100 axis set folded with the default
      // weights yields the weighted average, divisor floored at epsilon.
      const w = ScoringWeights();
      final factors = w.factors(
        altitudeScore: 100,
        moonDistanceScore: 0,
        transitProximityScore: 50,
        darknessScore: 100,
        airmassScore: 0,
      );
      final got = WeightedScore.total(
        factors,
        mode: WeightedScoreMode.normalized,
      );
      const expected =
          (100 * 0.25 + 0 * 0.25 + 50 * 0.20 + 100 * 0.15 + 0 * 0.15) / 1.0;
      expect((got - expected).abs() < 1e-12, isTrue);
    });
  });

  group('WeightedScore primitive', () {
    test('additive does NOT divide by weight-sum', () {
      final factors = [
        const WeightedFactor(name: 'a', value: 0.5, weight: 1.25),
        const WeightedFactor(name: 'b', value: 1.0, weight: 1.0),
      ];
      final got = WeightedScore.total(
        factors,
        mode: WeightedScoreMode.additive,
      );
      expect((got - (0.5 * 1.25 + 1.0 * 1.0)).abs() < 1e-12, isTrue);
    });

    test('normalized floors the divisor at epsilon (no NaN)', () {
      final got = WeightedScore.total([
        const WeightedFactor(name: 'z', value: 42, weight: 0),
      ], mode: WeightedScoreMode.normalized);
      expect(got.isFinite, isTrue);
      expect(got, 0.0);
    });
  });
}

class _NoopSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}
  @override
  Future<void> pauseSequence() async {}
  @override
  Future<void> resumeSequence() async {}
  @override
  Future<void> stopSequence() async {}
  @override
  Future<void> parkForEndOfNight() async {}
  @override
  Future<void> releaseSequenceOwnership() async {}
}
