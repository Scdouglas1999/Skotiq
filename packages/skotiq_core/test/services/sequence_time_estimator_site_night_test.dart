// A target's window is the site's night, whatever zone the computer is in.
//
// The estimator resolved the run's start to a night on the computer's clock
// and scanned from the computer's noon. A linked client in Los Angeles
// planning a New York rig opened the night at 15:00 EDT, after this target's
// 13:14 EDT culmination, and reported the next day's pass. Run this file under
// several `TZ` values; the expected values are New York's own.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

void main() {
  const latitude = 40.7128;
  const longitude = -74.0060;
  // 22:00 EDT on Aug 1 2026, as a local DateTime the way the app holds it.
  final runStart = DateTime.utc(2026, 8, 2, 2).toLocal();

  Sequence sequence() => Sequence.create(
    name: 'Site night',
    rootNodeId: 'target1',
    nodes: {
      'target1': TargetHeaderNode(
        id: 'target1',
        name: 'Afternoon transit',
        targetName: 'Afternoon transit',
        raHours: 9.0,
        decDegrees: 20.0,
        childIds: const ['exposure1'],
      ),
      'exposure1': ExposureNode(
        id: 'exposure1',
        name: 'Light 60s',
        durationSecs: 60,
        count: 5,
        parentId: 'target1',
      ),
    },
  );

  void expectNear(DateTime? actual, DateTime expected) {
    expect(actual, isNotNull);
    expect(
      actual!.toUtc().difference(expected).abs(),
      lessThan(const Duration(minutes: 1)),
      reason: 'got ${actual.toUtc()}, want $expected',
    );
  }

  test('rise, transit and set are the pass culminating in the site night', () {
    final window = const SequenceTimeEstimator().calculateTargetWindows(
      sequence(),
      runStart,
      latitude: latitude,
      longitude: longitude,
    )['target1']!;

    expectNear(window.riseTime, DateTime.utc(2026, 8, 1, 9, 59, 30));
    expectNear(window.transitTime, DateTime.utc(2026, 8, 1, 17, 14, 43));
    expectNear(window.setTime, DateTime.utc(2026, 8, 2, 0, 29, 56));
  });

  test('a direction-dependent floor is searched over the site night', () {
    final trees = SiteHorizonProfile.fromJson(
      '{"N":10,"NE":10,"E":10,"SE":10,"S":10,"SW":35,"W":35,"NW":10}',
    );
    final window =
        SequenceTimeEstimator(
          floor: AltitudeFloor(horizon: trees, minimumDeg: 0),
        ).calculateTargetWindows(
          sequence(),
          runStart,
          latitude: latitude,
          longitude: longitude,
        )['target1']!;

    // Still up when the search ends: the end is the site's next solar noon
    // (16:56 UTC at 74.006 W), not the computer's.
    expectNear(window.setTime, DateTime.utc(2026, 8, 2, 16, 56));
  });
}
