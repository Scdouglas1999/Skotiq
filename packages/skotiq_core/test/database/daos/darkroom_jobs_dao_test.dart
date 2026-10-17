// Behaviour tests for the v58 DarkroomJobsDao — the durable dawn-job queue.
// Covers enqueue defaults, the typed state machine (every legal move, and a
// refusal for every illegal one), progress reporting only while an executor
// holds the job, attempt counting, the session scope, and the cascade that
// takes a session's jobs with it.

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/darkroom_job.dart';

void main() {
  late SkotiqDatabase db;
  late DarkroomJobsDao dao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = DarkroomJobsDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedSession() {
    return db.customInsert(
      'INSERT INTO imaging_sessions (start_time) VALUES (?)',
      variables: [Variable.withInt(1770000000)],
    );
  }

  test('enqueue starts a dawn job queued at zero progress', () async {
    final sessionId = await seedSession();
    final id = await dao.enqueue(
      sessionId: sessionId,
      createdAt: DateTime.utc(2026, 8, 16, 5),
    );

    final job = await dao.getById(id);
    expect(job, isNotNull);
    expect(job!.sessionId, sessionId);
    expect(job.kind, DarkroomJobKind.dawn);
    expect(job.state, DarkroomJobState.queued);
    expect(job.progress, 0.0);
    expect(job.attempts, 0);
    expect(job.startedAt, isNull);
    expect(job.finishedAt, isNull);
    expect(job.errorText, isNull);
    expect(job.isTerminal, isFalse);
  });

  test('the happy path runs queued -> running -> done', () async {
    final id = await dao.enqueue(kind: DarkroomJobKind.manual);

    var job = await dao.markRunning(id, now: DateTime.utc(2026, 8, 16, 5, 10));
    expect(job.state, DarkroomJobState.running);
    expect(job.attempts, 1);
    expect(job.startedAt, DateTime.utc(2026, 8, 16, 5, 10));

    job = await dao.updateProgress(id, 0.4, note: 'Integrating Ha');
    expect(job.progress, 0.4);
    expect(job.note, 'Integrating Ha');

    job = await dao.markDone(id, now: DateTime.utc(2026, 8, 16, 5, 42));
    expect(job.state, DarkroomJobState.done);
    expect(job.progress, 1.0, reason: 'a finished job is finished');
    expect(job.finishedAt, DateTime.utc(2026, 8, 16, 5, 42));
    expect(job.isTerminal, isTrue);
  });

  test('a failure keeps the progress it reached and states why', () async {
    final id = await dao.enqueue();
    await dao.markRunning(id);
    await dao.updateProgress(id, 0.62, note: 'Registering');

    final job = await dao.markFailed(id, 'Disk full writing the master');
    expect(job.state, DarkroomJobState.failed);
    expect(job.errorText, 'Disk full writing the master');
    expect(
      job.progress,
      0.62,
      reason: 'the report must be able to say how far the attempt got',
    );
    expect(job.note, 'Registering');
  });

  test('cancellation is legal from queued and from running', () async {
    final queuedId = await dao.enqueue();
    final cancelledQueued = await dao.markCancelled(
      queuedId,
      reason: 'Operator stopped the queue',
    );
    expect(cancelledQueued.state, DarkroomJobState.cancelled);
    expect(cancelledQueued.errorText, 'Operator stopped the queue');

    final runningId = await dao.enqueue();
    await dao.markRunning(runningId);
    final cancelledRunning = await dao.markCancelled(
      runningId,
      reason: 'Safing',
    );
    expect(cancelledRunning.state, DarkroomJobState.cancelled);
    expect(cancelledRunning.startedAt, isNotNull);
  });

  test('illegal transitions are refused, naming both ends', () async {
    final id = await dao.enqueue();

    // queued cannot finish without running.
    await expectLater(
      dao.markDone(id),
      throwsA(
        isA<DarkroomJobTransitionException>()
            .having((e) => e.from, 'from', DarkroomJobState.queued)
            .having((e) => e.to, 'to', DarkroomJobState.done),
      ),
    );
    await expectLater(
      dao.markFailed(id, 'nope'),
      throwsA(isA<DarkroomJobTransitionException>()),
    );

    await dao.markRunning(id);
    // A running job cannot be taken twice.
    await expectLater(
      dao.markRunning(id),
      throwsA(isA<DarkroomJobTransitionException>()),
    );

    await dao.markDone(id);
    // Terminal is terminal, in every direction.
    for (final move in <Future<DarkroomJob> Function()>[
      () => dao.markRunning(id),
      () => dao.markDone(id),
      () => dao.markFailed(id, 'late'),
      () => dao.markCancelled(id),
    ]) {
      await expectLater(move(), throwsA(isA<DarkroomJobTransitionException>()));
    }
    expect((await dao.getById(id))!.state, DarkroomJobState.done);
  });

  test('progress is refused unless an executor holds the job', () async {
    final id = await dao.enqueue();
    await expectLater(
      dao.updateProgress(id, 0.5),
      throwsA(
        isA<DarkroomJobNotRunningException>().having(
          (e) => e.state,
          'state',
          DarkroomJobState.queued,
        ),
      ),
    );

    await dao.markRunning(id);
    await dao.markDone(id);
    await expectLater(
      dao.updateProgress(id, 0.5),
      throwsA(isA<DarkroomJobNotRunningException>()),
      reason: 'a late progress write must not repaint a finished job as busy',
    );
    expect((await dao.getById(id))!.progress, 1.0);

    await dao.markRunning(await dao.enqueue()).then((job) async {
      await expectLater(
        dao.updateProgress(job.id!, 1.5),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        dao.updateProgress(job.id!, -0.1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test(
    'a write against a missing job is reported, not silently dropped',
    () async {
      const ghost = 4242;
      await expectLater(
        dao.markRunning(ghost),
        throwsA(isA<DarkroomJobMissingException>()),
      );
      await expectLater(
        dao.updateProgress(ghost, 0.1),
        throwsA(isA<DarkroomJobMissingException>()),
      );
      expect(await dao.getById(ghost), isNull);
    },
  );

  test('nextQueued drains oldest first and skips non-queued rows', () async {
    final first = await dao.enqueue(createdAt: DateTime.utc(2026, 8, 16, 5));
    final second = await dao.enqueue(createdAt: DateTime.utc(2026, 8, 16, 6));

    expect((await dao.nextQueued())!.id, first);
    await dao.markRunning(first);
    expect((await dao.nextQueued())!.id, second);

    await dao.markRunning(second);
    expect(await dao.nextQueued(), isNull);
    expect(
      (await dao.listByState(DarkroomJobState.running)).map((j) => j.id),
      <int>[first, second],
    );
  });

  // An orderly stop is not a crash. Left `running`, a row a SIGTERM walked
  // away from is charged an attempt by the open-time recovery, so three
  // ordinary restarts during a dawn pass exhausted the three starts and failed
  // the night's job.
  test('an orderly stop re-queues the job and gives the start back', () async {
    final id = await dao.enqueue();
    await dao.markRunning(id, now: DateTime.utc(2026, 8, 31, 5));
    await dao.updateProgress(id, 0.35, note: 'Drafting Master L');

    final job = await dao.releaseForOrderlyStop(id, note: 'Stopping the host');
    expect(job.state, DarkroomJobState.queued);
    expect(job.attempts, 0, reason: 'the start it took is handed back');
    expect(job.startedAt, isNull);
    expect(job.note, 'Stopping the host');
    expect(
      job.progress,
      0.35,
      reason: 'the next attempt can say how far the interrupted one got',
    );
  });

  test('orderly stops never exhaust the attempt limit', () async {
    final id = await dao.enqueue();
    for (var restart = 0; restart < kDarkroomJobMaxAttempts + 2; restart++) {
      final running = await dao.markRunning(id);
      expect(running.attempts, 1, reason: 'every polite restart is the first');
      await dao.releaseForOrderlyStop(id);
    }

    final job = await dao.markRunning(id);
    expect(job.attempts, 1);
    expect(job.state, DarkroomJobState.running);
    await dao.markDone(id);
    expect((await dao.getById(id))!.state, DarkroomJobState.done);
  });

  test('only a running job can be released to an orderly stop', () async {
    final queued = await dao.enqueue();
    await expectLater(
      dao.releaseForOrderlyStop(queued),
      throwsA(
        isA<DarkroomJobNotRunningException>().having(
          (e) => e.state,
          'state',
          DarkroomJobState.queued,
        ),
      ),
    );

    final finished = await dao.enqueue();
    await dao.markRunning(finished);
    await dao.markDone(finished);
    await expectLater(
      dao.releaseForOrderlyStop(finished),
      throwsA(isA<DarkroomJobNotRunningException>()),
      reason: 'a finished pass must not be re-queued by a later shutdown',
    );
    expect((await dao.getById(finished))!.state, DarkroomJobState.done);

    await expectLater(
      dao.releaseForOrderlyStop(4242),
      throwsA(isA<DarkroomJobMissingException>()),
    );
  });

  test('the executor learns its job was released, at its next write', () async {
    final id = await dao.enqueue();
    await dao.markRunning(id);
    await dao.releaseForOrderlyStop(id);

    await expectLater(
      dao.updateProgress(id, 0.9),
      throwsA(isA<DarkroomJobNotRunningException>()),
    );
    await expectLater(
      dao.markDone(id),
      throwsA(isA<DarkroomJobTransitionException>()),
      reason: 'a released row must not be finished by the executor that left',
    );
    expect((await dao.getById(id))!.state, DarkroomJobState.queued);
  });

  test('jobs are scoped to a session and cascade with it', () async {
    final sessionId = await seedSession();
    final otherSession = await seedSession();
    final mine = await dao.enqueue(sessionId: sessionId);
    await dao.enqueue(sessionId: otherSession);

    expect(
      (await dao.listForSession(sessionId)).map((j) => j.id).toList(),
      <int>[mine],
    );

    await db.customStatement('DELETE FROM imaging_sessions WHERE id = ?', [
      sessionId,
    ]);
    expect(await dao.getById(mine), isNull);
    expect(await dao.listForSession(sessionId), isEmpty);
    expect(await dao.listForSession(otherSession), hasLength(1));
  });
}
