// Migration round-trip test for the v43 -> v44 step (Phase C — finishing
// foundation).
//
// Verifies that upgrading a pre-v44 (v43) database:
//   * adds the eight CD-matrix WCS columns + three finishing-artifact path
//     columns to the raw-DDL `integrated_masters` table,
//   * creates the new raw-DDL `narrowband_composites` table with its index,
//   * round-trips a plate-solved WCS + finishing paths through
//     IntegratedMastersDao (`updateWcs` / `updateFinishingPaths` -> `getById`),
//   * round-trips a composite row through NarrowbandCompositesDao, and
//   * re-running the v44 migration block is idempotent (no throw, no clobber).
//
// Strategy mirrors `campaigns_migration_test.dart`:
//   1. Open a fresh on-disk DB at v44 via onCreate (lands the full schema).
//   2. Simulate the pre-v44 (v43) state by stripping the v44 additive columns
//      from `integrated_masters`, DROPping `narrowband_composites`, and
//      rewinding `PRAGMA user_version = 43`.
//   3. Reopen — triggers onUpgrade(43, 44), running the v44 helpers.
//   4. Assert the columns + table + index exist and round-trip data.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/daos/narrowband_composites_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';

void main() {
  group('migration onUpgrade v43 -> v44 (Phase C finishing foundation)', () {
    // The eleven v44 additive `integrated_masters` columns.
    const wcsColumns = <String>[
      'wcs_crval1',
      'wcs_crval2',
      'wcs_crpix1',
      'wcs_crpix2',
      'wcs_cd1_1',
      'wcs_cd1_2',
      'wcs_cd2_1',
      'wcs_cd2_2',
    ];
    const finishingColumns = <String>[
      'background_extracted_path',
      'deconvolved_path',
      'star_reduced_path',
    ];

    /// Creates a fresh on-disk DB opened at v44 (so the full schema lands), then
    /// rebuilds `integrated_masters` WITHOUT the v44 additive columns (a v43
    /// shape), DROPs `narrowband_composites`, and rewinds
    /// `PRAGMA user_version = 43` so the next open triggers `onUpgrade(43, 44)`.
    Future<File> createV43Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        // Rebuild integrated_masters in its v43 shape (v41 base + v42 additive
        // columns, but none of the v44 WCS / finishing-path columns).
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS integrated_masters',
        );
        await setupDb.customStatement(
          'CREATE TABLE integrated_masters('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'target_id INTEGER,'
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
          'updated_at INTEGER NOT NULL,'
          // v42 additive columns are still present at v43.
          'color_calibrated_path TEXT,'
          'annotated_preview_path TEXT,'
          'background_extracted INTEGER NOT NULL DEFAULT 0,'
          'target_snr REAL,'
          'target_integration_s REAL,'
          'improvement_curve_json TEXT)',
        );
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS narrowband_composites',
        );
        await setupDb.customStatement('PRAGMA user_version = 43');
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

    Future<Set<String>> columnNames(SkotiqDatabase db, String table) async {
      final info = await db.customSelect("PRAGMA table_info('$table')").get();
      return info.map((r) => r.data['name'] as String).toSet();
    }

    Future<int> seedTarget(SkotiqDatabase db, String name) {
      return db.customInsert(
        'INSERT INTO targets (name, ra, dec) VALUES (?, ?, ?)',
        variables: [
          Variable.withString(name),
          Variable.withReal(13.5),
          Variable.withReal(47.2),
        ],
      );
    }

    test(
      'adds the v44 WCS + finishing columns and narrowband_composites table',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v43_v44_create_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV43Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final cols = await columnNames(upgraded, 'integrated_masters');
          for (final c in [...wcsColumns, ...finishingColumns]) {
            expect(
              cols,
              contains(c),
              reason: '$c column missing after v43 -> v44 upgrade',
            );
          }
          // The v42 columns must survive the upgrade untouched.
          expect(cols, contains('background_extracted'));
          expect(cols, contains('improvement_curve_json'));

          final names = await tableNames(upgraded);
          expect(names, contains('narrowband_composites'));

          final indexes = await upgraded
              .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
              .get();
          final indexNames = indexes.map((r) => r.read<String>('name')).toSet();
          expect(indexNames, contains('idx_narrowband_composites_target'));
        } finally {
          await upgraded.close();
        }
      },
    );

    test('plate-solved WCS + finishing paths round-trip through the DAO', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v43_v44_wcs_roundtrip_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV43Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final targetId = await seedTarget(upgraded, 'M51');
        final dao = IntegratedMastersDao(upgraded);

        final masterId = await dao.insertMaster(
          targetId: targetId,
          name: 'M51 · Ha',
          masterFitsPath: '/masters/m51_ha.fits',
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
          channels: 1,
          width: 4144,
          height: 2822,
        );

        // Pre-solve: no WCS persisted, so the master is honestly un-annotatable.
        final before = await dao.getById(masterId);
        expect(before, isNotNull);
        expect(before!.hasWcs, isFalse);
        expect(before.wcsCrval1, isNull);
        expect(before.backgroundExtractedPath, isNull);

        // Persist the eight CD-matrix scalars (ASTAP form) + the three finishing
        // artifact paths.
        await dao.updateWcs(
          masterId,
          crval1: 202.4696,
          crval2: 47.1952,
          crpix1: 2072.0,
          crpix2: 1411.0,
          cd1_1: -0.000352,
          cd1_2: 0.0000061,
          cd2_1: 0.0000061,
          cd2_2: 0.000352,
        );
        await dao.updateFinishingPaths(
          masterId,
          backgroundExtractedPath: '/masters/m51_ha_bgx.fits',
          deconvolvedPath: '/masters/m51_ha_decon.fits',
          starReducedPath: '/masters/m51_ha_starred.fits',
        );

        final after = await dao.getById(masterId);
        expect(after, isNotNull);
        expect(after!.hasWcs, isTrue);
        expect(after.wcsCrval1, closeTo(202.4696, 1e-9));
        expect(after.wcsCrval2, closeTo(47.1952, 1e-9));
        expect(after.wcsCrpix1, closeTo(2072.0, 1e-9));
        expect(after.wcsCrpix2, closeTo(1411.0, 1e-9));
        expect(after.wcsCd1_1, closeTo(-0.000352, 1e-12));
        expect(after.wcsCd1_2, closeTo(0.0000061, 1e-12));
        expect(after.wcsCd2_1, closeTo(0.0000061, 1e-12));
        expect(after.wcsCd2_2, closeTo(0.000352, 1e-12));
        expect(after.backgroundExtractedPath, '/masters/m51_ha_bgx.fits');
        expect(after.deconvolvedPath, '/masters/m51_ha_decon.fits');
        expect(after.starReducedPath, '/masters/m51_ha_starred.fits');
        // Untouched base columns survive.
        expect(after.name, 'M51 · Ha');
        expect(after.width, 4144);
      } finally {
        await upgraded.close();
      }
    });

    test('a narrowband composite round-trips through the new DAO', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v43_v44_composite_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV43Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final targetId = await seedTarget(upgraded, 'NGC 7000');
        final dao = NarrowbandCompositesDao(upgraded);

        final id = await dao.insertComposite(
          targetId: targetId,
          palette: 'SHO',
          componentMasterIds: const [11, 22, 33],
          outputPath: '/composites/ngc7000_sho.fits',
          width: 6248,
          height: 4176,
        );
        expect(id, greaterThan(0));

        final loaded = await dao.getById(id);
        expect(loaded, isNotNull);
        expect(loaded!.palette, 'SHO');
        expect(loaded.componentMasterIds, const [11, 22, 33]);
        expect(loaded.outputPath, '/composites/ngc7000_sho.fits');
        expect(loaded.width, 6248);
        expect(loaded.height, 4176);
        expect(loaded.targetId, targetId);

        final forTarget = await dao.getForTarget(targetId);
        expect(forTarget, hasLength(1));
        expect(forTarget.single.id, id);
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v44 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v43_v44_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV43Database(tempDir);

      // First open performs the v44 upgrade and seeds a composite so we can
      // prove the second migration pass does not recreate / clobber the table.
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final targetId = await seedTarget(first, 'M31');
      await NarrowbandCompositesDao(first).insertComposite(
        targetId: targetId,
        palette: 'HOO',
        componentMasterIds: const [1, 2],
        outputPath: '/composites/m31_hoo.fits',
      );
      await first.close();

      // Rewind to v43 again WITHOUT dropping anything, then reopen. The v44
      // helpers are all column-guarded / `IF NOT EXISTS`, so the second pass
      // must be a pure no-op: it must not throw and must not drop the row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 43');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final names = await tableNames(second);
        expect(names, contains('narrowband_composites'));

        final count = await second
            .customSelect('SELECT COUNT(*) AS c FROM narrowband_composites')
            .getSingle();
        expect(
          count.read<int>('c'),
          1,
          reason:
              'The idempotent helper must NOT recreate / clobber the '
              'pre-existing composite row.',
        );
      } finally {
        await second.close();
      }
    });
  });
}
