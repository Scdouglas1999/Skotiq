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
}
