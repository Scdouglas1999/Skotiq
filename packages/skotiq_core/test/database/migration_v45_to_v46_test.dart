// Migration round-trip test for the v45 -> v46 step (Calibration Library
// Manager — the `calibration_tags` annotation table).
//
// Verifies that upgrading a pre-v46 (v45) database:
//   * creates the new raw-DDL `calibration_tags` table + its index,
//   * round-trips tags / notes / camera-id through CalibrationTagsDao
//     (`upsert` merge semantics -> `getForMaster` / `getAllKeyed`),
//   * enforces `UNIQUE(master_type, master_id)` (upsert updates, not dupes),
//   * and re-running the v46 migration block is idempotent (no throw, no
//     clobber).
//
// Strategy mirrors `migration_v44_to_v45_test.dart`:
//   1. Open a fresh on-disk DB at v46 via onCreate (lands the full schema).
//   2. Simulate the pre-v46 (v45) state by DROPping `calibration_tags` and
//      rewinding `PRAGMA user_version = 45`.
//   3. Reopen — triggers onUpgrade(45, 46), running the v46 helper.
//   4. Assert the table + index exist and round-trip data.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/calibration/calibration_library_models.dart';

void main() {
  group('migration onUpgrade v45 -> v46 (Calibration Library tags)', () {
    /// Opens a fresh DB at v46, DROPs `calibration_tags`, and rewinds
    /// `PRAGMA user_version = 45` so the next open triggers onUpgrade(45, 46).
    Future<File> createV45Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DROP TABLE IF EXISTS calibration_tags');
        await setupDb.customStatement('PRAGMA user_version = 45');
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

    test('creates calibration_tags table and its index', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v45_v46_create_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV45Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(await tableNames(upgraded), contains('calibration_tags'));
        expect(
          await indexNames(upgraded),
          contains('idx_calibration_tags_camera'),
        );
      } finally {
        await upgraded.close();
      }
    });

    test('tags / notes / camera-id round-trip with merge semantics', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v45_v46_roundtrip_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV45Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final dao = CalibrationTagsDao(upgraded);

        // Cache a camera id (FITS enrichment path), then add tags later. The
        // merge must not clobber the camera id.
        await dao.upsert(CalibrationMasterType.dark, 7, cameraId: 'ASI2600MC');
        await dao.upsert(
          CalibrationMasterType.dark,
          7,
          tags: ['keeper', 'best'],
        );
        await dao.upsert(CalibrationMasterType.dark, 7, notes: 'shot at -10C');

        final entry = await dao.getForMaster(CalibrationMasterType.dark, 7);
        expect(entry, isNotNull);
        expect(entry!.cameraId, 'ASI2600MC');
        expect(entry.tags, ['keeper', 'best']);
        expect(entry.notes, 'shot at -10C');

        // Keyed lookup for list joins.
        final keyed = await dao.getAllKeyed();
        expect(keyed['dark:7'], isNotNull);
        expect(keyed['dark:7']!.tags, ['keeper', 'best']);
      } finally {
        await upgraded.close();
      }
    });

    test(
      'upsert keys on (master_type, master_id) — no duplicate rows',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v45_v46_upsert_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV45Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final dao = CalibrationTagsDao(upgraded);
          await dao.upsert(CalibrationMasterType.flat, 3, tags: ['a']);
          await dao.upsert(CalibrationMasterType.flat, 3, tags: ['b']);

          final count = await upgraded
              .customSelect('SELECT COUNT(*) AS c FROM calibration_tags')
              .getSingle();
          expect(count.read<int>('c'), 1);
          final entry = await dao.getForMaster(CalibrationMasterType.flat, 3);
          expect(entry!.tags, ['b']);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('re-running the v46 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v45_v46_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV45Database(tempDir);

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await CalibrationTagsDao(
        first,
      ).upsert(CalibrationMasterType.bias, 1, tags: ['keep']);
      await first.close();

      // Rewind to v45 WITHOUT dropping; the helper is all IF NOT EXISTS, so
      // the second pass must be a pure no-op that preserves the row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 45');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(await tableNames(second), contains('calibration_tags'));
        final count = await second
            .customSelect('SELECT COUNT(*) AS c FROM calibration_tags')
            .getSingle();
        expect(
          count.read<int>('c'),
          1,
          reason: 'The idempotent helper must NOT clobber the existing row.',
        );
      } finally {
        await second.close();
      }
    });
  });
}
