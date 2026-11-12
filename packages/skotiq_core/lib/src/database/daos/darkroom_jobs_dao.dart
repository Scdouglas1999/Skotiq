import 'package:drift/drift.dart';

import '../../models/darkroom/darkroom_job.dart';
import '../database.dart';
import '../epoch_seconds.dart';
import '../sqlite_busy.dart';

part 'darkroom_jobs_dao.g.dart';

/// Reads and writes for `darkroom_jobs`: the durable dawn-job queue.
///
/// TYPED TRANSITIONS. Every state-changing method reads the row's current state
/// first and refuses a move [DarkroomJobState.canTransitionTo] rejects, with a
/// [DarkroomJobTransitionException] naming both ends. A missing row is a
/// [DarkroomJobMissingException], never a silent zero-row update: a coordinator
/// that thinks it holds a job it does not must find out.
///
/// CRASH RECOVERY is NOT here. Re-queueing rows left `running` by a dead
/// process happens once, at start-up (`recoverFromPreviousProcessExit`),
/// because the rule that makes it sound — nothing can still be running when
/// the process has only just opened the database — only holds then. A second
/// implementation reachable at other times would re-queue a job a live
/// executor is holding.
///
/// LOCK CONTENTION. Every state-changing write runs under
/// [retryWhileSqliteBusy], on top of the connection-wide
/// [kSqliteBusyTimeout]. The two together are what stop an external reader —
/// a 3am backup script holding a transaction over the file — from failing one
/// `UPDATE` and stranding a job in `running` for the rest of the process's
/// life, since the open-time recovery that would rescue it does not run again
/// until the next launch. Contention that outlives both budgets is reported,
/// not swallowed: the [SqliteException] propagates with its result code.
@DriftAccessor(include: {'../schema/darkroom.drift'})
class DarkroomJobsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$DarkroomJobsDaoMixin {
  DarkroomJobsDao(super.db);

  /// Queue a job and return its id. The row starts
  /// [DarkroomJobState.queued] at zero progress with no attempts spent.
  Future<int> enqueue({
    int? sessionId,
    DarkroomJobKind kind = DarkroomJobKind.dawn,
    String? note,
    DateTime? createdAt,
  }) {
    final at = toEpochSeconds(createdAt ?? DateTime.now());
    return retryWhileSqliteBusy(
      () => into(darkroomJobs).insert(
        DarkroomJobsCompanion.insert(
          sessionId: Value(sessionId),
          kind: Value(kind.wire),
          state: Value(DarkroomJobState.queued.wire),
          progress: const Value(0.0),
          note: Value(note),
          attempts: const Value(0),
          createdAt: at,
        ),
      ),
    );
  }

