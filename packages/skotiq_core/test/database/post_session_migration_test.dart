// Migration round-trip test for the v40 -> v41 step (Post-Session Integration).
//
// Verifies that upgrading a pre-v41 (v40) database creates the three new
// raw-DDL tables (`integrated_masters`, `integrated_master_frames`,
// `flat_library`) with their indexes, that a master + fold record + flat entry
// round-trips through the DAOs after the upgrade, and that re-running the v41
// migration block is idempotent (no throw).
//
// Strategy mirrors `project_migration_test.dart`:
//   1. Open a fresh on-disk DB at v41 via onCreate (lands the full schema).
//   2. Simulate the pre-v41 (v40) state: DROP the three new tables and rewind
//      `PRAGMA user_version = 40`.
//   3. Reopen — triggers onUpgrade(40, 41), which runs `_createPostSessionTables()`.
//   4. Assert the tables + indexes exist and round-trip data.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/daos/night_reports_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';
import 'package:skotiq_core/src/models/imaging/night_report.dart';

void main() {
  group('migration onUpgrade v40 -> v41 (post-session integration)', () {
    Future<File> createV40Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS integrated_master_frames',
        );
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS integrated_masters',
        );
        await setupDb.customStatement('DROP TABLE IF EXISTS flat_library');
        await setupDb.customStatement('PRAGMA user_version = 40');
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

    test('creates the three tables + indexes on upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v40_v41_create_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV40Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final names = await tableNames(upgraded);
        expect(names, contains('integrated_masters'));
        expect(names, contains('integrated_master_frames'));
        expect(names, contains('flat_library'));

        final indexes = await upgraded
            .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
            .get();
        final indexNames = indexes.map((r) => r.read<String>('name')).toSet();
        expect(indexNames, contains('idx_integrated_masters_target'));
        expect(indexNames, contains('idx_integrated_master_frames_master'));
        expect(indexNames, contains('idx_flat_library_match'));
      } finally {
        await upgraded.close();
      }
    });

    test('a master + fold record + flat round-trips after the upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v40_v41_roundtrip_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV40Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final mastersDao = IntegratedMastersDao(upgraded);
        final flatDao = FlatLibraryDao(upgraded);

        // A captured sub to fold (FK target of integrated_master_frames).
        final imageId = await upgraded.customInsert(
          'INSERT INTO captured_images '
          '(file_path, file_name, frame_type, exposure_duration, captured_at) '
          'VALUES (?, ?, ?, ?, ?)',
          variables: [
            Variable.withString('/l/a.fits'),
            Variable.withString('a.fits'),
            Variable.withString('light'),
            Variable.withReal(120.0),
            Variable.withInt(
              DateTime.utc(2026, 6, 7).millisecondsSinceEpoch ~/ 1000,
            ),
          ],
        );

        final masterId = await mastersDao.insertMaster(
          name: 'M51 · L',
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
          masterFitsPath: '/out/m51.fits',
          frameCount: 1,
          filter: 'L',
        );
        expect(masterId, greaterThan(0));

        await mastersDao.recordFoldedFrame(
          masterId: masterId,
          imageId: imageId,
          weight: 1.0,
          accepted: true,
        );
        final folded = await mastersDao.getFoldedImageIds(masterId);
        expect(folded, {imageId});

        // The dedup UNIQUE(master_id, image_id) makes a re-fold a no-op upsert.
        await mastersDao.recordFoldedFrame(
          masterId: masterId,
          imageId: imageId,
          weight: 0.5,
        );
        expect((await mastersDao.getFramesForMaster(masterId)), hasLength(1));

        final flatId = await flatDao.addEntry(
          filePath: '/cal/flat_L.fits',
          filter: 'L',
          masterFrameCount: 25,
        );
        final flat = await flatDao.getEntryById(flatId);
        expect(flat, isNotNull);
        expect(flat!.filter, 'L');
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v41 migration block is idempotent', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v40_v41_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV40Database(tempDir);

      // First open performs the upgrade.
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await first.customSelect('SELECT 1').get();
      await first.close();

      // Rewind to v40 again and reopen — the helper must not throw on
      // already-existing tables (every statement is IF NOT EXISTS).
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 40');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final names = await (second
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get());
        final set = names.map((r) => r.read<String>('name')).toSet();
        expect(set, contains('integrated_masters'));
        expect(set, contains('flat_library'));
      } finally {
        await second.close();
      }
    });
  });

  // v41 -> v42 (Smart Morning Report / "Night Doctor"): the `night_reports`
  // table plus additive Smart-Morning-Report columns on the v41 raw-DDL
  // `integrated_masters` / `integrated_master_frames` tables.
  //
  // Strategy mirrors the v40 -> v41 group above:
  //   1. Open a fresh on-disk DB at v42 via onCreate (lands the full schema).
  //   2. Simulate the pre-v42 (v41) state: DROP `night_reports` and re-create
  //      `integrated_masters` / `integrated_master_frames` WITHOUT the v42
  //      additive columns (DROP + the literal v41 CREATE), then rewind
  //      `PRAGMA user_version = 41`. Re-creating the tables (rather than
  //      DROP COLUMN) keeps the simulation independent of the bundled sqlite's
  //      ALTER ... DROP COLUMN support.
  //   3. Reopen — triggers onUpgrade(41, 42), running
  //      `_createNightReportsTable()` + `_ensureIntegratedMastersV42Columns()`.
  //   4. Assert the table + columns exist, that a report round-trips through
  //      NightReportsDao, and that re-running the v42 block is idempotent.
  group('migration onUpgrade v41 -> v42 (smart morning report)', () {
    Future<bool> columnExists(
      SkotiqDatabase db,
      String table,
      String column,
    ) async {
      final rows = await db.customSelect("PRAGMA table_info('$table')").get();
      return rows.any((r) => r.read<String>('name') == column);
    }

    // Re-create `integrated_masters` / `integrated_master_frames` at their
    // exact v41 column layout (no v42 additive columns) so the upgrade has
    // something to ALTER. These are verbatim copies of the v41
    // `_createPostSessionTables()` DDL.
    Future<void> recreateV41PostSessionTables(SkotiqDatabase db) async {
      await db.customStatement('DROP TABLE IF EXISTS integrated_master_frames');
      await db.customStatement('DROP TABLE IF EXISTS integrated_masters');
      await db.customStatement(
        'CREATE TABLE integrated_masters('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
        'name TEXT NOT NULL,'
        'master_fits_path TEXT,'
        'preview_png_path TEXT,'
        'sidecar_path TEXT,'
        'rejection_map_path TEXT,'
        "status TEXT NOT NULL DEFAULT 'finalized',"
        "accumulation_mode TEXT NOT NULL DEFAULT 'batch',"
        'channels INTEGER NOT NULL DEFAULT 1,'
        'width INTEGER NOT NULL DEFAULT 0,'
        'height INTEGER NOT NULL DEFAULT 0,'
        'frame_count INTEGER NOT NULL DEFAULT 0,'
        'total_integration_seconds REAL NOT NULL DEFAULT 0.0,'
        'filter TEXT,'
        "settings_json TEXT NOT NULL DEFAULT '{}',"
        "stats_json TEXT NOT NULL DEFAULT '{}',"
        'created_at INTEGER NOT NULL,'
        'updated_at INTEGER NOT NULL)',
      );
      await db.customStatement(
        'CREATE TABLE integrated_master_frames('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'master_id INTEGER NOT NULL '
        'REFERENCES integrated_masters(id) ON DELETE CASCADE,'
        'image_id INTEGER NOT NULL '
        'REFERENCES captured_images(id) ON DELETE CASCADE,'
        'weight REAL,'
        'alignment_residual_px REAL,'
        'accepted INTEGER NOT NULL DEFAULT 1,'
        'rejection_reason TEXT,'
        'folded_at INTEGER NOT NULL,'
        'UNIQUE(master_id, image_id))',
      );
    }

    Future<File> createV41Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        // Remove the v42 surface so the reopen genuinely performs the upgrade.
        await setupDb.customStatement('DROP TABLE IF EXISTS night_reports');
        await recreateV41PostSessionTables(setupDb);
        await setupDb.customStatement('PRAGMA user_version = 41');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    test(
      'creates night_reports + the additive v42 columns on upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v41_v42_create_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV41Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final tables = await upgraded
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get();
          final tableNames = tables.map((r) => r.read<String>('name')).toSet();
          expect(tableNames, contains('night_reports'));

          final indexes = await upgraded
              .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
              .get();
          final indexNames = indexes.map((r) => r.read<String>('name')).toSet();
          expect(indexNames, contains('idx_night_reports_session'));
          expect(indexNames, contains('idx_night_reports_target'));
          expect(indexNames, contains('idx_night_reports_created'));

          // Additive integrated_masters columns.
          expect(
            await columnExists(
              upgraded,
              'integrated_masters',
              'color_calibrated_path',
            ),
            isTrue,
          );
          expect(
            await columnExists(
              upgraded,
              'integrated_masters',
              'annotated_preview_path',
            ),
            isTrue,
          );
          expect(
            await columnExists(
              upgraded,
              'integrated_masters',
              'background_extracted',
            ),
            isTrue,
          );
          expect(
            await columnExists(upgraded, 'integrated_masters', 'target_snr'),
            isTrue,
          );
          expect(
            await columnExists(
              upgraded,
              'integrated_masters',
              'target_integration_s',
            ),
            isTrue,
          );
          expect(
            await columnExists(
              upgraded,
              'integrated_masters',
              'improvement_curve_json',
            ),
            isTrue,
          );

          // Additive integrated_master_frames columns.
          expect(
            await columnExists(upgraded, 'integrated_master_frames', 'snr'),
            isTrue,
          );
          expect(
            await columnExists(upgraded, 'integrated_master_frames', 'fwhm'),
            isTrue,
          );
          expect(
            await columnExists(
              upgraded,
              'integrated_master_frames',
              'eccentricity',
            ),
            isTrue,
          );
        } finally {
          await upgraded.close();
        }
      },
    );

    test(
      'a night report round-trips through NightReportsDao after the upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v41_v42_roundtrip_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV41Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final dao = NightReportsDao(upgraded);
          final createdAt = DateTime.utc(2026, 6, 8, 6);
          final reportId = await dao.insertReport(
            score: 82,
            headline: 'Solid night — one focus wobble near meridian',
            findings: const [
              NightFinding(
                id: 'focus_drift',
                severity: NightFindingSeverity.warn,
                title: 'Focus drift',
                explanation: 'HFR climbed through the second half.',
                evidenceSubIds: [11, 12, 13],
                advice: 'Enable temperature compensation.',
                metricSeries: [2.1, 2.3, 2.6, 2.9],
              ),
            ],
            createdAt: createdAt,
          );
          expect(reportId, greaterThan(0));

          final loaded = await dao.getById(reportId);
          expect(loaded, isNotNull);
          expect(loaded!.score, 82);
          expect(
            loaded.headline,
            'Solid night — one focus wobble near meridian',
          );
          expect(loaded.createdAt, createdAt);
          expect(loaded.findings, hasLength(1));
          final finding = loaded.findings.single;
          expect(finding.id, 'focus_drift');
          expect(finding.severity, NightFindingSeverity.warn);
          expect(finding.evidenceSubIds, [11, 12, 13]);
          expect(finding.metricSeries, [2.1, 2.3, 2.6, 2.9]);

          // The additive v42 master columns are writable post-upgrade: a smart
          // update lands the finishing/curve fields without error.
          final mastersDao = IntegratedMastersDao(upgraded);
          final masterId = await mastersDao.insertMaster(
            name: 'NGC 7000 · Ha',
            status: IntegratedMasterStatus.finalized,
            accumulationMode: AccumulationMode.batch,
          );
          final updated = await mastersDao.updateSmartFields(
            masterId,
            colorCalibratedPath: '/out/ngc7000_spcc.fits',
            backgroundExtracted: true,
            targetSnr: 40.0,
            targetIntegrationS: 36000.0,
            improvementCurveJson: '{"points":[],"recommendation":{}}',
          );
          expect(updated, 1);
          final smartRow = await upgraded
              .customSelect(
                'SELECT color_calibrated_path, background_extracted, target_snr '
                'FROM integrated_masters WHERE id = ?',
                variables: [Variable<int>(masterId)],
              )
              .getSingle();
          expect(
            smartRow.read<String>('color_calibrated_path'),
            '/out/ngc7000_spcc.fits',
          );
          expect(smartRow.read<int>('background_extracted'), 1);
          expect(smartRow.read<double>('target_snr'), 40.0);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('re-running the v42 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v41_v42_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV41Database(tempDir);

      // First open performs the v42 upgrade.
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await first.customSelect('SELECT 1').get();
      // Seed a report so we can prove the second migration pass does not
      // recreate / clobber the existing table.
      await NightReportsDao(
        first,
      ).insertReport(score: 50, headline: 'baseline');
      await first.close();

      // Rewind to v41 again WITHOUT dropping night_reports or the v42 columns,
      // then reopen. `_createNightReportsTable()` is all `IF NOT EXISTS` and
      // `_ensureIntegratedMastersV42Columns()` guards every ALTER with
      // `_columnExists`, so the second pass must be a pure no-op: it must not
      // throw and must not drop the existing report row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 41');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final tables = await second
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get();
        expect(
          tables.map((r) => r.read<String>('name')).toSet(),
          contains('night_reports'),
        );
        // The v42 columns survive a second pass (no duplicate-column throw).
        expect(
          await columnExists(
            second,
            'integrated_masters',
            'color_calibrated_path',
          ),
          isTrue,
        );
        // The pre-existing report row is untouched — the table was NOT
        // recreated by the idempotent helper.
        final count = await second
            .customSelect('SELECT COUNT(*) AS c FROM night_reports')
            .getSingle();
        expect(count.read<int>('c'), 1);
      } finally {
        await second.close();
      }
    });
  });
}
