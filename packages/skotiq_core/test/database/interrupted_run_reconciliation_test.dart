import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A `sequence_runs` row is only `running` while the owning process's executor
/// is driving it, and that state lives in memory. So a row still marked
/// `running` when the database is opened is residue from a process that died
/// mid-run — a crash, a force quit, or a power cut.
///
/// Nothing used to clear them, which left the app contradicting itself: the run
/// list reported runs "running" (the oldest 17 hours old) while the sequencer
/// reported `idle`.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_interrupted_run_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'a run left running by a dead process is reconciled on next open',
    () async {
      // First process: start a run and die without ever finishing it.
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final runId = await first.sequenceRunsDao.startRun(
        sequenceId: null,
        sequenceName: 'interrupted by power cut',
      );
      final beforeCrash = await (first.select(
        first.sequenceRuns,
      )..where((r) => r.id.equals(runId))).getSingle();
      // Precondition: the row really is left mid-flight.
      expect(beforeCrash.status, 'running');
      expect(beforeCrash.endedAt, isNull);
      await first.close();

      // Second process opens the same file.
      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      final afterRestart = await (second.select(
        second.sequenceRuns,
      )..where((r) => r.id.equals(runId))).getSingle();

      expect(
        afterRestart.status,
        'interrupted',
        reason: 'a run nothing is driving must not still claim to be running',
      );
      // We do not know when it stopped; inventing an end time would invent a
      // duration spanning the whole downtime.
      expect(afterRestart.endedAt, isNull);
    },
  );

  test(
    'runs that already reached a terminal state are left untouched',
    () async {
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final completedId = await first.sequenceRunsDao.startRun(
        sequenceId: null,
        sequenceName: 'finished cleanly',
      );
      await first.sequenceRunsDao.finishRun(completedId, 'completed', '{}');
      final failedId = await first.sequenceRunsDao.startRun(
        sequenceId: null,
        sequenceName: 'failed cleanly',
      );
      await first.sequenceRunsDao.finishRun(failedId, 'failed', '{}');
      await first.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      final rows = await second.select(second.sequenceRuns).get();
      final byId = {for (final r in rows) r.id: r};

      expect(byId[completedId]!.status, 'completed');
      expect(byId[failedId]!.status, 'failed');
    },
  );

  test('every stale running row is reconciled, not just the newest', () async {
    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final ids = <int>[];
    for (var i = 0; i < 3; i++) {
      ids.add(
        await first.sequenceRunsDao.startRun(
          sequenceId: null,
          sequenceName: 'stale run $i',
        ),
      );
    }
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final rows = await second.select(second.sequenceRuns).get();

    expect(rows, hasLength(3));
    expect(
      rows.map((r) => r.status).toSet(),
      {'interrupted'},
      reason: 'all stale rows must be reconciled, not only the most recent',
    );
  });
}
