/// The durable dawn-job record — one unit of overnight Darkroom work whose
/// state survives a crash, a force quit, or safing mid-run.
///
/// A [DarkroomJob] maps 1:1 to a row of the raw-DDL `darkroom_jobs` table (see
/// `SkotiqDatabase._createDarkroomTables`) and is read/written through the
/// plain [DarkroomJobsDao].
///
/// The in-memory `JobManager` under `apps/desktop/lib/headless_api/` is purged
/// at 24 h and cleared on server stop, and does not exist at all in the GUI
/// path. This table is the durable queue that survives both.
library;

import 'recipe.dart' show DarkroomWireFormatException;

/// How many times a job may be started before the open-time crash recovery
/// stops re-queueing it and marks it failed.
///
/// A job that kills the process on every attempt would otherwise be re-queued
/// forever, and each restart would take the app down with it.
const int kDarkroomJobMaxAttempts = 3;

/// Lifecycle state of a [DarkroomJob].
///
/// Stored as the lowercase wire string in `darkroom_jobs.state`, constrained by
/// a `CHECK` on the column.
///
/// Legal transitions (enforced by [canTransitionTo] and by every
/// [DarkroomJobsDao] write):
///
/// ```text
///   queued  -> running | cancelled
///   running -> done | failed | cancelled | queued
///   done / failed / cancelled -> (terminal)
/// ```
///
/// `running -> queued` is the interruption edge, and only these two take it:
///
///   - the open-time crash recovery, for a row still marked `running` when the
///     database opens — that belongs to a process that died, and the re-queue
///     charges the attempt it spent;
///   - an orderly shutdown, through `DarkroomJobsDao.releaseForOrderlyStop`,
///     which hands the row back BEFORE the process exits and returns the start
///     it took, because a polite stop spends no attempt.
///
/// Nothing else may take that edge.
enum DarkroomJobState {
  /// Waiting for the coordinator to pick it up.
  queued,

  /// A live executor holds this job.
  running,

  /// Stopped on request before completing.
  cancelled,

  /// Completed; its artifacts exist.
  done,

  /// Stopped by an error; `error_text` says which.
  failed;

  /// The lowercase wire string stored in the DB.
  String get wire => name;

  /// True for a state no further transition leaves.
  bool get isTerminal =>
      this == DarkroomJobState.done ||
      this == DarkroomJobState.failed ||
      this == DarkroomJobState.cancelled;

  /// Whether [next] is a legal successor of this state.
  bool canTransitionTo(DarkroomJobState next) {
    switch (this) {
      case DarkroomJobState.queued:
        return next == DarkroomJobState.running ||
            next == DarkroomJobState.cancelled;
      case DarkroomJobState.running:
        return next != DarkroomJobState.running;
      case DarkroomJobState.cancelled:
      case DarkroomJobState.done:
      case DarkroomJobState.failed:
        return false;
    }
  }

  /// Parse a stored state string.
  ///
  /// Throws [DarkroomWireFormatException] on any value this app could not have
  /// written. Defaulting here would let a `failed` row read back as `queued`
  /// and re-run work that already lost its data.
  static DarkroomJobState fromWire(String? value) {
    switch (value) {
      case 'queued':
        return DarkroomJobState.queued;
      case 'running':
        return DarkroomJobState.running;
      case 'cancelled':
        return DarkroomJobState.cancelled;
      case 'done':
        return DarkroomJobState.done;
      case 'failed':
        return DarkroomJobState.failed;
      default:
        throw DarkroomWireFormatException('darkroom_jobs.state', value);
    }
  }
}

/// What asked for a [DarkroomJob].
///
/// Stored as the lowercase wire string in `darkroom_jobs.kind`, constrained by
/// a `CHECK` on the column. The distinction is load-bearing downstream: a dawn
/// run fires the morning notification, an operator-requested run does not.
enum DarkroomJobKind {
  /// Queued by the dawn autopilot off a terminal run result.
  dawn,

  /// Queued by an operator ("process tonight now").
  manual;

  /// The lowercase wire string stored in the DB.
  String get wire => name;

