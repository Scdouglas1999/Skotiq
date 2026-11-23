// A wait for twilight is estimated against the site's night at the moment the
// step is reached: no wait once it is dark, and the coming evening's twilight
// during the day. It read the twilight of the run start's calendar day on the
// computer's clock, so a step reached the next morning waited for nothing and
// a computer in another zone picked another evening. Run this file under
// several `TZ` values; the expected values are New York's own.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

void main() {
  const latitude = 40.7128;
  const longitude = -74.0060;

  // [until]: a wait for a clock time first, so the twilight wait is reached
  // then rather than at the run's start.
  Sequence plan({DateTime? until}) {
    return Sequence.create(
      name: 'Twilight wait',
      rootNodeId: 'root',
      nodes: {
        'root': InstructionSetNode(
          id: 'root',
          name: 'Root',
          childIds: [if (until != null) 'before', 'wait'],
        ),
        if (until != null)
          'before': WaitTimeNode(
            id: 'before',
            parentId: 'root',
            waitUntil: until,
          ),
        'wait': WaitTimeNode(
          id: 'wait',
          name: 'Wait for dark',
          parentId: 'root',
          waitForTwilight: TwilightType.astronomical,
        ),
      },
    );
  }

  // Astronomical dusk at the site on the evening of [day].
  DateTime duskOf(DateTime day) => AstronomyCalculations.calculateTwilightTimes(
    date: NightDate.ofCalendarDay(day),
    latitudeDeg: latitude,
    longitudeDeg: longitude,
  ).astronomicalDusk!;

  // How long the twilight wait is estimated to take (a step that takes no
  // time has no timing row).
  Duration waitOf(DateTime start, {DateTime? until}) {
    final rows = const SequenceTimeEstimator()
        .estimateSequenceTiming(
          plan(until: until),
          start,
          latitude: latitude,
          longitude: longitude,
        )
        .where((t) => t.nodeId == 'wait');
    return rows.isEmpty ? Duration.zero : rows.single.duration;
  }

  DateTime waitEnd(DateTime start, {DateTime? until}) =>
      const SequenceTimeEstimator()
          .estimateSequenceTiming(
            plan(until: until),
            start,
            latitude: latitude,
            longitude: longitude,
          )
          .singleWhere((t) => t.nodeId == 'wait')
          .estimatedEnd;

  void expectNear(DateTime actual, DateTime expected) => expect(
    actual.toUtc().difference(expected.toUtc()).abs(),
    lessThan(const Duration(minutes: 1)),
    reason: 'got ${actual.toUtc()}, want ${expected.toUtc()}',
  );

  test('reached after dark, the wait takes no time', () {
    // 22:00 EST on Nov 21.
    expect(waitOf(DateTime.utc(2026, 11, 22, 3).toLocal()), Duration.zero);
  });

  test('reached at 01:30, the wait takes no time', () {
    expect(waitOf(DateTime.utc(2026, 11, 22, 6, 30).toLocal()), Duration.zero);
  });

  test('reached in the morning, the wait runs to that evening', () {
    // 08:00 EST on Nov 22, before the site's solar noon.
    expectNear(
      waitEnd(DateTime.utc(2026, 11, 22, 13).toLocal()),
      duskOf(DateTime.utc(2026, 11, 22)),
    );
  });

  test('reached in the afternoon, the wait runs to that evening', () {
    // 14:00 EST on Nov 22.
    expectNear(
      waitEnd(DateTime.utc(2026, 11, 22, 19).toLocal()),
      duskOf(DateTime.utc(2026, 11, 22)),
    );
  });

  test('reached the morning after a run that started at night, the wait runs '
      'to that evening', () {
    // Started 22:00 EST on Nov 21; the step before waits until 08:00 EST.
    expectNear(
      waitEnd(
        DateTime.utc(2026, 11, 22, 3).toLocal(),
        until: DateTime.utc(2026, 11, 22, 13).toLocal(),
      ),
      duskOf(DateTime.utc(2026, 11, 22)),
    );
  });
}
