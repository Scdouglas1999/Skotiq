// drift is the only definition of the schema. These tests pin that the move
// from raw DDL to drift changed nothing on disk:
//
//   * a database written by the last build that created tables with raw DDL
//     (commit c04d55c8d, schema v64, a row in every table) opens with its
//     schema byte-for-byte unchanged and every row readable;
//   * a database created from nothing has the same structure that build
//     created, plus the tables that build only made on first use;
//   * a v64 database that never ran the services that used to create their
//     own tables gets those tables in the shape the services gave them.
//
// `fixtures/README.md` says how the fixtures were made.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/replay_decision.dart';
import 'package:skotiq_core/src/models/scheduler/target_constraint.dart';
import 'package:skotiq_core/src/services/conversational_builder/conversational_history_service.dart';
import 'package:skotiq_core/src/services/darkroom_state_store.dart';
import 'package:skotiq_core/src/services/notes_service.dart';
import 'package:skotiq_core/src/services/planning/project_service.dart';
import 'package:skotiq_core/src/services/replay_debug_service.dart';
import 'package:skotiq_core/src/services/scheduler/horizon_profile_store.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_queue_service.dart';
import 'package:skotiq_core/src/services/scheduler/target_constraint_service.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

import 'schema_dump.dart';

const _fixtures = 'test/database/schema/fixtures';

/// Tables the base build created only when their service first ran. A fresh
/// database now has them from the start.
const _onceLazyTables = {
  'integration_goals',
  'target_constraints',
  'horizon_profiles',
  'scheduler_removed_targets',
  'darkroom_state',
  'conversational_builds',
};

/// Columns schema steps after the base build added, by table. The base
/// comparisons leave them out; each step's own migration test covers it.
const _columnsAddedAfterBase = {
  'captured_images': {'gain_kind'},
};

/// [tables] (a [dumpSchema] `tables` map) without [_columnsAddedAfterBase].
Map<dynamic, dynamic> _asOfBase(Map<dynamic, dynamic> tables) => {
  for (final MapEntry(:key, :value) in tables.entries)
    key: _columnsAddedAfterBase[key] == null
        ? value
        : {
            ...(value as Map),
            'columns': [
              for (final column in (value['columns'] as List))
                if (!_columnsAddedAfterBase[key]!.contains(column['name']))
                  column,
            ],
          },
};

File _unpackPopulatedFixture(Directory dir) {
  final bytes = gzip.decode(
    File('$_fixtures/base_c04d55c8d_populated.db.gz').readAsBytesSync(),
  );
  return File('${dir.path}/skotiq.db')..writeAsBytesSync(bytes);
}

T _withRaw<T>(File file, T Function(raw.Database db) body) {
  final db = raw.sqlite3.open(file.path);
  try {
    return body(db);
  } finally {
    db.close();
  }
}

