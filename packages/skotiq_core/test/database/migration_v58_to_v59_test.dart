// Migration round-trip test for the v58 -> v59 step: `recipes.draft_notes_json`,
// the account of the pass that composed a recipe.
//
// Strategy mirrors migration_v56_to_v57_test.dart for an added column:
//   1. Open a fresh on-disk DB at v59 via onCreate (full schema) and write a
//      recipe through it.
//   2. Simulate the pre-v59 (v58) state by rebuilding `recipes` without the new
//      column and rewinding `PRAGMA user_version = 58`.
//   3. Reopen — triggers onUpgrade(58, 59), running the v59 helper.
//   4. Assert the column exists, the pre-existing row reads back as a recipe
//      with no draft account (rather than an unreadable one), the DAO
//      round-trips notes, and a second pass over the same file is a no-op.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/recipes_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/recipe.dart';

void main() {
  group('migration onUpgrade v58 -> v59 (recipes.draft_notes_json)', () {
    Future<Directory> tempDir(String suffix) async {
      final dir = await Directory.systemTemp.createTemp(
        'skotiq_v58_v59_$suffix',
      );
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      return dir;
    }

    Future<Set<String>> columnNames(SkotiqDatabase db, String table) async {
      final rows = await db.customSelect("PRAGMA table_info('$table')").get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    /// The v58 `recipes` table, verbatim: the v59 DDL minus the column this
    /// migration adds.
    ///
    /// Spelled out rather than copied with `CREATE TABLE ... AS SELECT`,
    /// because that form drops the primary key — the rebuilt table then takes
    /// inserts whose `id` is NULL, and every read by id after the upgrade
    /// misses a row that is plainly there.
    const v58Recipes =
        'CREATE TABLE recipes_v58('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
        'session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE SET NULL,'
        'master_id INTEGER REFERENCES integrated_masters(id) ON DELETE SET NULL,'
        'base_master_path TEXT NOT NULL,'
        "name TEXT NOT NULL DEFAULT '',"
        "steps_json TEXT NOT NULL DEFAULT '[]',"
        "created_by TEXT NOT NULL DEFAULT 'autopilot',"
        'parent_recipe_id INTEGER REFERENCES recipes(id) ON DELETE RESTRICT,'
        'divergence_index INTEGER,'
        'schema_version INTEGER NOT NULL DEFAULT 1,'
        'created_at INTEGER NOT NULL,'
        'updated_at INTEGER NOT NULL,'
        "CHECK (created_by IN ('autopilot', 'user')),"
        'CHECK (schema_version >= 1),'
        'CHECK (divergence_index IS NULL OR divergence_index >= 0),'
        'CHECK ((parent_recipe_id IS NULL) = (divergence_index IS NULL)))';

    /// A database at v58: `recipes` rebuilt without `draft_notes_json`, holding
    /// one legacy row, with the schema version rewound.
    Future<({File file, int recipeId})> createV58Database(Directory dir) async {
      final file = File('${dir.path}/skotiq.db');
      final setup = SkotiqDatabase.forTesting(NativeDatabase(file));
      try {
        final recipeId = await RecipesDao(setup).create(
          baseMasterPath: '/data/masters/M31_L_master.fits',
          name: 'Master · L draft',
          stepsJson: '[{"opId":"stretch","opVersion":1}]',
        );
        final legacy = (await columnNames(setup, 'recipes'))
            .where((name) => name != 'draft_notes_json')
            .map((name) => '"$name"')
            .join(', ');
        await setup.customStatement(v58Recipes);
        await setup.customStatement(
          'INSERT INTO recipes_v58($legacy) SELECT $legacy FROM recipes',
        );
        await setup.customStatement('DROP TABLE recipes');
        await setup.customStatement(
          'ALTER TABLE recipes_v58 RENAME TO recipes',
        );
        await setup.customStatement('PRAGMA user_version = 58');
        return (file: file, recipeId: recipeId);
      } finally {
        await setup.close();
      }
    }

    test(
      'adds the column and reads a pre-v59 row as a recipe nobody drafted',
      () async {
        final seeded = await createV58Database(await tempDir('schema_'));
        final upgraded = SkotiqDatabase.forTesting(
          NativeDatabase(seeded.file),
        );
        try {
          expect(
            await columnNames(upgraded, 'recipes'),
            contains('draft_notes_json'),
          );
          final dao = RecipesDao(upgraded);
          // The row survives the upgrade whole.
          expect(
            (await dao.getById(seeded.recipeId))?.name,
            'Master · L draft',
          );
          // And it reads as a recipe with no draft account — which is the truth
          // about every row written before the account was recorded.
          expect(await dao.draftNotesOf(seeded.recipeId), isEmpty);
        } finally {
          await upgraded.close();
        }
      },
    );

    test(
      'the draft account round-trips through the DAO after upgrade',
      () async {
        final seeded = await createV58Database(await tempDir('roundtrip_'));
        final upgraded = SkotiqDatabase.forTesting(
          NativeDatabase(seeded.file),
        );
        try {
          final dao = RecipesDao(upgraded);
          const notes = [
            RecipeDraftNote(
              opId: 'color_calibrate',
              outcome: 'omitted',
              reason:
                  'this master has 1 channel(s) and the colour fit needs '
                  'three',
            ),
            RecipeDraftNote(
              opId: 'stretch',
              outcome: 'included',
              reason: 'measured from this master by the operation registry',
            ),
          ];

          // On the row that was already there.
          await dao.setDraftNotes(seeded.recipeId, notes);
          final read = await dao.draftNotesOf(seeded.recipeId);
          expect(read.map((n) => n.opId), ['color_calibrate', 'stretch']);
          expect(read.first.outcome, 'omitted');
          expect(read.first.reason, contains('colour fit needs'));

          // And on a row created with them.
          final withNotes = await dao.create(
            baseMasterPath: '/data/masters/M31_B_master.fits',
            name: 'Master · B draft',
            createdBy: RecipeAuthor.autopilot,
            draftNotes: notes,
          );
          expect((await dao.draftNotesOf(withNotes)).map((n) => n.outcome), [
            'omitted',
            'included',
          ]);

          // Replace, never append: one composing pass supersedes the last.
          await dao.setDraftNotes(withNotes, const []);
          expect(await dao.draftNotesOf(withNotes), isEmpty);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('an id with no row is named, and corrupt text is refused', () async {
      final seeded = await createV58Database(await tempDir('errors_'));
      final upgraded = SkotiqDatabase.forTesting(
        NativeDatabase(seeded.file),
      );
      try {
        final dao = RecipesDao(upgraded);
        // Reading an absent recipe's account as "none" would show a draft with
        // its reasons stripped and no sign anything was missing.
        await expectLater(
          dao.draftNotesOf(seeded.recipeId + 999),
          throwsA(isA<RecipeMissingException>()),
        );

        // This app is the only writer, so unreadable text is corruption, not an
        // older format — it is reported rather than read as an empty account.
        await upgraded.customStatement(
          "UPDATE recipes SET draft_notes_json = 'not json' WHERE id = "
          '${seeded.recipeId}',
        );
        await expectLater(
          dao.draftNotesOf(seeded.recipeId),
          throwsA(isA<DarkroomWireFormatException>()),
        );
        await upgraded.customStatement(
          'UPDATE recipes SET draft_notes_json = \'[{"opId":"stretch"}]\' '
          'WHERE id = ${seeded.recipeId}',
        );
        await expectLater(
          dao.draftNotesOf(seeded.recipeId),
          throwsA(isA<DarkroomWireFormatException>()),
        );
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v59 migration block is idempotent (no-op)', () async {
      final seeded = await createV58Database(await tempDir('idem_'));

      final first = SkotiqDatabase.forTesting(NativeDatabase(seeded.file));
      await RecipesDao(first).setDraftNotes(seeded.recipeId, const [
        RecipeDraftNote(
          opId: 'crop',
          outcome: 'omitted',
          reason: 'no fully covered rectangle survives in this master',
        ),
      ]);
      await first.close();

      // Rewind WITHOUT dropping the column; the helper is guarded by
      // `_columnExists`, so the second pass preserves what is stored.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(seeded.file));
      await rewind.customStatement('PRAGMA user_version = 58');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(seeded.file));
      try {
        final kept = await RecipesDao(second).draftNotesOf(seeded.recipeId);
        expect(
          kept.single.opId,
          'crop',
          reason: 'the guarded ALTER must NOT clobber a stored account',
        );
      } finally {
        await second.close();
      }
    });
  });
}
