// The background full check on deliberately damaged copies: an index made to
// disagree with its table (repaired by REINDEX, nothing lost), a UNIQUE index
// over duplicate rows and a damaged page (both sent to the start-up recovery
// at the next start). Every database here is a fresh file in a temp directory.

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/database_health_check.dart';
import 'package:skotiq_core/src/database/integrity_check.dart';
import 'package:skotiq_core/src/database/sqlite_busy.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_health_check_test_');
    dbFile = File(p.join(tempDir.path, 'skotiq.db'));
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // A handle a failed test left open must not fail the next one.
    }
  });

  /// An app database with one extra table of 200 rows and an index on it.
  Future<void> createDatabase() async {
    final db = SkotiqDatabase.forTesting(
      NativeDatabase(dbFile, setup: applySqliteBusyTimeout),
    );
    await db.customStatement(
      'CREATE TABLE frames_probe (id INTEGER PRIMARY KEY, a INT, b INT, '
      'note TEXT)',
    );
    await db.customStatement(
      'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c '
      'WHERE x < 200) INSERT INTO frames_probe (a, b, note) '
      "SELECT x, x % 7, printf('frame %04d of the night', x) FROM c",
    );
    await db.customStatement('CREATE INDEX idx_probe_a ON frames_probe(a)');
    await db.close();
  }

  /// Rewrites how SQLite reads the index without touching its entries, the
  /// way a desynchronized index looks on disk.
  void editSchema(String sql) {
    final raw = sqlite3.open(dbFile.path);
    try {
      raw.execute('PRAGMA writable_schema = ON');
      raw.execute(sql);
    } finally {
      raw.close();
    }
  }

  List<String> fullCheckRows() {
    final raw = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    try {
      return integrityCheckRows(raw, full: true);
    } finally {
      raw.close();
    }
  }

  int rowCount() {
    final raw = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    try {
      return raw.select('SELECT COUNT(*) AS n FROM frames_probe').first['n']
          as int;
    } finally {
      raw.close();
    }
  }

  Future<DatabaseHealthOutcome> runCheck() async {
    final db = SkotiqDatabase.forTesting(
      NativeDatabase(dbFile, setup: applySqliteBusyTimeout),
    );
    try {
      return await DatabaseHealthCheck(db).run();
    } finally {
      await db.close();
    }
  }

  test('a healthy database is reported healthy and left alone', () async {
    await createDatabase();
    final before = await dbFile.readAsBytes();

    expect(await runCheck(), isA<DatabaseHealthy>());
    expect(await dbFile.readAsBytes(), before);
    expect(await fullCheckRequestedAtNextStart(tempDir), isFalse);
  });

  group('an index out of step with its table', () {
    setUp(() async {
      await createDatabase();
      // The index holds `a`; SQLite now reads it as an index on `b`.
      editSchema(
        "UPDATE sqlite_schema SET sql = 'CREATE INDEX idx_probe_a ON "
        "frames_probe(b)' WHERE name = 'idx_probe_a'",
      );
    });

    test('passes the start-up quick_check, so the app starts on it', () async {
      final report = await runIntegrityCheckAndRecover(dbFile);
      expect(report.wasHealthy, isTrue);
      expect(await dbFile.exists(), isTrue);
      expect(fullCheckRows(), contains('row 7 missing from index idx_probe_a'));
    });

    test('is rebuilt by REINDEX and confirmed, with every row kept', () async {
      final outcome = await runCheck();

      expect(outcome, isA<DatabaseIndexRepaired>());
      final repaired = outcome as DatabaseIndexRepaired;
      expect(repaired.findings.indexes, {'idx_probe_a'});
      expect(
        repaired.findings.messages,
        contains('row 7 missing from index idx_probe_a'),
      );
      expect(fullCheckRows(), ['ok']);
      expect(rowCount(), 200);
      expect(await fullCheckRequestedAtNextStart(tempDir), isFalse);

      final notice = repaired.notice;
      expect(notice.message, 'Skotiq repaired a database index; nothing was lost.');
      expect(notice.severity, EventSeverity.info);
    });

    test('a second start finds nothing to say', () async {
      await runCheck();
      expect(await runCheck(), isA<DatabaseHealthy>());
    });
  });

  test('a UNIQUE index over duplicate rows cannot be rebuilt, so the next '
      'start runs the recovery', () async {
    await createDatabase();
    // 200 rows over seven values of `b`, read as a UNIQUE index on `b`.
    final raw = sqlite3.open(dbFile.path);
    raw.execute('CREATE INDEX idx_probe_b ON frames_probe(b)');
    raw.close();
    editSchema(
      "UPDATE sqlite_schema SET sql = 'CREATE UNIQUE INDEX idx_probe_b ON "
      "frames_probe(b)' WHERE name = 'idx_probe_b'",
    );

    final outcome = await runCheck();

    expect(outcome, isA<DatabaseRepairAtNextStart>());
    final repair = outcome as DatabaseRepairAtNextStart;
    expect(repair.findings.indexOnly, isTrue);
    expect(repair.reindexFailure, contains('UNIQUE constraint failed'));
    expect(rowCount(), 200, reason: 'no row may be removed to make it fit');
    expect(await fullCheckRequestedAtNextStart(tempDir), isTrue);

    final report = await runIntegrityCheckAndRecover(dbFile);
    expect(report.recovered, isTrue);
    expect(report.failureReason, contains('non-unique entry in index'));
    expect(await fullCheckRequestedAtNextStart(tempDir), isFalse);
  });

  group('a damaged page', () {
    setUp(() async {
      await createDatabase();
      final raw = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
      final root =
          raw
                  .select(
                    "SELECT rootpage FROM sqlite_schema WHERE name = "
                    "'frames_probe'",
                  )
                  .first['rootpage']
              as int;
      final pageSize =
          raw.select('PRAGMA page_size').first.values.first as int;
      raw.close();
      // Overwrite the table's root page past its header: the child page
      // numbers and cells it holds become garbage.
      final bytes = await dbFile.readAsBytes();
      final start = (root - 1) * pageSize;
      for (var i = start + 12; i < start + pageSize; i++) {
        bytes[i] = (i * 31) & 0xff;
      }
      await dbFile.writeAsBytes(Uint8List.fromList(bytes), flush: true);
    });

    test('is sent to the start-up recovery at the next start, and nothing is '
        'changed now', () async {
      final before = await dbFile.readAsBytes();

      final outcome = await runCheck();

      expect(outcome, isA<DatabaseRepairAtNextStart>());
      final repair = outcome as DatabaseRepairAtNextStart;
      expect(repair.findings.indexOnly, isFalse);
      expect(repair.reindexFailure, isNull);
      expect(await dbFile.readAsBytes(), before);
      expect(await fullCheckRequestedAtNextStart(tempDir), isTrue);

      final notice = repair.notice;
      expect(notice.title, 'Database needs repair');
      expect(notice.message, startsWith('Back up the database folder'));
      expect(notice.message, endsWith('Folder: ${tempDir.path}'));
      expect(notice.severity, EventSeverity.warning);

      final report = await runIntegrityCheckAndRecover(dbFile);
      expect(report.recovered, isTrue);
      expect(await dbFile.exists(), isFalse);
      expect(await File(report.backupPath!).readAsBytes(), before);
      expect(await readRecoveryMarker(tempDir), isNotNull);
      expect(await fullCheckRequestedAtNextStart(tempDir), isFalse);
    });

    test('is caught by the start-up quick_check too', () async {
      final report = await runIntegrityCheckAndRecover(dbFile);
      expect(report.recovered, isTrue);
    });
  });

  test('a full check asked for at the next start leaves a healthy database '
      'alone and is answered', () async {
    await createDatabase();
    await requestFullCheckAtNextStart(dbFile, ['Page 3: never used']);

    final report = await runIntegrityCheckAndRecover(dbFile);

    expect(report.wasHealthy, isTrue);
    expect(await dbFile.exists(), isTrue);
    expect(await fullCheckRequestedAtNextStart(tempDir), isFalse);
  });

  test('the notice is a system notification event', () {
    const notice = DatabaseHealthNotice(
      title: 'Database index repaired',
      message: 'Skotiq repaired a database index; nothing was lost.',
      severity: EventSeverity.info,
    );
    final event = notice.toEvent();
    expect(event.category, EventCategory.system);
    expect(event.eventType, 'Notification');
    expect(event.data, {
      'title': 'Database index repaired',
      'message': 'Skotiq repaired a database index; nothing was lost.',
      'level': 'info',
    });
  });
}
