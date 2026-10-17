// job model for long-running headless operations.
//
// Autofocus, plate-solve, center-on-target, mosaic plan, and polar alignment
// would otherwise hold an HTTP connection open for the entire run. A
// client-side 30s timeout (or an OS-level background TCP teardown on mobile)
// kills the connection while the server-side op continues unobserved — with
// no job handle to re-query and no way for a second client to cancel the run.
// Polar-alignment Start is excluded: the backend call only admits an async
// run and returns quickly, while its progress and Stop command have dedicated
// protocol surfaces. Queuing that admission would hide immediate failures.
//
// This module fixes that by making long-running ops register as `Job`s
// owned by a `JobManager`. The action POST returns `{jobId, status: queued}`
// immediately; progress and completion flow through the existing
// WebSocket event stream as `SkotiqEvent` with `category: job`. The
// REST surface gains `GET /api/jobs/{jobId}`, `GET /api/jobs`,
// `POST /api/jobs/{jobId}/cancel`, and `DELETE /api/jobs/{jobId}`.
//
// State is in-memory only. Jobs older than 24 hours are purged by a
// periodic sweep. Persistence across restart is documented as a future
// enhancement; mobile clients should treat a `serverInstanceId` change as
// a signal to abandon their cached job ids.

import 'dart:async';
import 'dart:math';

import 'package:skotiq_core/skotiq_core.dart';

/// Lifecycle states for a [Job]. Transitions:
///   queued  -> running -> succeeded | failed | cancelled
///   queued  -> cancelled (when cancelled before the executor picks it up)
enum JobState { queued, running, succeeded, failed, cancelled }

extension JobStateX on JobState {
  String get wireName => name;
  bool get isTerminal =>
      this == JobState.succeeded ||
      this == JobState.failed ||
      this == JobState.cancelled;
}

JobState? parseJobState(String raw) {
  for (final state in JobState.values) {
    if (state.name == raw) return state;
  }
  return null;
}

/// Snapshot of a single long-running operation. Instances are immutable;
/// mutation goes through [JobManager] which builds a new snapshot on each
/// state change.
class Job {
  /// UUID v4 assigned at registration time. Returned to the caller in the
  /// action POST response body and used as the URL path parameter for
  /// `GET /api/jobs/{jobId}` / `POST /api/jobs/{jobId}/cancel`.
  final String jobId;

  /// Dotted-path operation identifier, e.g. `focuser.autofocus`,
  /// `plate-solve`, `framing.center-on-target`. Used by clients that
  /// subscribe to a specific kind of work and by the operations-filtered
  /// `GET /api/jobs?operation=...` query.
  final String operation;

  /// Optional device id this job operates against. Used to derive a
  /// best-effort correlation between a job and the underlying driver's
  /// device-status events. Null for jobs that are not device-scoped
  /// (mosaic plan, polar alignment).
  final String? deviceId;

  /// correlation: the commandId returned in the action POST response
  /// body. Identical to [jobId] in the new flow (the job IS the command),
  /// but kept distinct in the model so a future refactor that decouples
  /// them does not require a wire change.
  final String? commandId;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// State machine position. Once terminal, [progress] and [error] are
  /// frozen and no further state changes are allowed.
  final JobState state;

  /// 0.0 .. 1.0 fractional progress when known, null when the operation
  /// has no measurable progress (e.g. a single-step plate solve).
  final double? progress;

  /// Free-form caller-visible progress message. Surfaced in mobile UI
  /// toasts and the dashboard's job-status panel.
  final String? progressMessage;

  /// Populated when [state] == succeeded. Contains the operation's result
  /// payload (autofocus best-position, plate-solve coordinates, etc.).
  /// Wire shape is operation-specific — clients dispatch on [operation].
  final Map<String, Object?>? result;

  /// Populated when [state] == failed or cancelled.
  /// Keys: `code` (stable identifier), `message` (caller-visible), and
  /// optional `details` (extra context).
  final Map<String, Object?>? error;

  const Job({
    required this.jobId,
    required this.operation,
    required this.deviceId,
    required this.commandId,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    this.progress,
    this.progressMessage,
    this.result,
    this.error,
  });

  Job _copyWith({
    DateTime? updatedAt,
    JobState? state,
    double? progress,
    String? progressMessage,
    Map<String, Object?>? result,
    Map<String, Object?>? error,
    bool clearProgress = false,
    bool clearProgressMessage = false,
  }) {
    return Job(
      jobId: jobId,
      operation: operation,
      deviceId: deviceId,
      commandId: commandId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      state: state ?? this.state,
      progress: clearProgress ? null : (progress ?? this.progress),
      progressMessage: clearProgressMessage
          ? null
          : (progressMessage ?? this.progressMessage),
      result: result ?? this.result,
      error: error ?? this.error,
    );
  }

