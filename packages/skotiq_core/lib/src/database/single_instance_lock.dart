import 'dart:io';

import 'package:path/path.dart' as p;

/// Set to `1`/`true` to let a second process open the same database anyway.
///
/// The guard exists because SQLite's own locking is per-statement: a second
/// Skotiq does not fail loudly, it interleaves writes with the first one
/// and trips every "database is locked" path in the app. There is no
/// supported multi-writer configuration, so the escape hatch is only for
/// operators who know they are pointing two processes at genuinely different
/// data (and for whom [skotiqDatabaseDirEnv] would be the better answer).
const String skotiqAllowMultipleInstancesEnv =
    'SKOTIQ_ALLOW_MULTIPLE_INSTANCES';

/// Raised instead of touching the database when another Skotiq process
/// already owns it.
///
/// Why this is worth its own type: "Skotiq is already running" is a
/// user-actionable condition with a one-line fix (close the other window,
/// or stop the headless service), and it must never be confused with the
/// database being damaged. The version of the startup path that could not
/// tell those two apart quarantined healthy databases.
class SkotiqAlreadyRunningException implements Exception {
  /// The lockfile whose exclusive lock we could not take.
  final String lockPath;

  /// The database the other instance is using.
  final String databasePath;

  /// PID recorded by the holder, when it wrote one before we looked.
  final int? holderPid;

  /// Raw contents of the lockfile, for the log.
  final String? holderDetail;

  const SkotiqAlreadyRunningException({
    required this.lockPath,
    required this.databasePath,
    this.holderPid,
    this.holderDetail,
  });

  String get message {
    final who = holderPid == null ? '' : ' (process $holderPid)';
    return 'Skotiq is already running$who and is using the database at '
        '$databasePath. Only one instance can use a database at a time. '
        'Close the other Skotiq window or stop the headless service, '
        'then try again. To run a second instance against separate data, '
        'point it at another folder with SKOTIQ_DATABASE_DIR.';
  }

  @override
  String toString() => 'SkotiqAlreadyRunningException: $message';
}

/// An exclusive, process-wide claim on one Skotiq database directory.
///
/// Backed by an OS advisory lock (`fcntl` record lock on POSIX, `LockFile`
/// on Windows) held on a `skotiq.db.lock` file beside the database. The
/// kernel drops the lock when the process exits for any reason, including a
/// crash or SIGKILL, so there is no stale-lock recovery to get wrong.
class SingleInstanceLock {
  /// Path of the lockfile this instance holds.
  final String lockPath;

  final RandomAccessFile? _handle;

  int _refCount = 1;

  SingleInstanceLock._(this.lockPath, this._handle);

  /// True when the guard was bypassed via
  /// [skotiqAllowMultipleInstancesEnv] and nothing is actually held.
  bool get isNoOp => _handle == null;

  /// How many live callers share this claim. Exposed for diagnostics.
  int get holders => _refCount;

  /// The claims this process owns, keyed by lockfile path.
  ///
  /// The guard exists to keep two *processes* off one file. Inside a single
  /// process there is no such hazard — drift and SQLite serialize correctly —
  /// and closing a database then opening it again (a rebuilt provider
  /// container, a test that constructs its own) is legitimate. So a repeat
  /// acquire from the same process shares the existing claim and bumps a
  /// refcount instead of failing. Without this, the OS layer could not help:
  /// POSIX record locks are granted unconditionally to the process that
  /// already holds them, while Windows `LockFileEx` refuses a second handle,
  /// so the platforms would disagree about what a re-open means.
  static final Map<String, SingleInstanceLock> _heldInThisProcess =
      <String, SingleInstanceLock>{};

  static String lockPathFor(File dbFile) => '${dbFile.path}.lock';

