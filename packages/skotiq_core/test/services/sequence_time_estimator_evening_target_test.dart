// Pre-flight sees an evening target set under it.
//
// `calculateObjectVisibility` scans local noon to local noon. A target already
// above the horizon when that window opens — everything that culminates in the
// afternoon, i.e. the whole early-evening half of the sky — otherwise comes back
// with the NEXT day's rise and a set hunted forward to match it, so both ends
// sit ~24 h after the events they describe.
//
// The "target sets mid-block" conflict is gated on `end.isAfter(setTime)`, and
// no node ending tonight is after a set instant reported for tomorrow night, so
// a six-hour block on a target that drops below the horizon three hours in
// passes pre-flight in silence.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  const estimator = SequenceTimeEstimator();
  const latitude = 40.0;

  // The scan runs local noon to local noon off the HOST's clock, while the sky
  // comes from this longitude, so a hardcoded one only lines up in one
  // timezone: pinned at -105 this passed in US Mountain/Eastern and failed on
  // a UTC runner, where 18:00 local is late morning at the site. Deriving the
  // longitude from the host's own offset makes 18:00 local mean 18:00 at the
  // site everywhere.
  final start = DateTime(2024, 1, 15, 18, 0);
  final longitude = start.timeZoneOffset.inMinutes / 4.0;

  // RA 22h / Dec +20 at 40 N culminates in the early afternoon in mid-January
  // and sets in the evening: the exact shape that used to slip a day.
  Sequence buildSequence(DateTime start) {
    final target = TargetHeaderNode(
      id: 'target1',
      name: 'Evening Target',
      targetName: 'Evening Target',
      raHours: 22.0,
      decDegrees: 20.0,
      childIds: const ['exposure1'],
      startAfter: start,
    );
    return Sequence.create(
      name: 'Evening target',
      rootNodeId: 'target1',
      nodes: {
        'target1': target,
        'exposure1': ExposureNode(
          id: 'exposure1',
          name: 'Light 300s',
          // Six hours of subs on a target that sets partway through.
          durationSecs: 300,
          count: 72,
          parentId: 'target1',
        ),
      },
    );
  }

  test('the window names the set on the night the run is in', () {
    final window = estimator.calculateTargetWindows(
      buildSequence(start),
      start,
      latitude: latitude,
      longitude: longitude,
    )['target1']!;

    expect(window.riseTime, isNotNull);
    expect(window.setTime, isNotNull);
    expect(window.transitTime, isNotNull);

    // The three timestamps are one pass of the sky, so the target cannot rise
    // after it culminates nor stay up for more than a day.
    expect(window.riseTime!.isBefore(window.transitTime!), isTrue);
    expect(window.setTime!.isAfter(window.transitTime!), isTrue);
    expect(window.setTime!.difference(window.riseTime!).inHours, lessThan(24));

    // And the set is the one that ends THIS evening, hours after the run
    // starts — not the same clock time a day later.
    expect(window.setTime!.difference(start).inHours, lessThan(12));
  });

  test('a block that outlasts the target raises the conflict', () {
    final sequence = buildSequence(start);

    final analysis = estimator.analyzeSequence(
      sequence,
      start,
      latitude: latitude,
      longitude: longitude,
    );

    expect(
      analysis.conflicts.any(
        (c) => c.contains('Evening Target') && c.contains('after target sets'),
      ),
      isTrue,
      reason:
          'six hours of subs on a target that sets partway through must not '
          'pass pre-flight in silence — conflicts were ${analysis.conflicts}',
    );
  });
}
