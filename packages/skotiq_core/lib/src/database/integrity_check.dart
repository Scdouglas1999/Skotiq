import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_busy.dart';

/// Outcome of [runIntegrityCheckAndRecover].
///
/// Why a structured result instead of a bool: the UI needs to surface a
/// one-time "your database was recovered" dialog, and support engineers need
/// the path of the corrupt-file backup to triage. A boolean would force every
/// caller to re-derive the marker / backup path, which is fragile.
class IntegrityRecoveryReport {
  /// True iff `PRAGMA integrity_check` returned anything other than `ok` AND
  /// the corrupt file was rotated out of the way successfully.
  final bool recovered;

  /// True iff the database file did not exist when the check ran. This is the
  /// normal first-launch state — no integrity check needed, no recovery
  /// performed, but distinguished from "checked and clean" so callers can log
  /// the path the DB will end up at.
  final bool freshInstall;

  /// True iff the file existed AND `integrity_check` returned `ok`. Mutually
  /// exclusive with [recovered] and [freshInstall].
  final bool wasHealthy;

  /// Absolute path of the corrupt-file backup that was retained for forensic
  /// retrieval. Null unless [recovered] is true.
  final String? backupPath;

  /// Absolute path of the recovery marker file that the UI hook should
  /// consume + delete on next launch. Null unless [recovered] is true.
  final String? markerPath;

  /// Raw `integrity_check` result string that triggered the recovery (e.g.
  /// `'database disk image is malformed'`). Null unless [recovered] is true.
  final String? failureReason;

  const IntegrityRecoveryReport._({
    required this.recovered,
    required this.freshInstall,
    required this.wasHealthy,
    this.backupPath,
    this.markerPath,
    this.failureReason,
  });

  factory IntegrityRecoveryReport.freshInstall() =>
      const IntegrityRecoveryReport._(
        recovered: false,
        freshInstall: true,
        wasHealthy: false,
      );

  factory IntegrityRecoveryReport.healthy() => const IntegrityRecoveryReport._(
    recovered: false,
    freshInstall: false,
    wasHealthy: true,
  );

  factory IntegrityRecoveryReport.recovered({
    required String backupPath,
    required String markerPath,
    required String failureReason,
  }) => IntegrityRecoveryReport._(
    recovered: true,
    freshInstall: false,
    wasHealthy: false,
    backupPath: backupPath,
    markerPath: markerPath,
    failureReason: failureReason,
  );
}

/// Filename prefix for the forensic backup of a corrupt database file.
/// Visible in the same directory as `skotiq.db` so a user can attach it
/// to a support email without spelunking through OS-specific paths.
const String _corruptBackupPrefix = 'skotiq-corrupt-';

/// Filename prefix for the database that a restore displaced. Deliberately
/// NOT [_corruptBackupPrefix] so a restored-over file is never offered back
/// to the user as "the database we quarantined".
const String _replacedBackupPrefix = 'skotiq-replaced-';

/// Filename prefix for a database whose very first schema creation was
/// interrupted. Deliberately NOT [_corruptBackupPrefix]: the file is not
/// corrupt and holds nothing anyone could want back, so it must never be
/// offered to the user as a restorable quarantined database.
const String _incompleteBackupPrefix = 'skotiq-incomplete-';

/// Filename prefix for the one-time UI marker that signals "we just recovered
/// from corruption — please tell the user." The marker is consumed +
/// unlinked by the UI layer on the next launch.
const String _recoveryMarkerPrefix = '.recovered-on-';

/// Name of the file that requests a quarantined database be swapped back in
/// on the next launch. Restoring cannot happen while the app is running —
/// drift holds the live file open — so the UI stages the request and the
/// pre-flight in [applyPendingRestore] performs the swap before anything
/// opens the database.
const String _restoreRequestName = '.restore-pending.txt';

