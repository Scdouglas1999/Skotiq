// A backup holds every table of the schema except the named exclusions, and a
// restore into a fresh database brings every row back. Every table is seeded
// with one row from its own schema (PRAGMA table_info / foreign_key_list), so
// a table added later is covered without this test listing it.
//
// With SKOTIQ_REAL_DB_DIR set (a folder of `.db` copies of real databases;
// the test copies them again and never opens the originals), each copy is
// upgraded, seeded on top and round-tripped too.
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';

import 'backup_restore_support.dart';

LoggingService _logger(Directory dir) => LoggingService(
  applicationSupportDirectoryProvider: () async => dir,
  nativeInitWithLogging: ({String? logDirectory}) {},
  nativeInit: () {},
  currentLogFileProvider: () => null,
);

/// [t]'s rows, with every link to a profile written as the profile's name: a
/// restore matches profiles by name, so their ids may differ.
Future<List<Map<String, Object?>>> _rows(SkotiqDatabase db, String t) async {
  final profileNames = {
    for (final r
        in await db
            .customSelect('SELECT id, name FROM equipment_profiles')
            .get())
      r.read<int>('id'): r.read<String>('name'),
  };
  final profileLinks = [
    for (final fk
        in await db.customSelect('PRAGMA foreign_key_list("$t")').get())
      if (fk.read<String>('table') == 'equipment_profiles')
        fk.read<String>('from'),
  ];
  return [
    for (final r
        in await db.customSelect('SELECT * FROM "$t" ORDER BY rowid').get())
      {
        ...r.data,
        for (final c in profileLinks)
          if (r.data[c] case final int id) c: profileNames[id],
      },
  ];
}

BackupService _service(SkotiqDatabase db, Directory dir) => BackupService(
  database: db,
  logger: _logger(dir),
  backupDirectoryProvider: () async => Directory('${dir.path}/backups'),
);

/// Every table's rows, by table.
Future<Map<String, List<Map<String, Object?>>>> _everything(
  SkotiqDatabase db,
) async => {
  for (final t in db.allTables)
    t.actualTableName: await _rows(db, t.actualTableName),
};

