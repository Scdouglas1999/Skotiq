// The scheduler asks the wheel for a goal's filter by the same rule the run
// uses to find the slot: a goal "Ha" on a wheel whose slot reads "Ha 7nm" is
// one the run can take.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

class _NullSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}

  @override
  Future<void> pauseSequence() async {}

  @override
  Future<void> resumeSequence() async {}

  @override
  Future<void> stopSequence() async {}

  @override
  Future<void> releaseSequenceOwnership() async {}

  @override
  Future<void> parkForEndOfNight() async {}
}

const _site = SchedulerSite(
  latitudeDegrees: 45.0,
  longitudeDegrees: 21.0,
  localOffset: Duration(hours: 2),
);

DateTime _night() => DateTime.utc(2026, 8, 13, 22, 50);

SchedulerCandidate _candidate(int id, String goalFilter) => SchedulerCandidate(
  targetId: id,
  name: 'Polaris field $id',
  raHours: 2.5,
  decDegrees: 89.0,
  userPriority: 5,
  goals: [
    IntegrationGoal(
      targetId: id,
      filter: goalFilter,
      exposureSeconds: 300,
      frameCount: 10,
      createdAt: DateTime.utc(2026),
    ),
  ],
  capturedCounts: const [0],
  availableFilters: const ['L', 'R', 'G', 'B', 'Ha 7nm'],
  constraints: const [],
  horizonProfiles: const {},
);

void main() {
  test('a goal the wheel has under a longer name is scheduled, one it lacks '
      'is not', () async {
    final engine = SchedulerEngine(
      site: _site,
      sequenceSink: _NullSink(),
      candidateLoader: () async => [_candidate(1, 'Ha'), _candidate(2, 'OIII')],
      clock: _night,
    );
    addTearDown(engine.dispose);
    await engine.evaluateNow(reason: 'preview');
    final decision = engine.lastDecision!;

    expect(decision.rejected.map((r) => r.targetId), [2]);
    expect(
      decision.rejected.single.hardConstraintFailures,
      contains(contains('not in equipment wheel (OIII)')),
    );
    expect(decision.chosenTargetId, 1);
  });

  test('the plan built for it exposes the goal\'s frames', () {
    final engine = SchedulerEngine(
      site: _site,
      sequenceSink: _NullSink(),
      candidateLoader: () async => const [],
      clock: _night,
    );
    addTearDown(engine.dispose);
    final plan = engine.buildSequenceForCandidate(_candidate(1, 'Ha'));
    final exposures = plan.nodes.values.whereType<ExposureNode>().toList();
    expect(exposures.single.filter, 'Ha');
    expect(exposures.single.count, 10);
  });

  group('a target with several filters still needed', () {
    SchedulerCandidate lrgb({required bool rotatesFilters}) =>
        SchedulerCandidate(
          targetId: 3,
          name: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
          userPriority: 5,
          goals: [
            for (final (filter, count) in [('L', 20), ('R', 10), ('G', 10)])
              IntegrationGoal(
                targetId: 3,
                filter: filter,
                exposureSeconds: 120,
                frameCount: count,
                createdAt: DateTime.utc(2026),
              ),
          ],
          capturedCounts: const [5, 0, 10],
          availableFilters: const ['L', 'R', 'G', 'B'],
          constraints: const [],
          horizonProfiles: const {},
          rotatesFilters: rotatesFilters,
        );

    SchedulerEngine engine() {
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: _NullSink(),
        candidateLoader: () async => const [],
        clock: _night,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('rotates through every one of them on a motorized wheel', () {
      final plan = engine().buildSequenceForCandidate(
        lrgb(rotatesFilters: true),
      );
      final smart = plan.nodes.values.whereType<SmartExposureNode>().single;
      expect(smart.rotateFilters, isTrue);
      expect(smart.batchSize, 1);
      expect(smart.plans.map((p) => (p.filterName, p.count)), [
        ('L', 15),
        ('R', 10),
      ]);
      expect(plan.nodes.values.whereType<ExposureNode>(), isEmpty);
    });

    test('images the most-needed one alone without one', () {
      final plan = engine().buildSequenceForCandidate(
        lrgb(rotatesFilters: false),
      );
      final exposure = plan.nodes.values.whereType<ExposureNode>().single;
      expect((exposure.filter, exposure.count), ('L', 15));
      expect(plan.nodes.values.whereType<SmartExposureNode>(), isEmpty);
    });
  });
}