/// SQLite primary result codes that mean "this file is not a usable SQLite
/// database" — the ONLY two conditions under which we are allowed to move a
/// user's database out of the way.
///
/// Everything else SQLite can raise at open time (`SQLITE_BUSY`,
/// `SQLITE_LOCKED`, `SQLITE_CANTOPEN`, `SQLITE_READONLY`, `SQLITE_PERM`,
/// `SQLITE_IOERR`, ...) describes the *environment*, not the file: another
/// process holds a lock, the directory is read-only, a hot journal needs
/// replaying, the volume is unmounted. Rotating on those destroys a perfectly
/// good database — which is exactly the data-loss bug this list exists to
/// prevent. Those cases are rethrown so the operator sees the real error.
const int _sqliteCorrupt = 11; // SQLITE_CORRUPT
const int _sqliteNotADb = 26; // SQLITE_NOTADB

/// Primary result codes that mean "I need write access to even read this
/// file" rather than "this file is broken": a WAL database whose `-shm` we
/// could not create, or a rollback journal that has to be replayed before the
/// database is readable. Both are recoverable by re-opening read/write and
/// letting SQLite do its normal crash recovery.
const int _sqliteCantOpen = 14; // SQLITE_CANTOPEN
const int _sqliteReadOnly = 8; // SQLITE_READONLY

bool _isCorruption(SqliteException e) =>
    e.resultCode == _sqliteCorrupt || e.resultCode == _sqliteNotADb;

bool _needsWritableRetry(SqliteException e) =>
    e.resultCode == _sqliteCantOpen || e.resultCode == _sqliteReadOnly;

/// Open the database file once, run `PRAGMA integrity_check`, and on failure
/// rotate the corrupt file to a forensic backup so that drift's `onCreate`
/// can run on a fresh file. Does NOT delete the backup — it is retained as
/// evidence for support.
///
/// Why this lives outside [SkotiqDatabase]: the integrity check has to
/// run BEFORE drift opens the database, otherwise drift's migrator may begin
/// reading schema metadata from a corrupt file and crash in a way that
/// bypasses our recovery path. Drift's `beforeOpen` fires AFTER the
/// connection is established, which is too late to swap files without race
/// conditions in the background isolate.
///
/// Throws if the recovery itself fails (e.g. the OS refuses to rename the
/// corrupt file because of an open file handle): a hard failure rather than
/// continuing on a half-broken state.
///
/// Also throws — deliberately, without touching the file — when the database
/// could not be *reached* rather than could not be *parsed*: another instance
/// holds a lock (`SQLITE_BUSY`/`SQLITE_LOCKED`), the file or directory is not
/// writable (`SQLITE_PERM`, `SQLITE_READONLY`), the volume is gone
/// (`SQLITE_IOERR`). Those are operator-visible faults, not corruption, and
/// quarantining the database in response silently destroys real data.
Future<IntegrityRecoveryReport> runIntegrityCheckAndRecover(File dbFile) async {
  if (!await dbFile.exists()) {
    return IntegrityRecoveryReport.freshInstall();
  }

  final String failureReason;
  try {
    failureReason = _checkIntegrity(dbFile.path, mode: OpenMode.readOnly);
  } on SqliteException catch (e) {
    if (!await dbFile.exists()) {
      // The file was there a moment ago and is gone now: deleted underneath
      // us, or its volume went away. Nothing left to verify and nothing to
      // quarantine, so report the fresh install the next open is about to
      // create anyway.
      return IntegrityRecoveryReport.freshInstall();
    }
    if (_needsWritableRetry(e)) {
      // SQLite is telling us it must write to read: a WAL database whose
      // `-shm` does not exist yet, or a hot rollback journal left by a crash
      // that has to be replayed first. A read-only handle can never satisfy
      // either, so the read-only probe reports SQLITE_READONLY_RECOVERY /
      // _ROLLBACK / _CANTINIT for a database that is completely healthy.
      // Re-open read/write (never create) and let SQLite do its normal
      // crash recovery.
      final String retry;
      try {
        retry = _checkIntegrity(dbFile.path, mode: OpenMode.readWrite);
      } on SqliteException catch (retryError) {
        // Same rule on the second attempt: only a file SQLite calls corrupt
        // or not-a-database may be moved. Anything else (still unwritable,
        // now locked, volume gone) is the operator's to see.
        if (!_isCorruption(retryError)) rethrow;
        return _quarantine(dbFile, 'open-time error: ${retryError.message}');
      }
      if (retry.isEmpty) return IntegrityRecoveryReport.healthy();
      return _quarantine(dbFile, retry);
    }
    if (!_isCorruption(e)) {
      // NOT corruption — the database is fine and something else is wrong.
      // Rethrowing keeps the operator's data on disk and puts the real
      // SQLite error in front of them, which is what
      // `_openConnection`'s contract already promised.
      rethrow;
    }
    // SQLITE_CORRUPT / SQLITE_NOTADB at open time: the header itself is
    // unreadable. Same recovery path as a failed integrity_check.
    return _quarantine(dbFile, 'open-time error: ${e.message}');
  }

  if (failureReason.isEmpty) {
    return IntegrityRecoveryReport.healthy();
  }
  return _quarantine(dbFile, failureReason);
}

