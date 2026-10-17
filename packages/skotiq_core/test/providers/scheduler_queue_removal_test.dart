// "Remove from scheduler" / "Clear all" make a target INELIGIBLE for the
// autopilot.
//
// Deleting the target's integration goals and constraints is not enough: a
// goal-less target is a legal free-form candidate — the contract an OSC rig
// with no goal rows relies on — so the autopilot would pick the target the
// operator just removed and the row would reappear on the next evaluation.
// Removal records queue membership, and the candidate loader drops removed
// targets before the engine scores them.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/database/database.dart' hide Sequence;
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/scheduler_provider.dart';
import 'package:skotiq_core/src/services/planning/project_service.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_queue_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  Future<int> insertTarget(String name) {
    return database
        .into(database.targets)
        .insert(
          TargetsCompanion.insert(
            name: name,
            ra: 5.5,
            dec: -5.4,
            priority: const Value(5),
          ),
        );
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<List<int>> loadCandidateIds(
    ProviderContainer container, {
    int? projectId,
  }) async {
    final candidates = await container
        .read(schedulerCandidateLoaderProvider)
        .load(projectId: projectId);
    return candidates.map((c) => c.targetId).toList();
  }

  group('a target removed from the scheduler queue', () {
    test('is never a candidate, even with no goals of its own', () async {
      final container = makeContainer();
      final removedId = await insertTarget('Removed');
      final keptId = await insertTarget('Kept');

      expect(
        await loadCandidateIds(container),
        containsAll(<int>[removedId, keptId]),
        reason: 'both are goal-less free-form candidates to begin with',
      );

      await container.read(schedulerQueueServiceProvider).remove(removedId);

      expect(
        await loadCandidateIds(container),
        <int>[keptId],
        reason:
            'the autopilot re-picked the target the operator had just removed, '
            'because deleting its goals left it goal-less rather than removed',
      );
    });

    test('stays removed across a rebuild of the service', () async {
      final container = makeContainer();
      final removedId = await insertTarget('Removed');
      await container.read(schedulerQueueServiceProvider).remove(removedId);

      final fresh = makeContainer();

      expect(await loadCandidateIds(fresh), isEmpty);
      expect(
        await fresh.read(schedulerQueueServiceProvider).removedTargetIds(),
        <int>{removedId},
      );
    });

    test('is dropped from a project-scoped load too', () async {
      final container = makeContainer();
      final removedId = await insertTarget('Removed');
      final keptId = await insertTarget('Kept');

      final projects = container.read(projectServiceProvider);
      final projectId = await projects.createProject(name: 'Campaign');
      await projects.addTarget(projectId: projectId, targetId: removedId);
      await projects.addTarget(projectId: projectId, targetId: keptId);

      await container.read(schedulerQueueServiceProvider).remove(removedId);

      expect(await loadCandidateIds(container, projectId: projectId), <int>[
        keptId,
      ]);
    });

    test('comes back when the operator readmits it', () async {
      final container = makeContainer();
      final targetId = await insertTarget('Second thoughts');
      final queue = container.read(schedulerQueueServiceProvider);

      await queue.remove(targetId);
      await queue.readmit(targetId);

      expect(await loadCandidateIds(container), <int>[targetId]);
    });

    test('comes back when the operator gives it a new goal', () async {
      final container = makeContainer();
      final targetId = await insertTarget('Second thoughts');
      await container.read(schedulerQueueServiceProvider).remove(targetId);

      await container
          .read(integrationGoalServiceProvider)
          .upsert(
            IntegrationGoal(
              targetId: targetId,
              filter: 'Ha',
              exposureSeconds: 300,
              frameCount: 20,
              createdAt: DateTime.utc(2026, 5, 1),
            ),
          );

      expect(
        await loadCandidateIds(container),
        <int>[targetId],
        reason:
            'a goal the operator just typed on a removed target would sit '
            'there while the autopilot went on ignoring the target',
      );
    });
  });

  group('Clear all', () {
    test('leaves the autopilot with nothing to pick', () async {
      final container = makeContainer();
      final aId = await insertTarget('Alpha');
      final bId = await insertTarget('Beta');
      // A target with real work attached is cleared as well: clear-all means
      // the queue is empty, not "the goal-less ones are gone".
      await container
          .read(integrationGoalServiceProvider)
          .upsert(
            IntegrationGoal(
              targetId: bId,
              filter: 'L',
              exposureSeconds: 60,
              frameCount: 10,
              createdAt: DateTime.utc(2026, 5, 1),
            ),
          );

      await container.read(schedulerQueueServiceProvider).removeAll();

      expect(await loadCandidateIds(container), isEmpty);
      expect(
        await container.read(schedulerQueueServiceProvider).removedTargetIds(),
        <int>{aId, bId},
      );
    });

    test('a target added after the clear is in the queue again', () async {
      final container = makeContainer();
      await insertTarget('Before');
      await container.read(schedulerQueueServiceProvider).removeAll();

      final laterId = await insertTarget('Added after the clear');

      expect(
        await loadCandidateIds(container),
        <int>[laterId],
        reason:
            'clear-all empties the queue as it stands; it is not a standing '
            'rule against every target the operator adds afterwards',
      );
    });
  });
}
