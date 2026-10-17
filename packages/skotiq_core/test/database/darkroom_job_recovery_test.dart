// The v58 crash-recovery contract for `darkroom_jobs`.
//
// A row is only 'running' while a live executor in THIS process holds it, and
// that state lives in memory — so any 'running' row at the moment the database
// opens belongs to a process that died. `beforeOpen` re-queues it with a note,
// exactly as it already does for `sequence_runs`.
//
// Tested the honest way: write the row, close the database, reopen it, and read
// what the reopen did. Mirrors interrupted_run_reconciliation_test.dart.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/darkroom_job.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('skotiq_darkroom_rec_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SkotiqDatabase open() =>
      SkotiqDatabase.forTesting(NativeDatabase(dbFile));

  test(
    'a job left running by a dead process is re-queued with a note',
    () async {
      final first = open();
      late int jobId;
      try {
        final dao = DarkroomJobsDao(first);
        jobId = await dao.enqueue();
        await dao.markRunning(jobId);
        final running = await dao.updateProgress(jobId, 0.35, note: 'Stacking');
        expect(running.state, DarkroomJobState.running);
        expect(running.startedAt, isNotNull);
      } finally {
        // The process dies here — nothing marks the job done, failed, or
        // cancelled.
        await first.close();
      }

      final second = open();
      try {
        final job = await DarkroomJobsDao(second).getById(jobId);
        expect(job, isNotNull);
        expect(job!.state, DarkroomJobState.queued);
        expect(job.startedAt, isNull, reason: 'the dead start is not this run');
        expect(
          job.note,
          contains('Re-queued'),
          reason: 'the recovery must state what happened, not stay silent',
        );
        expect(
          job.progress,
          0.35,
          reason: 'how far the dead attempt got is worth keeping',
        );
        expect(
          job.attempts,
          1,
          reason: 'attempts counts starts; the restart increments it',
        );
        expect(
          await DarkroomJobsDao(second).nextQueued(),
          isNotNull,
          reason: 'the recovered job is drainable again',
        );
      } finally {
        await second.close();
      }
    },
  );

  test(
    'a job that has used every attempt is failed instead of re-queued',
    () async {
      final first = open();
      late int jobId;
      try {
        final dao = DarkroomJobsDao(first);
        jobId = await dao.enqueue();
        // Burn every attempt: each start is followed by a process death, which
        // the reopen below is standing in for.
        for (var i = 0; i < kDarkroomJobMaxAttempts; i++) {
          await dao.markRunning(jobId);
          await first.customStatement(
            "UPDATE darkroom_jobs SET state = 'queued' WHERE id = ?",
            [jobId],
          );
        }
        await dao.markRunning(jobId);
        expect(
          (await dao.getById(jobId))!.attempts,
          kDarkroomJobMaxAttempts + 1,
        );
        await first.customStatement(
          'UPDATE darkroom_jobs SET attempts = ? WHERE id = ?',
          [kDarkroomJobMaxAttempts, jobId],
        );
      } finally {
        await first.close();
      }

      final second = open();
      try {
        final job = await DarkroomJobsDao(second).getById(jobId);
        expect(job!.state, DarkroomJobState.failed);
        expect(job.errorText, contains('not retried'));
        expect(job.finishedAt, isNotNull);
        expect(await DarkroomJobsDao(second).nextQueued(), isNull);
      } finally {
        await second.close();
      }
    },
  );

  test(
    'the retry-limit sentence names the attempt the row actually reached',
    () async {
      // The recovery's own WHERE clause is `attempts >= kDarkroomJobMaxAttempts`
      // — greater-or-equal — while its sentence was the constant "on attempt 3
      // of 3". A row started five times was therefore told it died on its
      // third, which is a number nothing in the row supports.
      final first = open();
      late int jobId;
      try {
        final dao = DarkroomJobsDao(first);
        jobId = await dao.enqueue();
        await dao.markRunning(jobId);
        await first.customStatement(
          'UPDATE darkroom_jobs SET attempts = ? WHERE id = ?',
          [kDarkroomJobMaxAttempts + 2, jobId],
        );
      } finally {
        await first.close();
      }

      final second = open();
      try {
        final job = await DarkroomJobsDao(second).getById(jobId);
        expect(job!.state, DarkroomJobState.failed);
        expect(job.attempts, kDarkroomJobMaxAttempts + 2);
        expect(
          job.errorText,
          contains('on attempt ${kDarkroomJobMaxAttempts + 2}'),
          reason: 'the sentence counts the starts the row counted',
        );
        expect(
          job.errorText,
          contains('the limit is $kDarkroomJobMaxAttempts starts'),
        );
        expect(job.errorText, contains('not retried'));
      } finally {
        await second.close();
      }
    },
  );

  test('recovery leaves terminal and queued jobs alone', () async {
    final first = open();
    late int doneId;
    late int failedId;
    late int cancelledId;
    late int queuedId;
    try {
      final dao = DarkroomJobsDao(first);

      doneId = await dao.enqueue();
      await dao.markRunning(doneId);
      await dao.markDone(doneId);

      failedId = await dao.enqueue();
      await dao.markRunning(failedId);
      await dao.markFailed(failedId, 'Corrupt FITS in the stack');

      cancelledId = await dao.enqueue();
      await dao.markCancelled(cancelledId, reason: 'Safing');

      queuedId = await dao.enqueue(note: 'Waiting for the queue');
    } finally {
      await first.close();
    }

    final second = open();
    try {
      final dao = DarkroomJobsDao(second);
      expect((await dao.getById(doneId))!.state, DarkroomJobState.done);

      final failed = await dao.getById(failedId);
      expect(failed!.state, DarkroomJobState.failed);
      expect(failed.errorText, 'Corrupt FITS in the stack');

      expect(
        (await dao.getById(cancelledId))!.state,
        DarkroomJobState.cancelled,
      );

      final queued = await dao.getById(queuedId);
      expect(queued!.state, DarkroomJobState.queued);
      expect(
        queued.note,
        'Waiting for the queue',
        reason: 'an untouched queued job keeps its own note',
      );
      expect(queued.attempts, 0);
    } finally {
      await second.close();
    }
  });
}