/// Outcome of [discardInterruptedFirstCreate].
class InterruptedCreateReport {
  /// True iff a half-created database was found and moved aside.
  final bool discarded;

  /// Absolute path the half-created file was renamed to. Null unless
  /// [discarded] is true.
  final String? backupPath;

  /// How many tables the half-created file carried. Reported so the log line
  /// says how far the interrupted creation had got.
  final int tableCount;

  const InterruptedCreateReport({
    required this.discarded,
    this.backupPath,
    this.tableCount = 0,
  });

  static const InterruptedCreateReport none = InterruptedCreateReport(
    discarded: false,
  );
}

/// Move aside a database whose FIRST schema creation was interrupted, so the
/// next open creates a fresh one instead of dying forever.
///
/// THE GUARD, and the only state this touches: `user_version == 0` while
/// `sqlite_master` already holds tables. Drift stamps the schema version only
/// after `onCreate` returns (`DelegatedDatabase._runMigrations`), so a file in
/// that state is one a process died inside during its very first boot. It has
/// never presented a complete schema to the app, no session has ever written
/// to it, and it therefore cannot hold user data. Anything with a stamped
/// version — every real database — is left alone, as is an empty file (0
/// tables), which is simply a fresh install about to be populated.
///
/// Without this, such a file is a permanent brick: version 0 reads as "brand
/// new" on the next open, drift re-enters `onCreate`, and the first duplicate
/// `CREATE INDEX` aborts startup. Every subsequent launch repeats it.
///
/// New databases are created atomically (see the migration strategy's
/// `onCreate`), so this repairs installs bricked by earlier builds and stands
/// as the backstop for any future path that can commit tables without a
/// version.
///
/// Rename, never delete: the file is worthless to the user but is evidence for
/// support, and moving it is what makes the repair reversible.
Future<InterruptedCreateReport> discardInterruptedFirstCreate(
  File dbFile,
) async {
  if (!await dbFile.exists()) return InterruptedCreateReport.none;

  final int version;
  final int tables;
  final db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
  try {
    applySqliteBusyTimeout(db);
    version = db.select('PRAGMA user_version;').first.values.first as int;
    tables =
        db
                .select(
                  "SELECT COUNT(*) AS n FROM sqlite_master "
                  "WHERE type = 'table' AND name NOT LIKE 'sqlite_%';",
                )
                .first
                .values
                .first
            as int;
  } finally {
    db.close();
  }

  if (version != 0 || tables == 0) return InterruptedCreateReport.none;

  final backupPath = await _rotateAside(dbFile, _incompleteBackupPrefix);
  return InterruptedCreateReport(
    discarded: true,
    backupPath: backupPath,
    tableCount: tables,
  );
}

