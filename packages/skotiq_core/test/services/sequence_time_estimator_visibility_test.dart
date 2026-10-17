import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Pre-flight told the operator that a node scheduled at 12:47 ran "before
/// target rises at 03:41" for a target that was near the zenith at 12:47.
///
/// The rise/set solver scans one local-noon-to-noon window, so a target that
/// is ALREADY up at the anchor has no rise inside its own visible interval;
/// what comes back is the NEXT night's rise. Testing membership of that
/// interval is guaranteed to report a target at the zenith as "not up yet".
void main() {
  const estimator = SequenceTimeEstimator();
  const latitude = 40.0;
  const longitude = 0.0;
  const minAltitude = 20.0;

  // RA 6h30m / Dec +40: from latitude 40 it passes within a degree of the
  // zenith, so "is it up" is never a marginal call.
  const raHours = 6.5;
  const decDegrees = 40.0;

  Sequence buildSequence() {
    final target = TargetHeaderNode(
      id: 'target1',
      name: 'Zenith Target',
      targetName: 'Zenith Target',
      raHours: raHours,
      decDegrees: decDegrees,
      childIds: const ['exposure1'],
    );
    return Sequence.create(
      name: 'Visibility',
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

  /// Find a date on which the reported shape actually occurs in this
  /// process's timezone: the target is comfortably above the altitude floor
  /// at 12:47 local, yet the solved window's rise time is still in the
  /// future. Sidereal time at local noon sweeps a full 24 h over a year, so
  /// such a date always exists for a fixed RA whatever the host offset is.
  ({DateTime scheduled, TargetWindow window}) findZenithNoonCase() {
    final sequence = buildSequence();
    for (var dayOffset = 0; dayOffset < 366; dayOffset++) {
      final scheduled = DateTime(
        2024,
        1,
        1,
        12,
        47,
      ).add(Duration(days: dayOffset));
      final windows = estimator.calculateTargetWindows(
        sequence,
        scheduled,
        latitude: latitude,
        longitude: longitude,
        minAltitude: minAltitude,
      );
      final window = windows['target1']!;
      final altitude = window.altitudeAt(scheduled);
      if (altitude != null &&
          altitude > 60 &&
          window.riseTime != null &&
          window.riseTime!.isAfter(scheduled)) {
        return (scheduled: scheduled, window: window);
      }
    }
    fail('No date produced a target up at local 12:47 with a later rise time');
  }

  test('a target at the zenith is not reported as "before target rises"', () {
    final testCase = findZenithNoonCase();
    final sequence = buildSequence();

    final analysis = estimator.analyzeSequence(
      sequence,
      testCase.scheduled,
      latitude: latitude,
      longitude: longitude,
      minAltitude: minAltitude,
    );

    // Guard the premise: the window really does report a rise that has not
    // happened yet, which is the case a plain interval test gets wrong.
    expect(testCase.window.riseTime!.isAfter(testCase.scheduled), isTrue);
    expect(testCase.window.altitudeAt(testCase.scheduled), greaterThan(60.0));

    expect(
      analysis.conflicts.where((c) => c.contains('before target rises')),
      isEmpty,
      reason:
          'target is at ${testCase.window.altitudeAt(testCase.scheduled)} '
          'degrees at ${testCase.scheduled}',
    );
    expect(
      analysis.conflicts.where((c) => c.contains('after target sets')),
      isEmpty,
    );
  });

  test('isVisibleAt answers from the sky, not from the reported interval', () {
    final testCase = findZenithNoonCase();
    expect(testCase.window.isVisibleAt(testCase.scheduled), isTrue);
  });

  test('a target genuinely below the floor still raises a conflict', () {
    final sequence = buildSequence();
    // Twelve hours from the zenith case the same target is on the far side of
    // the sky and provably down.
    final zenith = findZenithNoonCase();
    final scheduled = zenith.scheduled.add(const Duration(hours: 12));
    final windows = estimator.calculateTargetWindows(
      sequence,
      scheduled,
      latitude: latitude,
      longitude: longitude,
      minAltitude: minAltitude,
    );
    final window = windows['target1']!;
    expect(window.altitudeAt(scheduled), lessThan(minAltitude));

    final timings = [
      NodeTiming(
        nodeId: 'exposure1',
        nodeName: 'Light 60s',
        nodeType: 'TakeExposure',
        estimatedStart: scheduled,
        estimatedEnd: scheduled.add(const Duration(minutes: 5)),
        duration: const Duration(minutes: 5),
        targetHeaderId: 'target1',
      ),
    ];

    final conflicts = estimator.findTimingConflicts(timings, windows, sequence);
    expect(conflicts, isNotEmpty);
  });

  test('a boundary on another calendar day is printed with its date', () {
    final sequence = buildSequence();
    final scheduled = DateTime(2024, 6, 15, 19, 0);
    final windows = {
      'target1': TargetWindow(
        targetId: 'target1',
        targetName: 'Zenith Target',
        // Rises the following morning: "03:41" alone reads as time already
        // past when printed beside a 19:00 start.
        riseTime: DateTime(2024, 6, 16, 3, 41),
        setTime: DateTime(2024, 6, 16, 11, 0),
      ),
    };
    final timings = [
      NodeTiming(
        nodeId: 'exposure1',
        nodeName: 'Light 60s',
        nodeType: 'TakeExposure',
        estimatedStart: scheduled,
        estimatedEnd: scheduled.add(const Duration(minutes: 5)),
        duration: const Duration(minutes: 5),
        targetHeaderId: 'target1',
      ),
    ];

    final conflicts = estimator.findTimingConflicts(timings, windows, sequence);
    expect(conflicts, hasLength(1));
    expect(conflicts.single, contains('before target rises at 03:41 on 06-16'));
  });
}