  /// Wire-format JSON used by REST responses and WS event payloads.
  Map<String, Object?> toJson() => {
    'jobId': jobId,
    'operation': operation,
    if (deviceId != null) 'deviceId': deviceId,
    if (commandId != null) 'commandId': commandId,
    'state': state.wireName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (progress != null) 'progress': progress,
    if (progressMessage != null) 'progressMessage': progressMessage,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
  };
}

/// Caller-side sink the work callback writes progress updates to.
///
/// The sink is one-way: it pushes the progress through the manager's
/// state machine, which broadcasts a `JobProgress` event and updates the
/// stored [Job] snapshot. Calls after the job has terminated are silently
/// ignored — the work may not have noticed it was cancelled yet, and we
/// don't want a stale `update()` to overwrite the terminal state.
abstract class JobProgressSink {
  /// Push a progress update. [progress] must be in `[0.0, 1.0]` or null.
  /// [message] is free-form and may be null when only the percentage is
  /// known.
  void update(double? progress, String? message);
}

/// Cooperative cancellation token handed to the work callback. The work
/// must poll [isCancelled] (or race against [whenCancelled]) and abort
/// promptly when the flag is set; the manager cannot interrupt
/// blocking FFI/HTTP calls on its own.
abstract class JobCancellation {
  bool get isCancelled;

  /// Future that completes when cancellation is requested. The work can
  /// `Future.any([work, cancellation.whenCancelled])` to surface a
  /// `JobCancelled` exception promptly.
  Future<void> get whenCancelled;
}

/// Exception the work callback throws to signal cooperative cancellation.
/// Manager catches this and transitions the job to `cancelled` rather
/// than `failed`.
class JobCancelledException implements Exception {
  final String? reason;
  const JobCancelledException([this.reason]);

  @override
  String toString() => reason == null
      ? 'JobCancelledException'
      : 'JobCancelledException($reason)';
}

class _JobProgressSink implements JobProgressSink {
  final JobManager _manager;
  final String _jobId;
  _JobProgressSink(this._manager, this._jobId);

  @override
  void update(double? progress, String? message) {
    _manager._recordProgress(_jobId, progress, message);
  }
}

class _JobCancellation implements JobCancellation {
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Owner + dispatcher for long-running jobs.
///
/// Thread safety: the class assumes single-threaded access from the Dart
/// event loop. The `work` callback may await freely; manager mutations
/// happen synchronously between awaits so no two state transitions can
/// interleave.
class JobManager {
  /// Maximum age before a terminal job is purged from the in-memory
  /// store. Default 24h matches the audit's specification.
  final Duration retention;

  /// Pluggable clock used for [createdAt] / [updatedAt] / retention sweep.
  /// Tests inject a controllable clock; production uses [DateTime.now].
  final DateTime Function() _now;

  /// Sink the manager calls every time a [Job] mutates. Wired by the
  /// server to [HeadlessApiServer.broadcastEvent] so JobStarted /
  /// JobProgress / JobCompleted / JobFailed / JobCancelled events fan out
  /// to every WebSocket subscriber.
  final void Function(SkotiqEvent event) _emitEvent;

  /// Random source for UUID v4 generation. We avoid `package:uuid` so
  /// this module has no new dependency — RFC 4122 §4.4 is small enough
  /// to inline.
  final String Function() _generateJobId;

  final StreamController<Job> _changes = StreamController<Job>.broadcast(
    sync: true,
  );

  final Map<String, Job> _jobs = {};
  final Map<String, _JobCancellation> _cancellations = {};

  JobManager({
    required void Function(SkotiqEvent event) emitEvent,
    this.retention = const Duration(hours: 24),
    DateTime Function()? now,
    String Function()? generateJobId,
  }) : _emitEvent = emitEvent,
       _now = now ?? DateTime.now,
       _generateJobId = generateJobId ?? _defaultUuidV4Generator;

  /// Stream of [Job] snapshots emitted on every state change. Internal to
  /// the server (event broadcast is the public API); exposed for tests.
  Stream<Job> get changes => _changes.stream;

