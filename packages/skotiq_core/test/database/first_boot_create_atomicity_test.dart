// A first boot that is killed part-way through schema creation must not brick
// the install.
//
// Reproduced on the release bundle (2026-08-17): `kill -9` between ~0.4 s and
// ~0.75 s of the very first headless boot left `skotiq.db` carrying the
// tables drift had already committed under `PRAGMA user_version = 0`. Version 0
// reads as "brand new database", so every later launch re-entered `onCreate`
// and died on `CREATE INDEX idx_profiles_name` — the daemon never bound its
// port again and the only fix was deleting the file by hand.
//
// Two halves are tested here, matching the two halves of the fix:
//   1. `onCreate` runs as ONE transaction, so an interrupted creation rolls
//      back to an empty file instead of a half-schema.
//   2. `discardInterruptedFirstCreate` moves aside a half-schema left by an
//      older build, so the next launch boots — and only ever that state.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/integrity_check.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_first_boot_test_');
    dbFile = File(p.join(tempDir.path, 'skotiq.db'));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // Best-effort, as elsewhere in these tests: a lingering handle must not
        // fail an otherwise-passing run.
      }
    }
  });

  /// `PRAGMA user_version` and the table count of the file on disk, read
  /// through a plain sqlite3 handle — the same two numbers the kill sweep
  /// measured against the bundle.
  ({int version, int tables}) inspect(File file) {
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      return (
        version: db.select('PRAGMA user_version;').first.values.first as int,
        tables:
            db
                    .select(
                      "SELECT COUNT(*) AS n FROM sqlite_master "
                      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%';",
                    )
                    .first
                    .values
                    .first
                as int,
      );
    } finally {
      db.close();
    }
  }

  /// The version a complete creation stamps: the database's own, never a
  /// literal. A schema bump is a one-line change in `database.dart`, and a test
  /// that spells the number out fails on the bump rather than on the behaviour
  /// it is about.
  final currentSchemaVersion = SkotiqDatabase.forTesting(
    NativeDatabase.memory(),
  ).schemaVersion;

  /// Open the real database at [file] and force the migration to run.
  Future<void> openAndMigrate(File file) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase(file));
    try {
      await db.customSelect('SELECT 1').get();
    } finally {
      try {
        await db.close();
      } catch (_) {
        // A connection whose migration threw is already unusable; the test's
        // assertions read the FILE, not this handle.
      }
    }
  }

  /// The exact state the killed first boot left behind: a complete set of
  /// tables under schema version 0.
  Future<void> makeInterruptedFirstCreate(File file) async {
    await openAndMigrate(file);
    final db = sqlite3.open(file.path);
    try {
      db.execute('PRAGMA user_version = 0');
    } finally {
      db.close();
    }
  }

  group('onCreate atomicity', () {
    test(
      'a creation that fails part-way leaves no half-schema behind',
      () async {
        // Plant a table drift's `createAll` will collide with. `narrator_events`
        // sits well down the declaration order, so dozens of tables are created
        // before the failure — exactly the shape a mid-creation kill produces.
        final planted = sqlite3.open(dbFile.path);
        try {
          planted.execute(
            'CREATE TABLE narrator_events (id INTEGER PRIMARY KEY)',
          );
        } finally {
          planted.close();
        }

        await expectLater(openAndMigrate(dbFile), throwsA(isA<Object>()));

        final after = inspect(dbFile);
        // Only the planted table survives: every table the aborted creation had
        // already run went back with the rollback.
        expect(after.tables, 1);
        // And no half-stamped version — the version is written inside the same
        // transaction as the tables.
        expect(after.version, 0);
      },
    );

    test('a completed creation stamps the schema version', () async {
      await openAndMigrate(dbFile);

      final after = inspect(dbFile);
      expect(after.version, currentSchemaVersion);
      expect(after.tables, greaterThan(1));
    });
  });

  group('discardInterruptedFirstCreate', () {
    test('a half-created database bricks the next open, and the repair '
        'un-bricks it', () async {
      await makeInterruptedFirstCreate(dbFile);
      final bricked = inspect(dbFile);
      expect(bricked.version, 0);
      expect(bricked.tables, greaterThan(1));

      // The brick itself: drift reads version 0 as "brand new" and re-runs
      // onCreate against a file that already has the schema.
      await expectLater(openAndMigrate(dbFile), throwsA(isA<Object>()));

      final report = await discardInterruptedFirstCreate(dbFile);
      expect(report.discarded, isTrue);
      expect(report.tableCount, greaterThan(1));
      expect(
        p.basename(report.backupPath!),
        startsWith('skotiq-incomplete-'),
      );
      expect(File(report.backupPath!).existsSync(), isTrue);
      expect(dbFile.existsSync(), isFalse);

      // The launch after the repair comes up on a complete, stamped schema.
      await openAndMigrate(dbFile);
      final repaired = inspect(dbFile);
      expect(repaired.version, currentSchemaVersion);
      expect(repaired.tables, greaterThan(1));
    });

    test('a healthy database is never discarded', () async {
      await openAndMigrate(dbFile);
      final before = inspect(dbFile);

      final report = await discardInterruptedFirstCreate(dbFile);

      expect(report.discarded, isFalse);
      expect(report.backupPath, isNull);
      expect(dbFile.existsSync(), isTrue);
      expect(inspect(dbFile).version, before.version);
    });

    test('an empty file is left for drift to populate', () async {
      final empty = sqlite3.open(dbFile.path);
      empty.close();

      final report = await discardInterruptedFirstCreate(dbFile);

      expect(report.discarded, isFalse);
      expect(dbFile.existsSync(), isTrue);
    });

    test('no database file is a no-op', () async {
      final report = await discardInterruptedFirstCreate(dbFile);

      expect(report.discarded, isFalse);
      expect(report.backupPath, isNull);
    });
  });
}