/// Runs `PRAGMA integrity_check` against [path]. Returns an empty string when
/// the database is healthy, or the joined failure rows when it is not.
/// Propagates [SqliteException] to the caller for classification.
String _checkIntegrity(String path, {required OpenMode mode}) {
  final db = sqlite3.open(path, mode: mode);
  try {
    // The same lock-wait budget the live connection gets, from the same
    // definition. A read-only probe still needs it: an external writer holding
    // an EXCLUSIVE lock makes `integrity_check` report SQLITE_BUSY, and this
    // function's contract is that anything other than corruption propagates —
    // so without the timeout a passing backup turns a healthy database into a
    // startup failure.
    applySqliteBusyTimeout(db);
    final result = db.select('PRAGMA integrity_check;');
    // PRAGMA integrity_check returns either a single row {integrity_check:
    // 'ok'} on a healthy database, or one or more rows describing the
    // corruption (e.g. {integrity_check: 'database disk image is
    // malformed'}). The single-row 'ok' shape is the only healthy case.
    if (result.length == 1 &&
        result.first.values.length == 1 &&
        result.first.values.first == 'ok') {
      return '';
    }
    return result
        .map((row) => row.values.isNotEmpty ? '${row.values.first}' : '?')
        .join('; ');
  } finally {
    db.close();
  }
}

Future<IntegrityRecoveryReport> _quarantine(
  File dbFile,
  String failureReason,
) async {
  // Corruption confirmed. Rotate the file, drop a marker, and let the caller
  // proceed with `NativeDatabase.createInBackground` which will trigger
  // drift's onCreate on a now-absent file.
  final backupPath = await _rotateCorruptFile(dbFile);
  final markerPath = await _writeRecoveryMarker(dbFile, failureReason);

  return IntegrityRecoveryReport.recovered(
    backupPath: backupPath,
    markerPath: markerPath,
    failureReason: failureReason,
  );
}

/// Rename the corrupt DB file in place to `skotiq-corrupt-<ts>.db` in the
/// same directory. Also moves any `-wal` / `-shm` companion files so that the
/// fresh DB doesn't accidentally inherit a stale WAL.
///
/// Why rename, not copy: copying followed by delete races with WAL-mode write
/// recovery, so a rename (atomic on POSIX, near-atomic on NTFS) is safer.
Future<String> _rotateCorruptFile(File dbFile) =>
    _rotateAside(dbFile, _corruptBackupPrefix);

/// The rename half of a rotation, with the caller choosing the prefix that
/// says WHY the file was moved. The prefix is load-bearing: only
/// [_corruptBackupPrefix] files are offered back to the user as restorable.
Future<String> _rotateAside(File dbFile, String prefix) async {
  final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
  final dir = dbFile.parent;
  final baseName = p.basename(dbFile.path);
  final backupName = '$prefix$ts-$baseName';
  final backupPath = p.join(dir.path, backupName);

  await dbFile.rename(backupPath);

  // Companion files left behind by WAL mode can resurrect corrupt content
  // when sqlite re-opens the now-absent main file, so move them aside too.
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    final companion = File('${dbFile.path}$suffix');
    if (await companion.exists()) {
      final companionBackup = p.join(dir.path, '$backupName$suffix');
      try {
        await companion.rename(companionBackup);
      } on FileSystemException {
        // Why best-effort here: the companion files are sometimes locked by
        // a kernel-level cache flush. We've already preserved the main file
        // (the actual forensic evidence) and the recovery path can proceed.
        // We swallow this single sub-step, but the overall recovery is
        // still considered to have succeeded.
      }
    }
  }

  return backupPath;
}

/// Write a marker file that the UI hook consumes on next launch to surface a
/// "database was corrupted and recovered from backup" dialog. The marker
/// payload is a single line listing the backup path and the failure reason
/// so support engineers can find the evidence without an extra round-trip.
Future<String> _writeRecoveryMarker(File dbFile, String? failureReason) async {
  final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
  final markerPath = p.join(
    dbFile.parent.path,
    '$_recoveryMarkerPrefix$ts.txt',
  );
  final marker = File(markerPath);
  await marker.writeAsString(
    'db_path=${dbFile.path}\n'
    'recovered_at_utc=${DateTime.now().toUtc().toIso8601String()}\n'
    'reason=${failureReason ?? 'unknown'}\n',
    flush: true,
  );
  return markerPath;
}

/// One-time signal consumed by the UI layer. Returns the most recent recovery
/// marker (and clears all markers in the directory) iff at least one is
/// present. Returns null on a clean startup so the caller can short-circuit
/// without showing a dialog.
///
/// Why this clears the markers as a side-effect: the UX requirement is a
/// one-shot dialog. If the user dismisses it and re-launches the app, they
/// must not see the dialog again unless a NEW corruption-recovery happened
/// in the interim.
class DatabaseRecoveryMarker {
  final String markerPath;
  final String? backupPath;
  final DateTime recoveredAtUtc;
  final String? reason;
  final List<String> observedMarkerPaths;

