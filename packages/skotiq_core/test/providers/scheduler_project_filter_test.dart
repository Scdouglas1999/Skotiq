// Tests for the project-scoped scheduler candidate loader (component C7).
//
// Coverage:
//   * SchedulerCandidateLoader.load(projectId:) restricts the candidate set to
//     the targets that belong to the project, and applies the per-membership
//     priority_override (falling back to the target's own priority when no
//     override is set).
//   * load() with no projectId returns the full catalog verbatim (the original
//     behavior — non-project users are unaffected).
//   * A member target whose integration goals are all met is dropped by the
//     engine's scoreCandidate (carry-forward: only incomplete + in-project
//     candidates survive a night's rotation), proving the loader stays in scope
//     while completion is still decided downstream in the engine.
//
// Setup mirrors planning_provider_test.dart: an in-memory drift database wired
// through databaseProvider, with the project / project_targets tables created
// via ProjectService (the canonical owner of that DDL) and integration goals /
// captured frames seeded through the integration-goal stack.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/database/database.dart' hide Sequence;
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart'
    show ExposureNode, Sequence;
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart'
    show EquipmentProfileModel, activeEquipmentProfileProvider;
import 'package:skotiq_core/src/providers/scheduler_provider.dart';
import 'package:skotiq_core/src/services/planning/project_service.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  Future<int> insertTarget({
    required String name,
    double ra = 5.5,
    double dec = -5.4,
    int priority = 5,
  }) {
    return database
        .into(database.targets)
        .insert(
          TargetsCompanion.insert(
            name: name,
            ra: ra,
            dec: dec,
            priority: Value(priority),
          ),
        );
  }

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

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('SchedulerCandidateLoader.load(projectId:)', () {
    test(
      'returns only the project members, with the priority override applied',
      () async {
        final container = makeContainer();

        // Two catalog targets at different global priorities.
        final inProjectId = await insertTarget(name: 'In Project', priority: 3);
        final outOfProjectId = await insertTarget(
          name: 'Out Of Project',
          priority: 9,
        );

        // A project containing only the first target, with a priority override
        // that differs from both the target's own priority (3) and the other
        // target's (9), so we can prove the override — not either raw priority —
        // is what surfaces.
        final projectService = container.read(projectServiceProvider);
        final projectId = await projectService.createProject(name: 'Campaign');
        await projectService.addTarget(
          projectId: projectId,
          targetId: inProjectId,
          priorityOverride: 7,
        );

        final loader = container.read(schedulerCandidateLoaderProvider);
        final scoped = await loader.load(projectId: projectId);

        expect(scoped, hasLength(1));
        expect(scoped.single.targetId, inProjectId);
        expect(scoped.single.name, 'In Project');
        // Override (7) beats the target's own global priority (3).
        expect(scoped.single.userPriority, 7);
        expect(scoped.map((c) => c.targetId), isNot(contains(outOfProjectId)));
      },
    );

    test('falls back to the target priority when no override is set', () async {
      final container = makeContainer();
      final targetId = await insertTarget(name: 'No Override', priority: 4);

      final projectService = container.read(projectServiceProvider);
      final projectId = await projectService.createProject(name: 'Campaign');
      // No priorityOverride argument → COALESCE falls through to t.priority.
      await projectService.addTarget(projectId: projectId, targetId: targetId);

      final scoped = await container
          .read(schedulerCandidateLoaderProvider)
          .load(projectId: projectId);

      expect(scoped, hasLength(1));
      expect(scoped.single.userPriority, 4);
    });

    test('null projectId returns the full catalog', () async {
      final container = makeContainer();

      final aId = await insertTarget(name: 'Alpha', priority: 5);
      final bId = await insertTarget(name: 'Beta', priority: 5);

      // Attach only one to a project; the unfiltered load must still see both.
      final projectService = container.read(projectServiceProvider);
      final projectId = await projectService.createProject(name: 'Campaign');
      await projectService.addTarget(projectId: projectId, targetId: aId);

      final all = await container
          .read(schedulerCandidateLoaderProvider)
          .load(projectId: null);

      expect(all.map((c) => c.targetId), containsAll(<int>[aId, bId]));
      expect(all, hasLength(2));
    });

    test(
      'an empty project loads no candidates (not the full catalog)',
      () async {
        final container = makeContainer();
        await insertTarget(name: 'Lonely', priority: 5);

        final projectService = container.read(projectServiceProvider);
        final projectId = await projectService.createProject(name: 'Empty');

        final scoped = await container
            .read(schedulerCandidateLoaderProvider)
            .load(projectId: projectId);

        expect(scoped, isEmpty);
      },
    );
  });

  group('carry-forward: completed member targets drop in the engine', () {
    test(
      'a project member whose goals are all met is rejected by scoreCandidate',
      () async {
        final container = makeContainer();

        final completeId = await insertTarget(name: 'Complete', priority: 6);
        final incompleteId = await insertTarget(
          name: 'Incomplete',
          priority: 6,
        );

        final goalService = container.read(integrationGoalServiceProvider);
        // "Complete" target: a 5-frame goal that has been fully imaged.
        await goalService.upsert(
          IntegrationGoal(
            targetId: completeId,
            filter: 'L',
            exposureSeconds: 60,
            frameCount: 5,
            createdAt: DateTime(2026, 5, 1),
          ),
        );
        await insertCaptures(targetId: completeId, filter: 'L', count: 5);

        // "Incomplete" target: a 5-frame goal with only 1 frame captured.
        await goalService.upsert(
          IntegrationGoal(
            targetId: incompleteId,
            filter: 'L',
            exposureSeconds: 60,
            frameCount: 5,
            createdAt: DateTime(2026, 5, 1),
          ),
        );
        await insertCaptures(targetId: incompleteId, filter: 'L', count: 1);

        // Both targets belong to the active project.
        final projectService = container.read(projectServiceProvider);
        final projectId = await projectService.createProject(name: 'Campaign');
        await projectService.addTarget(
          projectId: projectId,
          targetId: completeId,
        );
        await projectService.addTarget(
          projectId: projectId,
          targetId: incompleteId,
        );

        final scoped = await container
            .read(schedulerCandidateLoaderProvider)
            .load(projectId: projectId);

        // The loader keeps both members in scope — completion is decided by the
        // engine, not the loader.
        expect(scoped, hasLength(2));

        // Build a pure engine instance and score each member. The completed one
        // must hard-fail on "all integration goals complete"; the incomplete one
        // must not carry that rejection (it may carry an altitude rejection
        // depending on the chosen `now`, which is irrelevant to this assertion).
        final engine = SchedulerEngine(
          site: const SchedulerSite(
            latitudeDegrees: 47.6,
            longitudeDegrees: -122.3,
            localOffset: Duration(hours: -8),
          ),
          sequenceSink: _NoopSink(),
        );
        addTearDown(engine.dispose);

        final now = DateTime.utc(2026, 5, 13, 6, 0);

        final complete = scoped.firstWhere((c) => c.targetId == completeId);
        final incomplete = scoped.firstWhere((c) => c.targetId == incompleteId);

        final completeScore = engine.scoreCandidate(complete, now);
        final incompleteScore = engine.scoreCandidate(incomplete, now);

        expect(completeScore.hardConstraintFailed, isTrue);
        expect(
          completeScore.rejectionReasons,
          contains('all integration goals complete'),
        );

        expect(
          incompleteScore.rejectionReasons,
          isNot(contains('all integration goals complete')),
        );
      },
    );
  });

  group('wheel-less profiles', () {
    // A profile with no named filters is an OSC/DSLR rig, not a
    // misconfiguration. Handing the engine a bare empty availableFilters list
    // makes every filter containment check false, so an unfiltered goal scores
    // 0 in _filterCoverageFactor and its frames drop out of the dispatched
    // sequence in favour of a defensive 30 s default frame.
    test(
      'a profile with no filters is loaded as one unfiltered slot, not none',
      () async {
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            activeEquipmentProfileProvider.overrideWithValue(
              const EquipmentProfileModel(name: 'OSC rig', filterNames: []),
            ),
          ],
        );
        addTearDown(container.dispose);

        final targetId = await insertTarget(name: 'OSC target');
        await container
            .read(integrationGoalServiceProvider)
            .upsert(
              IntegrationGoal(
                targetId: targetId,
                filter: '',
                exposureSeconds: 180.0,
                frameCount: 20,
                priority: 5,
                createdAt: DateTime.utc(2026, 5, 11),
              ),
            );

        final loaded = await container
            .read(schedulerCandidateLoaderProvider)
            .load(projectId: null);

        final candidate = loaded.firstWhere((c) => c.targetId == targetId);
        expect(candidate.availableFilters, <String>['']);

        // The whole point: the operator's 20 x 180 s unfiltered goal survives
        // into the dispatched sequence instead of being replaced by the
        // defensive single 30 s frame.
        final engine = SchedulerEngine(
          site: const SchedulerSite(
            latitudeDegrees: 47.6,
            longitudeDegrees: -122.3,
            localOffset: Duration(hours: -8),
          ),
          sequenceSink: _NoopSink(),
        );
        addTearDown(engine.dispose);

        final sequence = engine.buildSequenceForCandidate(candidate);
        final exposures = sequence.nodes.values.whereType<ExposureNode>();
        expect(exposures, hasLength(1));
        expect(exposures.single.count, 20);
        expect(exposures.single.durationSecs, 180.0);
        // null, not '': the empty sentinel would ask a wheel-less rig to
        // select a filter named "".
        expect(exposures.single.filter, isNull);
      },
    );

    test(
      'a profile that does name filters is passed through verbatim',
      () async {
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            activeEquipmentProfileProvider.overrideWithValue(
              const EquipmentProfileModel(
                name: 'Mono rig',
                filterNames: ['L', 'Ha'],
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final targetId = await insertTarget(name: 'Mono target');
        final loaded = await container
            .read(schedulerCandidateLoaderProvider)
            .load(projectId: null);

        expect(
          loaded.firstWhere((c) => c.targetId == targetId).availableFilters,
          <String>['L', 'Ha'],
        );
      },
    );
  });
}

/// A sequence sink that does nothing — the carry-forward test only exercises
/// the engine's pure scoring path (`scoreCandidate`), never its dispatch path.
class _NoopSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}

  @override
  Future<void> pauseSequence() async {}

  @override
  Future<void> resumeSequence() async {}

  @override
  Future<void> stopSequence() async {}

  @override
  Future<void> parkForEndOfNight() async {}

  @override
  Future<void> releaseSequenceOwnership() async {}
}
