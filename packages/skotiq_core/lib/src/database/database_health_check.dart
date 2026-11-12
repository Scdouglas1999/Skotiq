import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../models/backend/event_types.dart';
import 'database.dart';
import 'integrity_check.dart';
import 'integrity_findings.dart';
import 'sqlite_busy.dart';

/// What the background full check found, and what it did about it.
sealed class DatabaseHealthOutcome {
  const DatabaseHealthOutcome();

  /// The notice the user is given once, or null when there is nothing to say.
  DatabaseHealthNotice? get notice => null;
}

/// `PRAGMA integrity_check` said `ok`.
class DatabaseHealthy extends DatabaseHealthOutcome {
  const DatabaseHealthy();
}

/// The check could not run, so nothing is known: an in-memory database, or
/// the file could not be read (another program holding a lock, the volume
/// gone). The start-up `quick_check` still runs at every start.
class DatabaseNotChecked extends DatabaseHealthOutcome {
  const DatabaseNotChecked(this.reason);

  final String reason;
}

/// Only indexes were out of step with their tables, `REINDEX` rebuilt them
/// from the tables, and the check now says `ok`.
class DatabaseIndexRepaired extends DatabaseHealthOutcome {
  const DatabaseIndexRepaired(this.findings);

  final IntegrityFindings findings;

  @override
  DatabaseHealthNotice get notice => const DatabaseHealthNotice(
    title: 'Database index repaired',
    message: 'Skotiq repaired a database index; nothing was lost.',
    severity: EventSeverity.info,
  );
}

/// Damage `REINDEX` cannot repair: the next start runs the full check and,
/// when it fails there, the start-up recovery.
class DatabaseRepairAtNextStart extends DatabaseHealthOutcome {
  const DatabaseRepairAtNextStart({
    required this.findings,
    required this.databaseDirectory,
    this.reindexFailure,
  });

  final IntegrityFindings findings;
  final String databaseDirectory;

  /// Why the index repair did not work, when one was tried: `REINDEX` failed
  /// (a UNIQUE index whose table holds duplicates) or the check still failed
  /// after it.
  final String? reindexFailure;

  @override
  DatabaseHealthNotice get notice => DatabaseHealthNotice(
    title: 'Database needs repair',
    // The advice comes first: a toast shows three lines.
    message:
        'Back up the database folder before you restart Skotiq. It found '
        'damage it cannot repair while running; the next start checks again '
        'and, if the damage is still there, sets the file aside (kept on '
        'disk) and starts with an empty database. Folder: $databaseDirectory',
    severity: EventSeverity.warning,
  );
}

/// The words a [DatabaseHealthOutcome] gives the user.
class DatabaseHealthNotice {
  const DatabaseHealthNotice({
    required this.title,
    required this.message,
    required this.severity,
  });

  final String title;
  final String message;
  final EventSeverity severity;

  /// The notice as the system notification the event history, the night log
  /// and every linked client show.
  SkotiqEvent toEvent() => SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: severity,
    category: EventCategory.system,
    eventType: 'Notification',
    data: {'title': title, 'message': message, 'level': severity.name},
  );
}

/// The full `PRAGMA integrity_check` the start-up `quick_check` leaves out,
/// run once while the app is up, with the repair it allows.
///
/// The check reads a copy of the database, never the live file. The
/// database runs in SQLite's `delete` journal mode, where a reader's lock
/// keeps every writer from committing: a full check on the live file holds it
/// for 1.2 s on a 185 MB rig database (12 s straight after a boot, past the
/// 5 s busy timeout), and a frame written meanwhile waits that long or fails.
/// SQLite's online backup copies the file under the lock in a fraction of
/// that, and the check then runs on the copy with no lock at all.
class DatabaseHealthCheck {
  DatabaseHealthCheck(
    this._db, {
    Future<List<String>> Function(String path) fullCheck =
        fullIntegrityCheckOfCopy,
  }) : _fullCheck = fullCheck;

  final SkotiqDatabase _db;
  final Future<List<String>> Function(String path) _fullCheck;

  Future<DatabaseHealthOutcome> run() async {
    final file = await _db.databaseFile();
    if (file == null) {
      return const DatabaseNotChecked('the database is not a file');
    }

    final IntegrityFindings findings;
    try {
      findings = classifyIntegrityCheck(await _fullCheck(file.path));
    } on SqliteException catch (e) {
      return DatabaseNotChecked(e.message);
    }
    if (findings.healthy) return const DatabaseHealthy();

    String? reindexFailure;
    if (findings.indexOnly) {
      reindexFailure = await _reindex(findings.indexes);
      if (reindexFailure == null) {
        final after = classifyIntegrityCheck(await _fullCheck(file.path));
        if (after.healthy) return DatabaseIndexRepaired(findings);
        reindexFailure =
            'the check still fails after REINDEX: '
            '${after.messages.join('; ')}';
      }
    }

    await requestFullCheckAtNextStart(file, findings.messages);
    return DatabaseRepairAtNextStart(
      findings: findings,
      databaseDirectory: file.parent.path,
      reindexFailure: reindexFailure,
    );
  }

  /// Rebuilds [indexes] from their tables on the live connection, or every
  /// index when one of the names is not an index in the schema. Returns why it
  /// failed, or null.
  Future<String?> _reindex(Set<String> indexes) async {
    try {
      final known = {
        for (final row in await _db
            .customSelect("SELECT name FROM sqlite_schema WHERE type = 'index'")
            .get())
          row.read<String>('name'),
      };
      if (indexes.isEmpty || !known.containsAll(indexes)) {
        await _db.customStatement('REINDEX');
      } else {
        for (final index in indexes) {
          await _db.customStatement('REINDEX "${index.replaceAll('"', '""')}"');
        }
      }
      return null;
    } on Exception catch (e) {
      // A UNIQUE index whose table holds duplicate rows cannot be rebuilt;
      // removing the duplicates would change user data, so it goes to the
      // start-up recovery instead.
      return 'REINDEX failed: $e';
    }
  }
}

/// `PRAGMA integrity_check` on a copy of the database at [path], taken with
/// SQLite's online backup in another isolate. A copy SQLite reports as
/// corrupt while being checked is answered with that error as the one
/// finding.
Future<List<String>> fullIntegrityCheckOfCopy(String path) => Isolate.run(
  () async {
    final live = sqlite3.open(path, mode: OpenMode.readOnly);
    final copy = sqlite3.openInMemory();
    try {
      try {
        applySqliteBusyTimeout(live);
        // One step: the copy holds the lock about as long as reading the file
        // takes. Smaller steps let a write in between restart the copy from
        // the first page.
        await live.backup(copy, nPage: -1).drain<void>();
      } finally {
        live.close();
      }
      try {
        return integrityCheckRows(copy, full: true);
      } on SqliteException catch (e) {
        if (e.resultCode != 11 && e.resultCode != 26) rethrow;
        return [e.message];
      }
    } finally {
      copy.close();
    }
  },
);