  const DatabaseRecoveryMarker({
    required this.markerPath,
    required this.backupPath,
    required this.recoveredAtUtc,
    required this.reason,
    this.observedMarkerPaths = const [],
  });
}

/// Reads the newest recovery marker without deleting it. The UI uses this
/// two-phase path so a crash, app shutdown, or Navigator replacement before
/// the warning is actually dismissed cannot silently consume the warning.
Future<DatabaseRecoveryMarker?> readRecoveryMarker(
  Directory dbDirectory,
) async {
  final entries = await _recoveryMarkerFiles(dbDirectory);
  if (entries.isEmpty) {
    return null;
  }

  // Newest by mtime wins because the filename timestamp could collide if
  // two recoveries happened in the same millisecond.
  entries.sort(
    (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
  );
  final newest = entries.first;
  final raw = await newest.readAsString();

  final fields = <String, String>{};
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final idx = line.indexOf('=');
    if (idx <= 0) continue;
    fields[line.substring(0, idx)] = line.substring(idx + 1);
  }

  final backupPathFromMarker = await _findMostRecentBackup(dbDirectory);

  final recoveredAt =
      DateTime.tryParse(fields['recovered_at_utc'] ?? '') ??
      newest.statSync().modified.toUtc();

  return DatabaseRecoveryMarker(
    markerPath: newest.path,
    backupPath: backupPathFromMarker,
    recoveredAtUtc: recoveredAt,
    reason: fields['reason'],
    observedMarkerPaths: entries.map((entry) => entry.path).toList(),
  );
}

/// Deletes exactly the recovery markers observed by [readRecoveryMarker].
/// A marker created after the read is deliberately left for the next launch.
Future<void> acknowledgeRecoveryMarker(
  Directory dbDirectory,
  DatabaseRecoveryMarker marker,
) async {
  final observed = marker.observedMarkerPaths.isEmpty
      ? <String>{marker.markerPath}
      : marker.observedMarkerPaths.toSet();
  for (final entry in await _recoveryMarkerFiles(dbDirectory)) {
    if (!observed.contains(entry.path)) continue;
    try {
      await entry.delete();
    } on FileSystemException {
      // Best effort: an undeletable marker can repeat the warning, but the
      // recovered database remains usable and no notification is lost.
    }
  }
}

/// Backwards-compatible one-shot read used by non-UI callers.
Future<DatabaseRecoveryMarker?> consumeRecoveryMarker(
  Directory dbDirectory,
) async {
  final marker = await readRecoveryMarker(dbDirectory);
  if (marker != null) {
    await acknowledgeRecoveryMarker(dbDirectory, marker);
  }
  return marker;
}

Future<List<File>> _recoveryMarkerFiles(Directory dbDirectory) async {
  if (!await dbDirectory.exists()) return const [];
  return dbDirectory
      .list()
      .where(
        (entry) =>
            entry is File &&
            p.basename(entry.path).startsWith(_recoveryMarkerPrefix) &&
            p.basename(entry.path).endsWith('.txt'),
      )
      .cast<File>()
      .toList();
}

