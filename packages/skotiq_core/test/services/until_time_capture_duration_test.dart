import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

void main() {
  const estimator = SequenceTimeEstimator();

  Sequence sequence({
    required DateTime start,
    required DateTime loopUntil,
    required DateTime parentEnd,
    TargetTrigger? endWhen,
    double raHours = 0,
    double decDegrees = 0,
  }) {
    return Sequence.create(
      name: 'timed',
      nodes: {
        'target': TargetHeaderNode(
          id: 'target',
          name: 'Target',
          targetName: 'M31',
          raHours: raHours,
          decDegrees: decDegrees,
          endBefore: parentEnd,
          endWhen: endWhen,
          childIds: const ['loop'],
        ),
        'loop': LoopNode(
          id: 'loop',
          name: 'Until the window',
          parentId: 'target',
          conditionType: LoopConditionType.untilTime,
          repeatUntil: loopUntil,
          childIds: const ['exposure'],
        ),
        'exposure': ExposureNode(
          id: 'exposure',
          name: '60s',
          parentId: 'loop',
          durationSecs: 60,
          count: 1000,
        ),
      },
    );
  }

  test('an untilTime loop lasts until the earlier deadline', () {
    final start = DateTime.utc(2026, 10, 31, 22);
    final parentEnd = start.add(const Duration(hours: 1));

    final halfHour = estimator.estimateTotalDuration(
      sequence(
        start: start,
        loopUntil: start.add(const Duration(minutes: 30)),
        parentEnd: parentEnd,
      ),
      start,
    );
    final hour = estimator.estimateTotalDuration(
      sequence(
        start: start,
        loopUntil: start.add(const Duration(hours: 2)),
        parentEnd: parentEnd,
      ),
      start,
    );

    expect(halfHour, const Duration(minutes: 30));
    expect(hour, const Duration(hours: 1));
  });

  test('an altitude stop ends the capture at the set time', () {
    const latitude = 40.0;
    const longitude = -75.0;
    const raHours = 0.7123;
    const dec = 41.269;
    // Wall times at the site: 22:00 on 2026-10-31 through 08:00 the next morning.
    final start = DateTime(2026, 10, 31, 22);
    final clockEnd = DateTime(2026, 11, 1, 8);
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raHours * 15,
      decDeg: dec,
      date: start,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      minAltitude: 30,
    );
    final setTime = visibility.setTime;
    expect(setTime, isNotNull);
    expect(setTime!.isBefore(clockEnd), isTrue);

    final plan = sequence(
      start: start,
      loopUntil: clockEnd,
      parentEnd: clockEnd,
      raHours: raHours,
      decDegrees: dec,
      endWhen: TargetTrigger.or([
        const TargetTrigger.altitudeBelow(30),
        TargetTrigger.timeAfter(clockEnd.millisecondsSinceEpoch ~/ 1000),
      ]),
    );
    final timings = estimator.estimateSequenceTiming(
      plan,
      start,
      latitude: latitude,
      longitude: longitude,
    );
    final capture = timings.firstWhere((timing) => timing.nodeId == 'loop');
    // The walk refines a crossing to 15 seconds. The capture ends on that
    // crossing, which is the visibility set, and before the 08:00 clock.
    expect(
      capture.estimatedEnd.difference(setTime!).inSeconds.abs(),
      lessThanOrEqualTo(15),
    );
    expect(capture.estimatedEnd.isBefore(clockEnd), isTrue);
  });
}