  /// Register a new job, broadcast `JobStarted`, schedule [work] on the
  /// event loop, and return the initial snapshot synchronously so the
  /// action handler can return `{jobId, status: queued}` immediately.
  ///
  /// The [work] callback receives:
  ///   * a [JobProgressSink] for incremental updates;
  ///   * a [JobCancellation] it must poll to honour client-side cancel.
  ///
  /// Returning a non-null map transitions the job to `succeeded` with
  /// that map as `result`. Throwing [JobCancelledException] transitions
  /// to `cancelled`. Any other exception transitions to `failed` with
  /// `error: {code: 'job_failed', message: e.toString()}`.
  Job start({
    required String operation,
    String? deviceId,
    String? commandId,
    required Future<Map<String, Object?>> Function(
      JobProgressSink sink,
      JobCancellation cancellation,
    )
    work,
  }) {
    final jobId = _generateJobId();
    final now = _now();
    final initial = Job(
      jobId: jobId,
      operation: operation,
      deviceId: deviceId,
      commandId: commandId ?? jobId,
      createdAt: now,
      updatedAt: now,
      state: JobState.queued,
    );
    _jobs[jobId] = initial;
    final cancellation = _JobCancellation();
    _cancellations[jobId] = cancellation;

    _emit('JobStarted', initial, severity: EventSeverity.info);
    _changes.add(initial);

    // Why scheduleMicrotask rather than unawaited(work(...)): scheduling
    // through the event loop guarantees the handler returns its
    // {jobId, status: queued} response BEFORE the work begins, so a
    // synchronous `work` body cannot accidentally race against the
    // response write. The transition from queued to running happens
    // inside _runWork once we're on the next microtask.
    scheduleMicrotask(() => _runWork(jobId, work, cancellation));

    return initial;
  }

  Future<void> _runWork(
    String jobId,
    Future<Map<String, Object?>> Function(JobProgressSink, JobCancellation)
    work,
    _JobCancellation cancellation,
  ) async {
    // The job may have been cancelled between start() and this microtask
    // (e.g. a fast `POST /jobs/{id}/cancel`). Honour the cancellation
    // before invoking work.
    if (cancellation.isCancelled) {
      _transitionCancelled(jobId, reason: 'cancelled_before_start');
      return;
    }

    final running = _jobs[jobId];
    if (running == null) {
      // Job was deleted before work started — nothing to do.
      return;
    }
    final running2 = running._copyWith(
      state: JobState.running,
      updatedAt: _now(),
    );
    _jobs[jobId] = running2;
    _emit('JobProgress', running2, severity: EventSeverity.info);
    _changes.add(running2);

    final sink = _JobProgressSink(this, jobId);
    try {
      final result = await work(sink, cancellation);
      // The work may finish AFTER cancellation was requested. If so,
      // honour the cancellation rather than reporting success — the user
      // explicitly asked for the operation to stop.
      if (cancellation.isCancelled) {
        _transitionCancelled(jobId, reason: 'cancelled_during_completion');
        return;
      }
      _transitionSucceeded(jobId, result);
    } on JobCancelledException catch (e) {
      _transitionCancelled(jobId, reason: e.reason);
    } catch (e) {
      _transitionFailed(
        jobId,
        code: 'job_failed',
        message: e.toString(),
        details: {'exceptionType': e.runtimeType.toString()},
      );
    }
  }

  void _recordProgress(String jobId, double? progress, String? message) {
    final job = _jobs[jobId];
    if (job == null) return;
    if (job.state.isTerminal) return;
    final updated = job._copyWith(
      updatedAt: _now(),
      progress: progress,
      progressMessage: message,
      clearProgress: progress == null,
      clearProgressMessage: message == null,
    );
    _jobs[jobId] = updated;
    _emit('JobProgress', updated, severity: EventSeverity.info);
    _changes.add(updated);
  }

  void _transitionSucceeded(String jobId, Map<String, Object?> result) {
    final job = _jobs[jobId];
    if (job == null || job.state.isTerminal) return;
    final updated = job._copyWith(
      state: JobState.succeeded,
      updatedAt: _now(),
      result: result,
      progress: 1.0,
    );
    _jobs[jobId] = updated;
    _cancellations.remove(jobId);
    _emit('JobCompleted', updated, severity: EventSeverity.info);
    _changes.add(updated);
  }

  void _transitionFailed(
    String jobId, {
    required String code,
    required String message,
    Map<String, Object?>? details,
  }) {
    final job = _jobs[jobId];
    if (job == null || job.state.isTerminal) return;
    final updated = job._copyWith(
      state: JobState.failed,
      updatedAt: _now(),
      error: {
        'code': code,
        'message': message,
        if (details != null) 'details': details,
      },
    );
    _jobs[jobId] = updated;
    _cancellations.remove(jobId);
    _emit('JobFailed', updated, severity: EventSeverity.error);
    _changes.add(updated);
  }

  void _transitionCancelled(String jobId, {String? reason}) {
    final job = _jobs[jobId];
    if (job == null || job.state.isTerminal) return;
    final updated = job._copyWith(
      state: JobState.cancelled,
      updatedAt: _now(),
      error: {
        'code': 'job_cancelled',
        'message': reason ?? 'Job was cancelled',
      },
    );
    _jobs[jobId] = updated;
    _cancellations.remove(jobId);
    _emit('JobCancelled', updated, severity: EventSeverity.warning);
    _changes.add(updated);
  }

  /// Lookup by id. Returns null when the job is unknown (already purged,
  /// or never registered).
  Job? get(String jobId) => _jobs[jobId];

