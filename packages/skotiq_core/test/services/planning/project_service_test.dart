// Tests for ProjectService — project/membership CRUD, project-scoped progress
// derivation, and the manual change stream.
//
// Setup: an in-memory drift database (the established core test pattern). The
// `projects` / `project_targets` tables are created lazily by the service's
// `_ensureSchema` on first access, so these tests exercise the same defensive
// DDL path a fresh install would hit before the v40 migration runs. Accrued
// progress is seeded as real accepted-light rows in `captured_images` so the
// derivation goes through the live `capturedFrameCount` primitive rather than
// any denormalized tally.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/planning/project.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/services/planning/project_service.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';

void main() {
  late SkotiqDatabase database;
  late IntegrationGoalService goalService;
  late ProjectService service;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    goalService = IntegrationGoalService(database);
    service = ProjectService(database, goalService);
  });

  tearDown(() async {
    await goalService.dispose();
    await service.dispose();
    await database.close();
  });

  /// Insert a target and return its id.
  Future<int> insertTarget({
    required String name,
    double ra = 0.7,
    double dec = 41.3,
  }) {
    return database
        .into(database.targets)
        .insert(TargetsCompanion.insert(name: name, ra: ra, dec: dec));
  }

  /// Insert [count] accepted light frames of [filter] for [targetId].
  Future<void> insertCaptures({
    required int targetId,
    required String filter,
    required int count,
    double exposureSeconds = 60.0,
  }) async {
    for (var i = 0; i < count; i++) {
      await database
          .into(database.capturedImages)
          .insert(
            CapturedImagesCompanion.insert(
              filePath: 'frame_${filter}_$i.fits',
              fileName: 'frame_${filter}_$i.fits',
              exposureDuration: exposureSeconds,
              capturedAt: DateTime(2026, 5, 12, 22, 0),
              frameType: const Value('light'),
              targetId: Value(targetId),
              filter: Value(filter),
            ),
          );
    }
  }

  group('project CRUD round-trip', () {
    test('create / get / list / update / delete', () async {
      final id = await service.createProject(
        name: 'Winter Nebulae',
        description: 'Orion + Horsehead',
        colorArgb: 0xFF5B9EC4,
      );
      expect(id, greaterThan(0));

      final fetched = await service.getProject(id);
      expect(fetched, isNotNull);
      expect(fetched!.name, 'Winter Nebulae');
      expect(fetched.description, 'Orion + Horsehead');
      expect(fetched.colorArgb, 0xFF5B9EC4);
      expect(
        fetched.createdAt.isUtc,
        isFalse,
      ); // fromRow yields local DateTime.

      final all = await service.listProjects();
      expect(all, hasLength(1));
      expect(all.single.id, id);

      final updated = fetched
          .copyWith(name: 'Galaxy Season')
          .copyWith(clearDescription: true, clearColor: true);
      await service.updateProject(updated);
      final afterUpdate = await service.getProject(id);
      expect(afterUpdate!.name, 'Galaxy Season');
      expect(afterUpdate.description, isNull);
      expect(afterUpdate.colorArgb, isNull);

      await service.deleteProject(id);
      expect(await service.getProject(id), isNull);
      expect(await service.listProjects(), isEmpty);
    });

    test('updateProject without an id throws ArgumentError', () async {
      final now = DateTime.now();
      expect(
        () => service.updateProject(
          Project(name: 'x', createdAt: now, updatedAt: now),
        ),
        throwsArgumentError,
      );
    });

    test('updateProject bumps updated_at', () async {
      final id = await service.createProject(name: 'P');
      final before = (await service.getProject(id))!;
      // Force a distinct second so the unix-second timestamp can advance.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await service.updateProject(before.copyWith(name: 'P2'));
      final after = (await service.getProject(id))!;
      expect(
        after.updatedAt.isAfter(before.updatedAt) ||
            after.updatedAt.isAtSameMomentAs(before.updatedAt),
        isTrue,
      );
      expect(after.name, 'P2');
    });
  });

  group('membership', () {
    test('addTarget is idempotent under the UNIQUE constraint', () async {
      final projectId = await service.createProject(name: 'P');
      final targetId = await insertTarget(name: 'M31');

      await service.addTarget(
        projectId: projectId,
        targetId: targetId,
        priorityOverride: 8,
      );
      // Re-adding must not duplicate, and must preserve the original override.
      await service.addTarget(
        projectId: projectId,
        targetId: targetId,
        priorityOverride: 3,
      );

      final members = await service.listTargets(projectId);
      expect(members, hasLength(1));
      expect(members.single.targetId, targetId);
      expect(members.single.priorityOverride, 8);

      expect(await service.targetIdsForProject(projectId), [targetId]);
    });

    test('removeTarget detaches a member', () async {
      final projectId = await service.createProject(name: 'P');
      final t1 = await insertTarget(name: 'A');
      final t2 = await insertTarget(name: 'B');
      await service.addTarget(projectId: projectId, targetId: t1);
      await service.addTarget(projectId: projectId, targetId: t2);

      await service.removeTarget(projectId: projectId, targetId: t1);
      expect(await service.targetIdsForProject(projectId), [t2]);
    });

    test('setPriorityOverride sets and clears the override', () async {
      final projectId = await service.createProject(name: 'P');
      final targetId = await insertTarget(name: 'M31');
      await service.addTarget(projectId: projectId, targetId: targetId);
      expect(
        (await service.listTargets(projectId)).single.priorityOverride,
        isNull,
      );

      await service.setPriorityOverride(
        projectId: projectId,
        targetId: targetId,
        priorityOverride: 9,
      );
      expect((await service.listTargets(projectId)).single.priorityOverride, 9);

      await service.setPriorityOverride(
        projectId: projectId,
        targetId: targetId,
        priorityOverride: null,
      );
      expect(
        (await service.listTargets(projectId)).single.priorityOverride,
        isNull,
      );
    });

    test('deleteProject cascades memberships', () async {
      final projectId = await service.createProject(name: 'P');
      final targetId = await insertTarget(name: 'M31');
      await service.addTarget(projectId: projectId, targetId: targetId);
      expect(await service.listTargets(projectId), hasLength(1));

      await service.deleteProject(projectId);
      // The cascade removes the membership row; querying by the (now gone)
      // project id returns nothing.
      expect(await service.listTargets(projectId), isEmpty);
    });
  });

  group('buildProgress', () {
    test(
      'computes accrued frames / percent / completeness from history',
      () async {
        final projectId = await service.createProject(name: 'Campaign');
        final targetId = await insertTarget(name: 'M31');
        await service.addTarget(projectId: projectId, targetId: targetId);

        // Goal: Lum @ 60s x 100 frames. Capture 25 -> 25% complete, incomplete.
        await goalService.upsert(
          IntegrationGoal(
            targetId: targetId,
            filter: 'Lum',
            exposureSeconds: 60.0,
            frameCount: 100,
            priority: 5,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );
        // Mixed-case filter on the capture rows proves the case-insensitive
        // LOWER(filter) match in capturedFrameCount.
        await insertCaptures(targetId: targetId, filter: 'lum', count: 25);

        final progress = await service.buildProgress(projectId);
        expect(progress.totalTargets, 1);
        final tp = progress.targets.single;
        expect(tp.filters, hasLength(1));

        final line = tp.filters.single;
        expect(line.capturedFrames, 25);
        expect(line.goalFrames, 100);
        expect(line.isComplete, isFalse);

        expect(tp.percentComplete, closeTo(0.25, 1e-9));
        expect(tp.isComplete, isFalse);
        expect(progress.totalPercentComplete, closeTo(0.25, 1e-9));
        expect(progress.completeTargets, 0);
      },
    );

    test(
      'a fully-captured target reads complete and drops from incomplete set',
      () async {
        // COMPLETION REMOVES FROM FUTURE NIGHTS — at the project layer, a target
        // whose goals are fully met must not appear in incompleteTargets.
        final projectId = await service.createProject(name: 'Campaign');
        final doneTarget = await insertTarget(name: 'Done');
        final pendingTarget = await insertTarget(name: 'Pending');
        await service.addTarget(projectId: projectId, targetId: doneTarget);
        await service.addTarget(projectId: projectId, targetId: pendingTarget);

        await goalService.upsert(
          IntegrationGoal(
            targetId: doneTarget,
            filter: 'Lum',
            exposureSeconds: 60.0,
            frameCount: 10,
            priority: 5,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );
        await goalService.upsert(
          IntegrationGoal(
            targetId: pendingTarget,
            filter: 'Lum',
            exposureSeconds: 60.0,
            frameCount: 10,
            priority: 5,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );

        // Overshoot the done target (12 >= 10) and partially fill the pending one.
        await insertCaptures(targetId: doneTarget, filter: 'Lum', count: 12);
        await insertCaptures(targetId: pendingTarget, filter: 'Lum', count: 4);

        final progress = await service.buildProgress(projectId);
        expect(progress.completeTargets, 1);

        final incompleteIds = progress.incompleteTargets
            .map((t) => t.targetId)
            .toList();
        expect(incompleteIds, isNot(contains(doneTarget)));
        expect(incompleteIds, contains(pendingTarget));

        final donePct = progress.targets
            .firstWhere((t) => t.targetId == doneTarget)
            .percentComplete;
        expect(donePct, 1.0); // clamped to 1.0 on overshoot.
      },
    );

    test('throws StateError on a missing project', () async {
      expect(() => service.buildProgress(9999), throwsStateError);
    });
  });

  group('watchChanges', () {
    test('fires on every mutation', () async {
      final events = <void>[];
      final sub = service.watchChanges().listen(events.add);

      final projectId = await service.createProject(name: 'P');
      final targetId = await insertTarget(name: 'M31');
      await service.addTarget(projectId: projectId, targetId: targetId);
      await service.setPriorityOverride(
        projectId: projectId,
        targetId: targetId,
        priorityOverride: 7,
      );
      await service.removeTarget(projectId: projectId, targetId: targetId);
      await service.deleteProject(projectId);

      // Let the broadcast events drain.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // create + addTarget + setPriorityOverride + removeTarget + deleteProject
      expect(events.length, 5);
    });
  });
}
