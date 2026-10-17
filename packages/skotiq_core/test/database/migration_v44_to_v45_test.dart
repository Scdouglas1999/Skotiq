// Migration round-trip test for the v44 -> v45 step (Mosaic M2 — durable
// mosaic projects).
//
// Verifies that upgrading a pre-v45 (v44) database:
//   * creates the new raw-DDL `mosaic_projects` + `mosaic_panels` tables with
//     their indexes,
//   * round-trips a project through MosaicProjectsDao
//     (`create` / `updateStatus` / `setOutputMaster` -> `getById`),
//   * round-trips panels through MosaicPanelsDao
//     (`upsert` / `setMaster` / `incrementCaptured` -> `getForProject`),
//   * enforces `UNIQUE(project_id, panel_index)` (upsert updates, not dupes),
//   * cascades panel deletion when the owning project is deleted, and
//   * re-running the v45 migration block is idempotent (no throw, no clobber).
//
// Strategy mirrors `migration_v43_to_v44_test.dart`:
//   1. Open a fresh on-disk DB at v45 via onCreate (lands the full schema).
//   2. Simulate the pre-v45 (v44) state by DROPping the mosaic tables and
//      rewinding `PRAGMA user_version = 44`.
//   3. Reopen — triggers onUpgrade(44, 45), running the v45 helper.
//   4. Assert the tables + indexes exist and round-trip data.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/mosaic_panels_dao.dart';
import 'package:skotiq_core/src/database/daos/mosaic_projects_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/mosaic_project.dart';

