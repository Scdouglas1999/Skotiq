// Closeout coverage for the sequence repository's library-summary,
// tags/favorites, run-diff, and version-history wiring. Drives a real
// in-memory database so the grouped summary query, snapshot diff, and version
// snapshot/restore all round-trip end to end.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late SequenceRepository repo;
  late SequenceFileService fileService;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    fileService = SequenceFileService();
    repo = SequenceRepository(
      db.sequencesDao,
      runsDao: db.sequenceRunsDao,
      versionsDao: db.sequenceVersionsDao,
      fileService: fileService,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Sequence buildSequence({
    required String id,
    required String name,
    required String targetName,
  }) {
    final root = InstructionSetNode(id: '$id-root', childIds: ['$id-target']);
    final target = TargetHeaderNode(
      id: '$id-target',
      name: targetName,
      parentId: '$id-root',
      childIds: ['$id-expose'],
      targetName: targetName,
      raHours: 5.5,
      decDegrees: -5.4,
    );
    final expose = ExposureNode(
      id: '$id-expose',
      parentId: '$id-target',
      filter: 'L',
      durationSecs: 120,
      count: 10,
    );
    return Sequence.create(
      id: id,
      name: name,
      rootNodeId: root.id,
      nodes: {root.id: root, target.id: target, expose.id: expose},
    );
  }

  test(
    'loadSequenceSummaries returns grouped counts without full hydration',
    () async {
      final idA = await repo.saveSequence(
        buildSequence(id: 'a', name: 'Orion', targetName: 'M42'),
      );
      await repo.saveSequence(
        buildSequence(id: 'b', name: 'Andromeda', targetName: 'M31'),
      );

      final summaries = await repo.loadSequenceSummaries();
      expect(summaries.length, 2);

      final orion = summaries.firstWhere((s) => s.id == idA);
      expect(orion.name, 'Orion');
      expect(orion.nodeCount, 3);
      expect(orion.targetCount, 1);
      expect(orion.exposureCount, 1);
      expect(orion.primaryTargetName, 'M42');
      expect(orion.runCount, 0);
      expect(orion.lastRunAt, isNull);
      expect(orion.isFavorite, isFalse);
      expect(orion.tags, isEmpty);
      expect(orion.createdAt, (await repo.loadSequence(idA))!.createdAt);
    },
  );

  test('setTags normalises and toggleFavorite flips persisted flags', () async {
    final id = await repo.saveSequence(
      buildSequence(id: 'a', name: 'Orion', targetName: 'M42'),
    );

    await repo.setTags(id, ['  narrowband ', 'winter', 'winter', '   ']);
    final taggedNow = await repo.toggleFavorite(id);
    expect(taggedNow, isTrue);

    final summary = (await repo.loadSequenceSummaries()).single;
    expect(summary.tags, ['narrowband', 'winter']);
    expect(summary.isFavorite, isTrue);

    expect(await repo.toggleFavorite(id), isFalse);
    expect((await repo.loadSequenceSummaries()).single.isFavorite, isFalse);
  });

  test(
    'loadPreviousRunSnapshot returns the prior completed run snapshot',
    () async {
      final id = await repo.saveSequence(
        buildSequence(id: 'a', name: 'Orion', targetName: 'M42'),
      );
      final runsDao = db.sequenceRunsDao;

      final firstRun = await runsDao.startRun(
        sequenceId: id,
        sequenceName: 'Orion',
        sequenceSnapshotJson: '{"marker":"first"}',
      );
      await runsDao.finishRun(firstRun, 'completed', '{}');

      // Ensure the two runs land on distinct `startedAt` values so the
      // "strictly before" prior-run query is unambiguous. Drift persists
      // DateTime at second resolution, and real runs are nights apart, so the
      // delay must cross a whole-second boundary to be observable here.
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      final secondRun = await runsDao.startRun(
        sequenceId: id,
        sequenceName: 'Orion',
        sequenceSnapshotJson: '{"marker":"second"}',
      );
      await runsDao.finishRun(secondRun, 'completed', '{}');

      final prior = await repo.loadPreviousRunSnapshot(
        id,
        beforeRunId: secondRun,
      );
      expect(prior, '{"marker":"first"}');

      final context = await repo.loadRunDiffContext(secondRun);
      expect(context.sequenceId, id);
      expect(context.currentSnapshotJson, '{"marker":"second"}');
      expect(context.previousSnapshotJson, '{"marker":"first"}');

      // An unknown row must not accidentally compare against the newest run.
      expect(
        await repo.loadPreviousRunSnapshot(id, beforeRunId: 999999),
        isNull,
      );

      // Run-history roll-up must now surface in the summary.
      final summary = (await repo.loadSequenceSummaries()).single;
      expect(summary.runCount, 2);
      expect(summary.lastRunAt, isNotNull);
    },
  );

  test(
    'snapshotVersionOnSave / listVersions / restoreVersion round-trip',
    () async {
      final id = await repo.saveSequence(
        buildSequence(id: 'a', name: 'Orion v1', targetName: 'M42'),
      );

      final loaded = await repo.loadSequence(id);
      expect(loaded, isNotNull);

      final versionId = await repo.snapshotVersionOnSave(
        loaded!,
        label: 'before edit',
      );
      expect(versionId, isNotNull);

      // Mutate + re-save so the live row differs from the captured version.
      await repo.saveSequence(loaded.copyWith(name: 'Orion v2'));
      expect((await repo.loadSequence(id))!.name, 'Orion v2');

      final versions = await repo.listVersions(id);
      expect(versions.length, 1);
      expect(versions.single.label, 'before edit');

      final restored = await repo.restoreVersion(versions.single.id);
      expect(restored, isNotNull);
      expect(restored!.name, 'Orion v1');
      expect(restored.databaseId, id, reason: 'restore re-anchors to same row');
    },
  );

  test('snapshotVersionOnSave is a no-op for an unsaved sequence', () async {
    final unsaved = buildSequence(id: 'a', name: 'Draft', targetName: 'M42');
    expect(await repo.snapshotVersionOnSave(unsaved), isNull);
  });
}
