// Migration round-trip test for the v39 -> v40 step (Multi-Night & Forecast
// Planning, C3): the `projects` and `project_targets` tables plus the
// `planning.active_project_id` settings seed land on an in-place upgrade from a
// pre-v40 database, a project + membership round-trips through them after the
// upgrade, and re-running the v40 migration block is idempotent (no throw).
//
// Pattern mirrors migration_v38_to_v39_test.dart:
//   1. Open a fresh on-disk DB at v40 via onCreate (lands the full schema).
//   2. Simulate the pre-v40 (v39) state: DROP `projects` / `project_targets`
//      and DELETE the `planning.active_project_id` settings row, then rewind
//      `PRAGMA user_version = 39` and close.
//   3. Reopen — triggers onUpgrade(39, 40), which runs `_createProjectsTables()`
//      and `_ensureDefaultSettings()` from database.dart.
//   4. Assert the tables + settings seed exist and a project + membership
//      round-trips.
//   5. Drive the migrator's onUpgrade(39, 40) a second time to prove the v40
//      block is re-runnable without error (CREATE ... IF NOT EXISTS +
//      INSERT ... ON CONFLICT DO NOTHING).
//
// `Variable` is imported explicitly (not the whole drift barrel) to avoid the
// `isNull` symbol collision with flutter_test.
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v39 -> v40 (projects / project_targets)', () {
    /// Creates a fresh on-disk database opened at v40 (so the full schema
    /// lands), then simulates the pre-v40 (v39) state by dropping the two
    /// planner tables and removing the `planning.active_project_id` settings
    /// row, and rewinds `PRAGMA user_version = 39` so the next open triggers
    /// `onUpgrade(39, 40)`.
    Future<File> createV39Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DROP TABLE IF EXISTS project_targets');
        await setupDb.customStatement('DROP TABLE IF EXISTS projects');
        await setupDb.customStatement(
          "DELETE FROM app_settings WHERE key = 'planning.active_project_id'",
        );
        await setupDb.customStatement('PRAGMA user_version = 39');
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

    test(
      'creates projects + project_targets and seeds active_project_id',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v39_v40_create_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV39Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final names = await tableNames(upgraded);
          expect(
            names,
            contains('projects'),
            reason: 'projects table missing after v39 -> v40 upgrade',
          );
          expect(
            names,
            contains('project_targets'),
            reason: 'project_targets table missing after v39 -> v40 upgrade',
          );

          // Both indexes land.
          final indexes = await upgraded
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='index' "
                "AND tbl_name='project_targets'",
              )
              .get();
          final indexNames = indexes.map((r) => r.read<String>('name')).toSet();
          expect(indexNames, contains('idx_project_targets_project'));
          expect(indexNames, contains('idx_project_targets_target'));

          // The active-project settings row is seeded to the empty-string
          // "no active project" sentinel.
          final settings = await upgraded
              .customSelect(
                "SELECT value FROM app_settings WHERE key = 'planning.active_project_id'",
              )
              .getSingleOrNull();
          expect(
            settings,
            isNotNull,
            reason: 'planning.active_project_id settings row not seeded',
          );
          expect(settings!.read<String>('value'), '');
        } finally {
          await upgraded.close();
        }
      },
    );

    test('a project + membership round-trips after the upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v39_v40_roundtrip_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV39Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        // Seed a target to attach (FK target of project_targets).
        final targetId = await upgraded.customInsert(
          'INSERT INTO targets (name, ra, dec) VALUES (?, ?, ?)',
          variables: [
            Variable.withString('M31'),
            Variable.withReal(0.7),
            Variable.withReal(41.3),
          ],
        );

        final now = DateTime.utc(2026, 5, 30).millisecondsSinceEpoch ~/ 1000;
        final projectId = await upgraded.customInsert(
          'INSERT INTO projects (name, description, color_argb, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?)',
          variables: [
            Variable.withString('Galaxy Season'),
            Variable.withString('Spring galaxies'),
            Variable.withInt(0xFF5B9EC4),
            Variable.withInt(now),
            Variable.withInt(now),
          ],
        );
        expect(projectId, greaterThan(0));

        await upgraded.customInsert(
          'INSERT INTO project_targets '
          '(project_id, target_id, priority_override, added_at) '
          'VALUES (?, ?, ?, ?)',
          variables: [
            Variable.withInt(projectId),
            Variable.withInt(targetId),
            Variable.withInt(9),
            Variable.withInt(now),
          ],
        );

        final project = await upgraded
            .customSelect(
              'SELECT name, description, color_argb FROM projects WHERE id = ?',
              variables: [Variable.withInt(projectId)],
            )
            .getSingle();
        expect(project.read<String>('name'), 'Galaxy Season');
        expect(project.read<String>('description'), 'Spring galaxies');
        expect(project.read<int>('color_argb'), 0xFF5B9EC4);

        final member = await upgraded
            .customSelect(
              'SELECT target_id, priority_override FROM project_targets '
              'WHERE project_id = ?',
              variables: [Variable.withInt(projectId)],
            )
            .getSingle();
        expect(member.read<int>('target_id'), targetId);
        expect(member.read<int>('priority_override'), 9);

        // CASCADE: deleting the project tears down the membership row (FK
        // enforcement is enabled in beforeOpen).
        await upgraded.customStatement('DELETE FROM projects WHERE id = ?', [
          projectId,
        ]);
        final remaining = await upgraded
            .customSelect(
              'SELECT COUNT(*) AS c FROM project_targets WHERE project_id = ?',
              variables: [Variable.withInt(projectId)],
            )
            .getSingle();
        expect(
          remaining.read<int>('c'),
          0,
          reason: 'project_targets row not cascaded on project delete',
        );
      } finally {
        await upgraded.close();
      }
    });

    test(
      're-running the v40 migration block is idempotent (no throw)',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v39_v40_idempotent_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV39Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          // First open already ran onUpgrade(39, 40). Drive it again directly to
          // prove the v40 block (CREATE ... IF NOT EXISTS +
          // INSERT ... ON CONFLICT DO NOTHING) is re-runnable without error and
          // does not duplicate the tables or the settings seed.
          await expectLater(
            upgraded.migration.onUpgrade(upgraded.createMigrator(), 39, 40),
            completes,
          );

          final names = await tableNames(upgraded);
          expect(names, contains('projects'));
          expect(names, contains('project_targets'));

          // Exactly one settings row for the key (the seed did not duplicate).
          final count = await upgraded
              .customSelect(
                "SELECT COUNT(*) AS c FROM app_settings "
                "WHERE key = 'planning.active_project_id'",
              )
              .getSingle();
          expect(count.read<int>('c'), 1);
        } finally {
          await upgraded.close();
        }
      },
    );
  });
}
