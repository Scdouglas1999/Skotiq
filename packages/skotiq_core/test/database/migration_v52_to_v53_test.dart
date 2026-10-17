// Migration round-trip test for the v52 -> v53 step.
//
// v53 adds two additive columns to `equipment_profiles` so a remote slave can
// mirror user-friendly display names for the safety monitor and switch (the
// existing camera/mount/focuser/... *_name columns already had this):
//   * `equipment_profiles.safety_monitor_name`
//   * `equipment_profiles.switch_name`
//
// Strategy mirrors migration_v48_to_v49_test.dart for an additive-column step:
//   1. Open a fresh on-disk DB at v53 via onCreate (lands the full schema).
//   2. Simulate the pre-v53 (v52) state by DROPping the two new columns and
//      rewinding `PRAGMA user_version = 52`.
//   3. Reopen — triggers onUpgrade(52, 53), running the v53 helper.
//   4. Assert the columns exist + round-trip, and the idempotency guard holds
//      (re-running the block preserves data and does not duplicate columns).
//
// Modern SQLite (the version bundled via package:sqlite3 hooks / NativeDatabase
// in this repo) supports `ALTER TABLE ... DROP COLUMN`, so dropping the columns
// first exercises the real ADD path.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v52 -> v53 (safety/switch display names)', () {
    /// Opens a fresh DB at v53, DROPs the two new columns, and rewinds
    /// `PRAGMA user_version = 52` so the next open triggers onUpgrade(52, 53).
    Future<File> createV52Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement(
          'ALTER TABLE equipment_profiles DROP COLUMN safety_monitor_name',
        );
        await setupDb.customStatement(
          'ALTER TABLE equipment_profiles DROP COLUMN switch_name',
        );
        await setupDb.customStatement('PRAGMA user_version = 52');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    Future<Set<String>> columnNames(SkotiqDatabase db, String table) async {
      final rows = await db.customSelect('PRAGMA table_info($table)').get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    test('adds safety_monitor_name and switch_name columns', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v52_v53_cols_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV52Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(
          await columnNames(upgraded, 'equipment_profiles'),
          containsAll(<String>['safety_monitor_name', 'switch_name']),
        );
      } finally {
        await upgraded.close();
      }
    });

    test('the new columns round-trip through the DAO', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v52_v53_rt_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV52Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final id = await upgraded.equipmentProfilesDao.createProfile(
          EquipmentProfilesCompanion.insert(
            name: 'Upgraded Rig',
            safetyMonitorName: const Value('Roof Safety'),
            switchName: const Value('Mains Box'),
          ),
        );

        final row = await upgraded.equipmentProfilesDao.getProfileById(id);
        expect(row, isNotNull);
        expect(row!.safetyMonitorName, 'Roof Safety');
        expect(row.switchName, 'Mains Box');
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v53 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v52_v53_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV52Database(tempDir);

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final id = await first.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(
          name: 'Keep Me',
          safetyMonitorName: const Value('Keep Safety'),
        ),
      );
      await first.close();

      // Rewind to v52 WITHOUT dropping; the helper guards each ADD with
      // _columnExists, so the second pass must be a pure no-op that preserves
      // the existing row + values.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 52');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(
          await columnNames(second, 'equipment_profiles'),
          containsAll(<String>['safety_monitor_name', 'switch_name']),
        );
        final row = await second.equipmentProfilesDao.getProfileById(id);
        expect(
          row?.safetyMonitorName,
          'Keep Safety',
          reason: 'The idempotent helper must NOT clobber existing data.',
        );
      } finally {
        await second.close();
      }
    });
  });
}