  /// Claims [dbFile] for this process.
  ///
  /// Throws [SkotiqAlreadyRunningException] if another process holds it.
  /// Never creates, opens, reads or modifies the database itself — the whole
  /// point is to fail before any code can mistake contention for corruption.
  static Future<SingleInstanceLock> acquire(
    File dbFile, {
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final bypass = env[skotiqAllowMultipleInstancesEnv]?.trim().toLowerCase();
    if (bypass == '1' || bypass == 'true' || bypass == 'yes') {
      return SingleInstanceLock._(lockPathFor(dbFile), null);
    }

    final lockPath = lockPathFor(dbFile);
    final existing = _heldInThisProcess[lockPath];
    if (existing != null) {
      existing._refCount++;
      return existing;
    }

    await dbFile.parent.create(recursive: true);

    // FileMode.append, not write: `write` truncates on open, which would
    // erase the holder's PID before we know whether we are allowed to have
    // the file at all.
    final handle = await File(lockPath).open(mode: FileMode.append);
    try {
      // Non-blocking. FileLock.exclusive fails immediately when the lock is
      // taken; FileLock.blockingExclusive would hang startup behind whatever
      // the other instance is doing, which for an all-night session is
      // indistinguishable from a freeze.
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      final detail = await _readHolder(lockPath);
      await handle.close();
      throw SkotiqAlreadyRunningException(
        lockPath: lockPath,
        databasePath: dbFile.path,
        holderPid: _pidFrom(detail),
        holderDetail: detail,
      );
    }

    final lock = SingleInstanceLock._(lockPath, handle);
    _heldInThisProcess[lockPath] = lock;
    try {
      await handle.truncate(0);
      await handle.setPosition(0);
      await handle.writeString(
        'pid=$pid\n'
        'since_utc=${DateTime.now().toUtc().toIso8601String()}\n'
        'database=${dbFile.path}\n',
      );
      await handle.flush();
    } on FileSystemException {
      // The lock is what matters; the PID note is a courtesy for the error
      // message. A read-only volume can refuse the write without invalidating
      // the claim we already hold.
    }
    return lock;
  }

  /// Advisory pre-flight: returns the exception a real [acquire] would throw,
  /// or null when the database looks free.
  ///
  /// Takes and immediately drops the lock, so it is inherently racy — it
  /// exists only so an entry point can print "Skotiq is already running"
  /// before spending a second on window setup. The authoritative claim is
  /// still the one [acquire] takes when the database is opened; a launch that
  /// wins this probe and loses that one still fails safely.
  static Future<SkotiqAlreadyRunningException?> probe(
    File dbFile, {
    Map<String, String>? environment,
  }) async {
    try {
      final lock = await acquire(dbFile, environment: environment);
      await lock.release();
      return null;
    } on SkotiqAlreadyRunningException catch (e) {
      return e;
    } on FileSystemException {
      // Cannot even create the lockfile. That is a separate problem and the
      // real open path will report it properly; this advisory probe must not
      // block startup.
      return null;
    }
  }

  /// Drops one hold on the claim. The OS lock is released when the last
  /// holder lets go. Safe to call more than once.
  Future<void> release() async {
    final handle = _handle;
    if (handle == null) return;
    if (_refCount <= 0) return;
    if (--_refCount > 0) return;
    _heldInThisProcess.remove(lockPath);
    try {
      await handle.unlock();
    } on FileSystemException {
      // Already gone; closing below still drops the kernel lock.
    }
    try {
      await handle.close();
    } on FileSystemException {
      // Nothing left to do — process exit releases everything.
    }
  }

  static Future<String?> _readHolder(String lockPath) async {
    try {
      return await File(lockPath).readAsString();
    } on FileSystemException {
      return null;
    }
  }

  static int? _pidFrom(String? detail) {
    if (detail == null) return null;
    for (final line in detail.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('pid=')) {
        return int.tryParse(line.substring(4).trim());
      }
    }
    return null;
  }
}

/// Convenience for callers that only have a directory in hand.
File skotiqLockFileIn(Directory dbDirectory, String dbFileName) =>
    File(p.join(dbDirectory.path, '$dbFileName.lock'));
