import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/depthlock/depthlock_models.dart';

import 'mock_backend.dart';

/// The widget-test seam is only useful if it behaves like the native store,
/// so the revision bookkeeping other packages lean on is pinned here.
void main() {
  late MockBackend backend;
  late InMemoryDepthLockGoals store;

  setUp(() {
    backend = MockBackend();
    store = stubDepthLockGoals(
      backend,
      seed: [depthLockGoalFixture(id: 'seeded', revision: 4)],
    );
  });

  test(
    'a seeded goal is readable at the revision it was seeded with',
    () async {
      final goal = await backend.getDepthLockGoal('seeded');
      expect(goal.revision, 4);
      expect((await backend.listDepthLockGoals()).single.id, 'seeded');
    },
  );

  test('creating and revising advances the revision', () async {
    final created = await backend.createDepthLockGoal(
      depthLockDefinitionFixture(filterName: 'OIII'),
      goalId: 'm42-oiii',
    );
    expect(created.revision, 1);

    final revised = await backend.reviseDepthLockGoal(
      goalId: 'm42-oiii',
      expectedRevision: 1,
      definition: depthLockDefinitionFixture(threshold: 20),
    );
    expect(revised.revision, 2);
    expect(revised.definition.measurement.threshold, 20);
  });

  test('a stale expected revision is refused and changes nothing', () async {
    await expectLater(
      backend.reviseDepthLockGoal(
        goalId: 'seeded',
        expectedRevision: 1,
        definition: depthLockDefinitionFixture(),
      ),
      throwsA(isA<StateError>()),
    );
    expect(store.goals['seeded']!.revision, 4);
  });

  test('preferences change the flags without moving the revision', () async {
    final updated = await backend.setDepthLockGoalPreferences(
      goalId: 'seeded',
      expectedRevision: 4,
      enabled: true,
      automaticCompletion: false,
    );
    expect(updated.revision, 4);
    expect(updated.definition.automaticCompletion, isFalse);
  });

  test('ingest records the path it was handed', () async {
    final outcome = await backend.ingestDepthLockFrame(
      goalId: 'seeded',
      path: '/data/light_0001.fits',
    );
    expect(outcome.outcome, 'added');
    expect(outcome.state, DepthLockState.collecting);
    expect(store.ingestedPaths, ['/data/light_0001.fits']);
  });

  test('the curve climbs, then projects past the last measurement', () async {
    final points = await backend.depthLockGoalCurve('seeded');

    expect(points, isNotEmpty);
    final measured = points.where((p) => !p.projected).toList();
    final projected = points.where((p) => p.projected).toList();
    expect(measured, isNotEmpty);
    expect(projected, isNotEmpty);
    // Frame counts only ever increase, and every projection sits past the
    // last thing actually measured.
    expect(measured.last.frames, lessThan(projected.first.frames));
    expect(measured.first.score, lessThan(measured.last.score));
    for (final point in points) {
      expect(point.conservativeScore, lessThanOrEqualTo(point.score));
    }
  });

  test('the floor suggestion answers with a plausible measurement', () async {
    final suggestion = await backend.suggestDepthLockFloor(
      referencePath: '/data/m42/ref.fits',
      darkPath: '/data/masters/dark.fits',
      flatPath: '/data/masters/flat.fits',
      scaleArcsec: 6,
    );

    expect(suggestion.floorAdu, greaterThan(0));
    expect(suggestion.aperturePixels, greaterThan(0));
    expect(suggestion.source, isNotEmpty);
  });

  test('removing needs the current revision', () async {
    await expectLater(
      backend.removeDepthLockGoal(goalId: 'seeded', expectedRevision: 1),
      throwsA(isA<StateError>()),
    );
    await backend.removeDepthLockGoal(goalId: 'seeded', expectedRevision: 4);
    expect(store.goals, isEmpty);
  });
}
