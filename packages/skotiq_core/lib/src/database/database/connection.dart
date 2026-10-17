part of '../database.dart';

/// Environment variable used by headless/systemd deployments to pin the Drift
/// database under a daemon-owned state directory instead of a user Documents
/// folder.
const skotiqDatabaseDirEnv = 'SKOTIQ_DATABASE_DIR';

/// Resolve the on-disk path the desktop/mobile database lives at. Exposed
/// separately so the UI bootstrap and CLI tools can find the file (e.g. for
/// "Show database location" buttons or post-recovery diagnostics) without
/// re-implementing the path heuristic.
Future<File> resolveDefaultDatabaseFile({
  Map<String, String>? environment,
  Future<Directory> Function()? documentsDirectoryProvider,
}) async {
  // [skotiqProcessEnvironment], not `Platform.environment`: apps/desktop
  // writes its resolved SKOTIQ_DATA_DIR back into the process environment
  // for the Rust side, and reading that back would move an ordinary install's
  // `skotiq.db` off `~/Documents`.
  final env = environment ?? skotiqProcessEnvironment;
  final overrideDir = env[skotiqDatabaseDirEnv]?.trim();
  if (overrideDir != null && overrideDir.isNotEmpty) {
    return File(p.join(overrideDir, 'skotiq.db'));
  }

  final dbFolder = await resolveSkotiqDocumentsDirectory(
    environment: env,
    documentsDirectoryProvider: documentsDirectoryProvider,
  );
  return File(p.join(dbFolder.path, 'Skotiq', 'skotiq.db'));
}

/// Held for the life of the process once [_openConnection] resolves. Kept in
/// a library-level field so the [RandomAccessFile] behind it is never
/// collected while the database is open — dropping it would silently hand the
/// database to a second instance.
SingleInstanceLock? _instanceLock;

/// The single-instance claim this process holds, for diagnostics.
SingleInstanceLock? get activeDatabaseInstanceLock => _instanceLock;

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final file = await resolveDefaultDatabaseFile();

    // Ensure directory exists
    await file.parent.create(recursive: true);

    // The GUI and the headless service resolve the same default database
    // path, so "launch the app twice" points two SQLite writers at one file.
    // The directory is claimed before anything opens the file; otherwise the
    // second opener hits the first one's lock, reports SQLITE_BUSY, and the
    // healthy database is quarantined out from under the operator. Throws
    // [SkotiqAlreadyRunningException] out of the LazyDatabase so startup
    // fails loudly instead of racing.
    _instanceLock = await SingleInstanceLock.acquire(file);

    // A restore requested from the recovery dialog is performed here, before
    // any connection exists, because drift holds the live file open once it
    // does and the swap could not complete underneath it.
    await integrity.applyPendingRestore(file);

    // WHY pre-flight integrity check: Drift's `beforeOpen` runs after the
    // SQLite connection is established, which is too late to swap a corrupt
    // file out of the way without race conditions inside the background
    // isolate. Running the check here — on the foreground isolate, before
    // `NativeDatabase.createInBackground` ever resolves — lets us rotate the
    // corrupt file to a `skotiq-corrupt-<ts>.db` forensic backup so that
    // drift's `onCreate` then seeds a fresh database.
    //
    // The recovery marker file written by [runIntegrityCheckAndRecover] is
    // consumed on next launch by [SkotiqDatabase.consumeRecoveryMarker]
    // so the UI can show a one-shot "your database was corrupted and
    // recovered from backup" dialog.
    //
    // Recovery failures are not swallowed: if the integrity check itself
    // throws (file lock, permission denied, …) the exception propagates and
    // the operator sees the real error rather than a silently broken
    // database. The check only quarantines a file SQLite reports as
    // SQLITE_CORRUPT/SQLITE_NOTADB or that fails `PRAGMA integrity_check`.
    await integrity.runIntegrityCheckAndRecover(file);

    // A first boot that was killed part-way through schema creation leaves a
    // structurally VALID file — `integrity_check` passes it — carrying tables
    // under schema version 0. Drift reads that as a brand-new database, runs
    // `onCreate` again, and dies on the first duplicate `CREATE`, so the
    // install never boots again. The check is here, next to the corruption
    // pre-flight, for the same reason: the file has to be moved before drift
    // opens it. See [integrity.discardInterruptedFirstCreate] for the guard
    // that keeps this off any database holding data.
    final interruptedCreate = await integrity.discardInterruptedFirstCreate(
      file,
    );
    if (interruptedCreate.discarded) {
      // ignore: avoid_print
      print(
        '[skotiq_db] A previous first launch was interrupted while '
        'creating the database (${interruptedCreate.tableCount} tables under '
        'schema version 0, no data). Moved it to '
        '${interruptedCreate.backupPath} and creating a fresh one.',
      );
    }

    // `beforeOpen` WRITES — it closes out interrupted runs and Darkroom jobs
    // and rebuilds session statistics — so without a lock-wait budget the
    // daemon exits at startup whenever anything else holds a read transaction
    // over the file. See [kSqliteBusyTimeout] for why five seconds.
    return NativeDatabase.createInBackground(
      file,
      setup: applySqliteBusyTimeout,
    );
  });
}
