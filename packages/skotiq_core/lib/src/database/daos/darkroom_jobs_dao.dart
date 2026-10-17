import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/darkroom/darkroom_job.dart';
import '../../providers/database_provider.dart';
import '../database.dart';
import '../sqlite_busy.dart';

/// Data-access object for the v58 `darkroom_jobs` table — the durable dawn-job
/// queue.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createDarkroomTables]) rather than a drift `Table`
/// class, so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customInsert`/`customStatement` APIs — mirroring
/// [MosaicProjectsDao] and [CampaignsDao]. It is deliberately NOT a
/// `@DriftAccessor`.
///
/// TYPED TRANSITIONS. Every state-changing method reads the row's current state
/// first and refuses a move [DarkroomJobState.canTransitionTo] rejects, with a
/// [DarkroomJobTransitionException] naming both ends. A missing row is a
/// [DarkroomJobMissingException], never a silent zero-row update: a coordinator
/// that thinks it holds a job it does not must find out.
///
/// CRASH RECOVERY is NOT here. Re-queueing rows left `running` by a dead
/// process happens once, in `beforeOpen`
/// (`SkotiqDatabase._recoverInterruptedDarkroomJobs`), because the rule
/// that makes it sound — nothing can still be running at the moment the
/// database opens — only holds at open. A second implementation reachable at
/// other times would re-queue a job a live executor is holding.
///
/// LOCK CONTENTION. Every state-changing write runs under
/// [retryWhileSqliteBusy], on top of the connection-wide
/// [kSqliteBusyTimeout]. The two together are what stop an external reader —
/// a 3am backup script holding a transaction over the file — from failing one
/// `UPDATE` and stranding a job in `running` for the rest of the process's
/// life, since the open-time recovery that would rescue it does not run again
/// until the next launch. Contention that outlives both budgets is reported,
/// not swallowed: the [SqliteException] propagates with its result code.
class DarkroomJobsDao {
  DarkroomJobsDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, session_id, kind, state, progress, note, error_text, attempts, '
      'created_at, started_at, finished_at';

  /// Queue a job and return its id. The row starts
  /// [DarkroomJobState.queued] at zero progress with no attempts spent.
  Future<int> enqueue({
    int? sessionId,
    DarkroomJobKind kind = DarkroomJobKind.dawn,
    String? note,
    DateTime? createdAt,
  }) {
    final at = _toEpochSeconds(createdAt ?? DateTime.now());
    return retryWhileSqliteBusy(
      () => _db.customInsert(
        'INSERT INTO darkroom_jobs('
        'session_id, kind, state, progress, note, attempts, created_at'
        ') VALUES (?, ?, ?, 0.0, ?, 0, ?)',
        variables: [
          Variable<int>(sessionId),
          Variable<String>(kind.wire),
          Variable<String>(DarkroomJobState.queued.wire),
          Variable<String>(note),
          Variable<int>(at),
        ],
      ),
    );
  }

