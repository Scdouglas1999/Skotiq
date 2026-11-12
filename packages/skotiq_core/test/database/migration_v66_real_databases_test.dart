// The v66 step on copies of real databases (`SKOTIQ_REAL_DB_DIR`, a folder of
// `.db` copies; the test copies them again and never opens the originals).
// Each upgrades to the current version with every row kept and the
// `captured_images.gain_kind` column in place. Without the variable the test
// says so and checks nothing.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

Map<String, int> _rowCounts(String path) {
  final db = raw.sqlite3.open(path);
  try {
    return {
      for (final row in db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      ))
        row['name'] as String:
            db.select('SELECT COUNT(*) AS n FROM "${row['name']}"').first['n']
                as int,
    };
  } finally {
    db.close();
  }
}

void main() {
  final source = Platform.environment['SKOTIQ_REAL_DB_DIR'];
  final copies = source == null
      ? const <File>[]
      : Directory(source).listSync().whereType<File>().where(
          (f) => f.path.endsWith('.db'),
        ).toList();

  test('real databases upgrade to v66 with every row kept', () async {
    if (copies.isEmpty) {
      markTestSkipped('SKOTIQ_REAL_DB_DIR is not set; no real database checked');
      return;
    }
    final work = await Directory.systemTemp.createTemp('skotiq_v66_real_');
    addTearDown(() => work.delete(recursive: true));
    for (final original in copies) {
      final copy = await original.copy(
        '${work.path}/${original.uri.pathSegments.last}',
      );
      final before = _rowCounts(copy.path);
      final db = SkotiqDatabase.forTesting(NativeDatabase(copy));
      await db.customSelect('SELECT 1').get();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion, reason: copy.path);
      final columns = await db
          .customSelect('PRAGMA table_info(captured_images)')
          .get();
      expect(
        columns.map((c) => c.read<String>('name')),
        contains('gain_kind'),
        reason: copy.path,
      );
      final integrity = await db.customSelect('PRAGMA integrity_check').get();
      expect(integrity.single.data.values.single, 'ok', reason: copy.path);
      await db.close();
      final after = _rowCounts(copy.path);
      for (final MapEntry(:key, :value) in before.entries) {
        if (key == 'app_settings') continue;
        expect(after[key], value, reason: '${copy.path} $key');
      }
    }
  });
}