Future<void> _openAndClose(File file) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase(file));
  try {
    await db.customSelect('SELECT 1').get();
  } finally {
    await db.close();
  }
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('skotiq_schema_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('a database written by the raw-DDL build', () {
    test('opens with its schema and row counts unchanged', () async {
      final file = _unpackPopulatedFixture(dir);
      final masterBefore = _withRaw(file, dumpMasterSql);
      final shapeBefore = _withRaw(file, dumpSchema)['tables']! as Map;
      final countsBefore = _withRaw(file, dumpRowCounts);
      expect(
        _withRaw(file, (db) => db.select('PRAGMA user_version').first.values),
        [64],
      );
      expect(countsBefore.values.where((n) => n == 0), isEmpty);

      await _openAndClose(file);

      _withRaw(file, (db) {
        expect(db.select('PRAGMA integrity_check').first.values, ['ok']);
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
        expect(db.select('PRAGMA user_version').first.values, [66]);
      });
      // Same tables, same indexes, same SQL text: nothing was rebuilt,
      // altered or added, except the columns later steps add.
      String withoutAdded(String key) =>
          _columnsAddedAfterBase.keys.contains(key.split(':').last) ? '' : key;
      final masterAfter = _withRaw(file, dumpMasterSql);
      expect(
        {
          for (final e in masterAfter.entries)
            if (withoutAdded(e.key).isNotEmpty) e.key: e.value,
        },
        {
          for (final e in masterBefore.entries)
            if (withoutAdded(e.key).isNotEmpty) e.key: e.value,
        },
      );
      final shapeAfter = _withRaw(file, dumpSchema)['tables']! as Map;
      for (final table in _columnsAddedAfterBase.keys) {
        expect(
          jsonDecode(jsonEncode(_asOfBase(shapeAfter)[table])),
          jsonDecode(jsonEncode(shapeBefore[table])),
          reason: table,
        );
      }

      final countsAfter = _withRaw(file, dumpRowCounts);
      // The settings seed may grow with the build; nothing else may change.
      expect(
        countsAfter['app_settings'],
        greaterThanOrEqualTo(countsBefore['app_settings']!),
      );
      expect(
        {...countsAfter}..remove('app_settings'),
        {...countsBefore}..remove('app_settings'),
      );
    });

    test('reads every table through its drift definition', () async {
      final file = _unpackPopulatedFixture(dir);
      final db = SkotiqDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);

      final onDisk = _withRaw(file, dumpRowCounts);
      final declared = {for (final t in db.allTables) t.actualTableName};
      expect(declared, onDisk.keys.toSet());

      for (final table in db.allTables) {
        final rows = await db.select(table).get();
        expect(
          rows,
          hasLength(onDisk[table.actualTableName]),
          reason: table.actualTableName,
        );
      }
    });

    test('reads the rows the services wrote', () async {
      final file = _unpackPopulatedFixture(dir);
      final db = SkotiqDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);
      final targetId = (await db.select(db.targets).get()).first.id;

      final goals = IntegrationGoalService(db);
      addTearDown(goals.dispose);
      final goal = (await goals.listAll()).singleWhere((g) => g.filter == 'Ha');
      expect(goal.targetId, targetId);
      expect(goal.exposureSeconds, 300);
      expect(goal.frameCount, 40);
      expect(goal.priority, 7);
      expect(goal.createdAt, DateTime.utc(2026, 10, 1, 3));

      final constraints = TargetConstraintService(db);
      addTearDown(constraints.dispose);
      final constraint = (await constraints.listAll()).singleWhere(
        (c) => c.kind == TargetConstraintKind.moonIlluminationMax,
      );
      expect(constraint.targetId, targetId);
      expect(constraint.moonIlluminationMax, 0.3);
      expect(constraint.enabled, isTrue);

      expect(
        await SchedulerQueueService(db).removedTargetIds(),
        contains(targetId),
      );

      final notes = NotesService(db);
      addTearDown(notes.dispose);
      final m31 = (await notes.notesForTarget('M31')).single;
      expect(m31.title, 'First night');
      expect(m31.body, 'Thin cloud after midnight.');
      expect(m31.sequenceRunId, 1);
      expect(m31.tags, ['seeing', 'cloud']);
      expect(m31.attachments, ['/tmp/a.png']);
      expect(m31.sentiment, 'neutral');
      expect((await notes.notesForRun(1)).map((n) => n.id), contains(m31.id));
      final m42 = (await notes.notesForTarget('M42')).single;
      expect(m42.title, isNull);
      expect(m42.sequenceRunId, isNull);
      expect(await notes.searchNotes(tags: const ['cloud']), hasLength(1));

      final replay = ReplayDebugService(db);
      addTearDown(replay.dispose);
      final decision = (await replay.listByRunAndCategory(
        1,
        DecisionCategory.triggerFired,
      )).single;
      expect(decision.summary, 'Autofocus trigger fired');
      expect(decision.timestamp.toUtc(), DateTime.utc(2026, 10, 1, 4));
      expect(decision.details, {'hfr': 2.4});
      expect(decision.nodeId, 'node-1');
      expect(await replay.countByRun(1), greaterThanOrEqualTo(1));

      final projects = ProjectService(db, goals);
      addTearDown(projects.dispose);
      final project = (await projects.listProjects()).singleWhere(
        (p) => p.name == 'Autumn galaxies',
      );
      expect(project.description, 'Two nights');
      expect(project.colorArgb, 0xFF336699);
      final member = (await projects.listTargets(project.id!)).single;
      expect(member.targetId, targetId);
      expect(member.priorityOverride, 9);
      final progress = await projects.buildProgress(project.id!);
      expect(progress.targets.single.targetId, targetId);

      expect(await DarkroomStateStore(db).read('master_builds'), {
        'jobs': [1, 2],
      });

      final history = ConversationalHistoryService(db);
      addTearDown(history.dispose);
      final builds = await history.recent();
      final accepted = builds.singleWhere((b) => b.userPrompt.startsWith('Im'));
      expect(accepted.successful, isTrue);
      expect(accepted.rounds, 2);
      expect(accepted.usage?.totalTokens, 30);
      expect(accepted.acceptedSequenceId, 'seq-1');
      expect(accepted.providerKind, 'ollama');
      final unused = builds.singleWhere((b) => b.userPrompt == 'No usage');
      expect(unused.usage, isNull);
      expect(unused.successful, isFalse);

      final horizon = (await loadHorizonProfiles(
        db,
      )).singleWhere((h) => h.name == 'Back yard');
      expect(horizon.samples, hasLength(2));
    });

    test(
      'gets the once-lazy tables it never created, in their old shape',
      () async {
        final file = _unpackPopulatedFixture(dir);
        final shapeBefore = _withRaw(file, dumpSchema)['tables']! as Map;
        _withRaw(file, (db) {
          for (final table in _onceLazyTables) {
            db.execute('DROP TABLE "$table"');
          }
          db.execute(
            'ALTER TABLE captured_images DROP COLUMN plate_solve_failed_at',
          );
        });

        await _openAndClose(file);

        final shapeAfter = _asOfBase(
          _withRaw(file, dumpSchema)['tables']! as Map,
        );
        expect(shapeAfter.keys.toSet(), shapeBefore.keys.toSet());
        for (final table in [..._onceLazyTables, 'captured_images']) {
          expect(shapeAfter[table], shapeBefore[table], reason: table);
        }
      },
    );
  });

  test('rows that break an index the database never had do not stop it '
      'opening', () async {
    // Databases upgraded through v52 never got `idx_sky_tiles_pixel`, so
    // nothing stopped two rows for one pixel.
    final file = _unpackPopulatedFixture(dir);
    _withRaw(file, (db) {
      db.execute('DROP INDEX idx_sky_tiles_pixel');
      final columns = [
        for (final c in db.select('PRAGMA table_info(sky_tiles)'))
          if (c['name'] != 'id') '"${c['name']}"',
      ].join(', ');
      db.execute(
        'INSERT INTO sky_tiles ($columns) SELECT $columns FROM sky_tiles',
      );
    });

    await _openAndClose(file);

    _withRaw(file, (db) {
      expect(db.select('PRAGMA user_version').first.values, [66]);
      expect(db.select('SELECT COUNT(*) AS n FROM sky_tiles').first['n'], 2);
      expect(
        db.select(
          "SELECT 1 FROM sqlite_master WHERE name = 'idx_sky_tiles_pixel'",
        ),
        isEmpty,
      );
    });
  });

  test(
    'a fresh database has the structure the raw-DDL build created',
    () async {
      final file = File('${dir.path}/skotiq.db');
      await _openAndClose(file);
      final fresh = _withRaw(file, dumpSchema);
      final base =
          jsonDecode(
                File(
                  '$_fixtures/base_c04d55c8d_fresh_schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;

      final freshTables = _asOfBase(fresh['tables']! as Map);
      final baseTables = base['tables'] as Map;
      expect(freshTables.keys.toSet(), {
        ...baseTables.keys,
        ..._onceLazyTables,
      });
      // Through JSON so both sides hold the same plain types.
      final normalized = jsonDecode(jsonEncode(freshTables)) as Map;
      for (final name in baseTables.keys) {
        expect(normalized[name], baseTables[name], reason: name as String);
      }
      expect(jsonDecode(jsonEncode(fresh['other'])), base['other']);

      // The once-lazy tables match what the services used to create.
      final populated = _unpackPopulatedFixture(
        Directory('${dir.path}/p')..createSync(),
      );
      final served = _withRaw(populated, dumpSchema)['tables']! as Map;
      for (final name in _onceLazyTables) {
        expect(freshTables[name], served[name], reason: name);
      }
    },
  );
}
