// Shared scheduler-screen test doubles, used by the scheduler screen tests, the
// planner-screen tests and the scheduler tab-content tests.
//
// Keeping every fake here means a change to (e.g.) SchedulerEngine fields only
// needs to land in one place — the test files carry only the per-test scenario
// data.

import 'package:skotiq_core/skotiq_core.dart';

class FakeSchedulerSequenceSink implements SchedulerSequenceSink {
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

/// In-memory fake of [IntegrationGoalService] for widget tests. Only
/// implements the methods the scheduler screen actually calls.
class FakeIntegrationGoalService implements IntegrationGoalService {
  final List<int> deletedForTarget = [];
  int deleteAllCalls = 0;

  @override
  Future<void> deleteForTarget(int targetId) async {
    deletedForTarget.add(targetId);
  }

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
        'FakeIntegrationGoalService.${invocation.memberName} not implemented');
  }
}

class FakeTargetConstraintService implements TargetConstraintService {
  final List<int> deletedForTarget = [];
  int deleteAllCalls = 0;

  @override
  Future<void> deleteForTarget(int targetId) async {
    deletedForTarget.add(targetId);
  }

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
        'FakeTargetConstraintService.${invocation.memberName} not implemented');
  }
}

SchedulerEngine buildTestSchedulerEngine() {
  return SchedulerEngine(
    site: const SchedulerSite(
      latitudeDegrees: 40.0,
      longitudeDegrees: -75.0,
      localOffset: Duration(hours: -5),
    ),
    sequenceSink: FakeSchedulerSequenceSink(),
    candidateLoader: () async => const <SchedulerCandidate>[],
    clock: () => DateTime.utc(2026, 5, 11, 4, 0),
  );
}

TargetScore scoreFor({
  required int id,
  required String name,
  required double total,
  bool hardFail = false,
  List<String> rejections = const [],
}) {
  return TargetScore(
    targetId: id,
    targetName: name,
    totalScore: total,
    factors: const [
      ScoreFactor(name: 'altitude', value: 0.7, weight: 1.0, weighted: 0.7),
      ScoreFactor(name: 'meridian', value: 0.5, weight: 1.0, weighted: 0.5),
    ],
    hardConstraintFailed: hardFail,
    rejectionReasons: rejections,
  );
}

SchedulerDecision decisionWith({
  required int? chosenId,
  required String? chosenName,
  required List<TargetScore> scored,
  List<RejectedCandidate> rejected = const [],
}) {
  return SchedulerDecision(
    chosenTargetId: chosenId,
    chosenTargetName: chosenName,
    score: chosenId != null ? scored.first.totalScore : 0.0,
    reasoning: [
      if (chosenName != null)
        'Chose $chosenName at 2026-05-11T04:00:00Z (manual)'
      else
        'No eligible candidates',
    ],
    scoredCandidates: scored,
    rejected: rejected,
    evaluatedAt: DateTime.utc(2026, 5, 11, 4, 0),
    isSwitch: chosenId != null,
  );
}

/// Convenience for tests that need a rejected entry without restating
/// the whole factor breakdown.
RejectedCandidate rejectionFor({
  required int id,
  required String name,
  required double score,
  required String primaryReason,
  List<String> hardConstraintFailures = const [],
  List<ScoreFactor>? factors,
}) {
  return RejectedCandidate(
    targetId: id,
    targetName: name,
    score: score,
    primaryReason: primaryReason,
    hardConstraintFailures: hardConstraintFailures,
    factors: factors ??
        const [
          ScoreFactor(name: 'altitude', value: 0.5, weight: 1.0, weighted: 0.5),
          ScoreFactor(name: 'meridian', value: 0.3, weight: 1.0, weighted: 0.3),
        ],
  );
}

class FakeSchedulerStatusNotifier extends SchedulerStatusNotifier {
  FakeSchedulerStatusNotifier(SchedulerStatus initial) : super(_DummyEngine()) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

class FakeCurrentSchedulerDecisionNotifier
    extends CurrentSchedulerDecisionNotifier {
  FakeCurrentSchedulerDecisionNotifier(SchedulerDecision? initial)
      : super(_DummyEngine()) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

/// Bare-bones SchedulerEngine that satisfies the notifier constructor
/// signature without doing any real work — the fake notifiers above only
/// pass their initial state up to the StateNotifier base class and never
/// listen to the engine's streams (the streams are still live, but they
/// emit nothing so the fake state stays put).
class _DummyEngine extends SchedulerEngine {
  _DummyEngine()
      : super(
          site: const SchedulerSite(
            latitudeDegrees: 0,
            longitudeDegrees: 0,
            localOffset: Duration.zero,
          ),
          sequenceSink: FakeSchedulerSequenceSink(),
          candidateLoader: () async => const <SchedulerCandidate>[],
        );
}
