// The contention contract: an external reader must not kill the daemon at
// startup, and must not strand a Darkroom job in `running`.
//
// The two halves of the fix are tested where each one lives:
//
//  - `applySqliteBusyTimeout` is what `_openConnection` hands drift as its
//    `setup`, so asserting the pragma it leaves on a real drift connection is
//    asserting what every launch gets.
//  - `retryWhileSqliteBusy` is the second belt, and it is exercised against
//    REAL `SQLITE_BUSY` from a second isolate holding a read transaction.
//
// WHY a second isolate for the contention: SQLite skips the busy handler
// entirely when the conflicting lock is held inside the same process — it
// returns SQLITE_BUSY at once rather than risk a deadlock it cannot see out
// of. That makes an in-process reader the sharpest possible test of the retry
// (every attempt gets a real, instant SQLITE_BUSY) and a useless test of the
// timeout. The timeout's own behaviour — waiting for a reader in ANOTHER
// process and then succeeding — is proven against the running daemon, which is
// the only place that arrangement exists.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/sqlite_busy.dart';
import 'package:skotiq_core/src/models/darkroom/darkroom_job.dart';
import 'package:sqlite3/sqlite3.dart';

/// A read transaction over another isolate's connection, held until it is told
/// to let go.
///
/// Handshaked rather than timed: a reader on a timer races the write it is
/// supposed to block, and a test that sometimes writes into an uncontended
/// database is a test that sometimes proves nothing.
class HeldReadLock {
  HeldReadLock._(this._release, this._done);

  final SendPort _release;
  final Future<void> _done;

  static Future<HeldReadLock> acquire(String path) async {
    final fromReader = ReceivePort();
    // The SendPort, not the port itself: a ReceivePort cannot cross isolates,
    // so capturing `fromReader` in the closure would fail to spawn.
    final replyTo = fromReader.sendPort;
    final done = Isolate.run(() async {
      final control = ReceivePort();
      final db = sqlite3.open(path);
      db.execute('BEGIN');
      db.select('SELECT COUNT(*) FROM darkroom_jobs');
      replyTo.send(control.sendPort);
      await control.first;
      db.execute('ROLLBACK');
      db.close();
      control.close();
    });
    final release = await fromReader.first as SendPort;
    fromReader.close();
    return HeldReadLock._(release, done);
  }

  Future<void> release() {
    _release.send('release');
    return _done;
  }
}

/// The exception SQLite raises when it will not wait for a lock.
SqliteException _busy({int code = 5}) =>
    SqliteException(extendedResultCode: code, message: 'database is locked');

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('skotiq_busy_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SkotiqDatabase open() => SkotiqDatabase.forTesting(
    NativeDatabase(dbFile, setup: applySqliteBusyTimeout),
  );

  test(
    'the connection setup leaves a lock-wait budget on the handle',
    () async {
      final db = open();
      addTearDown(db.close);

      final rows = await db.customSelect('PRAGMA busy_timeout').get();
      expect(
        rows.single.data.values.single,
        kSqliteBusyTimeout.inMilliseconds,
        reason:
            'without this every write in beforeOpen fails the instant anything '
            'else holds a read transaction, and the daemon exits at startup',
      );
      expect(
        kSqliteBusyTimeout.inMilliseconds,
        greaterThan(0),
        reason:
            'a zero budget is the sqlite3 default this fix exists to replace',
      );
    },
  );

  /// Prove the lock really refuses the write before letting it through, so a
  /// green result cannot come from an uncontended database.
  Future<void> expectFirstAttemptBlocked(File file) async {
    final probe = sqlite3.open(file.path);
    try {
      expect(
        () => probe.execute("UPDATE darkroom_jobs SET note = 'probe'"),
        throwsA(
          predicate<Object>(isSqliteBusy, 'a real SQLITE_BUSY from the lock'),
        ),
      );
    } finally {
      probe.close();
    }
  }

  test('a job state write survives a concurrent read transaction', () async {
    final db = open();
    addTearDown(db.close);
    final dao = DarkroomJobsDao(db);
    final jobId = await dao.enqueue(note: 'seed');
    await dao.markRunning(jobId);

    final lock = await HeldReadLock.acquire(dbFile.path);
    await expectFirstAttemptBlocked(dbFile);
    // Released during the DAO's first backoff, so the write only lands
    // because it went again.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 50), lock.release),
    );

    final finished = await dao.markDone(jobId, note: 'finished');

    expect(finished.state, DarkroomJobState.done);
    expect(
      (await dao.getById(jobId))!.state,
      DarkroomJobState.done,
      reason:
          'a job stranded in running is invisible until the next launch — the '
          'open-time recovery is the only thing that rescues it',
    );
  });

  test('markRunning under contention still counts starts, not tries', () async {
    final db = open();
    addTearDown(db.close);
    final dao = DarkroomJobsDao(db);
    final jobId = await dao.enqueue();

    final lock = await HeldReadLock.acquire(dbFile.path);
    await expectFirstAttemptBlocked(dbFile);
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 50), lock.release),
    );

    final running = await dao.markRunning(jobId);

    expect(running.state, DarkroomJobState.running);
    expect(
      running.attempts,
      1,
      reason:
          'a retried write must not burn attempts — three retries would trip '
          'the kDarkroomJobMaxAttempts ceiling on the first real start',
    );
  });

  group('retryWhileSqliteBusy', () {
    test('retries contention up to the attempt ceiling', () async {
      var calls = 0;
      final result = await retryWhileSqliteBusy(() async {
        calls++;
        if (calls < kSqliteBusyMaxAttempts) {
          throw _busy();
        }
        return 'wrote';
      }, backoff: Duration.zero);

      expect(result, 'wrote');
      expect(calls, kSqliteBusyMaxAttempts);
    });

    test('reports contention that outlives the ceiling', () async {
      var calls = 0;
      await expectLater(
        retryWhileSqliteBusy(() async {
          calls++;
          throw _busy();
        }, backoff: Duration.zero),
        throwsA(isA<SqliteException>()),
      );
      expect(
        calls,
        kSqliteBusyMaxAttempts,
        reason: 'bounded — a wedged queue must not retry forever',
      );
    });

    test('never retries an error that going again cannot fix', () async {
      var calls = 0;
      await expectLater(
        retryWhileSqliteBusy(() async {
          calls++;
          throw const DarkroomJobMissingException(7);
        }),
        throwsA(isA<DarkroomJobMissingException>()),
      );
      expect(calls, 1);
    });

    test('classifies extended busy/locked result codes', () {
      // SQLITE_BUSY_SNAPSHOT and SQLITE_LOCKED_SHAREDCACHE.
      expect(isSqliteBusy(_busy(code: 517)), isTrue);
      expect(isSqliteBusy(_busy(code: 262)), isTrue);
      expect(isSqliteBusy(_busy(code: 11)), isFalse);
      expect(isSqliteBusy(StateError('not sqlite')), isFalse);
    });
  });
}