  /// Filtered listing. Caller pre-filters by [state] / [operation] and
  /// applies a max [limit] (default 200) to keep responses bounded.
  /// Results are sorted newest-first by `updatedAt` so a phone polling
  /// `/api/jobs?state=running` sees the most recent work first.
  List<Job> list({JobState? state, String? operation, int limit = 200}) {
    final filtered = _jobs.values.where((j) {
      if (state != null && j.state != state) return false;
      if (operation != null && j.operation != operation) return false;
      return true;
    }).toList();
    filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (filtered.length > limit) {
      return filtered.sublist(0, limit);
    }
    return filtered;
  }

  /// Returns the current count of registered jobs (diagnostic).
  int get length => _jobs.length;

  /// Request cooperative cancellation. Returns the current snapshot when
  /// the request was honoured (the work will see [JobCancellation.isCancelled]
  /// on its next poll), null when the job is unknown, and throws
  /// [StateError] when the job is already terminal — the caller surfaces
  /// that as 409.
  Job? cancel(String jobId) {
    final job = _jobs[jobId];
    if (job == null) return null;
    if (job.state.isTerminal) {
      throw StateError('Job ${job.jobId} is already ${job.state.wireName}');
    }
    final cancellation = _cancellations[jobId];
    if (cancellation == null) {
      // Cancellation token was already collected (work raced ahead and
      // entered the terminal path between our state read and this line).
      // Re-read state and surface the same StateError contract.
      final fresh = _jobs[jobId];
      if (fresh != null && fresh.state.isTerminal) {
        throw StateError(
          'Job ${fresh.jobId} is already ${fresh.state.wireName}',
        );
      }
      // The job is non-terminal but has no cancellation token — a wiring bug.
      // Throw rather than reporting a cancel that cannot have happened.
      throw StateError(
        'Job $jobId has no cancellation token but is not terminal',
      );
    }
    cancellation.cancel();
    // Pre-running jobs flip straight to cancelled here so the response
    // body reflects the post-cancel state; running jobs continue until
    // the work polls the cancellation flag and exits cooperatively.
    if (job.state == JobState.queued) {
      _transitionCancelled(jobId, reason: 'cancelled_before_start');
    }
    return _jobs[jobId];
  }

  /// Remove a terminal job from the in-memory store. Returns true if the
  /// entry was removed, false when the id was unknown. Throws
  /// [StateError] when called on a non-terminal job — clearing a live
  /// job would orphan the work callback.
  bool purge(String jobId) {
    final job = _jobs[jobId];
    if (job == null) return false;
    if (!job.state.isTerminal) {
      throw StateError(
        'Cannot purge non-terminal job $jobId (state=${job.state.wireName})',
      );
    }
    _jobs.remove(jobId);
    return true;
  }

  /// Walk the table and drop terminal jobs older than [retention].
  /// Called from a periodic sweep started by [HeadlessApiServer.start].
  void evictExpired() {
    final cutoff = _now().subtract(retention);
    final stale = <String>[];
    _jobs.forEach((id, job) {
      if (job.state.isTerminal && job.updatedAt.isBefore(cutoff)) {
        stale.add(id);
      }
    });
    for (final id in stale) {
      _jobs.remove(id);
    }
  }

  /// Drop every retained entry. Used by tests and by
  /// [HeadlessApiServer.stop].
  void clear() {
    for (final cancellation in _cancellations.values) {
      cancellation.cancel();
    }
    _cancellations.clear();
    _jobs.clear();
  }

  /// Release the broadcast controller. After this the manager cannot be
  /// reused — call only from [HeadlessApiServer.stop].
  Future<void> dispose() async {
    clear();
    await _changes.close();
  }

  void _emit(String eventType, Job job, {required EventSeverity severity}) {
    final event = SkotiqEvent(
      timestamp: job.updatedAt.toUtc().millisecondsSinceEpoch,
      severity: severity,
      category: EventCategory.job,
      eventType: eventType,
      data: {
        'jobId': job.jobId,
        'operation': job.operation,
        if (job.deviceId != null) 'deviceId': job.deviceId,
        if (job.commandId != null) 'commandId': job.commandId,
        'state': job.state.wireName,
        if (job.progress != null) 'progress': job.progress,
        if (job.progressMessage != null) 'message': job.progressMessage,
        if (job.result != null) 'result': job.result,
        if (job.error != null) 'error': job.error,
      },
    );
    _emitEvent(event);
  }
}

/// Default RFC 4122 §4.4 UUID v4 generator. Mirrors the approach in
/// [CommandCorrelator] so jobIds and commandIds share a format.
String _defaultUuidV4Generator() {
  final rng = _secureRng;
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  String hex(int n) => n.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-'
      '${h.substring(20)}';
}

final Random _secureRng = Random.secure();
