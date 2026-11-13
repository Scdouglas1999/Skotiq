import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// A "loop until stopped" target that is up all night at the test site, so
/// only the dawn park ends it.
Sequence _loopingPlan() => Sequence.create(
  name: 'Heart',
  rootNodeId: 'root',
  nodes: {
    'root': InstructionSetNode(
      id: 'root',
      name: 'Root',
      childIds: const ['target'],
    ),
    'target': TargetHeaderNode(
      id: 'target',
      name: 'Heart',
      targetName: 'Heart',
      raHours: 2.545,
      decDegrees: 61.45,
      parentId: 'root',
      childIds: const ['se'],
    ),
    'se': SmartExposureNode(
      id: 'se',
      name: 'SHO',
      parentId: 'target',
      loopUntilStopped: true,
      plans: const [
        FilterPlan(filterName: 'Ha', count: 999, durationSecs: 180),
        FilterPlan(filterName: 'OIII', count: 999, durationSecs: 180),
      ],
    ),
  },
);

void main() {
  final start = DateTime.utc(2026, 11, 13, 1);
  final parkAt = start.add(const Duration(hours: 3));
  PlanTimer timer({int autoFocusEveryMinutes = 0}) => PlanTimer(
    site: (latitude: 41.0, longitude: -74.0),
    runEndsBy: (_) => parkAt,
    autoFocusEveryMinutes: autoFocusEveryMinutes,
  );

  test('the dawn park ends a plan that loops until stopped', () {
    final timing = timer().time(_loopingPlan(), start);

    expect(timing.runEndsBy, parkAt);
    expect(timing.end.difference(parkAt).inMinutes.abs(), lessThan(10));
  });

  test('the pre-flight simulation ends where the plan\'s timing ends', () {
    final plan = _loopingPlan();
    for (final t in [timer(), timer(autoFocusEveryMinutes: 60)]) {
      expect(
        t.simulate(plan, start: start).end,
        t.time(plan, start).end,
        reason: 'one plan, one answer',
      );
    }
  });

  test('the autofocus runs the executor adds are in the total', () {
    final plan = _loopingPlan();
    final without = timer().time(plan, start).total;
    final withAf = timer(autoFocusEveryMinutes: 60).time(plan, start).total;

    expect(withAf, greaterThan(without));
  });

  test('without a site nothing but the plan bounds it', () {
    const noSite = PlanTimer();
    final timing = noSite.time(_loopingPlan(), start);

    expect(timing.runEndsBy, isNull);
    expect(timing.timings.any((t) => t.openEnded), isTrue);
  });
}
