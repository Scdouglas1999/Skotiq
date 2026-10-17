// An upgrade that is interrupted must leave the database where it started, and
// the one migration step that cannot simply be repeated must be able to resume.
//
// `onUpgrade` ran in auto-commit: every statement committed as it ran while
// `user_version` stayed at the OLD number until the whole chain returned. A
// process killed part-way through therefore left a file that was half at the
// new schema and labelled as being entirely at the old one — and the next
// launch re-ran the chain over it, where each step is only as re-runnable as
// its own guard.
//
// The v30 `guide_rms_history` step is the one that had none. It is
// rename-create-copy-drop, and its guard was `guide_rms_history` existing —
// the one name that stops existing at the first statement. A kill after the
// RENAME made every later run skip the block, v34 then created the table empty
// under `IF NOT EXISTS`, and the guiding history stayed in
// `guide_rms_history_v29` where nothing would read it again.
//
// The interruption is planted the same way `first_boot_create_atomicity_test`
// plants one: a colliding object that makes a step throw part-way, which is
// the state a kill leaves without needing to kill anything.
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
    tempDir = await Directory.systemTemp.createTemp('sk_upgrade_atomicity_');
    dbFile = File(p.join(tempDir.path, 'skotiq.db'));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // Best-effort: a lingering handle must not fail a passing run.
      }
    }
  });

  /// Open the real database at [dbFile] and force the migration to run.
  Future<void> openAndMigrate() async {
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await db.customSelect('SELECT 1').get();
    } finally {
      try {
        await db.close();
      } catch (_) {
        // A connection whose migration threw is already unusable; the
        // assertions read the FILE, not this handle.
      }
    }
  }

  /// Run [statements] against the file with a plain sqlite3 handle — the way a
  /// previous process would have left it, with no migration in the way.
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

  T read<T>(T Function(Database db) body) {
    final db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    try {
      return body(db);
    } finally {
      db.close();
    }
  }

  int userVersion() =>
      read((db) => db.select('PRAGMA user_version;').first.values.first as int);

  bool hasObject(String name) => read(
    (db) => db.select('SELECT name FROM sqlite_master WHERE name = ?', [
      name,
    ]).isNotEmpty,
  );

  int rowCount(String table) => read(
    (db) =>
        db.select('SELECT count(*) AS c FROM $table').first.values.first as int,
  );

  /// The v29 shape of `guide_rms_history`: `exposure_seconds` still NOT NULL
  /// and no helper index, seeded with one row whose survival is the point.
  const seedRow =
      'INSERT INTO guide_rms_history (session_id, mount_id, target_id, '
      'total_rms_arcsec, sample_count, exposure_seconds, recorded_at) '
      "VALUES ('seed-session', 'eq6r-pro', 42, 0.83, 312, 90.0, 1750000000)";

  const createLegacyShape =
      'CREATE TABLE guide_rms_history ('
      'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      'session_id TEXT NOT NULL, mount_id TEXT NOT NULL, '
      'target_id INTEGER NULL, total_rms_arcsec REAL NOT NULL, '
      'sample_count INTEGER NOT NULL, exposure_seconds REAL NOT NULL, '
      'recorded_at INTEGER NOT NULL)';

  group('onUpgrade atomicity', () {
    test('an upgrade that fails part-way leaves nothing behind', () async {
      await openAndMigrate();

      // A `guide_rms_history` with the right NAME and no `mount_id` column, so
      // the v30 step's `CREATE INDEX ... (mount_id, ...)` throws part-way
      // through the chain.
      plant([
        'DROP INDEX IF EXISTS idx_guide_rms_mount_recent',
        'DROP TABLE guide_rms_history',
        'CREATE TABLE guide_rms_history (id INTEGER PRIMARY KEY)',
        // The observable earlier effect: the v30 step re-creates this index
        // several statements BEFORE the one that fails.
        'DROP INDEX IF EXISTS idx_images_producing_run',
        'PRAGMA user_version = 29',
      ]);
      expect(hasObject('idx_images_producing_run'), isFalse);

      await expectLater(openAndMigrate(), throwsA(isA<Object>()));

      expect(
        hasObject('idx_images_producing_run'),
        isFalse,
        reason:
            'work the aborted upgrade had already done must go back with '
            'it, or the file is half-migrated under the old version number',
      );
      expect(
        userVersion(),
        29,
        reason: 'and the version must still say where the file actually is',
      );
    });

    test('a completed upgrade stamps the new version', () async {
      await openAndMigrate();
      final current = userVersion();
      plant(['PRAGMA user_version = 58']);

      await openAndMigrate();

      expect(userVersion(), current);
    });
  });

  group('the v30 guide_rms_history rebuild resumes', () {
    /// Put the file at v29 with the legacy table and one row in it.
    void plantV29() {
      plant([
        'DROP INDEX IF EXISTS idx_guide_rms_mount_recent',
        'DROP TABLE guide_rms_history',
        createLegacyShape,
        seedRow,
      ]);
    }

    test('a kill after the RENAME still recovers the rows', () async {
      await openAndMigrate();
      plantV29();
      // THE KILL: the rebuild renamed the table aside and the process died
      // before it created the replacement.
      plant([
        'ALTER TABLE guide_rms_history RENAME TO guide_rms_history_v29',
        'PRAGMA user_version = 29',
      ]);

      await openAndMigrate();

      expect(
        rowCount('guide_rms_history'),
        1,
        reason: 'the guiding history must come back, not be re-created empty',
      );
      expect(
        hasObject('guide_rms_history_v29'),
        isFalse,
        reason: 'and the aside table is dropped once its rows are safe',
      );
      expect(hasObject('idx_guide_rms_mount_recent'), isTrue);
      expect(
        read(
          (db) => db
              .select("PRAGMA table_info('guide_rms_history')")
              .firstWhere((r) => r['name'] == 'exposure_seconds')['notnull'],
        ),
        0,
        reason: 'the resumed rebuild still delivers the nullable column',
      );
    });

    test('a kill between the copy and the DROP loses and duplicates '
        'nothing', () async {
      await openAndMigrate();
      plantV29();
      // THE KILL: renamed, replacement created, rows already copied — the
      // process died before the DROP.
      plant([
        'ALTER TABLE guide_rms_history RENAME TO guide_rms_history_v29',
        'CREATE TABLE guide_rms_history ('
            'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
            'session_id TEXT NOT NULL, mount_id TEXT NOT NULL, '
            'target_id INTEGER NULL, total_rms_arcsec REAL NOT NULL, '
            'sample_count INTEGER NOT NULL, exposure_seconds REAL, '
            'recorded_at INTEGER NOT NULL)',
        'INSERT INTO guide_rms_history (id, session_id, mount_id, target_id, '
            'total_rms_arcsec, sample_count, exposure_seconds, recorded_at) '
            'SELECT id, session_id, mount_id, target_id, total_rms_arcsec, '
            'sample_count, exposure_seconds, recorded_at '
            'FROM guide_rms_history_v29',
        'PRAGMA user_version = 29',
      ]);

      await openAndMigrate();

      expect(
        rowCount('guide_rms_history'),
        1,
        reason:
            'the row was already copied; copying it again must not double '
            'it',
      );
      expect(hasObject('guide_rms_history_v29'), isFalse);
    });

    test('a database that never had the table is left alone', () async {
      await openAndMigrate();
      plant([
        'DROP INDEX IF EXISTS idx_guide_rms_mount_recent',
        'DROP TABLE guide_rms_history',
        'PRAGMA user_version = 29',
      ]);

      // The guard's original job: a database upgrading from before 30 has
      // neither table, and an unguarded CREATE INDEX here aborted the whole
      // migration.
      await openAndMigrate();

      expect(
        hasObject('guide_rms_history'),
        isTrue,
        reason: 'the v34 step creates it, and the upgrade must reach v34',
      );
      expect(rowCount('guide_rms_history'), 0);
    });
  });
}
