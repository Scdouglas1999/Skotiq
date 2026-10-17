// Migration round-trip test for the v55 -> v56 step (Collaborative Sky Wave 0 —
// shared trust substrate). v56 is purely additive:
//   * calibration_tags gains shared_by / shared_at / license / provenance_json /
//     published_remote_id.
//   * mosaic_panels gains assigned_rig_id / assigned_user_id / claim_token /
//     uploaded_master_id.
//   * constellation_contributions gains session_id.
//   * NEW table co_imaging_sessions (+ its unique (hub_key, session_id) index).
//
// Strategy mirrors migration_v54_to_v55_test.dart for an additive step:
//   1. Open a fresh on-disk DB at v56 via onCreate (full schema).
//   2. Simulate the pre-v56 (v55) state by DROPping the new table + index,
//      rebuilding calibration_tags / mosaic_panels / constellation_contributions
//      WITHOUT the new columns, and rewinding `PRAGMA user_version = 55`.
//   3. Reopen — triggers onUpgrade(55, 56), running the v56 helper.
//   4. Assert the columns/table/index exist, round-trip the co-imaging DAO, and
//      confirm the idempotent re-run preserves data.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/mosaic_panels_dao.dart';
import 'package:skotiq_core/src/database/daos/mosaic_projects_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v55 -> v56 (Collaborative Sky trust substrate)', () {
    /// Opens a fresh DB at v56, strips everything v56 added (the new table +
    /// index, and the new columns on the three pre-existing tables), and rewinds
    /// `PRAGMA user_version = 55` so the next open triggers onUpgrade(55, 56).
    ///
    /// The three raw-DDL/Drift tables are rebuilt without the v56 columns by the
    /// table-rebuild dance (create *_old, copy the legacy columns, drop, rename)
    /// so the ADD COLUMN branches in the v56 helper have real work to do.
    Future<File> createV55Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('PRAGMA foreign_keys = OFF');

        // co_imaging_sessions is brand new in v56 — just drop it.
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS co_imaging_sessions',
        );
        await setupDb.customStatement(
          'DROP INDEX IF EXISTS idx_coimaging_sessions_key',
        );

        // calibration_tags — rebuild without the v56 sharing columns.
        await setupDb.customStatement(
          'CREATE TABLE calibration_tags_old('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'master_type TEXT NOT NULL,'
          'master_id INTEGER NOT NULL,'
          "tags_json TEXT NOT NULL DEFAULT '[]',"
          'notes TEXT,'
          'camera_id TEXT,'
          'updated_at INTEGER NOT NULL,'
          'UNIQUE(master_type, master_id))',
        );
        await setupDb.customStatement(
          'INSERT INTO calibration_tags_old '
          '(id, master_type, master_id, tags_json, notes, camera_id, updated_at) '
          'SELECT id, master_type, master_id, tags_json, notes, camera_id, '
          'updated_at FROM calibration_tags',
        );
        await setupDb.customStatement('DROP TABLE calibration_tags');
        await setupDb.customStatement(
          'ALTER TABLE calibration_tags_old RENAME TO calibration_tags',
        );

        // mosaic_panels — rebuild without the v56 distribution columns.
        await setupDb.customStatement(
          'CREATE TABLE mosaic_panels_old('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'project_id INTEGER NOT NULL,'
          'panel_index INTEGER NOT NULL,'
          'center_ra REAL NOT NULL,'
          'center_dec REAL NOT NULL,'
          'target_id INTEGER,'
          'integrated_master_id INTEGER,'
          'captured_count INTEGER NOT NULL DEFAULT 0,'
          "status TEXT NOT NULL DEFAULT 'pending',"
          'UNIQUE(project_id, panel_index))',
        );
        await setupDb.customStatement(
          'INSERT INTO mosaic_panels_old '
          '(id, project_id, panel_index, center_ra, center_dec, target_id, '
          'integrated_master_id, captured_count, status) '
          'SELECT id, project_id, panel_index, center_ra, center_dec, target_id, '
          'integrated_master_id, captured_count, status FROM mosaic_panels',
        );
        await setupDb.customStatement('DROP TABLE mosaic_panels');
        await setupDb.customStatement(
          'ALTER TABLE mosaic_panels_old RENAME TO mosaic_panels',
        );

        // mosaic_projects — rebuild without the v56 collaborative columns so the
        // mosaic_projects ADD COLUMN branches have real work to do.
        await setupDb.customStatement(
          'DROP INDEX IF EXISTS idx_mosaic_projects_hub',
        );
        await setupDb.customStatement(
          'CREATE TABLE mosaic_projects_old('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'target_id INTEGER,'
          'name TEXT NOT NULL,'
          'rows INTEGER NOT NULL,'
          'cols INTEGER NOT NULL,'
          'overlap_pct REAL NOT NULL DEFAULT 15.0,'
          'position_angle_deg REAL NOT NULL DEFAULT 0.0,'
          "status TEXT NOT NULL DEFAULT 'planning',"
          'output_master_id INTEGER,'
          'created_at INTEGER NOT NULL,'
          'updated_at INTEGER NOT NULL)',
        );
        await setupDb.customStatement(
          'INSERT INTO mosaic_projects_old '
          '(id, target_id, name, rows, cols, overlap_pct, position_angle_deg, '
          'status, output_master_id, created_at, updated_at) '
          'SELECT id, target_id, name, rows, cols, overlap_pct, '
          'position_angle_deg, status, output_master_id, created_at, updated_at '
          'FROM mosaic_projects',
        );
        await setupDb.customStatement('DROP TABLE mosaic_projects');
        await setupDb.customStatement(
          'ALTER TABLE mosaic_projects_old RENAME TO mosaic_projects',
        );

        // constellation_contributions — drop only the v56 session_id column.
        await setupDb.customStatement(
          'ALTER TABLE constellation_contributions DROP COLUMN session_id',
        );

        await setupDb.customStatement('PRAGMA user_version = 55');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    Future<Set<String>> indexNames(SkotiqDatabase db) async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    Future<bool> tableExists(SkotiqDatabase db, String table) async {
      final rows = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            variables: [Variable.withString(table)],
          )
          .get();
      return rows.isNotEmpty;
    }

    Future<Set<String>> columnNames(SkotiqDatabase db, String table) async {
      final rows = await db.customSelect("PRAGMA table_info('$table')").get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    test(
      'adds the collaboration columns, the co_imaging_sessions table and its '
      'unique index on upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v55_v56_schema_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV55Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          expect(
            await columnNames(upgraded, 'calibration_tags'),
            containsAll(<String>[
              'shared_by',
              'shared_at',
              'license',
              'provenance_json',
              'published_remote_id',
            ]),
          );
          expect(
            await columnNames(upgraded, 'mosaic_panels'),
            containsAll(<String>[
              'assigned_rig_id',
              'assigned_user_id',
              'claim_token',
              'uploaded_master_id',
            ]),
          );
          expect(
            await columnNames(upgraded, 'mosaic_projects'),
            containsAll(<String>[
              'hub_mosaic_id',
              'collab_role',
              'collab_status',
            ]),
          );
          expect(
            await indexNames(upgraded),
            contains('idx_mosaic_projects_hub'),
            reason: 'the hub_mosaic_id lookup index must exist',
          );
          expect(
            await columnNames(upgraded, 'constellation_contributions'),
            contains('session_id'),
          );

          expect(await tableExists(upgraded, 'co_imaging_sessions'), isTrue);
          expect(
            await indexNames(upgraded),
            contains('idx_coimaging_sessions_key'),
            reason: 'the unique (hub_key, session_id) index must exist',
          );
        } finally {
          await upgraded.close();
        }
      },
    );

    test(
      'co_imaging_sessions round-trips a membership via the DAO after upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v55_v56_rt_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV55Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final dao = upgraded.coImagingSessionsDao;
          const hubKey = 'https://hub.example';
          const sessionId = 'sess-1';

          expect(await dao.getSession(hubKey, sessionId), isNull);

          await dao.upsertMembership(
            hubKey,
            sessionId,
            targetName: 'NGC 7000',
            targetRaDeg: 314.7,
            targetDecDeg: 44.5,
            role: 'contribute',
            claimToken: 'baton-abc',
            framingOffsetIndex: 2,
            framingOffsetRaArcsec: 30.0,
            framingOffsetDecArcsec: -15.0,
          );

          var row = await dao.getSession(hubKey, sessionId);
          expect(row, isNotNull);
          expect(row!.targetName, 'NGC 7000');
          expect(row.role, 'contribute');
          expect(row.claimToken, 'baton-abc');
          expect(row.framingOffsetIndex, 2);
          expect(row.active, isTrue);
          expect(row.contributedFrames, 0);

          // Progress advances tallies without clobbering the assigned offset.
          await dao.updateProgress(
            hubKey,
            sessionId,
            contributedFrames: 12,
            contributedIntegrationSeconds: 720.0,
          );
          row = await dao.getSession(hubKey, sessionId);
          expect(row!.contributedFrames, 12);
          expect(row.contributedIntegrationSeconds, 720.0);
          expect(row.framingOffsetIndex, 2, reason: 'offset is preserved');
          expect(row.claimToken, 'baton-abc', reason: 'token is preserved');

          // A single-field membership refresh (e.g. the hub reassigns the framing
          // offset when the rig count changes) MUST NOT null out the unrelated
          // claim token / cached target the call omits.
          await dao.upsertMembership(
            hubKey,
            sessionId,
            framingOffsetIndex: 3,
            framingOffsetRaArcsec: 45.0,
            framingOffsetDecArcsec: -20.0,
          );
          row = await dao.getSession(hubKey, sessionId);
          expect(row!.framingOffsetIndex, 3);
          expect(row.framingOffsetRaArcsec, 45.0);
          expect(
            row.claimToken,
            'baton-abc',
            reason:
                'partial membership update must not wipe the auth credential',
          );
          expect(
            row.targetName,
            'NGC 7000',
            reason: 'partial membership update must not wipe the cached target',
          );
          expect(row.targetRaDeg, 314.7);
          expect(row.targetDecDeg, 44.5);
          expect(
            row.role,
            'contribute',
            reason: 'role survives a partial update',
          );

          // Leaving keeps the row but flips active.
          await dao.markInactive(hubKey, sessionId);
          expect((await dao.getSession(hubKey, sessionId))!.active, isFalse);
          expect(await dao.getActiveSessions(), isEmpty);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('constellation_contributions.session_id is writable through its DAO '
        'after upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v55_v56_session_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV55Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final dao = upgraded.constellationContributionsDao;
        const hubKey = 'https://hub.example';
        const tileId = 42;

        await dao.upsertContribution(
          hubKey,
          tileId,
          contributionId: 'receipt-1',
          contributedFrames: 5,
          contributedIntegrationSeconds: 300.0,
          sessionId: 'sess-1',
        );
        final row = await dao.getContribution(hubKey, tileId);
        expect(row, isNotNull);
        expect(row!.sessionId, 'sess-1');
        expect(row.contributionId, 'receipt-1');
      } finally {
        await upgraded.close();
      }
    });

    test(
      'mosaic collab columns round-trip through the DAOs after upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v55_v56_mosaic_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV55Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final projectsDao = MosaicProjectsDao(upgraded);
          final panelsDao = MosaicPanelsDao(upgraded);

          final projectId = await projectsDao.create(
            name: 'Veil',
            rows: 1,
            cols: 2,
          );
          final panelId = await panelsDao.upsert(
            projectId: projectId,
            panelIndex: 0,
            centerRa: 20.0,
            centerDec: 30.0,
          );

          // Project: publish records hub_mosaic_id + owner role + status.
          await projectsDao.setHubMosaic(projectId, 'mos-9', 'owner');
          var project = await projectsDao.getById(projectId);
          expect(project!.hubMosaicId, 'mos-9');
          expect(project.collabRole, 'owner');
          expect(project.collabStatus, 'published');
          expect(project.isPublished, isTrue);

          await projectsDao.setCollabStatus(projectId, 'assembling');
          project = await projectsDao.getById(projectId);
          expect(project!.collabStatus, 'assembling');

          // Panel: claim then upload persist the collaboration columns.
          await panelsDao.setClaim(
            panelId,
            claimToken: 'baton-0',
            rigId: 'rig-x',
            accountId: 'acct-7',
          );
          var panel = await panelsDao.getByIndex(projectId, 0);
          expect(panel!.claimToken, 'baton-0');
          expect(panel.assignedRigId, 'rig-x');
          expect(panel.assignedUserId, 'acct-7');
          expect(panel.isClaimed, isTrue);

          await panelsDao.setUploaded(panelId, 555);
          panel = await panelsDao.getByIndex(projectId, 0);
          expect(panel!.uploadedMasterId, 555);
          expect(panel.isUploaded, isTrue);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('re-running the v56 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v55_v56_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV55Database(tempDir);

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await first.coImagingSessionsDao.upsertMembership(
        'https://hub.example',
        'keep-me',
        targetName: 'M31',
      );
      await first.close();

      // Rewind to v55 WITHOUT dropping; the helper guards the new table with
      // _tableExists, the columns with _columnExists, and the index with IF NOT
      // EXISTS, so the second pass is a pure no-op that preserves the row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 55');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(await tableExists(second, 'co_imaging_sessions'), isTrue);
        final row = await second.coImagingSessionsDao.getSession(
          'https://hub.example',
          'keep-me',
        );
        expect(
          row?.targetName,
          'M31',
          reason: 'the idempotent helper must NOT clobber existing data',
        );
      } finally {
        await second.close();
      }
    });
  });
}
