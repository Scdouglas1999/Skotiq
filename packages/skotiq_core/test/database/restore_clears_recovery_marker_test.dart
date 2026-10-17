import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/integrity_check.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Reproduced on the owner's rig, 2026-08-09.
///
/// An older build quarantined a perfectly healthy database because the open
/// hit `SQLITE_READONLY` ("attempt to write a readonly database") on a file
/// living in a OneDrive-synced folder with a hot rollback journal. The user
/// was left on an empty database with their real one — one equipment profile,
/// five sequences, fifty captured frames, `PRAGMA integrity_check` = ok —
/// sitting in `skotiq-corrupt-*`.
///
/// The restore path put it all back correctly. What it did not do was clear
/// the `.recovered-on-*.txt` marker, so every launch afterwards announced:
///
///   "Your existing settings, profiles, sessions and captures are not in the
///    new database."
///
/// about a database that contained every one of them.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sk-restore-marker');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A real SQLite file carrying a row we can identify after the swap.
  File makeDb(String path, String marker) {
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE t(a TEXT);');
    db.execute("INSERT INTO t VALUES ('$marker');");
    db.dispose();
    return File(path);
  }

  String readMarkerRow(String path) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return db.select('SELECT a FROM t;').first.values.first! as String;
    } finally {
      db.dispose();
    }
  }

  List<String> markerFiles() => dir
      .listSync()
      .map((e) => p.basename(e.path))
      .where((n) => n.startsWith('.recovered-on-'))
      .toList();

  test('a completed restore clears the recovery marker', () async {
    final dbFile = makeDb(p.join(dir.path, 'skotiq.db'), 'empty-recreated');
    final quarantined = makeDb(
      p.join(dir.path, 'skotiq-corrupt-1786325956700-skotiq.db'),
      'the-users-real-data',
    );

    // A recovery marker in the shape the recovery path writes.
    File(p.join(dir.path, '.recovered-on-1786325956702.txt')).writeAsStringSync(
      'db_path=${dbFile.path}\n'
      'recovered_at_utc=2026-08-10T01:39:16.702486Z\n'
      'reason=open-time error: attempt to write a readonly database\n',
    );
    expect(markerFiles(), hasLength(1));

    await stageDatabaseRestore(dbFile: dbFile, backupPath: quarantined.path);
    final outcome = await applyPendingRestore(dbFile);

    expect(outcome?.restored, isTrue);
    expect(
      readMarkerRow(dbFile.path),
      'the-users-real-data',
      reason: 'the restore must actually swap the file, not just clean up',
    );

    expect(
      markerFiles(),
      isEmpty,
      reason:
          'the marker claims the live database is not the user\'s; the restore '
          'just made that false, so a launch after it must not repeat the claim',
    );

    // And the notice must not come back: readRecoveryMarker is what the
    // startup launcher consults on the very next run.
    expect(await readRecoveryMarker(dir), isNull);
  });

  test('a restore that could not run keeps the marker', () async {
    // The complement, and the reason this is not simply "always delete": if
    // the swap did not happen the user is still on the wrong database and the
    // warning is still true. Suppressing it there would hide real data loss.
    final dbFile = makeDb(p.join(dir.path, 'skotiq.db'), 'empty-recreated');
    File(p.join(dir.path, '.recovered-on-1786325956702.txt')).writeAsStringSync(
      'db_path=${dbFile.path}\n'
      'recovered_at_utc=2026-08-10T01:39:16.702486Z\n'
      'reason=open-time error: attempt to write a readonly database\n',
    );

    final vanished = p.join(dir.path, 'skotiq-corrupt-gone-skotiq.db');
    makeDb(vanished, 'doomed').deleteSync();
    // Stage against a file that exists, then remove it before the pre-flight
    // runs — the "backup is no longer on disk" branch.
    final present = makeDb(vanished, 'doomed');
    await stageDatabaseRestore(dbFile: dbFile, backupPath: present.path);
    present.deleteSync();

    final outcome = await applyPendingRestore(dbFile);

    expect(outcome?.restored, isFalse);
    expect(readMarkerRow(dbFile.path), 'empty-recreated');
    expect(
      markerFiles(),
      hasLength(1),
      reason: 'still on the recreated database, so the notice is still honest',
    );
  });
}