Future<void> _roundTrip(
  SkotiqDatabase source,
  Directory dir, {
  void Function(String step)? lap,
}) async {
  final seeded = await seedEveryTable(source);
  final file = '${dir.path}/round-trip.skbackup';
  lap?.call('seeded');
  final made = await _service(source, dir).createBackup(customPath: file);
  expect(made.success, isTrue, reason: made.errorMessage);
  lap?.call(
    'backup of ${made.itemsBackedUp} rows, ${File(file).lengthSync()} bytes',
  );

  // A merge into an empty database adds every row but the settings.
  final target = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final restored = await _service(target, dir).restoreBackup(filePath: file);
  expect(restored.success, isTrue, reason: restored.errorMessage);
  lap?.call('merge into an empty database');
  expect(restored.notRestored, isEmpty);
  final again = await _service(target, dir).restoreBackup(filePath: file);
  lap?.call('merge of the same backup again');
  expect(again.itemsRestored, 0);
  expect(again.notRestored, isEmpty);

  for (final t in seeded) {
    if (backupMergeKeepsYours.containsKey(t)) continue;
    final there = await _rows(target, t);
    if (backupExcludedTables.containsKey(t)) {
      expect(
        there,
        isEmpty,
        reason: '$t is excluded: ${backupExcludedTables[t]}',
      );
      continue;
    }
    expect(there, await _rows(source, t), reason: '$t comes back row for row');
  }

  // Rows deleted since come back, beside the rows that are still here.
  final frames = (await _rows(target, 'captured_images')).length;
  await target.customStatement('PRAGMA foreign_keys = ON');
  await target.customStatement(
    'DELETE FROM captured_images WHERE id IN '
    '(SELECT id FROM captured_images ORDER BY id DESC LIMIT 25)',
  );
  final readded = await _service(target, dir).restoreBackup(filePath: file);
  lap?.call('merge after deleting 25 frames: ${readded.report}');
  expect(readded.success, isTrue, reason: readded.errorMessage);
  expect((await _rows(target, 'captured_images')).length, frames);
  await target.close();

  // A replace makes a database with rows of its own the backup.
  final live = File('${dir.path}/live/skotiq.db');
  await live.parent.create();
  var replaced = SkotiqDatabase.forTesting(NativeDatabase(live));
  await replaced.customStatement(
    "INSERT INTO targets (id, name, ra, dec) VALUES (3, 'Only here', 1, 2)",
  );
  await SettingsDao(replaced).setSetting('only_here', 'yes');
  final before = await _everything(replaced);
  final replace = await _service(
    replaced,
    dir,
  ).restoreBackup(filePath: file, mode: RestoreMode.replace);
  expect(replace.success, isTrue, reason: replace.errorMessage);
  lap?.call('replace built');
  expect(replace.pendingRestart, isTrue);
  expect(File(replace.safetyBackupPath!).existsSync(), isTrue);
  expect(
    {...await _everything(replaced)}..remove('app_settings'),
    {...before}..remove('app_settings'),
    reason: 'this database is not written before the restart',
  );
  await replaced.close();

  final outcome = await applyPendingRestore(live);
  expect(outcome?.restored, isTrue, reason: outcome?.failureReason);
  expect(File(outcome!.replacedPath!).existsSync(), isTrue);
  replaced = SkotiqDatabase.forTesting(NativeDatabase(live));
  for (final t in seeded) {
    final there = await _rows(replaced, t);
    if (backupExcludedTables.containsKey(t)) {
      expect(there, isEmpty, reason: t);
    } else if (t != 'app_settings') {
      expect(there, await _rows(source, t), reason: '$t is the backup\'s');
    }
  }
  final settingsHere = await SettingsDao(source).getAllSettings()
    ..remove(BackupService.backupDirectorySettingKey)
    ..remove(BackupService.lastBackupSettingKey);
  final settingsThere = await SettingsDao(replaced).getAllSettings();
  for (final MapEntry(:key, :value) in settingsHere.entries) {
    expect(settingsThere[key], value, reason: 'setting $key');
  }
  expect(settingsThere.containsKey('only_here'), isFalse);
  await replaced.close();

  // The safety backup holds the database as it was.
  final back = SkotiqDatabase.forTesting(NativeDatabase.memory());
  expect(
    (await _service(
      back,
      dir,
    ).restoreBackup(filePath: replace.safetyBackupPath!)).success,
    isTrue,
  );
  expect((await _rows(back, 'targets')).map((r) => r['name']), ['Only here']);
  await back.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('the tables a backup leaves out are tables of the schema', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final names = {for (final t in db.allTables) t.actualTableName};
    expect(names, containsAll(backupExcludedTables.keys));
    expect(names, containsAll(backupOwnSectionTables.keys));
    expect(names, containsAll(backupMergeKeepsYours.keys));
    expect(names, containsAll(backupMergeRules.keys));
  });

  test('every table and every row-id column has a merge rule', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final t in db.allTables.map((t) => t.actualTableName)) {
      if (backupExcludedTables.containsKey(t) ||
          backupMergeKeepsYours.containsKey(t)) {
        continue;
      }
      final rule = backupMergeRules[t];
      expect(rule, isNotNull, reason: '$t has no merge rule');
      final columns = await db.customSelect('PRAGMA table_info("$t")').get();
      final names = {for (final c in columns) c.read<String>('name')};
      final foreign = {
        for (final fk
            in await db.customSelect('PRAGMA foreign_key_list("$t")').get())
          fk.read<String>('from'),
      };
      for (final c in [...rule!.keys.expand((k) => k), ...rule.partOf]) {
        expect(names, contains(c), reason: '$t.$c');
      }
      for (final c in rule.partOf) {
        expect(
          foreign.contains(c) || rule.links.containsKey(c),
          isTrue,
          reason: '$t.$c is a link',
        );
      }
      // An integer `_id` column is a row id of some table unless said not.
      for (final c in columns) {
        final name = c.read<String>('name');
        if (!name.endsWith('_id') ||
            c.read<int>('pk') > 0 ||
            !c.read<String>('type').toUpperCase().contains('INT')) {
          continue;
        }
        expect(
          foreign.contains(name) ||
              rule.links.containsKey(name) ||
              rule.typedLinks.containsKey(name) ||
              rule.plainIds.contains(name),
          isTrue,
          reason: '$t.$name holds an id the merge rule does not place',
        );
      }
    }
  });

  test('every table with data comes back from a backup', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    await _roundTrip(source, dir);
  });

  test(
    'a real database comes back from a backup',
    timeout: const Timeout(Duration(minutes: 30)),
    () async {
      final real = Platform.environment['SKOTIQ_REAL_DB_DIR'];
      final copies = real == null
          ? const <File>[]
          : Directory(real)
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.db'))
                .toList();
      if (copies.isEmpty) {
        markTestSkipped(
          'SKOTIQ_REAL_DB_DIR is not set; no real database checked',
        );
        return;
      }
      for (final original in copies) {
        final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
        addTearDown(() => dir.delete(recursive: true));
        final copy = await original.copy(
          '${dir.path}/${original.uri.pathSegments.last}',
        );
        final source = SkotiqDatabase.forTesting(NativeDatabase(copy));
        final watch = Stopwatch()..start();
        try {
          await _roundTrip(
            source,
            dir,
            // ignore: avoid_print
            lap: (step) => print(
              '${original.uri.pathSegments.last}: '
              '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s $step',
            ),
          );
        } finally {
          await source.close();
        }
      }
    },
  );

  test('a merge into a database with its own target, session, frame and '
      'measurements under the same ids keeps both sets apart', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    await seedEveryTable(source);
    final file = '${dir.path}/conflict.skbackup';
    await BackupService(
      database: source,
      logger: _logger(dir),
    ).createBackup(customPath: file);

    // This database's own night: the same row ids as the backup's target and
    // session, a frame under another id (so the backup frame's id is free),
    // and one measurement of that frame.
    final target = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    for (final sql in [
      "INSERT INTO targets (id, name, ra, dec) VALUES (7, 'Live target', 1, 2)",
      'INSERT INTO imaging_sessions (id, name, target_id, start_time) '
          "VALUES (7, 'Live night', 7, 1700000000)",
      'INSERT INTO captured_images (id, file_path, file_name, session_id, '
          'target_id, frame_type, exposure_duration, captured_at) '
          "VALUES (8, '/live/a.fits', 'a.fits', 7, 7, 'light', 60, 1700000100)",
      'INSERT INTO science_tile_metrics (id, captured_image_id, session_id, '
          'timestamp, layer_type, tile_row, tile_col, sample_count, value, '
          "p05, p50, p95, aux_value) VALUES (3, 8, 7, 1700000100, 'live', 0, "
          '0, 9, 9.5, 9, 9, 9, 9)',
    ]) {
      await target.customStatement(sql);
    }
    Future<List<Map<String, Object?>>> liveRows() async => [
      for (final t in [
        'targets',
        'imaging_sessions',
        'captured_images',
        'science_tile_metrics',
      ])
        ...(await _rows(target, t)).where(
          (r) => '${r['name'] ?? r['file_path'] ?? r['layer_type']}'
              .toLowerCase()
              .contains('live'),
        ),
    ];
    final liveBefore = await liveRows();
    expect(liveBefore, hasLength(4));

    final restored = await BackupService(
      database: target,
      logger: _logger(dir),
    ).restoreBackup(filePath: file);
    expect(restored.success, isTrue, reason: restored.errorMessage);

    expect(await liveRows(), liveBefore, reason: 'live rows are untouched');

    // Every row that points at a session, frame or target points at the one
    // it came with: a backup row at a backup row, a live row at a live row.
    Future<List<Map<String, Object?>>> select(String sql) async => [
      for (final r in await target.customSelect(sql).get()) r.data,
    ];
    final tables = [for (final t in target.allTables) t.actualTableName];
    for (final t in tables) {
      final fks = await target
          .customSelect('PRAGMA foreign_key_list("$t")')
          .get();
      for (final fk in fks) {
        final parent = fk.read<String>('table');
        final column = fk.read<String>('from');
        final label = switch (parent) {
          'targets' => 'name',
          'imaging_sessions' => 'name',
          'captured_images' => 'file_path',
          _ => null,
        };
        if (label == null) continue;
        final liveParents = await select(
          'SELECT c.rowid AS child FROM "$t" c JOIN "$parent" p '
          'ON p.id = c."$column" WHERE lower(p."$label") LIKE \'%live%\'',
        );
        final ownChildren = switch (t) {
          'imaging_sessions' || 'captured_images' => 1,
          'science_tile_metrics' => 1,
          _ => 0,
        };
        expect(
          liveParents,
          hasLength(ownChildren),
          reason:
              '$t.$column: only this database\'s own rows hang on its '
              'own $parent',
        );
      }
    }
    expect(await select('PRAGMA foreign_key_check'), isEmpty);

    // The backup's target, session, frame and measurement are all here, in
    // one chain, and none of them lost a link it had.
    final chain = await select(
      'SELECT t.name AS target, s.name AS session, i.file_path AS frame, '
      'm.layer_type AS layer, m.session_id = s.id AS same_session, '
      'i.target_id = t.id AS same_target '
      'FROM science_tile_metrics m '
      'JOIN captured_images i ON i.id = m.captured_image_id '
      'JOIN imaging_sessions s ON s.id = i.session_id '
      'JOIN targets t ON t.id = s.target_id '
      "WHERE m.layer_type = 'seed science_tile_metrics layer_type'",
    );
    expect(chain, [
      {
        'target': 'seed targets name',
        'session': 'seed imaging_sessions name',
        'frame': 'seed captured_images file_path',
        'layer': 'seed science_tile_metrics layer_type',
        'same_session': 1,
        'same_target': 1,
      },
    ]);
    for (final t in tables) {
      if (!t.startsWith('science_') && t != 'psf_field_tiles') continue;
      final columns = await select('PRAGMA table_info("$t")');
      if (!columns.any((c) => c['name'] == 'captured_image_id')) continue;
      expect(
        await select(
          'SELECT 1 FROM "$t" WHERE captured_image_id IS NULL '
          'OR session_id IS NULL',
        ),
        isEmpty,
        reason: '$t: no restored row is left attached to nothing',
      );
    }

    // The result says what happened to every backup row.
    expect(restored.categoryCounts['targets'], 1);
    expect(restored.categoryCounts['imaging_sessions'], 1);
    expect(restored.categoryCounts['captured_images'], 1);
    expect(restored.categoryCounts['science_tile_metrics'], 1);
    expect(restored.notRestored, isEmpty);
  });

  test('a merge into the same database after an edit reports only the edited '
      'record as left out, and a second merge adds nothing', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    await seedEveryTable(source);
    final service = _service(source, dir);
    final file = '${dir.path}/same.skbackup';
    await service.createBackup(customPath: file);
    await source.customStatement(
      "UPDATE targets SET name = 'Renamed' WHERE id = 7",
    );
    final before = await _everything(source);

    for (var pass = 0; pass < 2; pass++) {
      final restored = await service.restoreBackup(filePath: file);
      expect(restored.success, isTrue, reason: restored.errorMessage);
      // Its children are here already, unchanged: nothing of theirs is
      // missing, and nothing is added a second time.
      expect(restored.notRestored, {'targets': 1});
      expect(restored.leftOut, {RestoreLeftOut.yoursKept: 1});
      expect(restored.itemsRestored, 0);
      expect(await _everything(source), before);
    }
  });

  test('a row deleted since the backup comes back with what hung on it, and '
      'nothing is added inside a record that is still here', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seedEveryTable(db);
    final service = _service(db, dir);
    final file = '${dir.path}/deleted.skbackup';
    await service.createBackup(customPath: file);
    final before = await _everything(db);

    await db.customStatement('PRAGMA foreign_keys = ON');
    await db.customStatement('DELETE FROM captured_images WHERE id = 7');
    await db.customStatement('DELETE FROM sequence_nodes WHERE id = 7');
    expect(await _rows(db, 'science_tile_metrics'), isEmpty);

    final restored = await service.restoreBackup(filePath: file);
    expect(restored.success, isTrue, reason: restored.errorMessage);
    final after = await _everything(db);
    expect(after['captured_images'], before['captured_images']);
    expect(after['science_tile_metrics'], before['science_tile_metrics']);
    expect(after['image_metadata'], before['image_metadata']);
    expect(after['sequence_nodes'], isEmpty, reason: 'the sequence is yours');
    expect(restored.notRestored['sequence_nodes'], 1);
    expect(restored.leftOut[RestoreLeftOut.insideYours], greaterThan(0));
  });

  test('a replace that cannot finish leaves the database as it was', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    await seedEveryTable(source);
    final good = '${dir.path}/good.skbackup';
    await _service(source, dir).createBackup(customPath: good);

    final live = File('${dir.path}/live/skotiq.db');
    await live.parent.create();
    var db = SkotiqDatabase.forTesting(NativeDatabase(live));
    await db.customStatement(
      "INSERT INTO targets (id, name, ra, dec) VALUES (3, 'Only here', 1, 2)",
    );
    final before = await _everything(db);
    Future<void> unchanged(String why) async {
      expect(
        {...await _everything(db)}..remove('app_settings'),
        {...before}..remove('app_settings'),
        reason: why,
      );
      expect(await _service(db, dir).pendingReplace(), isNull, reason: why);
      expect(
        live.parent
            .listSync()
            .map((e) => e.uri.pathSegments.last)
            .where((name) => name.contains('restore') || name.contains('work')),
        isEmpty,
        reason: '$why: no work file is left',
      );
    }

    // A backup cut off part-way.
    final cut = File('${dir.path}/cut.skbackup');
    final bytes = await File(good).readAsBytes();
    await cut.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));
    var result = await _service(
      db,
      dir,
    ).restoreBackup(filePath: cut.path, mode: RestoreMode.replace);
    expect(result.success, isFalse);
    await unchanged('a truncated backup');

    // No safety backup can be written.
    final blocked = File('${dir.path}/not-a-folder')..writeAsStringSync('x');
    result = await BackupService(
      database: db,
      logger: _logger(dir),
      backupDirectoryProvider: () async => Directory('${blocked.path}/in'),
    ).restoreBackup(filePath: good, mode: RestoreMode.replace);
    expect(result.success, isFalse);
    expect(result.errorMessage, contains('safety backup'));
    await unchanged('no safety backup');

    // The built database is gone or damaged by the time Skotiq starts.
    for (final damage in ['gone', 'damaged']) {
      result = await _service(
        db,
        dir,
      ).restoreBackup(filePath: good, mode: RestoreMode.replace);
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(
        (await _service(db, dir).pendingReplace())?.backupName,
        'good.skbackup',
      );
      await db.close();
      final ready = File((await readPendingRestore(live.parent))!);
      if (damage == 'gone') {
        await ready.delete();
      } else {
        await ready.writeAsBytes(List.filled(8192, 7));
      }
      final outcome = await applyPendingRestore(live);
      expect(outcome?.restored, isFalse, reason: damage);
      expect(
        (await readRestoreOutcome(live.parent))?.report,
        contains('It is unchanged'),
      );
      if (damage == 'damaged') await ready.delete();
      await clearRestoreOutcome(live.parent);
      db = SkotiqDatabase.forTesting(NativeDatabase(live));
      await unchanged('the built database is $damage');
    }

    // A replace that is withdrawn.
    result = await _service(
      db,
      dir,
    ).restoreBackup(filePath: good, mode: RestoreMode.replace);
    expect(result.success, isTrue, reason: result.errorMessage);
    await _service(db, dir).cancelPendingReplace();
    await unchanged('a withdrawn replace');

    // A built database the start-up refused is cleared by the next backup.
    final refused = File('${live.parent.path}/skotiq-restore-ready-old.db')
      ..writeAsStringSync('x');
    await _service(db, dir).createBackup(customPath: '${dir.path}/b.skbackup');
    expect(refused.existsSync(), isFalse);
    await db.close();
  });
}
