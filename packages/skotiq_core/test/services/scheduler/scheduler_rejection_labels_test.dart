// The scheduler queue's STATUS chip and its own sentence say the same thing: a
// chip reading "Below horizon" for a target at +9.8° sits beside "altitude 9.8°
// below site minimum 30.0°", and above the horizon is not the same as below the
// site minimum.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_decision.dart';
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

// Northern site; deep night at the instant below so the Sun gate never fires.
const _site = SchedulerSite(
  latitudeDegrees: 45.0,
  longitudeDegrees: 21.0,
  localOffset: Duration(hours: 2),
);

DateTime _night() => DateTime.utc(2026, 8, 13, 22, 50);

SchedulerCandidate _candidate({
  required int id,
  required String name,
  required double raHours,
  required double decDegrees,
}) {
  return SchedulerCandidate(
    targetId: id,
    name: name,
    raHours: raHours,
    decDegrees: decDegrees,
    userPriority: 5,
    goals: const [],
    capturedCounts: const [],
    availableFilters: const ['L'],
    constraints: const [],
    horizonProfiles: const {},
  );
}

Future<RejectedCandidate> _rejectionFor(SchedulerCandidate c) async {
  final engine = SchedulerEngine(
    site: _site,
    sequenceSink: _NullSink(),
    candidateLoader: () async => [c],
    clock: _night,
  );
  addTearDown(engine.dispose);
  await engine.evaluateNow(reason: 'preview');
  final decision = engine.lastDecision!;
  return decision.rejected.firstWhere((r) => r.targetId == c.targetId);
}

void main() {
  test(
    'a target that is up but under the site minimum is not "below horizon"',
    () async {
      // Dec −35 from lat +45: culminates ~+9.8°, i.e. above the horizon and
      // below the 30° default site minimum.
      final rejection = await _rejectionFor(
        _candidate(id: 1, name: 'M42-TEST', raHours: 21.42, decDegrees: -35.0),
      );

      expect(
        rejection.hardConstraintFailures.first,
        contains('below site minimum'),
        reason: 'the underlying sentence is the one the row already showed',
      );
      expect(
        rejection.primaryReason.toLowerCase(),
        isNot(contains('below horizon')),
        reason: 'the target is up — it is merely too low to image',
      );
      expect(rejection.primaryReason, contains('site minimum'));
    },
  );

  test(
    'a target actually under the horizon still says "below horizon"',
    () async {
      // Dec −80 from lat +45 never rises.
      final rejection = await _rejectionFor(
        _candidate(id: 2, name: 'Never up', raHours: 21.42, decDegrees: -80.0),
      );

      expect(rejection.primaryReason.toLowerCase(), contains('below horizon'));
    },
  );
}
