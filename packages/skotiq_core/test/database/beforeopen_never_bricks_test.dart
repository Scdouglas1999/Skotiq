// `beforeOpen` writes a post-mortem for a night a previous process died in.
// That report is a courtesy. The database opening is not.
//
// The marker file the report reads names its session by id, and by the time it
// is read that row can be gone — deleted from the sessions list, rotated away
// by the corruption quarantine, replaced by a restore. The report then INSERTs
// a `narrator_events` row against a missing parent under
// `PRAGMA foreign_keys = ON`, the foreign-key failure is thrown out of
// `beforeOpen`, and drift refuses every later open while the marker stays on
// disk to cause the same failure again. An undamaged database that never opens
// again.
//
// Tested the way the rest of this directory tests open-time behaviour: put the
// file and the marker into the state the crash leaves, open, and read what the
// open did.
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/integration_stage_marker.dart';
import 'package:skotiq_core/src/database/sqlite_busy.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('skotiq_open_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SkotiqDatabase open() => SkotiqDatabase.forTesting(
    NativeDatabase(dbFile, setup: applySqliteBusyTimeout),
  );

  /// Open the database and ask it one trivial question, returning the error the
  /// open produced or null. Drift opens lazily, so the failure surfaces on the
  /// first statement rather than at construction.
  Future<Object?> openAndQuery() async {
    final db = open();
    Object? error;
    try {
      await db.customSelect('SELECT count(*) AS c FROM imaging_sessions').get();
    } catch (e) {
      error = e;
    }
    try {
      await db.close();
    } catch (_) {}
    return error;
  }

  Future<void> writeMarkerFor(int sessionId) => markIntegrationStarted(
    tempDir,
    InterruptedIntegration(
      sessionId: sessionId,
      targetName: 'M31',
      startedAtUtc: DateTime.utc(2026, 8, 17, 3, 30),
      intendedMasterPaths: const [],
    ),
  );

  test(
    'a marker naming a session the database no longer holds does not stop it '
    'opening',
    () async {
      // The corruption quarantine rotated the damaged file aside and a fresh
      // database is created here. The marker survived the rotation beside it
      // and still names session 42, which this schema has never held.
      await writeMarkerFor(42);

      expect(
        await openAndQuery(),
        isNull,
        reason: 'a post-mortem for a session that is gone must not be fatal',
      );
      expect(
        await integrationMarkerFile(tempDir).exists(),
        isFalse,
        reason: 'the marker is consumed, so the next open has nothing to retry',
      );

      // The brick was never one failure — it was the same failure at every
      // launch, because the marker outlived it.
      expect(await openAndQuery(), isNull);
      expect(await openAndQuery(), isNull);
    },
  );

  test(
    'a session deleted after the crash does not stop the database opening',
    () async {
      final db = open();
      final sessionId = await db.customInsert(
        'INSERT INTO imaging_sessions(start_time, status) VALUES (?, ?)',
        variables: [
          Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          const Variable<String>('completed'),
        ],
      );
      // The marker is written when the integrate starts...
      await writeMarkerFor(sessionId);
      // ...then the operator deletes the night from the sessions list on the
      // same live connection, and the process is killed. Nothing reopens in
      // between, so nothing consumes the marker.
      await db.customUpdate(
        'DELETE FROM imaging_sessions WHERE id = ?',
        variables: [Variable<int>(sessionId)],
      );
      await db.close();

      expect(await openAndQuery(), isNull);
      expect(await openAndQuery(), isNull);
    },
  );

  test('a report that fails for any other reason still opens', () async {
    // The missing-session probe covers the reachable case. This covers the
    // class: whatever else makes the post-mortem throw — a half-applied
    // migration, a table a partial restore left behind — the open survives it.
    // `narrator_events` is dropped underneath a marker whose session DOES
    // exist, so the probe passes and the INSERT is what fails.
    final db = open();
    final sessionId = await db.customInsert(
      'INSERT INTO imaging_sessions(start_time, status) VALUES (?, ?)',
      variables: [
        Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        const Variable<String>('completed'),
      ],
    );
    await db.close();

    final raw = sqlite3.open(dbFile.path);
    raw.execute('DROP TABLE narrator_events');
    raw.close();

    await writeMarkerFor(sessionId);

    expect(
      await openAndQuery(),
      isNull,
      reason: 'the database must open even when the post-mortem cannot land',
    );
    expect(
      await integrationMarkerFile(tempDir).exists(),
      isFalse,
      reason: 'the marker that caused it is discarded, not left to repeat',
    );
    expect(await openAndQuery(), isNull);
  });
}