  /// Fetch a job by id, or null when absent.
  Future<DarkroomJob?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM darkroom_jobs WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// The oldest queued job, or null when the queue is empty. The order a
  /// serialized coordinator drains in.
  Future<DarkroomJob?> nextQueued() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM darkroom_jobs WHERE state = ? '
          'ORDER BY created_at ASC, id ASC LIMIT 1',
          variables: [Variable<String>(DarkroomJobState.queued.wire)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// Every job in [state], oldest first.
  Future<List<DarkroomJob>> listByState(DarkroomJobState state) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM darkroom_jobs WHERE state = ? '
          'ORDER BY created_at ASC, id ASC',
          variables: [Variable<String>(state.wire)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Every job for one imaging session, newest first.
  Future<List<DarkroomJob>> listForSession(int sessionId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM darkroom_jobs WHERE session_id = ? '
          'ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(sessionId)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Take a queued job: state becomes [DarkroomJobState.running], `attempts`
  /// increments, `started_at` is stamped, and any error text from a previous
  /// attempt is cleared. Returns the job as it now stands.
  Future<DarkroomJob> markRunning(int id, {DateTime? now}) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      // Inside the retry so a re-attempt re-reads the row: the transition is
      // re-checked against what is actually stored, and a busy `UPDATE`
      // incremented nothing, so `attempts` still counts starts, not tries.
      await _requireTransition(id, DarkroomJobState.running);
      await _db.customUpdate(
        'UPDATE darkroom_jobs SET state = ?, attempts = attempts + 1, '
        'started_at = ?, error_text = NULL WHERE id = ?',
        variables: [
          Variable<String>(DarkroomJobState.running.wire),
          Variable<int>(at),
          Variable<int>(id),
        ],
        updateKind: UpdateKind.update,
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
      await _db.customUpdate(
        'UPDATE darkroom_jobs SET progress = ?, '
        'note = COALESCE(?, note) WHERE id = ?',
        variables: [
          Variable<double>(progress),
          Variable<String>(note),
          Variable<int>(id),
        ],
        updateKind: UpdateKind.update,
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
      final changed = await _db.customUpdate(
        'UPDATE darkroom_jobs SET note = ? WHERE id = ? AND state = ?',
        variables: [
          Variable<String>(note),
          Variable<int>(id),
          Variable<String>(DarkroomJobState.queued.wire),
        ],
        updateKind: UpdateKind.update,
      );
      return changed > 0;
    });
  }

  /// Finish a running job: state becomes [DarkroomJobState.done], progress
  /// reaches 1.0, `finished_at` is stamped. Returns the job as it now stands.
  Future<DarkroomJob> markDone(int id, {String? note, DateTime? now}) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      await _requireTransition(id, DarkroomJobState.done);
      await _db.customUpdate(
        'UPDATE darkroom_jobs SET state = ?, progress = 1.0, finished_at = ?, '
        'note = COALESCE(?, note) WHERE id = ?',
        variables: [
          Variable<String>(DarkroomJobState.done.wire),
          Variable<int>(at),
          Variable<String>(note),
          Variable<int>(id),
        ],
        updateKind: UpdateKind.update,
      );
      return _reread(id);
    });
  }

  /// Fail a running job with [errorText]. Progress is left where it stopped, so
  /// the report can state how far the attempt got. Returns the job as it now
  /// stands.
  Future<DarkroomJob> markFailed(int id, String errorText, {DateTime? now}) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      await _requireTransition(id, DarkroomJobState.failed);
      await _db.customUpdate(
        'UPDATE darkroom_jobs SET state = ?, finished_at = ?, error_text = ? '
        'WHERE id = ?',
        variables: [
          Variable<String>(DarkroomJobState.failed.wire),
          Variable<int>(at),
          Variable<String>(errorText),
          Variable<int>(id),
        ],
        updateKind: UpdateKind.update,
      );
      return _reread(id);
    });
  }

  /// Cancel a queued or running job, recording [reason] as its error text.
  /// Progress is left where it stopped. Returns the job as it now stands.
  Future<DarkroomJob> markCancelled(int id, {String? reason, DateTime? now}) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return retryWhileSqliteBusy(() async {
      await _requireTransition(id, DarkroomJobState.cancelled);
      await _db.customUpdate(
        'UPDATE darkroom_jobs SET state = ?, finished_at = ?, '
        'error_text = COALESCE(?, error_text) WHERE id = ?',
        variables: [
          Variable<String>(DarkroomJobState.cancelled.wire),
          Variable<int>(at),
          Variable<String>(reason),
          Variable<int>(id),
        ],
        updateKind: UpdateKind.update,
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
      await _db.customUpdate(
        'UPDATE darkroom_jobs SET state = ?, started_at = NULL, '
        'attempts = MAX(attempts - 1, 0), note = COALESCE(?, note) '
        'WHERE id = ? AND state = ?',
        variables: [
          Variable<String>(DarkroomJobState.queued.wire),
          Variable<String>(note),
          Variable<int>(id),
          Variable<String>(DarkroomJobState.running.wire),
        ],
        updateKind: UpdateKind.update,
      );
      return _reread(id);
    });
  }

  /// Delete a job by id. Its `delivery_journal` rows cascade. Returns the
  /// number of rows changed.
  Future<int> deleteJob(int id) {
    return retryWhileSqliteBusy(
      () => _db.customUpdate(
        'DELETE FROM darkroom_jobs WHERE id = ?',
        variables: [Variable<int>(id)],
        updateKind: UpdateKind.delete,
      ),
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

  DarkroomJob _map(QueryRow row) {
    final startedAt = row.readNullable<int>('started_at');
    final finishedAt = row.readNullable<int>('finished_at');
    return DarkroomJob(
      id: row.read<int>('id'),
      sessionId: row.readNullable<int>('session_id'),
      kind: DarkroomJobKind.fromWire(row.read<String>('kind')),
      state: DarkroomJobState.fromWire(row.read<String>('state')),
      progress: row.read<double>('progress'),
      note: row.readNullable<String>('note'),
      errorText: row.readNullable<String>('error_text'),
      attempts: row.read<int>('attempts'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
      startedAt: startedAt == null ? null : _fromEpochSeconds(startedAt),
      finishedAt: finishedAt == null ? null : _fromEpochSeconds(finishedAt),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [DarkroomJobsDao].
final darkroomJobsDaoProvider = Provider<DarkroomJobsDao>((ref) {
  return DarkroomJobsDao(ref.watch(databaseProvider));
});