  Future<DarkroomJob?> getById(int id) async {
    final row = await (select(
      darkroomJobs,
    )..where((j) => j.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// The oldest queued job, or null when the queue is empty. The order a
  /// serialized coordinator drains in.
  Future<DarkroomJob?> nextQueued() async {
    final row = await (_inState(
      DarkroomJobState.queued,
    )..limit(1)).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// Every job in [state], oldest first.
  Future<List<DarkroomJob>> listByState(DarkroomJobState state) async {
    final rows = await _inState(state).get();
    return rows.map(_map).toList();
  }

  /// Every job for one imaging session, newest first.
  Future<List<DarkroomJob>> listForSession(int sessionId) async {
    final rows =
        await (select(darkroomJobs)
              ..where((j) => j.sessionId.equals(sessionId))
              ..orderBy([
                (j) => OrderingTerm.desc(j.createdAt),
                (j) => OrderingTerm.desc(j.id),
              ]))
            .get();
    return rows.map(_map).toList();
  }

  /// Take a queued job: state becomes [DarkroomJobState.running], `attempts`
  /// increments, `started_at` is stamped, and any error text from a previous
  /// attempt is cleared. Returns the job as it now stands.
  Future<DarkroomJob> markRunning(int id, {DateTime? now}) {
    final at = toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      // Inside the retry so a re-attempt re-reads the row: the transition is
      // re-checked against what is actually stored, and a busy `UPDATE`
      // incremented nothing, so `attempts` still counts starts, not tries.
      await _requireTransition(id, DarkroomJobState.running);
      await _write(
        id,
        DarkroomJobsCompanion.custom(
          state: Variable(DarkroomJobState.running.wire),
          attempts: darkroomJobs.attempts + const Constant(1),
          startedAt: Variable(at),
          errorText: const Constant(null),
        ),
      );
      return _reread(id);
    });
  }

  /// Report how far a running job has got, optionally with the current step as
  /// [note]. Returns the job as it now stands.
  ///
  /// Throws [DarkroomJobNotRunningException] when no executor holds the job:
  /// a late progress write must never repaint a terminal state as busy.
  Future<DarkroomJob> updateProgress(
    int id,
    double progress, {
    String? note,
  }) async {
    if (progress < 0.0 || progress > 1.0) {
      throw ArgumentError.value(
        progress,
        'progress',
        'a job progress fraction lies in 0.0 .. 1.0',
      );
    }
    return retryWhileSqliteBusy(() async {
      final current = await _require(id);
      if (current.state != DarkroomJobState.running) {
        throw DarkroomJobNotRunningException(id, current.state);
      }
      await _write(
        id,
        DarkroomJobsCompanion(
          progress: Value(progress),
          note: Value.absentIfNull(note),
        ),
      );
      return _reread(id);
    });
  }

  /// Replace the note on a job that is still `queued`, and answer whether it
  /// was written.
  ///
  /// This is how a submission waiting for the one-pass-at-a-time gate says so:
  /// Session Review's queued banner reads `note` back verbatim as the row's own
  /// account of itself, so a pass that will not start for ten minutes says that
  /// rather than showing the label its enqueue wrote.
  ///
  /// Scoped to `queued` in the same statement that writes, so a job that
  /// reaches the front of the gate between the caller's decision and this write
  /// keeps the stage its pipeline is recording. `false` means exactly that —
  /// the row moved on — and is not an error.
  Future<bool> noteWhileQueued(int id, String note) {
    return retryWhileSqliteBusy(() async {
      final changed =
          await (update(darkroomJobs)..where(
                (j) =>
                    j.id.equals(id) &
                    j.state.equals(DarkroomJobState.queued.wire),
              ))
              .write(DarkroomJobsCompanion(note: Value(note)));
      return changed > 0;
    });
  }

  /// Finish a running job: state becomes [DarkroomJobState.done], progress
  /// reaches 1.0, `finished_at` is stamped. Returns the job as it now stands.
  Future<DarkroomJob> markDone(int id, {String? note, DateTime? now}) {
    final at = toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      await _requireTransition(id, DarkroomJobState.done);
      await _write(
        id,
        DarkroomJobsCompanion(
          state: Value(DarkroomJobState.done.wire),
          progress: const Value(1.0),
          finishedAt: Value(at),
          note: Value.absentIfNull(note),
        ),
      );
      return _reread(id);
    });
  }

