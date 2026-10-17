import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

DeepSkyObject _target(String id) => DeepSkyObject(
  id: id,
  name: id,
  coordinates: const CelestialCoordinate(ra: 1, dec: 2),
  type: DsoType.galaxy,
);

void main() {
  test('reorder moves a row and normalizes every priority', () {
    final notifier = TargetQueueNotifier();
    addTearDown(notifier.dispose);
    notifier.addTarget(_target('A'));
    notifier.addTarget(_target('B'));
    notifier.addTarget(_target('C'));

    final cId = notifier.state.targets
        .singleWhere((t) => t.displayName == 'C')
        .id;
    notifier.reorderTarget(cId, 1);

    expect(notifier.state.targets.map((t) => t.displayName), ['C', 'A', 'B']);
    expect(notifier.state.targets.map((t) => t.priority), [1, 2, 3]);
  });

  test('unknown active id cannot corrupt the queue selection', () {
    final notifier = TargetQueueNotifier();
    addTearDown(notifier.dispose);
    notifier.addTarget(_target('A'));

    notifier.setActiveTarget('missing');

    expect(notifier.state.activeTargetId, isNull);
    expect(notifier.state.targets.single.status, QueuedTargetStatus.pending);
  });

  test('open-ended progress stays active while a completed plan advances', () {
    final notifier = TargetQueueNotifier();
    addTearDown(notifier.dispose);
    notifier.addTarget(_target('Open ended'));
    notifier.addTarget(_target('Planned'), plannedExposures: 2);
    notifier.startSession();

    notifier.updateExposureProgress(3);
    expect(notifier.state.activeTarget?.displayName, 'Open ended');
    expect(notifier.state.activeTarget?.completedExposures, 3);
    expect(notifier.state.activeTarget?.status, QueuedTargetStatus.active);

    final planned = notifier.state.targets.singleWhere(
      (target) => target.displayName == 'Planned',
    );
    notifier.setActiveTarget(planned.id);
    notifier.updateExposureProgress(2);

    expect(notifier.state.activeTarget?.displayName, 'Open ended');
    expect(
      notifier.state.targets
          .singleWhere((target) => target.id == planned.id)
          .status,
      QueuedTargetStatus.completed,
    );
  });
}
