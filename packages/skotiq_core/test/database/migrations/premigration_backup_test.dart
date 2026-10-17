// An upgrade must leave the operator a copy of the database as it was before
// it ran.
//
// Nothing did. The only copies this codebase ever made were post-hoc: the
// corruption quarantine's `skotiq-corrupt-*.db` and the interrupted-first-
// boot `skotiq-incomplete-*.db`, both of which fire only once a file is
// already unusable. A schema upgrade rewrites tables in place, and a v7 install
// opened once by an older build re-stamps the version down and lets its foreign
// keys cascade over rows the old schema does not know about — so "restore from
// before the upgrade" had no artefact to restore from.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_premigration_');
    dbFile = File(p.join(tempDir.path, 'skotiq.db'));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // Best-effort.
      }
    }
  });

  Future<void> openAndMigrate() async {
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await db.customSelect('SELECT 1').get();
    } finally {
      try {
        await db.close();
      } catch (_) {}
    }
  }

  void plant(List<String> statements) {
    final db = sqlite3.open(dbFile.path);
    try {
      for (final statement in statements) {
        db.execute(statement);
      }
    } finally {
      db.close();
    }
  }

  List<String> backups() =>
      tempDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.startsWith('skotiq-premigration-'))
          .toList()
        ..sort();

  test('an upgrade copies the database aside first', () async {
    await openAndMigrate();
    // A night's worth of data the operator would want back.
    plant([
      "INSERT INTO imaging_sessions(start_time, status) "
          "VALUES (1750000000, 'completed')",
      'PRAGMA user_version = 58',
    ]);

    await openAndMigrate();

    final made = backups();
    expect(
      made,
      hasLength(1),
      reason: 'the upgrade must leave exactly one copy of what it started from',
    );
    expect(
      made.single,
      contains('-v58-'),
      reason:
          'named with the version it was taken at, so an operator can tell '
          'which build it belongs to',
    );

    // And it must be a real, readable database holding the pre-upgrade data.
    final backup = sqlite3.open(
      p.join(tempDir.path, made.single),
      mode: OpenMode.readOnly,
    );
    try {
      expect(backup.select('PRAGMA user_version;').first.values.first, 58);
      expect(
        backup
            .select('SELECT count(*) AS c FROM imaging_sessions')
            .first
            .values
            .first,
        1,
      );
    } finally {
      backup.close();
    }
  });

  test('a fresh install makes no backup', () async {
    await openAndMigrate();

    expect(
      backups(),
      isEmpty,
      reason: 'there is nothing to preserve before a database exists',
    );
  });

  test('an open with no upgrade to do makes no backup', () async {
    await openAndMigrate();
    await openAndMigrate();

    expect(backups(), isEmpty);
  });

  test('only the newest two copies are kept', () async {
    await openAndMigrate();

    for (var i = 0; i < 3; i++) {
      plant(['PRAGMA user_version = ${56 + i}']);
      await openAndMigrate();
      // The name carries a whole-second timestamp, so three upgrades inside
      // one second would otherwise collide.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    }

    final kept = backups();
    expect(
      kept,
      hasLength(2),
      reason:
          'copies of a database are large; the two most recent are the '
          'ones worth the disk',
    );
    expect(
      kept.any((n) => n.contains('-v58-')),
      isTrue,
      reason: 'and the newest must be among them',
    );
  });
}