  /// Parse a stored kind string, throwing [DarkroomWireFormatException] on a
  /// value outside the column's `CHECK` constraint.
  static DarkroomJobKind fromWire(String? value) {
    switch (value) {
      case 'dawn':
        return DarkroomJobKind.dawn;
      case 'manual':
        return DarkroomJobKind.manual;
      default:
        throw DarkroomWireFormatException('darkroom_jobs.kind', value);
    }
  }
}

/// A [DarkroomJobsDao] write was asked for a transition the state machine does
/// not allow.
class DarkroomJobTransitionException implements Exception {
  /// The job the write targeted.
  final int jobId;

  /// The state the row is actually in.
  final DarkroomJobState from;

  /// The state the caller asked for.
  final DarkroomJobState to;

  const DarkroomJobTransitionException(this.jobId, this.from, this.to);

  @override
  String toString() =>
      'Darkroom job $jobId cannot go ${from.wire} -> ${to.wire}';
}

/// Progress was reported for a job no executor is holding.
///
/// Progress means "this much of the work in flight is done"; a job that is
/// queued has none in flight, and a job that is terminal has a final answer a
/// late progress write must not overwrite.
class DarkroomJobNotRunningException implements Exception {
  /// The job the write targeted.
  final int jobId;

  /// The state the row is actually in.
  final DarkroomJobState state;

  const DarkroomJobNotRunningException(this.jobId, this.state);

  @override
  String toString() =>
      'Darkroom job $jobId is ${state.wire}, so it has no progress to report';
}

/// A [DarkroomJobsDao] write named a job id that no longer has a row.
class DarkroomJobMissingException implements Exception {
  final int jobId;

  const DarkroomJobMissingException(this.jobId);

  @override
  String toString() => 'Darkroom job $jobId does not exist';
}

/// One durable dawn job: what to process, how far it got, and how it ended.
class DarkroomJob {
  /// DB primary key (`darkroom_jobs.id`). Null for an unsaved record.
  final int? id;

  /// The `imaging_sessions.id` whose night this job processes, or null for a
  /// job queued outside a session. `ON DELETE CASCADE` — a job is a per-session
  /// work item and has nothing to process once its session is gone.
  final int? sessionId;

  /// What asked for this job.
  final DarkroomJobKind kind;

  /// Lifecycle state.
  final DarkroomJobState state;

  /// Fraction complete in `0.0 .. 1.0`. Advances only while [state] is
  /// [DarkroomJobState.running]; a terminal state leaves it at the last value
  /// reported, so a failure records how far it got.
  final double progress;

  /// The most recent human-readable statement about this job: the current step
  /// while it runs, and the recovery note after an open-time crash reset. Null
  /// until something is worth saying.
  final String? note;

  /// Why the job failed, or null. Set only alongside
  /// [DarkroomJobState.failed] / [DarkroomJobState.cancelled].
  final String? errorText;

  /// How many times this job has been started. Incremented on each transition
  /// into [DarkroomJobState.running], including a restart after crash
  /// recovery, so a job that kills the process is not re-queued forever.
  final int attempts;

  /// When the job was queued (UTC).
  final DateTime createdAt;

  /// When the job most recently started running (UTC), or null while queued.
  final DateTime? startedAt;

  /// When the job reached a terminal state (UTC), or null before then.
  final DateTime? finishedAt;

  const DarkroomJob({
    this.id,
    this.sessionId,
    required this.kind,
    required this.state,
    required this.progress,
    this.note,
    this.errorText,
    required this.attempts,
    required this.createdAt,
    this.startedAt,
    this.finishedAt,
  });

  /// True for a state no further transition leaves.
  bool get isTerminal => state.isTerminal;

  DarkroomJob copyWith({
    int? id,
    int? sessionId,
    DarkroomJobKind? kind,
    DarkroomJobState? state,
    double? progress,
    String? note,
    String? errorText,
    int? attempts,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? finishedAt,
  }) {
    return DarkroomJob(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      kind: kind ?? this.kind,
      state: state ?? this.state,
      progress: progress ?? this.progress,
      note: note ?? this.note,
      errorText: errorText ?? this.errorText,
      attempts: attempts ?? this.attempts,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }

  @override
  String toString() =>
      'DarkroomJob(id=$id, session=$sessionId, ${kind.wire}, '
      '${state.wire}, ${(progress * 100).toStringAsFixed(0)}%, '
      'attempts=$attempts)';
}
