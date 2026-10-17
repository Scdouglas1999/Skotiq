// A sequence that starts AFTER local midnight is scored against the night it
// runs in.
//
// `calculateObjectVisibility` scans one local-noon-to-noon window and reads only
// the calendar day of the instant it is given. A run beginning at 01:00
// otherwise has its rise/transit/set solved for the night that starts twelve
// hours LATER, so every set time comes back roughly a day late and the "target
// sets before this block finishes" conflicts pre-flight exists to raise become
// unreachable.
//
// The planetarium's "Best Targets Tonight" card reports transit times a sidereal
// day out for the same reason.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  const estimator = SequenceTimeEstimator();
  const latitude = 40.0;
  const longitude = 0.0;

  // RA 6h30m / Dec +40 transits near the zenith at latitude 40, so its window
  // is unambiguous.
  Sequence buildSequence() {
    final target = TargetHeaderNode(
      id: 'target1',
      name: 'Zenith Target',
      targetName: 'Zenith Target',
      raHours: 6.5,
      decDegrees: 40.0,
      childIds: const ['exposure1'],
    );
    return Sequence.create(
      name: 'Night anchor',
      rootNodeId: 'target1',
      nodes: {
        'target1': target,
        'exposure1': ExposureNode(
          id: 'exposure1',
          name: 'Light 60s',
          durationSecs: 60,
          count: 5,
          parentId: 'target1',
        ),
      },
    );
  }

  test('a run starting after midnight is scored on the night it is IN', () {
    final sequence = buildSequence();

    // 22:00 on the 15th and 01:00 on the 16th are the same observing night.
    final evening = DateTime(2024, 1, 15, 22, 0);
    final afterMidnight = DateTime(2024, 1, 16, 1, 0);

    final eveningWindow = estimator.calculateTargetWindows(
      sequence,
      evening,
      latitude: latitude,
      longitude: longitude,
    )['target1']!;
    final afterMidnightWindow = estimator.calculateTargetWindows(
      sequence,
      afterMidnight,
      latitude: latitude,
      longitude: longitude,
    )['target1']!;

    // Same night in, same window out: an 01:00 start solved for the night
    // beginning twelve hours later differs by about a sidereal day.
    expect(afterMidnightWindow.riseTime, eveningWindow.riseTime);
    expect(afterMidnightWindow.transitTime, eveningWindow.transitTime);
    expect(afterMidnightWindow.setTime, eveningWindow.setTime);
  });

  test('the night boundary is local noon, not midnight', () {
    final sequence = buildSequence();

    Duration? spanFrom(DateTime start) {
      final window = estimator.calculateTargetWindows(
        sequence,
        start,
        latitude: latitude,
        longitude: longitude,
      )['target1']!;
      return window.transitTime?.difference(start);
    }

    // 11:59 belongs to the night that began the previous evening; 12:00 opens
    // the next one. The transit they name must therefore differ by about a day.
    final before = spanFrom(DateTime(2024, 1, 16, 11, 59))!;
    final after = spanFrom(DateTime(2024, 1, 16, 12, 0))!;
    expect((after - before).inHours, greaterThanOrEqualTo(23));
  });
}