void main() {
  group('migration onUpgrade v44 -> v45 (Mosaic M2 durable projects)', () {
    /// Creates a fresh on-disk DB opened at v45 (so the full schema lands), then
    /// DROPs the v45 mosaic tables and rewinds `PRAGMA user_version = 44` so the
    /// next open triggers `onUpgrade(44, 45)`.
    Future<File> createV44Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DROP TABLE IF EXISTS mosaic_panels');
        await setupDb.customStatement('DROP TABLE IF EXISTS mosaic_projects');
        await setupDb.customStatement('PRAGMA user_version = 44');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    Future<Set<String>> tableNames(SkotiqDatabase db) async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    Future<Set<String>> indexNames(SkotiqDatabase db) async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
          .get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    Future<int> seedTarget(SkotiqDatabase db, String name) {
      return db.customInsert(
        'INSERT INTO targets (name, ra, dec) VALUES (?, ?, ?)',
        variables: [
          Variable.withString(name),
          Variable.withReal(20.85),
          Variable.withReal(30.7),
        ],
      );
    }

    Future<int> seedMaster(SkotiqDatabase db, int? targetId, String name) {
      return db.customInsert(
        'INSERT INTO integrated_masters '
        '(target_id, name, created_at, updated_at) VALUES (?, ?, ?, ?)',
        variables: [
          Variable<int>(targetId),
          Variable.withString(name),
          Variable.withInt(0),
          Variable.withInt(0),
        ],
      );
    }

    test(
      'creates mosaic_projects + mosaic_panels tables and their indexes',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v44_v45_create_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV44Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final names = await tableNames(upgraded);
          expect(names, contains('mosaic_projects'));
          expect(names, contains('mosaic_panels'));

          final indexes = await indexNames(upgraded);
          expect(indexes, contains('idx_mosaic_projects_target'));
          expect(indexes, contains('idx_mosaic_projects_status'));
          expect(indexes, contains('idx_mosaic_panels_project'));
          expect(indexes, contains('idx_mosaic_panels_master'));
        } finally {
          await upgraded.close();
        }
      },
    );

    test('a project + panels round-trip through the new DAOs', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v44_v45_roundtrip_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV44Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final regionTargetId = await seedTarget(upgraded, 'Veil Nebula');
        final panelTargetId = await seedTarget(upgraded, 'Veil · Panel 1');
        final projectsDao = MosaicProjectsDao(upgraded);
        final panelsDao = MosaicPanelsDao(upgraded);

        final projectId = await projectsDao.create(
          targetId: regionTargetId,
          name: 'Veil 3x2',
          rows: 2,
          cols: 3,
          overlapPct: 20.0,
          positionAngleDeg: 35.0,
        );
        expect(projectId, greaterThan(0));

        final project = await projectsDao.getById(projectId);
        expect(project, isNotNull);
        expect(project!.name, 'Veil 3x2');
        expect(project.rows, 2);
        expect(project.cols, 3);
        expect(project.totalPanels, 6);
        expect(project.overlapPct, closeTo(20.0, 1e-9));
        expect(project.positionAngleDeg, closeTo(35.0, 1e-9));
        expect(project.targetId, regionTargetId);
        expect(project.status, MosaicProjectStatus.planning);
        expect(project.outputMasterId, isNull);
        expect(project.isComplete, isFalse);

        // Two panels, one tied to a per-panel target.
        final panel0Id = await panelsDao.upsert(
          projectId: projectId,
          panelIndex: 0,
          centerRa: 20.80,
          centerDec: 30.50,
          targetId: panelTargetId,
        );
        final panel1Id = await panelsDao.upsert(
          projectId: projectId,
          panelIndex: 1,
          centerRa: 20.90,
          centerDec: 30.90,
        );
        expect(panel0Id, isNot(panel1Id));

        // Credit accepted frames + attach a per-panel master.
        await panelsDao.incrementCaptured(panel0Id, delta: 3);
        final panel0MasterId = await seedMaster(
          upgraded,
          panelTargetId,
          'Veil · Panel 1 · L',
        );
        await panelsDao.setMaster(panel0Id, panel0MasterId);
        // A rejected/no-op frame must never advance the counter.
        expect(await panelsDao.incrementCaptured(panel1Id, delta: 0), 0);

        final panels = await panelsDao.getForProject(projectId);
        expect(panels, hasLength(2));
        expect(panels[0].panelIndex, 0);
        expect(panels[0].centerRa, closeTo(20.80, 1e-9));
        expect(panels[0].centerDec, closeTo(30.50, 1e-9));
        expect(panels[0].targetId, panelTargetId);
        expect(panels[0].capturedCount, 3);
        expect(panels[0].integratedMasterId, panel0MasterId);
        expect(panels[0].status, MosaicPanelStatus.integrated);
        expect(panels[0].isIntegrated, isTrue);
        expect(panels[1].panelIndex, 1);
        expect(panels[1].capturedCount, 0);
        expect(panels[1].status, MosaicPanelStatus.pending);

        // Drive the project lifecycle and attach the stitched output master.
        await projectsDao.updateStatus(
          projectId,
          MosaicProjectStatus.stitching,
        );
        final stitchedMasterId = await seedMaster(
          upgraded,
          regionTargetId,
          'Veil 3x2 · Mosaic',
        );
        await projectsDao.setOutputMaster(projectId, stitchedMasterId);

        final done = await projectsDao.getById(projectId);
        expect(done!.status, MosaicProjectStatus.complete);
        expect(done.outputMasterId, stitchedMasterId);
        expect(done.isComplete, isTrue);

        final completeList = await projectsDao.listByStatus(
          MosaicProjectStatus.complete,
        );
        expect(completeList.map((p) => p.id), contains(projectId));
      } finally {
        await upgraded.close();
      }
    });

    test(
      'upsert keys on (project, panel_index) and preserves capture progress',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v44_v45_upsert_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV44Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final projectsDao = MosaicProjectsDao(upgraded);
          final panelsDao = MosaicPanelsDao(upgraded);

          final projectId = await projectsDao.create(
            name: 'M31 2x2',
            rows: 2,
            cols: 2,
          );

          final firstId = await panelsDao.upsert(
            projectId: projectId,
            panelIndex: 0,
            centerRa: 0.70,
            centerDec: 41.20,
          );
          // Accumulate progress and mark the panel captured.
          await panelsDao.incrementCaptured(firstId, delta: 5);
          await panelsDao.updateStatus(firstId, MosaicPanelStatus.captured);

          // Regenerate the same panel with refined geometry — same row, no dupe,
          // and the captured_count/status must survive.
          final secondId = await panelsDao.upsert(
            projectId: projectId,
            panelIndex: 0,
            centerRa: 0.75,
            centerDec: 41.25,
          );
          expect(
            secondId,
            firstId,
            reason:
                'upsert on the same (project, panel_index) must update '
                'the existing row, not create a duplicate.',
          );

          final panels = await panelsDao.getForProject(projectId);
          expect(panels, hasLength(1));
          expect(panels.single.centerRa, closeTo(0.75, 1e-9));
          expect(panels.single.centerDec, closeTo(41.25, 1e-9));
          expect(
            panels.single.capturedCount,
            5,
            reason: 'regenerating the grid must NOT reset capture progress.',
          );
          expect(
            panels.single.status,
            MosaicPanelStatus.captured,
            reason: 'regenerating the grid must NOT reset panel status.',
          );
        } finally {
          await upgraded.close();
        }
      },
    );

    test('deleting a project cascades its panels', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v44_v45_cascade_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV44Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final projectsDao = MosaicProjectsDao(upgraded);
        final panelsDao = MosaicPanelsDao(upgraded);

        final projectId = await projectsDao.create(
          name: 'Throwaway',
          rows: 1,
          cols: 2,
        );
        await panelsDao.upsert(
          projectId: projectId,
          panelIndex: 0,
          centerRa: 1.0,
          centerDec: 2.0,
        );
        await panelsDao.upsert(
          projectId: projectId,
          panelIndex: 1,
          centerRa: 1.1,
          centerDec: 2.0,
        );
        expect(await panelsDao.getForProject(projectId), hasLength(2));

        await projectsDao.deleteProject(projectId);

        expect(await projectsDao.getById(projectId), isNull);
        final orphanCount = await upgraded
            .customSelect(
              'SELECT COUNT(*) AS c FROM mosaic_panels WHERE project_id = ?',
              variables: [Variable<int>(projectId)],
            )
            .getSingle();
        expect(
          orphanCount.read<int>('c'),
          0,
          reason: 'ON DELETE CASCADE must tear down the project\'s panels.',
        );
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v45 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v44_v45_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV44Database(tempDir);

      // First open performs the v45 upgrade and seeds a project so we can prove
      // the second migration pass does not recreate / clobber the table.
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final projectId = await MosaicProjectsDao(
        first,
      ).create(name: 'Keep me', rows: 2, cols: 2);
      await MosaicPanelsDao(first).upsert(
        projectId: projectId,
        panelIndex: 0,
        centerRa: 5.0,
        centerDec: 10.0,
      );
      await first.close();

      // Rewind to v44 again WITHOUT dropping anything, then reopen. The v45
      // helper is all `IF NOT EXISTS`, so the second pass must be a pure no-op:
      // it must not throw and must not drop the rows.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 44');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final names = await tableNames(second);
        expect(names, contains('mosaic_projects'));
        expect(names, contains('mosaic_panels'));

        final projectCount = await second
            .customSelect('SELECT COUNT(*) AS c FROM mosaic_projects')
            .getSingle();
        expect(
          projectCount.read<int>('c'),
          1,
          reason:
              'The idempotent helper must NOT recreate / clobber the '
              'pre-existing project row.',
        );
        final panelCount = await second
            .customSelect('SELECT COUNT(*) AS c FROM mosaic_panels')
            .getSingle();
        expect(panelCount.read<int>('c'), 1);
      } finally {
        await second.close();
      }
    });
  });
}
