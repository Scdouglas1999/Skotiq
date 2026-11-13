// A backup holds every table of the schema except the named exclusions, and a
// restore into a fresh database brings every row back. Every table is seeded
// with one row from its own schema (PRAGMA table_info / foreign_key_list), so
// a table added later is covered without this test listing it.
//
// With SKOTIQ_REAL_DB_DIR set (a folder of `.db` copies of real databases;
// the test copies them again and never opens the originals), each copy is
// upgraded, seeded on top and round-tripped too.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';

LoggingService _logger(Directory dir) => LoggingService(
  applicationSupportDirectoryProvider: () async => dir,
  nativeInitWithLogging: ({String? logDirectory}) {},
  nativeInit: () {},
  currentLogFileProvider: () => null,
);

/// Values a CHECK constraint accepts, for the columns that have one.
const _checked = <String, Map<String, Object?>>{
  'recipes': {
    'created_by': 'user',
    'schema_version': 1,
    'parent_recipe_id': null,
    'divergence_index': null,
  },
  'darkroom_jobs': {
    'kind': 'manual',
    'state': 'done',
    'progress': 1.0,
    'attempts': 1,
  },
  'delivery_targets': {'kind': 'watched_folder', 'enabled': 1},
  'delivery_journal': {'state': 'delivered', 'attempts': 1, 'bytes': 10},
};

/// Seed one row in every table, parents first, and return the tables seeded.
Future<List<String>> _seedEveryTable(SkotiqDatabase db) async {
  final tables = [for (final t in db.allTables) t.actualTableName];
  final parents = <String, List<String>>{
    for (final t in tables)
      t: [
        for (final fk
            in await db.customSelect('PRAGMA foreign_key_list("$t")').get())
          if (fk.read<String>('table') != t) fk.read<String>('table'),
      ],
  };
  final seededId = <String, int>{};
  final order = <String>[];
  void place(String t) {
    if (order.contains(t)) return;
    parents[t]!.forEach(place);
    order.add(t);
  }

  tables.forEach(place);
  for (final t in order) {
    if (t == 'app_settings' || t == 'weather_settings') continue;
    final columns = await db.customSelect('PRAGMA table_info("$t")').get();
    final fks = {
      for (final fk
          in await db.customSelect('PRAGMA foreign_key_list("$t")').get())
        fk.read<String>('from'): fk.read<String>('table'),
    };
    final row = <String, Object?>{};
    for (final c in columns) {
      final name = c.read<String>('name');
      final type = c.read<String>('type').toUpperCase();
      final checked = _checked[t];
      if (checked != null && checked.containsKey(name)) {
        row[name] = checked[name];
      } else if (fks[name] case final parent?) {
        row[name] = parent == t ? null : seededId[parent];
      } else if (c.read<int>('pk') > 0 && type.contains('INT')) {
        row[name] = 7;
      } else if (type.contains('INT') || type.contains('BOOL')) {
        row[name] = 1;
      } else if (type.contains('REAL') ||
          type.contains('FLOA') ||
          type.contains('DOUB')) {
        row[name] = 2.5;
      } else if (type.contains('BLOB')) {
        row[name] = Uint8List.fromList([1, 2, 3]);
      } else {
        row[name] = 'seed $t $name';
      }
    }
    final names = row.keys.map((k) => '"$k"').join(', ');
    final marks = List.filled(row.length, '?').join(', ');
    // Re-seeding a table the real database already filled is fine: the
    // id 7 row is the one this test owns.
    await db.customStatement(
      'INSERT OR REPLACE INTO "$t" ($names) VALUES ($marks)',
      row.values.toList(),
    );
    seededId[t] = 7;
  }
  return order;
}

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

