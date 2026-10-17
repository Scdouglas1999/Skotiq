// Migration round-trip test for the v42 -> v43 step (Phase B — durable
// multi-night campaigns).
//
// Verifies that upgrading a pre-v43 (v42) database creates the new raw-DDL
// `campaigns` table with its index, that a campaign row round-trips through
// CampaignsDao after the upgrade, and that re-running the v43 migration block
// is idempotent (no throw, no clobber).
//
// Strategy mirrors `post_session_migration_test.dart`:
//   1. Open a fresh on-disk DB at v43 via onCreate (lands the full schema).
//   2. Simulate the pre-v43 (v42) state: DROP `campaigns` and rewind
//      `PRAGMA user_version = 42`.
//   3. Reopen — triggers onUpgrade(42, 43), running `_createCampaignsTable()`.
//   4. Assert the table + index exist and round-trip data.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/campaigns_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v42 -> v43 (durable campaigns)', () {
    Future<File> createV42Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DROP TABLE IF EXISTS campaigns');
        await setupDb.customStatement('PRAGMA user_version = 42');
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

    test('creates the campaigns table + index on upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v42_v43_create_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV42Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final names = await tableNames(upgraded);
        expect(names, contains('campaigns'));

        final indexes = await upgraded
            .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
            .get();
        final indexNames = indexes.map((r) => r.read<String>('name')).toSet();
        expect(indexNames, contains('idx_campaigns_target'));
      } finally {
        await upgraded.close();
      }
    });

    test(
      'a campaign round-trips through CampaignsDao after the upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v42_v43_roundtrip_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV42Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final targetId = await seedTarget(upgraded, 'M51');
          final dao = CampaignsDao(upgraded);

          final id = await dao.upsertDesired(
            targetId: targetId,
            filter: 'Ha',
            desiredCount: 40,
          );
          expect(id, greaterThan(0));

          final loaded = await dao.getForTargetFilter(targetId, 'Ha');
          expect(loaded, isNotNull);
          expect(loaded!.desiredCount, 40);
          expect(loaded.acceptedCount, 0);
          expect(loaded.lastCaptureAt, isNull);
          expect(loaded.remaining, 40);
          expect(loaded.isComplete, isFalse);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('re-running the v43 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v42_v43_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV42Database(tempDir);

      // First open performs the v43 upgrade and seeds a campaign so we can
      // prove the second migration pass does not recreate / clobber the table.
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final targetId = await seedTarget(first, 'NGC 7000');
      await CampaignsDao(
        first,
      ).upsertDesired(targetId: targetId, filter: 'OIII', desiredCount: 30);
      await first.close();

      // Rewind to v42 again WITHOUT dropping campaigns, then reopen. The
      // helper is all `IF NOT EXISTS`, so the second pass must be a pure no-op:
      // it must not throw and must not drop the existing campaign row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 42');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final names = await tableNames(second);
        expect(names, contains('campaigns'));

        // The pre-existing campaign row is untouched — the table was NOT
        // recreated by the idempotent helper.
        final count = await second
            .customSelect('SELECT COUNT(*) AS c FROM campaigns')
            .getSingle();
        expect(count.read<int>('c'), 1);
      } finally {
        await second.close();
      }
    });

    test(
      'UNIQUE(target_id, filter) enforces one row per pair on upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v42_v43_unique_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV42Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final targetId = await seedTarget(upgraded, 'M31');
          final dao = CampaignsDao(upgraded);

          final firstId = await dao.upsertDesired(
            targetId: targetId,
            filter: 'L',
            desiredCount: 50,
          );
          // Re-upserting the same (target, filter) updates the existing row
          // (preserving accepted_count) rather than inserting a duplicate.
          final secondId = await dao.upsertDesired(
            targetId: targetId,
            filter: 'L',
            desiredCount: 75,
          );
          expect(secondId, firstId);

          final rows = await dao.getForTarget(targetId);
          expect(rows, hasLength(1));
          expect(rows.single.desiredCount, 75);
        } finally {
          await upgraded.close();
        }
      },
    );
  });
}
