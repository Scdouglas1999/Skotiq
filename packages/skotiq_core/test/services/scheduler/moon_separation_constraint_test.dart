// The scheduler's per-target moon avoidance has to gate on SEPARATION.
//
// Before this, the only moon constraint the wizard could build was
// `moonIlluminationMax`, which is the wrong axis on its own: it rejects a
// target 150 degrees away from a 90% moon (harmless) and accepts one 10
// degrees from a 40% moon (ruined). Separation is what NINA and SGP gate on,
// and the rest of this app already speaks it.
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_decision.dart';
import 'package:skotiq_core/src/models/scheduler/target_constraint.dart';
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
  Future<void> parkForEndOfNight() async {}
  @override
  Future<void> releaseSequenceOwnership() async {}
}

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
  List<TargetConstraint> constraints = const [],
}) {
  return SchedulerCandidate(
    targetId: id,
    name: name,
    raHours: raHours,
    decDegrees: decDegrees,
    userPriority: 5,
    goals: const <IntegrationGoal>[],
    capturedCounts: const <int>[],
    constraints: constraints,
    horizonProfiles: const {},
    availableFilters: const ['L'],
    isMosaicTarget: false,
  );
}

Future<Map<int, TargetScore>> _scoreAll(
  List<SchedulerCandidate> candidates,
) async {
  final engine = SchedulerEngine(
    site: _site,
    sequenceSink: _NullSink(),
    candidateLoader: () async => candidates,
    clock: _fixedNow,
  );
  await engine.start();
  final decision = engine.lastDecision!;
  // scoredCandidates carries EVERY evaluated target, eligible or not — the
  // hardConstraintFailed flag and rejectionReasons live on it.
  final byId = {for (final s in decision.scoredCandidates) s.targetId: s};
  await engine.dispose();
  return byId;
}

void main() {
  // At 2026-05-11 04:00 UTC the Meeus ephemeris the engine uses puts the moon
  // at RA 22.70 h, Dec -13.76, 30% lit. A target at RA 14 h / Dec +30 is 131.7
  // degrees away from it and 79.5 degrees above the horizon for this site, so
  // altitude can never be what rejects it — only the separation gate can.
  const highRaHours = 14.0;
  const highDec = 30.0;
  const moonRaHours = 22.70;
  const moonDec = -13.76;

  SchedulerCandidate withMinSeparation({
    required double raHours,
    required double decDegrees,
    required double minDeg,
    bool enabled = true,
  }) {
    return _candidate(
      id: 1,
      name: 'T',
      raHours: raHours,
      decDegrees: decDegrees,
      constraints: [
        TargetConstraint(
          targetId: 1,
          kind: TargetConstraintKind.moonSeparationMin,
          moonSeparationMinDeg: minDeg,
          enabled: enabled,
        ),
      ],
    );
  }

  bool rejectedForMoon(TargetScore s) =>
      s.rejectionReasons.any((r) => r.contains('moon separation'));

  test('a target closer than the minimum separation is rejected', () async {
    // 131.7 degrees of separation, gate at 150.
    final scores = await _scoreAll([
      withMinSeparation(
        raHours: highRaHours,
        decDegrees: highDec,
        minDeg: 150.0,
      ),
    ]);

    final score = scores[1]!;
    expect(score.hardConstraintFailed, isTrue);
    expect(
      rejectedForMoon(score),
      isTrue,
      reason: 'reasons were ${score.rejectionReasons}',
    );
    // Nothing else rejected it: this target is 79 degrees up.
    expect(score.rejectionReasons.length, 1);
  });

  test(
    'the same target passes when it clears the minimum separation',
    () async {
      final scores = await _scoreAll([
        withMinSeparation(
          raHours: highRaHours,
          decDegrees: highDec,
          minDeg: 60.0,
        ),
      ]);

      expect(scores[1]!.hardConstraintFailed, isFalse);
      expect(rejectedForMoon(scores[1]!), isFalse);
    },
  );

  test(
    'a target sitting on the moon is rejected by a modest 30 deg gate',
    () async {
      final scores = await _scoreAll([
        withMinSeparation(
          raHours: moonRaHours,
          decDegrees: moonDec,
          minDeg: 30.0,
        ),
      ]);

      expect(
        rejectedForMoon(scores[1]!),
        isTrue,
        reason: 'reasons were ${scores[1]!.rejectionReasons}',
      );
    },
  );

  test('a disabled separation constraint is not evaluated', () async {
    final scores = await _scoreAll([
      withMinSeparation(
        raHours: highRaHours,
        decDegrees: highDec,
        minDeg: 179.0,
        enabled: false,
      ),
    ]);

    expect(rejectedForMoon(scores[1]!), isFalse);
    expect(scores[1]!.hardConstraintFailed, isFalse);
  });

  test('the payload survives a storage round-trip', () {
    const c = TargetConstraint(
      targetId: 9,
      kind: TargetConstraintKind.moonSeparationMin,
      moonSeparationMinDeg: 45.0,
    );
    final restored = TargetConstraint.fromRow(
      id: 1,
      targetId: 9,
      kindName: c.kind.name,
      payloadJson: c.encodePayload(),
      enabled: true,
    );
    expect(restored.kind, TargetConstraintKind.moonSeparationMin);
    expect(restored.moonSeparationMinDeg, 45.0);
  });
}
