import 'dart:async';

import 'package:sqlite3/sqlite3.dart' show Database, SqliteException;

/// How long SQLite waits for a lock before it gives up and reports
/// `SQLITE_BUSY`, set on every connection this app opens.
///
/// The database runs in SQLite's default `delete` journalling mode, where a
/// single reader's `SHARED` lock blocks every writer for as long as its
/// transaction is open. Anything that reads the file from outside the app —
/// a backup script, `sqlite3 skotiq.db`, a support engineer counting
/// frames — therefore parks a lock across the daemon's writes.
///
/// With the sqlite3 default of zero, the first such write fails instantly:
/// `beforeOpen` runs writes, so the daemon dies at startup, and a Darkroom job
/// write fails mid-pass and strands the row in `running`. Five seconds covers
/// the read transactions those tools actually hold (milliseconds to a second)
/// while staying far below any timeout an operator would read as a hang, and
/// it is the value SQLite's own documentation recommends for multi-process
/// access. It is a ceiling, not a delay: an uncontended write returns at once.
const Duration kSqliteBusyTimeout = Duration(seconds: 5);

/// Give a connection its lock-wait budget before its first statement runs.
///
/// Passed as drift's `setup` by `_openConnection`, and by every test that
/// opens a database file, so there is ONE definition of what a Skotiq
/// connection does about contention. A test that built its own executor
/// without it would pass against a connection the app never opens.
///
/// Top-level rather than a closure because drift sends `setup` to the
/// background isolate that owns the connection.
void applySqliteBusyTimeout(Database db) {
  db.execute('PRAGMA busy_timeout = ${kSqliteBusyTimeout.inMilliseconds}');
}

/// `SQLITE_BUSY` — the lock could not be taken within [kSqliteBusyTimeout].
const int _sqliteBusy = 5;

/// `SQLITE_LOCKED` — the table is locked by another connection in the same
/// process, or by a shared cache. Same remedy as busy: wait and try again.
const int _sqliteLocked = 6;

/// True when [error] is SQLite refusing a lock rather than reporting a fault
/// with the data.
///
/// Compared against `resultCode`, which the sqlite3 package already narrows to
/// the primary code: SQLite carries extended codes (`SQLITE_BUSY_SNAPSHOT` =
/// 517, `SQLITE_LOCKED_SHAREDCACHE` = 262) in the high bits, and every one of
/// them is still the same contention.
bool isSqliteBusy(Object error) =>
    error is SqliteException &&
    (error.resultCode == _sqliteBusy || error.resultCode == _sqliteLocked);

/// How many times a write is attempted before the contention is reported as a
/// failure.
///
/// Each attempt already waits [kSqliteBusyTimeout] inside SQLite, so three
/// attempts cover fifteen seconds of a held lock plus the backoff below. A
/// reader that outlasts that is not transient, and the caller is told the truth
/// instead of blocking a job queue behind an unbounded retry.
const int kSqliteBusyMaxAttempts = 3;

/// Pause between attempts, so a lock released just after SQLite gave up is not
/// immediately contended again by our own retry.
const Duration kSqliteBusyRetryBackoff = Duration(milliseconds: 250);

/// Run [action], retrying it while SQLite reports contention.
///
/// Retries ONLY [isSqliteBusy] errors, at most [kSqliteBusyMaxAttempts] times.
/// Every other error — a transition the state machine rejects, a missing row,
/// real corruption — propagates on the first attempt, untouched: contention is
/// the one failure that going again can fix.
///
/// When the attempts run out the last [SqliteException] is rethrown rather than
/// converted, so the caller sees the SQLite result code and the statement that
/// could not run.
///
/// [action] must be safe to run more than once. The Darkroom job writes that
/// use this are: each re-reads the row's state and re-applies one `UPDATE`, and
/// an `UPDATE` that reported busy applied nothing.
Future<T> retryWhileSqliteBusy<T>(
  Future<T> Function() action, {
  int maxAttempts = kSqliteBusyMaxAttempts,
  Duration backoff = kSqliteBusyRetryBackoff,
}) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await action();
    } catch (error) {
      if (!isSqliteBusy(error) || attempt >= maxAttempts) rethrow;
      await Future<void>.delayed(backoff);
    }
  }
}