Future<String?> _findMostRecentBackup(Directory dbDirectory) async {
  final backups = await dbDirectory
      .list()
      .where(
        (e) => e is File && p.basename(e.path).startsWith(_corruptBackupPrefix),
      )
      .cast<File>()
      .toList();
  if (backups.isEmpty) {
    return null;
  }
  backups.sort(
    (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
  );
  return backups.first.path;
}

/// What a quarantined `skotiq-corrupt-*.db` file actually turned out to
/// be when we looked at it again.
///
/// Why this exists: builds before the result-code fix quarantined databases
/// on ANY open failure, including `SQLITE_BUSY` from a second app instance.
/// Those files are named `skotiq-corrupt-…` but are perfectly healthy,
/// and the UI must not repeat the lie. Anything that shows a quarantined file
/// to a user asks here first.
class QuarantinedDatabaseCheck {
  /// False when the quarantined file named in the recovery marker is no
  /// longer on disk (user deleted it, or moved it off for support).
  final bool exists;

  /// True iff the file opened cleanly AND `PRAGMA integrity_check` said `ok`.
  /// When this is true the word "corrupt" must not appear in the UI.
  final bool integrityOk;

  /// Human-readable outcome of the re-check: the failing `integrity_check`
  /// rows, or the SQLite error, or null when [integrityOk].
  final String? detail;

  /// Size on disk, for a "restore 4.2 MB of history" style confirmation.
  final int sizeBytes;

  const QuarantinedDatabaseCheck({
    required this.exists,
    required this.integrityOk,
    required this.sizeBytes,
    this.detail,
  });

  static const QuarantinedDatabaseCheck missing = QuarantinedDatabaseCheck(
    exists: false,
    integrityOk: false,
    sizeBytes: 0,
    detail: 'The quarantined database file is no longer on disk.',
  );

  /// True when the file is present and readable enough to be worth putting
  /// back. Only healthy files are offered: swapping a genuinely corrupt file
  /// back in would just re-trigger the quarantine on the next launch.
  bool get canRestore => exists && integrityOk;
}

/// Re-runs the integrity check against a quarantined backup so callers can
/// tell "this really was corrupt" apart from "we quarantined a healthy
/// database because something else went wrong".
///
/// Deliberately short-circuits before touching sqlite3 when the file is
/// absent, so a UI that only needs the missing/present answer does not pay
/// for loading the native library.
Future<QuarantinedDatabaseCheck> inspectQuarantinedDatabase(
  String backupPath,
) async {
  final file = File(backupPath);
  if (!await file.exists()) {
    return QuarantinedDatabaseCheck.missing;
  }
  final sizeBytes = await file.length();
  try {
    // Read-only: inspecting evidence must never modify it. A backup that
    // needs journal replay reports SQLITE_READONLY here and is honestly
    // described as "could not be verified" rather than "corrupt".
    final failure = _checkIntegrity(backupPath, mode: OpenMode.readOnly);
    return QuarantinedDatabaseCheck(
      exists: true,
      integrityOk: failure.isEmpty,
      sizeBytes: sizeBytes,
      detail: failure.isEmpty ? null : failure,
    );
  } on SqliteException catch (e) {
    return QuarantinedDatabaseCheck(
      exists: true,
      integrityOk: false,
      sizeBytes: sizeBytes,
      detail: e.message,
    );
  }
}

/// Every quarantined database in [dbDirectory], newest first.
Future<List<String>> findQuarantinedDatabases(Directory dbDirectory) async {
  if (!await dbDirectory.exists()) return const [];
  final backups = await dbDirectory
      .list()
      .where(
        (e) =>
            e is File &&
            p.basename(e.path).startsWith(_corruptBackupPrefix) &&
            !p.basename(e.path).endsWith('-wal') &&
            !p.basename(e.path).endsWith('-shm') &&
            !p.basename(e.path).endsWith('-journal'),
      )
      .cast<File>()
      .toList();
  backups.sort(
    (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
  );
  return backups.map((e) => e.path).toList();
}

/// Records the user's request to put [backupPath] back as the live database.
///
/// The swap itself is deferred to the next launch ([applyPendingRestore]):
/// drift holds the current file open in a background isolate, so renaming it
/// underneath a live connection would either fail or silently strand writes.
Future<String> stageDatabaseRestore({
  required File dbFile,
  required String backupPath,
}) async {
  if (!await File(backupPath).exists()) {
    throw FileSystemException(
      'Cannot restore a database that is not on disk',
      backupPath,
    );
  }
  final requestPath = p.join(dbFile.parent.path, _restoreRequestName);
  await File(requestPath).writeAsString(
    'restore_from=$backupPath\n'
    'requested_at_utc=${DateTime.now().toUtc().toIso8601String()}\n',
    flush: true,
  );
  return requestPath;
}

/// The quarantined path a pending restore names, or null when none is staged.
Future<String?> readPendingRestore(Directory dbDirectory) async {
  final request = File(p.join(dbDirectory.path, _restoreRequestName));
  if (!await request.exists()) return null;
  for (final line in (await request.readAsString()).split(RegExp(r'\r?\n'))) {
    final idx = line.indexOf('=');
    if (idx <= 0) continue;
    if (line.substring(0, idx) == 'restore_from') {
      return line.substring(idx + 1);
    }
  }
  return null;
}

/// Drops a staged restore request without performing it.
Future<void> cancelPendingRestore(Directory dbDirectory) async {
  final request = File(p.join(dbDirectory.path, _restoreRequestName));
  if (await request.exists()) {
    await request.delete();
  }
}

/// Result of the restore pre-flight.
class DatabaseRestoreOutcome {
  final bool restored;

  /// The quarantined file that was swapped in. Null when [restored] is false.
  final String? restoredFrom;

  /// Where the database that was live at restore time got moved to, so a
  /// mistaken restore is itself reversible. Null on a fresh install.
  final String? replacedPath;

  /// Why the restore did not happen. Null when [restored].
  final String? failureReason;

  const DatabaseRestoreOutcome({
    required this.restored,
    this.restoredFrom,
    this.replacedPath,
    this.failureReason,
  });
}

/// Performs a restore staged by [stageDatabaseRestore], if one is pending.
///
/// Must run BEFORE anything opens the database. Ordering is: move the live
/// database aside (never delete — a wrong restore has to be undoable), then
/// rename the quarantined file into place along with its companions.
///
/// Returns null when no restore was staged. Clears the request either way so
/// a failing restore cannot wedge every subsequent launch.
Future<DatabaseRestoreOutcome?> applyPendingRestore(File dbFile) async {
  final dir = dbFile.parent;
  final source = await readPendingRestore(dir);
  if (source == null) return null;
  await cancelPendingRestore(dir);

  final backup = File(source);
  if (!await backup.exists()) {
    return DatabaseRestoreOutcome(
      restored: false,
      failureReason: 'The database to restore is no longer at $source.',
    );
  }

  final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
  final baseName = p.basename(dbFile.path);
  String? replacedPath;
  if (await dbFile.exists()) {
    replacedPath = p.join(dir.path, '$_replacedBackupPrefix$ts-$baseName');
    await dbFile.rename(replacedPath);
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final companion = File('${dbFile.path}$suffix');
      if (await companion.exists()) {
        try {
          await companion.rename('$replacedPath$suffix');
        } on FileSystemException {
          // Best effort. The main file is preserved, which is what makes the
          // restore reversible; a stranded -shm is rebuilt by SQLite.
        }
      }
    }
  }

  await backup.rename(dbFile.path);
  // The rotation moved `-wal`/`-shm`/`-journal` alongside the main file, so
  // bring the matched set back too — a database and its WAL are one unit.
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    final companion = File('$source$suffix');
    if (await companion.exists()) {
      try {
        await companion.rename('${dbFile.path}$suffix');
      } on FileSystemException {
        // Tolerable: SQLite rebuilds a missing -shm, and a WAL we could not
        // move just means the restored database is at its last checkpoint.
      }
    }
  }

  // The recovery marker says exactly one thing: "the database you are using
  // now is not yours." The swap above makes that false, so the marker goes
  // with it. A marker left behind after a restore that put back a profile,
  // five sequences and fifty frames makes every subsequent launch announce
  // "your existing settings, profiles, sessions and captures are not in the
  // new database" about a database that holds all of them — and the
  // quarantined file is by then named `skotiq-replaced-*`, so
  // `_findMostRecentBackup` finds nothing to offer and the notice degrades to
  // an alarm the user cannot act on.
  //
  // Only on success. A restore that failed leaves the user on the wrong
  // database, where the marker is accurate and must survive.
  for (final marker in await _recoveryMarkerFiles(dir)) {
    try {
      await marker.delete();
    } on FileSystemException {
      // Best effort, matching acknowledgeRecoveryMarker: an undeletable marker
      // repeats the notice, but the restored database is intact either way.
    }
  }

  return DatabaseRestoreOutcome(
    restored: true,
    restoredFrom: source,
    replacedPath: replacedPath,
  );
}
