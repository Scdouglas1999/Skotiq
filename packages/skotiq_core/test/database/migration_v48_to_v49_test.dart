// Migration round-trip test for the v48 -> v49 step (sequencer closeout).
//
// v49 makes a *historical* run report self-contained with additive columns
// and two new tables:
//   * `sequence_runs.sequence_snapshot_json` — the sequence JSON used per run.
//   * `sequences.tags_json` / `sequences.is_favorite` — library tags + stars.
//   * `sequence_versions` — append-only per-sequence version history.
//   * `session_diagnostics` — per-session recovery + optical-train snapshots.
//
// Strategy mirrors `migration_v45_to_v46_test.dart`:
//   1. Open a fresh on-disk DB at v49 via onCreate (lands the full schema).
//   2. Simulate the pre-v49 (v48) state by DROPping the two new tables and
//      rewinding `PRAGMA user_version = 48`.
//   3. Reopen — triggers onUpgrade(48, 49), running the v49 helper.
//   4. Assert the tables exist, the new columns exist + round-trip, and the
//      idempotency guards hold (re-running the block preserves data).
//
// The added COLUMNS cannot be dropped on the SQLite versions we target, so the
// drop/rewind exercises the two new TABLES; the columns are verified for
// existence + round-trip on the upgraded DB (the migration's `_columnExists`
// guard is what keeps the re-run a no-op, covered by the idempotency case).

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/sequence_versions_dao.dart';
import 'package:skotiq_core/src/database/daos/session_diagnostics_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v48 -> v49 (sequencer closeout)', () {
    /// Opens a fresh DB at v49, DROPs the two new tables, and rewinds
    /// `PRAGMA user_version = 48` so the next open triggers onUpgrade(48, 49).
    Future<File> createV48Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DROP TABLE IF EXISTS sequence_versions');
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS session_diagnostics',
        );
        await setupDb.customStatement('PRAGMA user_version = 48');
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
      final rows = await db.customSelect('PRAGMA table_info($table)').get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    test(
      'recreates sequence_versions and session_diagnostics tables',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v48_v49_create_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV48Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final tables = await tableNames(upgraded);
          expect(tables, contains('sequence_versions'));
          expect(tables, contains('session_diagnostics'));
        } finally {
          await upgraded.close();
        }
      },
    );

    test('adds the new sequences / sequence_runs columns', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v48_v49_cols_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV48Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(
          await columnNames(upgraded, 'sequences'),
          containsAll(<String>['tags_json', 'is_favorite']),
        );
        expect(
          await columnNames(upgraded, 'sequence_runs'),
          contains('sequence_snapshot_json'),
        );
      } finally {
        await upgraded.close();
      }
    });

    test('sequence_versions round-trips append + list', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v48_v49_versions_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV48Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        // Parent row for the sequence_versions -> sequences FK.
        await upgraded.customStatement(
          "INSERT INTO sequences (id, name) VALUES (1, 'parent seq')",
        );
        final dao = SequenceVersionsDao(upgraded);
        await dao.appendVersion(
          sequenceId: 1,
          snapshotJson: '{"v":1}',
          label: 'initial',
        );
        await dao.appendVersion(sequenceId: 1, snapshotJson: '{"v":2}');

        final versions = await dao.listVersions(1);
        expect(versions, hasLength(2));
        expect(await dao.versionCount(1), 2);
        // Newest first by createdAt/id; the latest snapshot must be retrievable.
        final snapshots = versions.map((v) => v.snapshotJson).toSet();
        expect(snapshots, containsAll(<String>['{"v":1}', '{"v":2}']));
      } finally {
        await upgraded.close();
      }
    });

    test('session_diagnostics upserts one row per session', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v48_v49_diag_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV48Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        // Parent row for the session_diagnostics -> imaging_sessions FK.
        await upgraded.customStatement(
          "INSERT INTO imaging_sessions (id, start_time) VALUES (5, 0)",
        );
        final dao = SessionDiagnosticsDao(upgraded);
        await dao.upsert(
          sessionId: 5,
          recoveryHistoryJson: '[]',
          opticalTrainBaselineJson: '{"tilt":1.0}',
        );
        // Re-save with the current snapshot — must update, not duplicate.
        await dao.upsert(
          sessionId: 5,
          recoveryHistoryJson: '[{"k":"v"}]',
          opticalTrainCurrentJson: '{"tilt":2.0}',
        );

        final count = await upgraded
            .customSelect('SELECT COUNT(*) AS c FROM session_diagnostics')
            .getSingle();
        expect(count.read<int>('c'), 1);

        final entry = await dao.getForSession(5);
        expect(entry, isNotNull);
        expect(entry!.recoveryHistoryJson, '[{"k":"v"}]');
        expect(entry.opticalTrainCurrentJson, '{"tilt":2.0}');
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v49 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v48_v49_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV48Database(tempDir);

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await first.customStatement(
        "INSERT INTO imaging_sessions (id, start_time) VALUES (9, 0)",
      );
      await SessionDiagnosticsDao(
        first,
      ).upsert(sessionId: 9, recoveryHistoryJson: '["keep"]');
      await first.close();

      // Rewind to v48 WITHOUT dropping; the helper guards every add with
      // _columnExists / _tableExists, so the second pass must be a pure no-op
      // that preserves the existing row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 48');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(await tableNames(second), contains('session_diagnostics'));
        final count = await second
            .customSelect('SELECT COUNT(*) AS c FROM session_diagnostics')
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
