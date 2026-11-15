import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';

var _databases = 0;

/// Replaces a file database in [dir] with the backup at [backupPath] the way
/// the app does (build the new one beside it, close, swap at the next open)
/// and returns it reopened; the caller closes it. [seed] fills the database
/// before the replace; [backupDirectory] is where its safety backup goes,
/// unless [seed] set one.
Future<SkotiqDatabase> replacedDatabase(
  Directory dir,
  String backupPath,
  LoggingService logger, {
  Future<void> Function(SkotiqDatabase live)? seed,
  bool backupsBesideIt = true,
}) async {
  final file = File('${dir.path}/replace-${_databases++}/skotiq.db');
  await file.parent.create(recursive: true);
  final live = SkotiqDatabase.forTesting(NativeDatabase(file));
  await seed?.call(live);
  final result = await BackupService(
    database: live,
    logger: logger,
    backupDirectoryProvider: backupsBesideIt
        ? () async => Directory('${file.parent.path}/backups')
        : null,
  ).restoreBackup(filePath: backupPath, mode: RestoreMode.replace);
  expect(result.success, isTrue, reason: result.errorMessage);
  expect(result.pendingRestart, isTrue);
  await live.close();
  final outcome = await applyPendingRestore(file);
  expect(outcome?.restored, isTrue, reason: outcome?.failureReason);
  return SkotiqDatabase.forTesting(NativeDatabase(file));
}

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
  // Columns that name a row of another table without a foreign key.
  'calibration_tags': {'master_type': 'dark', 'master_id': 7},
  'narrowband_composites': {'component_master_ids': '[7]'},
  'guide_rms_history': {'target_id': 7},
  'stacked_results': {'session_id': 7, 'target_id': 7},
  'sequence_decisions': {'sequence_run_id': 7},
  'frame_forensics': {'sequence_run_id': 7},
  'notes_journal': {'sequence_run_id': 7},
  'mosaic_panels': {'uploaded_master_id': 7},
};

/// Seed one row in every table, parents first, and return the tables seeded.
Future<List<String>> seedEveryTable(SkotiqDatabase db) async {
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
