// A "loop until stopped" Smart Exposure has no length of its own: it rotates
// its filters until its target's end condition stops it. The estimate billed
// it by its per-filter counts instead, so a 999-per-filter SHO rotation read
// as 176 hours per target and the plan as 353 hours, with an ETA days away.
// These pin the window the runtime actually gives it: the target waits for
// its start condition, stops at its end condition or the dawn park, and
// skips when its end condition already holds.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

void main() {
  const estimator = SequenceTimeEstimator();
  // The Heart Nebula from 40 N; at 13:31 UTC on Nov 8 2026 from 155 E it is
  // about half an hour past the meridian.
  const latitude = 40.0;
  const longitude = 155.0;
  const raHours = 2.545;
  const decDegrees = 61.45;
  final now = DateTime.utc(2026, 11, 8, 13, 31);

  SmartExposureNode rotation(String id, String parentId, {double budget = 0}) =>
      SmartExposureNode(
        id: id,
        name: 'SHO $id',
        parentId: parentId,
        loopUntilStopped: true,
        integrationBudgetSecs: budget,
        plans: const [
          FilterPlan(filterName: 'Ha', count: 999, durationSecs: 180),
          FilterPlan(filterName: 'OIII', count: 999, durationSecs: 180),
          FilterPlan(filterName: 'SII', count: 999, durationSecs: 180),
        ],
      );

  /// Before the meridian until 45 min before it, then after it from 20 min
  /// past until 5.2 h past or 30 degrees: the owner's plan, minus the
  /// focusing and guiding steps.
  Sequence heartPlan() {
    final before = TargetHeaderNode(
      id: 'before',
      name: 'Before',
      targetName: 'Heart',
      raHours: raHours,
      decDegrees: decDegrees,
      parentId: 'root',
      childIds: const ['se1'],
      startWhen: const TargetTrigger.and([
        TargetTrigger.altitudeAbove(45),
        TargetTrigger.hourAngleBetween(minHa: -12, maxHa: -0.75),
      ]),
      endWhen: const TargetTrigger.hourAngleBetween(minHa: -0.75, maxHa: 12),
    );
    final after = TargetHeaderNode(
      id: 'after',
      name: 'After',
      targetName: 'Heart',
      raHours: raHours,
      decDegrees: decDegrees,
      parentId: 'root',
      childIds: const ['se2', 'flip'],
      startWhen: const TargetTrigger.hourAngleBetween(minHa: 0.33, maxHa: 5.2),
      endWhen: const TargetTrigger.or([
        TargetTrigger.hourAngleBetween(minHa: 5.2, maxHa: 12),
        TargetTrigger.altitudeBelow(30),
      ]),
    );
    return Sequence.create(
      name: 'Heart',
      rootNodeId: 'root',
      nodes: {
        'root': InstructionSetNode(
          id: 'root',
          name: 'Root',
          childIds: const ['before', 'after', 'warm'],
        ),
        'before': before,
        'se1': rotation('se1', 'before'),
        'after': after,
        'se2': rotation('se2', 'after'),
        'flip': MeridianFlipNode(id: 'flip', name: 'Flip', parentId: 'after'),
        'warm': WarmCameraNode(id: 'warm', name: 'Warm', parentId: 'root'),
      },
    );
  }

  NodeTiming? timingOf(List<NodeTiming> timings, String id) {
    for (final t in timings) {
      if (t.nodeId == id) return t;
    }
    return null;
  }

  test('a loop-until-stopped block runs until its target window closes', () {
    final timings = estimator.estimateSequenceTiming(
      heartPlan(),
      now,
      latitude: latitude,
      longitude: longitude,
    );

    // The pre-meridian target's end condition already holds: skipped.
    expect(timingOf(timings, 'se1'), isNull);

    // The post-meridian block starts now (HA is past +0.33 h) and ends at
    // HA +5.2 h, about 4.7 h later: not 999 frames per filter.
    final se2 = timingOf(timings, 'se2')!;
    expect(se2.openEnded, isFalse);
    expect(se2.estimatedStart.difference(now).inMinutes, lessThan(2));
    expect(se2.duration.inMinutes, inInclusiveRange(270, 300));

    // The window closed, so the target skips the flip after the block; the
    // shutdown step at the root still runs.
    expect(timingOf(timings, 'flip'), isNull);
    expect(timingOf(timings, 'warm'), isNotNull);

    final total = estimator.estimateTotalDuration(
      heartPlan(),
      now,
      latitude: latitude,
      longitude: longitude,
    );
    expect(total.inHours, lessThan(6));
  });

  test('the dawn park ends the window early', () {
    final park = now.add(const Duration(hours: 2));
    final timings = estimator.estimateSequenceTiming(
      heartPlan(),
      now,
      latitude: latitude,
      longitude: longitude,
      runEndsBy: park,
    );
    final se2 = timingOf(timings, 'se2')!;
    expect(se2.estimatedEnd, park);
  });

  test('a target waits for its start condition', () {
    // Four hours earlier the target is east of the meridian and below the
    // pre-meridian end; the post-meridian target waits for HA +0.33 h.
    final early = now.subtract(const Duration(hours: 4));
    final timings = estimator.estimateSequenceTiming(
      heartPlan(),
      early,
      latitude: latitude,
      longitude: longitude,
    );
    final se1 = timingOf(timings, 'se1')!;
    final se2 = timingOf(timings, 'se2')!;
    // The pre-meridian block stops 45 min before the meridian...
    expect(se1.estimatedEnd.isBefore(se2.estimatedStart), isTrue);
    // ...and the post-meridian one starts about 20 min after it: a gap of
    // roughly an hour that the runtime spends waiting.
    expect(
      se2.estimatedStart.difference(se1.estimatedEnd).inMinutes,
      inInclusiveRange(55, 75),
    );
  });

  test('without a site the block is one rotation and open-ended', () {
    final timings = estimator.estimateSequenceTiming(heartPlan(), now);
    final se1 = timingOf(timings, 'se1')!;
    expect(se1.openEnded, isTrue);
    // Three 180 s frames plus their overheads, not 2997 of them.
    expect(se1.duration.inMinutes, inInclusiveRange(9, 12));
  });

  test('a budget fixes how many rotations a looping block runs', () {
    final sequence = Sequence.create(
      name: 'Budget',
      rootNodeId: 'se',
      nodes: {'se': rotation('se', 'none', budget: 3 * 3600)},
    );
    final timings = estimator.estimateSequenceTiming(sequence, now);
    final se = timingOf(timings, 'se')!;
    expect(se.openEnded, isFalse);
    // Three hours of integration plus per-frame overheads.
    expect(se.duration.inMinutes, inInclusiveRange(180, 200));
  });
}