Future<void> _roundTrip(SkotiqDatabase source, Directory dir) async {
  final seeded = await _seedEveryTable(source);
  final file = '${dir.path}/round-trip.skbackup';
  final made = await BackupService(
    database: source,
    sequenceRepository: LocalSequenceRepository(source.sequencesDao),
    logger: _logger(dir),
  ).createBackup(customPath: file);
  expect(made.success, isTrue, reason: made.errorMessage);

  final target = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final restored = await BackupService(
    database: target,
    sequenceRepository: LocalSequenceRepository(target.sequencesDao),
    logger: _logger(dir),
  ).restoreBackup(filePath: file);
  expect(restored.success, isTrue, reason: restored.errorMessage);

  for (final t in seeded) {
    if (t == 'app_settings' || backupRowRules.containsKey(t)) continue;
    final there = await _rows(target, t);
    if (backupExcludedTables.containsKey(t)) {
      expect(
        there,
        isEmpty,
        reason: '$t is excluded: ${backupExcludedTables[t]}',
      );
      continue;
    }
    final here = await _rows(source, t);
    if (t == 'equipment_profiles') {
      expect(
        there.map((r) => r['name']).toSet(),
        here.map((r) => r['name']).toSet(),
      );
      continue;
    }
    expect(there, here, reason: '$t comes back row for row');
  }

  final settingsHere = await SettingsDao(source).getAllSettings()
    ..remove(BackupService.backupDirectorySettingKey)
    ..remove(BackupService.lastBackupSettingKey);
  final settingsThere = await SettingsDao(target).getAllSettings();
  for (final MapEntry(:key, :value) in settingsHere.entries) {
    expect(settingsThere[key], value, reason: 'setting $key');
  }
  Map<String, Object?> weather(Map<String, Object?> row) =>
      Map.of(row)..removeWhere((k, _) => k == 'id' || k == 'updated_at');
  expect(
    (await _rows(target, 'weather_settings')).map(weather),
    (await _rows(source, 'weather_settings')).map(weather),
  );
  await target.close();
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
    expect(names, containsAll(backupRowRules.keys));
  });

  test('every table with data comes back from a backup', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    await _roundTrip(source, dir);
  });

  test('a real database comes back from a backup', () async {
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
      try {
        await _roundTrip(source, dir);
      } finally {
        await source.close();
      }
    }
  });

  test('a merge never hangs a backup row on a different live row', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final source = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    await _seedEveryTable(source);
    final file = '${dir.path}/merge.skbackup';
    await BackupService(
      database: source,
      sequenceRepository: LocalSequenceRepository(source.sequencesDao),
      logger: _logger(dir),
    ).createBackup(customPath: file);

    final target = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    await target.customStatement(
      "INSERT INTO targets (id, name, ra, dec) VALUES (7, 'Another target', 1, 2)",
    );
    final restored = await BackupService(
      database: target,
      sequenceRepository: LocalSequenceRepository(target.sequencesDao),
      logger: _logger(dir),
    ).restoreBackup(filePath: file);
    expect(restored.success, isTrue, reason: restored.errorMessage);

    final targets = await _rows(target, 'targets');
    expect(targets.single['name'], 'Another target');
    for (final child in ['integration_goals', 'project_targets', 'campaigns']) {
      expect(
        await _rows(target, child),
        isEmpty,
        reason: "the backup's $child rows belong to its own target 7",
      );
    }
    expect(await _rows(target, 'dark_library'), hasLength(1));
  });

  test('replacing a database with its own backup changes nothing', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_round_trip_');
    addTearDown(() => dir.delete(recursive: true));
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final seeded = await _seedEveryTable(db);
    final service = BackupService(
      database: db,
      sequenceRepository: LocalSequenceRepository(db.sequencesDao),
      logger: _logger(dir),
    );
    final file = '${dir.path}/replace.skbackup';
    await service.createBackup(customPath: file);
    final before = {for (final t in seeded) t: await _rows(db, t)};

    final restored = await service.restoreBackup(
      filePath: file,
      replaceExisting: true,
    );
    expect(restored.success, isTrue, reason: restored.errorMessage);

    for (final t in seeded) {
      if (t == 'app_settings' || backupExcludedTables.containsKey(t)) continue;
      final after = await _rows(db, t);
      if (t == 'equipment_profiles' || t == 'weather_settings') {
        expect(after.map((r) => r['name']), before[t]!.map((r) => r['name']));
        continue;
      }
      expect(after, before[t], reason: t);
    }
  });
}
