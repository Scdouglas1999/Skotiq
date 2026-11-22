// A target step's own horizon goes through the one floor rule with the site's
// floor: the target's altitude score is measured from it as well, not only
// its rejection.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_decision.dart';
import 'package:skotiq_core/src/models/scheduler/target_constraint.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/site/horizon_profile.dart';
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

/// Deep night at the site: the Sun gate never fires.
DateTime _night() => DateTime.utc(2026, 8, 13, 22, 50);

SchedulerCandidate _candidate(
  int id, {
  double raHours = 18.0,
  double decDegrees = 89.9,
  List<IntegrationGoal> goals = const [],
  List<int> captured = const [],
  List<String> filters = const ['L'],
  List<TargetConstraint> constraints = const [],
  Map<int, HorizonProfile> horizonProfiles = const {},
}) => SchedulerCandidate(
  targetId: id,
  name: 'T$id',
  raHours: raHours,
  decDegrees: decDegrees,
  userPriority: 5,
  goals: goals,
  capturedCounts: captured,
  availableFilters: filters,
  constraints: constraints,
  horizonProfiles: horizonProfiles,
);

Future<SchedulerDecision> _decide(List<SchedulerCandidate> candidates) async {
  final engine = SchedulerEngine(
    site: _site,
    sequenceSink: _NullSink(),
    candidateLoader: () async => candidates,
    clock: _night,
  );
  addTearDown(engine.dispose);
  await engine.evaluateNow(reason: 'preview');
  return engine.lastDecision!;
}

double _factor(SchedulerDecision decision, int id, String name) => decision
    .scoredCandidates
    .firstWhere((s) => s.targetId == id)
    .factors
    .firstWhere((f) => f.name == name)
    .value;

void main() {
  test('the altitude score is measured from the step horizon too', () async {
    final decision = await _decide([
      _candidate(1),
      _candidate(
        2,
        constraints: const [
          TargetConstraint(
            targetId: 2,
            kind: TargetConstraintKind.customHorizon,
            customHorizonId: 7,
          ),
        ],
        horizonProfiles: {
          7: HorizonProfile.flat(id: 7, name: 'Fence', altitudeDegrees: 40),
        },
      ),
    ]);
    final open = _factor(decision, 1, 'altitude');
    final fenced = _factor(decision, 2, 'altitude');
    expect(open, greaterThan(0));
    expect(fenced, lessThan(open));
    expect(
      decision.scoredCandidates.firstWhere((s) => s.targetId == 2).rejections,
      isEmpty,
    );
  });
}
