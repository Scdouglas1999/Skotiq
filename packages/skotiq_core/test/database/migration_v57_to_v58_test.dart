// Migration round-trip test for the v57 -> v58 step (7.0 Darkroom data layer).
// v58 is purely additive — four new raw-DDL tables and their indexes:
//   * recipes           — the non-destructive op stack + branch graph.
//   * darkroom_jobs     — the durable dawn-job queue.
//   * delivery_targets  — where the night's artifacts go.
//   * delivery_journal  — what happened to each delivered file.
//
// Strategy mirrors migration_v55_to_v56_test.dart for an additive step:
//   1. Open a fresh on-disk DB at v58 via onCreate (full schema).
//   2. Simulate the pre-v58 (v57) state by DROPping the four tables and
//      rewinding `PRAGMA user_version = 57`.
//   3. Reopen — triggers onUpgrade(57, 58), running the v58 helper.
//   4. Assert the tables/indexes/constraints exist, round-trip each DAO, and
//      confirm the idempotent re-run preserves data.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_journal_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_targets_dao.dart';
import 'package:skotiq_core/src/database/daos/recipes_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/darkroom_models.dart';

void main() {
  group('migration onUpgrade v57 -> v58 (Darkroom data layer)', () {
    /// Opens a fresh DB at v58, drops everything v58 added, and rewinds
    /// `PRAGMA user_version = 57` so the next open triggers onUpgrade(57, 58).
    Future<File> createV57Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('PRAGMA foreign_keys = OFF');
        // Journal first: it references both of the tables below.
        for (final table in const <String>[
          'delivery_journal',
          'delivery_targets',
          'darkroom_jobs',
          'recipes',
        ]) {
          await setupDb.customStatement('DROP TABLE IF EXISTS $table');
        }
        await setupDb.customStatement('PRAGMA user_version = 57');
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

    Future<Directory> tempDir(String suffix) async {
      final dir = await Directory.systemTemp.createTemp(
        'skotiq_v57_v58_$suffix',
      );
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      return dir;
    }

    test('creates the four Darkroom tables with their columns and '
        'indexes on upgrade', () async {
      final dbFile = await createV57Database(await tempDir('schema_'));
      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(await tableExists(upgraded, 'recipes'), isTrue);
        expect(await tableExists(upgraded, 'darkroom_jobs'), isTrue);
        expect(await tableExists(upgraded, 'delivery_targets'), isTrue);
        expect(await tableExists(upgraded, 'delivery_journal'), isTrue);

        expect(
          await columnNames(upgraded, 'recipes'),
          containsAll(<String>[
            'id',
            'target_id',
            'session_id',
            'master_id',
            'base_master_path',
            'name',
            'steps_json',
            'created_by',
            'parent_recipe_id',
            'divergence_index',
            'schema_version',
            'created_at',
            'updated_at',
          ]),
        );
        expect(
          await columnNames(upgraded, 'darkroom_jobs'),
          containsAll(<String>[
            'id',
            'session_id',
            'kind',
            'state',
            'progress',
            'note',
            'error_text',
            'attempts',
            'created_at',
            'started_at',
            'finished_at',
          ]),
        );
        expect(
          await columnNames(upgraded, 'delivery_targets'),
          containsAll(<String>[
            'id',
            'name',
            'kind',
            'config_json',
            'enabled',
            'content_json',
            'secret_ref',
            'created_at',
            'updated_at',
          ]),
        );
        expect(
          await columnNames(upgraded, 'delivery_journal'),
          containsAll(<String>[
            'id',
            'target_id',
            'job_id',
            'file_path',
            'bytes',
            'checksum',
            'state',
            'attempts',
            'last_error',
            'created_at',
            'updated_at',
            'delivered_at',
          ]),
        );

        expect(
          await indexNames(upgraded),
          containsAll(<String>[
            'idx_recipes_target',
            'idx_recipes_session',
            'idx_recipes_master',
            'idx_recipes_parent',
            'idx_recipes_base_master',
            'idx_recipes_created',
            'idx_darkroom_jobs_state',
            'idx_darkroom_jobs_session',
            'idx_darkroom_jobs_created',
            'idx_delivery_targets_enabled',
            'idx_delivery_targets_name',
            'idx_delivery_journal_target',
            'idx_delivery_journal_job',
            'idx_delivery_journal_state',
          ]),
        );
      } finally {
        await upgraded.close();
      }
    });

    test(
      'the new tables round-trip through their DAOs after upgrade',
      () async {
        final dbFile = await createV57Database(await tempDir('roundtrip_'));
        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final recipes = RecipesDao(upgraded);
          final jobs = DarkroomJobsDao(upgraded);
          final targets = DeliveryTargetsDao(upgraded);
          final journal = DeliveryJournalDao(upgraded);

          final recipeId = await recipes.create(
            baseMasterPath: '/data/masters/M31_Ha_master.fits',
            name: 'Draft',
            stepsJson: '[{"op_id":"stretch","version":1}]',
          );
          final recipe = await recipes.getById(recipeId);
          expect(recipe, isNotNull);
          expect(recipe!.baseMasterPath, '/data/masters/M31_Ha_master.fits');
          expect(recipe.createdBy, RecipeAuthor.autopilot);
          expect(recipe.schemaVersion, 1);

          final jobId = await jobs.enqueue();
          expect((await jobs.getById(jobId))!.state, DarkroomJobState.queued);

          final targetId = await targets.create(
            name: 'office-pc',
            kind: ArtifactDestinationKind.watchedFolder,
            configJson: '{"path":"/mnt/office"}',
            content: const <ArtifactContent>{ArtifactContent.linearMasters},
          );
          expect((await targets.getById(targetId))!.name, 'office-pc');

          final entry = await journal.recordAttempt(
            targetId: targetId,
            jobId: jobId,
            filePath: '/data/masters/M31_Ha_master.fits',
            bytes: 1024,
          );
          expect(entry.state, DeliveryAttemptState.retrying);
          expect(entry.attempts, 1);
          expect(entry.bytes, 1024);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('the CHECK constraints reject values outside each enum', () async {
      final dbFile = await createV57Database(await tempDir('checks_'));
      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await expectLater(
          upgraded.customStatement(
            "INSERT INTO darkroom_jobs(kind, state, progress, attempts, "
            "created_at) VALUES ('dawn', 'sleeping', 0.0, 0, 1)",
          ),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          upgraded.customStatement(
            'INSERT INTO recipes(base_master_path, name, steps_json, '
            "created_by, schema_version, created_at, updated_at) "
            "VALUES ('/m.fits', '', '[]', 'somebody', 1, 1, 1)",
          ),
          throwsA(isA<Exception>()),
        );
        // A divergence index without a parent is not a branch.
        await expectLater(
          upgraded.customStatement(
            'INSERT INTO recipes(base_master_path, name, steps_json, '
            'created_by, divergence_index, schema_version, created_at, '
            "updated_at) VALUES ('/m.fits', '', '[]', 'user', 2, 1, 1, 1)",
          ),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          upgraded.customStatement(
            'INSERT INTO delivery_targets(name, kind, config_json, enabled, '
            "content_json, created_at, updated_at) "
            "VALUES ('nas', 'carrier_pigeon', '{}', 1, '[]', 1, 1)",
          ),
          throwsA(isA<Exception>()),
        );
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v58 migration block is idempotent (no-op)', () async {
      final dbFile = await createV57Database(await tempDir('idem_'));

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final keptId = await RecipesDao(
        first,
      ).create(baseMasterPath: '/data/keep.fits', name: 'Keep me');
      await first.close();

      // Rewind to v57 WITHOUT dropping; the helper is CREATE ... IF NOT EXISTS
      // throughout, so the second pass is a pure no-op that preserves the row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 57');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final kept = await RecipesDao(second).getById(keptId);
        expect(
          kept?.name,
          'Keep me',
          reason: 'the idempotent helper must NOT clobber existing data',
        );
      } finally {
        await second.close();
      }
    });
  });
}