  /// Fail a running job with [errorText]. Progress is left where it stopped, so
  /// the report can state how far the attempt got. Returns the job as it now
  /// stands.
  Future<DarkroomJob> markFailed(int id, String errorText, {DateTime? now}) {
    final at = toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      await _requireTransition(id, DarkroomJobState.failed);
      await _write(
        id,
        DarkroomJobsCompanion(
          state: Value(DarkroomJobState.failed.wire),
          finishedAt: Value(at),
          errorText: Value(errorText),
        ),
      );
      return _reread(id);
    });
  }

  /// Cancel a queued or running job, recording [reason] as its error text.
  /// Progress is left where it stopped. Returns the job as it now stands.
  Future<DarkroomJob> markCancelled(int id, {String? reason, DateTime? now}) {
    final at = toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      await _requireTransition(id, DarkroomJobState.cancelled);
      await _write(
        id,
        DarkroomJobsCompanion(
          state: Value(DarkroomJobState.cancelled.wire),
          finishedAt: Value(at),
          errorText: Value.absentIfNull(reason),
        ),
      );
      return _reread(id);
    });
  }

  /// Hand a running job back to the queue because THIS process is stopping on
  /// purpose, and give back the start it took. Returns the job as it now
  /// stands.
  ///
  /// `attempts` counts starts that were spent — a start that ended in a crash,
  /// or in a finished pass. An orderly stop spends nothing: the same work is
  /// picked up from the same place by the next launch. So the increment
  /// [markRunning] made is returned here, and three ordinary service restarts
  /// during a pass can no longer exhaust [kDarkroomJobMaxAttempts] and fail the
  /// night's job. A crash still cannot reach this — it leaves the row
  /// `running` for the open-time recovery, which does charge the attempt.
  ///
  /// `progress` is left where the pass reached, so the next attempt's note can
  /// say how far the interrupted one got.
  Future<DarkroomJob> releaseForOrderlyStop(int id, {String? note}) {
    return retryWhileSqliteBusy(() async {
      final current = await _require(id);
      if (current.state != DarkroomJobState.running) {
        throw DarkroomJobNotRunningException(id, current.state);
      }
      final attempts = darkroomJobs.attempts;
      await (update(darkroomJobs)..where(
            (j) =>
                j.id.equals(id) & j.state.equals(DarkroomJobState.running.wire),
          ))
          .write(
            DarkroomJobsCompanion.custom(
              state: Variable(DarkroomJobState.queued.wire),
              startedAt: const Constant(null),
              attempts: CaseWhenExpression(
                cases: [
                  CaseWhen(
                    attempts.isBiggerThanValue(0),
                    then: attempts - const Constant(1),
                  ),
                ],
                orElse: const Constant(0),
              ),
              note: note == null ? null : Variable(note),
            ),
          );
      return _reread(id);
    });
  }

  /// Delete a job by id. Its `delivery_journal` rows cascade. Returns the
  /// number of rows changed.
  Future<int> deleteJob(int id) {
    return retryWhileSqliteBusy(
      () => (delete(darkroomJobs)..where((j) => j.id.equals(id))).go(),
    );
  }

  Future<DarkroomJob> _require(int id) async {
    final job = await getById(id);
    if (job == null) throw DarkroomJobMissingException(id);
    return job;
  }

  Future<DarkroomJob> _reread(int id) => _require(id);

  Future<void> _requireTransition(int id, DarkroomJobState to) async {
    final current = await _require(id);
    if (!current.state.canTransitionTo(to)) {
      throw DarkroomJobTransitionException(id, current.state, to);
    }
  }

  /// The jobs in [state], oldest first.
  SimpleSelectStatement<DarkroomJobs, DarkroomJobRow> _inState(
    DarkroomJobState state,
  ) {
    return select(darkroomJobs)
      ..where((j) => j.state.equals(state.wire))
      ..orderBy([
        (j) => OrderingTerm.asc(j.createdAt),
        (j) => OrderingTerm.asc(j.id),
      ]);
  }

  Future<int> _write(int id, Insertable<DarkroomJobRow> changes) =>
      (update(darkroomJobs)..where((j) => j.id.equals(id))).write(changes);

  DarkroomJob _map(DarkroomJobRow row) {
    final startedAt = row.startedAt;
    final finishedAt = row.finishedAt;
    return DarkroomJob(
      id: row.id,
      sessionId: row.sessionId,
      kind: DarkroomJobKind.fromWire(row.kind),
      state: DarkroomJobState.fromWire(row.state),
      progress: row.progress,
      note: row.note,
      errorText: row.errorText,
      attempts: row.attempts,
      createdAt: fromEpochSeconds(row.createdAt),
      startedAt: startedAt == null ? null : fromEpochSeconds(startedAt),
      finishedAt: finishedAt == null ? null : fromEpochSeconds(finishedAt),
    );
  }
}
