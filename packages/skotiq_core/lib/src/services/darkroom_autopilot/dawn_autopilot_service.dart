/// The dawn autopilot: what happens between the last sub of the night and the
/// message that wakes the operator.
///
/// The integration half has already run by the time this starts — masters exist
/// as linear FITS in the library. This service owns the interpretation half:
/// queue a durable job, compose a first-draft recipe for every master, persist
/// it, render the draft the operator wakes up to, write the night report, hand
/// the artifacts to delivery, and send one honest morning message.
///
/// **The job row is the unit of work, not this object.** Every step is bounded
/// by a `darkroom_jobs` row that survives a force quit; the open-time crash
/// recovery re-queues a row a dead process left `running`, and [drainQueue]
/// picks it up on the next start. The inputs are re-derived from the session
/// each time, so a resumed job and a fresh job run the same code.
///
/// **Cancellation is two flags, not one.** A render is a single synchronous FFI
/// descent, so Dart can only ask the engine's loops to stop; [requestCancel]
/// raises the engine's flag AND this service's own, and the second one is what
/// stops the pipeline moving on to the next master after the engine has
/// released the first.
///
/// **Delivery never fails the job.** A destination that is unreachable at 4am
/// is a line in the morning report and a row in the journal; the masters and
/// the draft are already on the rig's own disk.
///
/// **A night report belongs to a pass, not to a job.** The copy handed to
/// delivery is named for the pass that wrote it and is never rewritten, so a
/// re-run after a crash delivers its own report instead of colliding with the
/// previous pass's copy at a shared name. The rig keeps a second copy under the
/// job's own name, and that is the one carrying the delivery and notification
/// outcomes the delivered copy was written too early to hold.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../database/daos/darkroom_jobs_dao.dart';
import '../../database/daos/integrated_masters_dao.dart';
import '../../database/daos/recipes_dao.dart';
import '../../database/daos/targets_dao.dart';
import '../../models/darkroom/darkroom_job.dart';
import '../../models/darkroom/delivery.dart';
import '../../models/darkroom/recipe.dart';
import '../darkroom_delivery/delivery_artifact.dart';
import '../darkroom_delivery/delivery_failure.dart';
import '../darkroom_delivery/delivery_service.dart';
import '../logging_service.dart';
import 'darkroom_seam.dart';
import 'dawn_draft_builder.dart';
import 'dawn_job_report.dart';
import 'dawn_master_resolver.dart';
import 'dawn_morning_notifier.dart';
import 'dawn_photometry.dart';

/// What one dawn job did.
class DawnJobOutcome {
  /// The `darkroom_jobs.id` this outcome belongs to.
  final int jobId;

  /// The job's final state.
  final DarkroomJobState state;

  /// The morning report, or null when the job stopped before one could be
  /// composed.
  final DawnJobReport? report;

  /// Absolute path of the night report the rig keeps, or null when none was
  /// written.
  ///
  /// This is the copy carrying the delivery and notification outcomes, not the
  /// per-pass copy delivery took — those are two files by design, and only
  /// this one is rewritten when a second pass runs.
  final String? reportPath;

  /// Why the job failed, or null when it did not.
  final String? failure;

  const DawnJobOutcome({
    required this.jobId,
    required this.state,
    required this.report,
    required this.reportPath,
    required this.failure,
  });

  /// True when the job ran to the end.
  bool get succeeded => state == DarkroomJobState.done;
}

/// The dawn pipeline stopped because cancellation was requested.
///
/// Distinct from a failure: the operator asked, and the job obeyed. It is
/// internal to the pipeline — callers read [DawnJobOutcome.state].
class _DawnCancelled implements Exception {
  final String where;

  const _DawnCancelled(this.where);

  @override
  String toString() => 'The dawn job stopped during $where on request';
}

/// A pass over this session is already queued or running, so a second one was
/// refused.
///
/// The Darkroom runs one pass per session: two over the same masters fight for
/// the render cache and for the one cancellation id a job's render is stopped
/// by, and a Stop can only reach one of them. Carries the live job so the
/// caller can name it rather than saying "busy".
class DarkroomSessionBusyException implements Exception {
  /// The session the caller asked for.
  final int sessionId;

  /// The `darkroom_jobs.id` already holding it.
  final int jobId;

  /// What that job is doing.
  final DarkroomJobState state;

  const DarkroomSessionBusyException({
    required this.sessionId,
    required this.jobId,
    required this.state,
  });

  /// The sentence a surface shows the operator.
  String get message => state == DarkroomJobState.running
      ? 'A Darkroom pass over this session is already running (job $jobId). '
            'Wait for it to finish, or stop it first.'
      : 'A Darkroom pass over this session is already queued (job $jobId) and '
            'starts on its own.';

  @override
  String toString() => message;
}

/// Orchestrates the dawn Darkroom pass over a night's masters.
class DawnAutopilotService {
  final DarkroomJobsDao _jobs;
  final RecipesDao _recipes;
  final IntegratedMastersDao _masters;
  final TargetsDao _targets;
  final DawnMasterResolver _resolver;
  final DawnDraftBuilder _drafts;
  final DarkroomSeam _darkroom;
  final DawnPhotometryResolver _photometry;
  final DeliveryService _delivery;
  final DawnMorningNotifier _notifier;
  final Future<String> Function() _outputDirectory;
  final LoggingService? _logger;
  final DateTime Function() _clock;

  /// Job ids the operator has asked to stop. Membership outlives any one
  /// native render, which is what stops the pipeline advancing to the next
  /// master after the engine has released its own flag.
  final Set<int> _cancelRequested = <int>{};

  /// The stage each running job is in, in the words the failure sentence uses.
  /// The catch-all cannot see where in the descent an exception came from, so
  /// the pipeline records where it is as it goes.
  final Map<int, String> _stage = <int, String>{};

  /// Serializes "is a pass already live for this session?" with the insert that
  /// answers it, so two requests arriving together cannot both read an empty
  /// queue. See [_enqueueOnePassPerSession].
  Future<void> _enqueueGate = Future<void>.value();

  /// Serializes the RUNS. Every job this process executes chains behind it, so
  /// one pass is live at a time whoever asked for it. See [_runSerialized].
  Future<void> _runGate = Future<void>.value();

  /// Job ids that have been handed to [_runSerialized] and have not come back —
  /// the one waiting its turn as well as the one running. [drainQueue] skips
  /// them so a row an explicit caller already owns is not started a second time
  /// while it sits in the queue table waiting for the gate.
  final Set<int> _submitted = <int>{};

  /// Set once the host has begun an orderly shutdown, and never cleared — the
  /// process is on its way out.
  ///
  /// It closes the race between a pass STARTING and the teardown looking for
  /// passes to hand back: `markRunning` is one UPDATE, so a job could commit
  /// its start just after [releaseRunningJobsForShutdown] read the queue, and
  /// the row would be left `running` for the crash recovery to charge. With
  /// this flag [runJob] refuses to take a row once the stop has begun, and
  /// hands back a row it took in the same instant.
  bool _stopping = false;

  /// How many times a state-mark write is retried after a refusal before the
  /// failure is let out.
  static const int _markRetryAttempts = 5;

  /// The first retry delay; it doubles on each further attempt, so five
  /// retries span a little under eight seconds in total.
  static const Duration _markRetryFirstDelay = Duration(milliseconds: 250);

  /// Longest error detail carried into the operator-facing failure text, and
  /// how that budget splits either side of the elision when it is exceeded.
  static const int _failureDetailLimit = 160;
  static const int _failureDetailHead = 100;
  static const int _failureDetailTail =
      _failureDetailLimit - _failureDetailHead - 1;

  DawnAutopilotService({
    required DarkroomJobsDao jobs,
    required RecipesDao recipes,
    required IntegratedMastersDao masters,
    required TargetsDao targets,
    required DawnMasterResolver resolver,
    required DawnDraftBuilder drafts,
    required DarkroomSeam darkroom,
    required DawnPhotometryResolver photometry,
    required DeliveryService delivery,
    required DawnMorningNotifier notifier,
    required Future<String> Function() outputDirectory,
    LoggingService? logger,
    DateTime Function()? clock,
  }) : _jobs = jobs,
       _recipes = recipes,
       _masters = masters,
       _targets = targets,
       _resolver = resolver,
       _drafts = drafts,
       _darkroom = darkroom,
       _photometry = photometry,
       _delivery = delivery,
       _notifier = notifier,
       _outputDirectory = outputDirectory,
       _logger = logger,
       _clock = clock ?? DateTime.now;

  /// The cancellation handle the native side knows [jobId] by.
  ///
  /// Derived from the job id alone so a restart can still stop a job it did not
  /// start: the id is in the durable row, not in this process's memory.
  static String renderIdFor(int jobId) => 'darkroom-job-$jobId';

  /// Queue and run the dawn pass for [sessionId].
  ///
  /// The job is `dawn`, so it sends the morning notification when it finishes.
  ///
  /// Throws [DarkroomSessionBusyException] when a pass over this session is
  /// already queued or running — see [_enqueueOnePassPerSession].
  Future<DawnJobOutcome> runDawnForSession(int sessionId) async {
    final jobId = await _enqueueOnePassPerSession(
      sessionId: sessionId,
      kind: DarkroomJobKind.dawn,
      note: 'Queued by the dawn autopilot',
    );
    return _runSerialized(jobId);
  }

  /// Queue and run an operator-requested pass over [sessionId] — the
  /// "process this session now" action.
  ///
  /// The job is `manual`, so it produces the same drafts, the same report and
  /// the same delivery, and sends NO morning notification: the operator is
  /// standing at the machine and does not need to be told what they just asked
  /// for.
  ///
  /// Throws [DarkroomSessionBusyException] when a pass over this session is
  /// already queued or running — see [_enqueueOnePassPerSession].
  Future<DawnJobOutcome> processSessionNow(int sessionId) async {
    final jobId = await _enqueueOnePassPerSession(
      sessionId: sessionId,
      kind: DarkroomJobKind.manual,
      note: 'Queued on request',
    );
    return _runSerialized(jobId);
  }

  /// Queue one pass over [sessionId], or refuse because one is already live.
  ///
  /// **The guard is the durable row, not a screen's latch.** Session Review
  /// kept a per-screen `_darkroomRunning` flag, so navigating away and back
  /// built a fresh screen state that offered "Process now" again while the
  /// first pass was still rendering. Two passes then ran over one session's
  /// masters — fighting for the render cache and for the one cancellation id
  /// [renderIdFor] derives per job — and a Stop, which finds the session's
  /// newest live job, halted one of them. `darkroom_jobs` is the only record
  /// both presses can see, and any surface that grows a "process now" button
  /// later reaches this method rather than re-deriving the rule.
  ///
  /// **Why the enqueues are serialized.** The check and the insert are two
  /// awaits, so two calls that arrive together could both read an empty queue
  /// before either wrote its row. Chaining them through [_enqueueGate] makes
  /// the pair atomic for this process — which is every caller, since the
  /// autopilot is a single service instance and a second process opening the
  /// same database is what the open-time crash recovery already forbids.
  Future<int> _enqueueOnePassPerSession({
    required int sessionId,
    required DarkroomJobKind kind,
    required String note,
  }) {
    final queued = _enqueueGate.then((_) async {
      final live = await liveJobsForSession(sessionId);
      if (live.isNotEmpty) {
        throw DarkroomSessionBusyException(
          sessionId: sessionId,
          jobId: live.first.id!,
          state: live.first.state,
        );
      }
      return _jobs.enqueue(
        sessionId: sessionId,
        kind: kind,
        note: note,
        createdAt: _clock(),
      );
    });
    // The gate advances whether the enqueue succeeded or was refused, so one
    // refusal does not strand every later request behind it.
    _enqueueGate = queued.then((_) {}, onError: (_) {});
    return queued;
  }

  /// Every non-terminal `darkroom_jobs` row for [sessionId], oldest first.
  ///
  /// The passes a Stop has to reach and the passes a new request has to refuse
  /// behind are the same set, so both read it from here.
  Future<List<DarkroomJob>> liveJobsForSession(int sessionId) async {
    final jobs = await _jobs.listForSession(sessionId);
    return [
      for (final job in jobs.reversed)
        if (job.id != null && !job.state.isTerminal) job,
    ];
  }

  /// Run [jobId] with at most one pass live in this process.
  ///
  /// **Every entry point comes through here.** The one-at-a-time rule was
  /// [drainQueue]'s alone: it ran its jobs in a loop, so the rows IT owned
  /// never overlapped, while [runDawnForSession] and [processSessionNow]
  /// enqueued and then called `runJob` straight away. The per-session guard in
  /// [_enqueueOnePassPerSession] stopped a second pass over the SAME session
  /// and nothing else, so a dawn pass over last night and a "Process now" over
  /// a different night ran side by side — measured on the release bundle, two
  /// rows held `running` for minutes and both wrote drafts into the same output
  /// directory. That is exactly what the rule exists to prevent: a single
  /// process-wide render cache the two passes evict each other out of.
  ///
  /// **The waiting job says so.** A queued row's `note` is what Session
  /// Review's banner reads back verbatim, so a submission that has to wait
  /// records its position there rather than sitting silently at `Queued on
  /// request` while another night renders.
  ///
  /// **Claimed, not just chained.** The id goes into [_submitted] before the
  /// gate is awaited, so [drainQueue] — which re-reads the `queued` table each
  /// pass — cannot pick up a row that is already waiting its turn here and run
  /// it a second time.
  Future<DawnJobOutcome> _runSerialized(int jobId) {
    _submitted.add(jobId);
    final ahead = _submitted.length - 1;
    late final Future<DawnJobOutcome> queued;
    queued = _runGate.then((_) async {
      try {
        return await runJob(jobId);
      } finally {
        _submitted.remove(jobId);
      }
    });
    // The gate advances on failure too, so one job that could not even be
    // recorded does not strand every later submission behind it.
    _runGate = queued.then((_) {}, onError: (_) {});
    if (ahead > 0) {
      // Best effort by design: the position is a courtesy on the row, and a
      // job must not fail to run because its note could not be written.
      unawaited(_noteQueuePosition(jobId, ahead));
    }
    return queued;
  }

  /// Record on the row that this pass is waiting for another to finish.
  Future<void> _noteQueuePosition(int jobId, int ahead) async {
    try {
      await _jobs.noteWhileQueued(
        jobId,
        ahead == 1
            ? 'Waiting for the Darkroom pass ahead of it to finish.'
            : 'Waiting for $ahead Darkroom passes ahead of it to finish.',
      );
    } catch (error) {
      _logger?.warning(
        'The queued Darkroom job could not record its position; it still runs '
        'in turn',
        source: 'DawnAutopilotService',
        fields: {'jobId': jobId, 'ahead': ahead, 'error': '$error'},
      );
    }
  }

  /// Run every queued job, oldest first.
  ///
  /// This is what picks up the rows the open-time crash recovery re-queued.
  /// Jobs run one at a time: two Darkroom renders over the same master would
  /// fight for the render cache and for the one cancellation id. The rule is
  /// [_runSerialized]'s now rather than this loop's, so it holds for the
  /// explicit callers too.
  ///
  /// **One job cannot end the drain.** Every job runs behind its own guard, so
  /// a row this process cannot even record the failure of — a database locked
  /// by another writer is the case that happens — costs that job and nothing
  /// else. The queue behind it still runs.
  ///
  /// **Every id is offered once.** A job whose run threw before it could leave
  /// `queued` is still the oldest queued row, so taking "the oldest" again
  /// would hand back the same job forever. The queue is re-read each pass and
  /// the first id not yet tried is taken, which keeps the oldest-first order,
  /// picks up anything enqueued while the drain ran, and leaves the row that
  /// could not start `queued` for the next open to recover.
  Future<List<DawnJobOutcome>> drainQueue() async {
    final outcomes = <DawnJobOutcome>[];
    final tried = <int>{};
    while (true) {
      // The host is leaving; the rest of the queue waits for the next start
      // rather than each row taking a start it cannot use.
      if (_stopping) break;
      int? next;
      for (final job in await _jobs.listByState(DarkroomJobState.queued)) {
        final id = job.id;
        // A row an explicit caller already submitted is running, or waiting its
        // turn behind the same gate this drain uses. Taking it again would run
        // one job twice.
        if (id == null || tried.contains(id) || _submitted.contains(id)) {
          continue;
        }
        next = id;
        break;
      }
      if (next == null) break;
      tried.add(next);
      try {
        outcomes.add(await _runSerialized(next));
      } catch (error, stack) {
        _logger?.error(
          'The dawn job could not be run or recorded; the rest of the queue '
          'still runs',
          source: 'DawnAutopilotService',
          fields: {'jobId': next, 'error': '$error', 'stack': '$stack'},
        );
      }
    }
    return outcomes;
  }

  /// Hand every job this process is running back to the queue because the host
  /// is shutting down on purpose. Returns the ids released.
  ///
  /// An orderly stop is not a crash, and the durable row is the only thing that
  /// can tell them apart at the next open. Left `running`, a row a SIGTERM
  /// walked away from is indistinguishable from one a kill -9 abandoned: the
  /// open-time recovery re-queues it and charges the attempt, so three ordinary
  /// service restarts during a dawn pass burned all three starts and FAILED the
  /// night's job — no drafts, no report, no delivery, and nothing to retry.
  ///
  /// So teardown calls this before the process exits. The row goes back to
  /// `queued` with the start returned, which the next launch drains and runs
  /// from the beginning of the pass. It does not wait for the render: the host
  /// is leaving, and the pass has no partial state worth saving. The executor
  /// still in flight discovers the row moved at its next progress write and
  /// returns without writing over this ([DarkroomJobNotRunningException]).
  ///
  /// Never throws — teardown runs on the way out and one refused row must not
  /// stop the rest of the shutdown. A row that could not be released stays
  /// `running` for the crash recovery, which is the pre-existing behaviour.
  Future<List<int>> releaseRunningJobsForShutdown() async {
    // Before the queue is read, so nothing new takes a row behind this pass.
    _stopping = true;
    final released = <int>[];
    List<DarkroomJob> running;
    try {
      running = await _jobs.listByState(DarkroomJobState.running);
    } catch (error) {
      _logger?.warning(
        'The Darkroom queue could not be read during shutdown; any running '
        'job is left for the next start to recover',
        source: 'DawnAutopilotService',
        fields: {'error': '$error'},
      );
      return released;
    }
    for (final job in running) {
      final id = job.id;
      if (id == null) continue;
      if (await _releaseForShutdown(id, attemptsBefore: job.attempts) != null) {
        released.add(id);
      }
    }
    return released;
  }

  /// Hand [jobId] back to the queue for an orderly stop, or answer null when
  /// the row was not this executor's to hand back.
  ///
  /// Null covers the benign race as well as a genuine refusal: the sweep and
  /// [runJob]'s post-start check can both reach the same row, and the second
  /// one finds it already `queued`. Only an unexpected refusal is logged as a
  /// warning; the row it could not move stays `running` for the crash
  /// recovery, which is the pre-existing behaviour.
  Future<DarkroomJob?> _releaseForShutdown(
    int jobId, {
    int? attemptsBefore,
  }) async {
    try {
      final handedBack = await _jobs.releaseForOrderlyStop(
        jobId,
        note:
            'Re-queued by an orderly shutdown while the pass was running. '
            'The start it took is given back, so stopping Skotiq does '
            'not count against the retry limit.',
      );
      _logger?.info(
        'The Darkroom pass was handed back to the queue for an orderly stop',
        source: 'DawnAutopilotService',
        fields: {
          'jobId': jobId,
          if (attemptsBefore != null) 'attemptsBefore': attemptsBefore,
        },
      );
      return handedBack;
    } on DarkroomJobNotRunningException {
      // Already handed back, or already finished. Either way nothing is owed.
      return null;
    } catch (error) {
      _logger?.warning(
        'The Darkroom pass could not be handed back during shutdown; it is '
        'left for the next start to recover',
        source: 'DawnAutopilotService',
        fields: {'jobId': jobId, 'error': '$error'},
      );
      return null;
    }
  }

  /// Ask [jobId] to stop.
  ///
  /// A queued job is cancelled outright — no executor holds it, so there is
  /// nothing to wait for. A running job has the engine's flag raised for its
  /// render id and this service's own flag set; the render stops at its next
  /// poll and the pipeline stops before the next master.
  Future<void> requestCancel(int jobId, {String? reason}) async {
    _cancelRequested.add(jobId);
    final job = await _jobs.getById(jobId);
    if (job == null) throw DarkroomJobMissingException(jobId);
    if (job.state.isTerminal) return;

    try {
      await _darkroom.cancel({'op': 'cancel', 'renderId': renderIdFor(jobId)});
    } on DarkroomSeamException catch (error) {
      // The engine could not take the flag. The service's own flag still
      // stops the pipeline between stages, so say what was lost rather than
      // reporting a clean stop: a render already inside Rust runs to its end.
      _logger?.warning(
        'The Darkroom engine did not take the cancellation flag; the job stops '
        'between stages instead of mid-render',
        source: 'DawnAutopilotService',
        fields: {'jobId': jobId, 'error': error.message},
      );
    }

    if (job.state == DarkroomJobState.queued) {
      await _jobs.markCancelled(
        jobId,
        reason: reason ?? 'Cancelled before the job started',
        now: _clock(),
      );
    }
  }

  /// Run the job [jobId] holds.
  ///
  /// Never throws: every ending — done, cancelled, failed — is recorded on the
  /// row and returned. A thrown pipeline would leave the row `running` with no
  /// executor, which the crash recovery would then re-queue as though the
  /// process had died.
  Future<DawnJobOutcome> runJob(int jobId) async {
    final job = await _jobs.getById(jobId);
    if (job == null) throw DarkroomJobMissingException(jobId);
    if (_stopping) {
      // The host is leaving. Taking the row now would spend a start on a pass
      // that cannot run, and leave it `running` for the crash recovery.
      return DawnJobOutcome(
        jobId: jobId,
        state: job.state,
        report: null,
        reportPath: null,
        failure: 'The host is shutting down; this pass was not started.',
      );
    }
    if (_cancelRequested.contains(jobId)) {
      final cancelled = await _jobs.markCancelled(
        jobId,
        reason: 'Cancelled before the job started',
        now: _clock(),
      );
      return DawnJobOutcome(
        jobId: jobId,
        state: cancelled.state,
        report: null,
        reportPath: null,
        failure: cancelled.errorText,
      );
    }

    // The row is taken BEFORE the inputs are checked, because a job with no
    // session is a spent attempt like any other: `queued` may only become
    // `running` or `cancelled`, and a failure that never ran would have to
    // pretend the job was never picked up.
    //
    // `markRunning` increments `attempts` and hands the row back, so its
    // reading is this pass's number — 1 for a job's first execution, 2 for the
    // one the crash recovery re-queued after a dead process left it `running`.
    // [_passReportName] names the report by it.
    final startedAt = _clock();
    final running = await _jobs.markRunning(jobId, now: startedAt);

    // The stop can land in the instant between the check above and this write.
    // The teardown's sweep would then have read the queue before this row said
    // `running`, and nothing else would ever hand it back — so the start is
    // returned here instead, by whichever of the two got there second.
    if (_stopping) {
      final handedBack = await _releaseForShutdown(jobId);
      return DawnJobOutcome(
        jobId: jobId,
        state: handedBack?.state ?? running.state,
        report: null,
        reportPath: null,
        failure: 'The host is shutting down; this pass was not started.',
      );
    }

    _stage[jobId] = 'reading the job row';
    final sessionId = job.sessionId;
    if (sessionId == null) {
      final failed = await _markFailed(
        jobId,
        'This job names no imaging session, so there is nothing to process',
      );
      return DawnJobOutcome(
        jobId: jobId,
        state: failed.state,
        report: null,
        reportPath: null,
        failure: failed.errorText,
      );
    }

    try {
      return await _drive(
        jobId: jobId,
        kind: job.kind,
        sessionId: sessionId,
        startedAt: startedAt,
        pass: running.attempts,
      );
    } on _DawnCancelled catch (stop) {
      final cancelled = await _jobs.markCancelled(
        jobId,
        reason: 'Stopped on request during ${stop.where}',
        now: _clock(),
      );
      return DawnJobOutcome(
        jobId: jobId,
        state: cancelled.state,
        report: null,
        reportPath: null,
        failure: cancelled.errorText,
      );
    } on DarkroomCancelledOutcome catch (stop) {
      final cancelled = await _jobs.markCancelled(
        jobId,
        reason: 'Stopped on request during the ${stop.phase} phase',
        now: _clock(),
      );
      return DawnJobOutcome(
        jobId: jobId,
        state: cancelled.state,
        report: null,
        reportPath: null,
        failure: cancelled.errorText,
      );
    } on DarkroomJobNotRunningException catch (lost) {
      // Something else moved the row out from under this executor. Report it;
      // do not write over whatever decided the job's fate.
      _logger?.warning(
        'The dawn job left this executor before it finished',
        source: 'DawnAutopilotService',
        fields: {'jobId': jobId, 'state': lost.state.wire},
      );
      return DawnJobOutcome(
        jobId: jobId,
        state: lost.state,
        report: null,
        reportPath: null,
        failure: '$lost',
      );
    } catch (error, stack) {
      final stage = _stage[jobId] ?? 'running the dawn pass';
      // The exception, its type and its stack go here — the log is where a
      // `SqliteException` with its causing statement belongs. The row gets the
      // sentence below, which names the stage that stopped.
      _logger?.error(
        'The dawn job failed while $stage',
        source: 'DawnAutopilotService',
        fields: {
          'jobId': jobId,
          'stage': stage,
          'errorType': error.runtimeType.toString(),
          'error': '$error',
          'stack': '$stack',
        },
      );
      final failed = await _markFailed(jobId, _failureSentence(stage, error));
      return DawnJobOutcome(
        jobId: jobId,
        state: failed.state,
        report: null,
        reportPath: null,
        failure: failed.errorText,
      );
    } finally {
      _cancelRequested.remove(jobId);
      _stage.remove(jobId);
    }
  }

  /// The operator-facing sentence for a stopped job: the stage that stopped,
  /// and the error's own opening line.
  ///
  /// Only the first line, and only up to [_failureDetailLimit] characters of
  /// it. A raw `SqliteException` carries its causing SQL statement and every
  /// bound parameter on the following lines, which is diagnostic text for the
  /// log, not something to hand an operator reading a job row at 7am. The whole
  /// exception is logged beside this, so nothing is lost.
  ///
  /// An over-long line is elided in the MIDDLE, not cut off at the end: the
  /// head carries the exception's own name and the tail carries what a message
  /// built around a long path ends with — `(OS Error: Permission denied)` —
  /// which is the half that says what to do about it.
  static String _failureSentence(String stage, Object error) {
    final first = '$error'.split('\n').first.trim();
    final detail = first.length <= _failureDetailLimit
        ? first
        : '${first.substring(0, _failureDetailHead)}…'
              '${first.substring(first.length - _failureDetailTail)}';
    if (detail.isEmpty) {
      return 'The dawn pass stopped while $stage; the log records the error.';
    }
    return 'The dawn pass stopped while $stage: $detail. '
        'The log records the full error.';
  }

  /// Fail [jobId] with [errorText], retrying the write while it is refused.
  ///
  /// The mark is the only record that the attempt ended. A transient refusal —
  /// another writer holding the database — would otherwise leave the row
  /// `running` with an empty error for as long as this process lives, which
  /// reads exactly like a job still working.
  Future<DarkroomJob> _markFailed(int jobId, String errorText) =>
      _withWriteRetry(
        jobId,
        'record the failure',
        () => _jobs.markFailed(jobId, errorText, now: _clock()),
      );

  /// Finish [jobId], retrying the write while it is refused — the same reason
  /// as [_markFailed]: a finished job left `running` is a job the operator is
  /// told is still going.
  Future<DarkroomJob> _markDone(int jobId, String note) => _withWriteRetry(
    jobId,
    'record the completion',
    () => _jobs.markDone(jobId, note: note, now: _clock()),
  );

  /// Run [write], retrying a refusal a bounded number of times with a doubling
  /// delay, then letting the last failure out.
  ///
  /// The bound is what makes this honest: the write is retried, never assumed.
  /// When every attempt is refused the caller still sees the exception and the
  /// row keeps whatever state it had, which the open-time crash recovery picks
  /// up on the next start.
  Future<T> _withWriteRetry<T>(
    int jobId,
    String what,
    Future<T> Function() write,
  ) async {
    var delay = _markRetryFirstDelay;
    for (var attempt = 1; ; attempt++) {
      try {
        return await write();
      } on DarkroomJobMissingException {
        rethrow;
      } on DarkroomJobTransitionException {
        rethrow;
      } catch (error) {
        if (attempt > _markRetryAttempts) {
          _logger?.error(
            'The dawn job could not $what after $attempt attempts; the row '
            'keeps its current state for the next start to recover',
            source: 'DawnAutopilotService',
            fields: {'jobId': jobId, 'error': '$error'},
          );
          rethrow;
        }
        _logger?.warning(
          'The dawn job could not $what; retrying',
          source: 'DawnAutopilotService',
          fields: {
            'jobId': jobId,
            'attempt': attempt,
            'retryInMs': delay.inMilliseconds,
            'error': '$error',
          },
        );
        await Future<void>.delayed(delay);
        delay *= 2;
      }
    }
  }

  Future<DawnJobOutcome> _drive({
    required int jobId,
    required DarkroomJobKind kind,
    required int sessionId,
    required DateTime startedAt,
    required int pass,
  }) async {
    final renderId = renderIdFor(jobId);
    _stopIfCancelled(jobId, 'the master lookup');

    _stage[jobId] = "looking up the night's masters";
    final set = await _resolver.resolve(sessionId);
    _stage[jobId] = 'preparing the Darkroom output directory';
    final baseDirectory = await _darkroomDirectory();

    var reports = <DawnMasterReport>[];

    for (var index = 0; index < set.masters.length; index++) {
      _stopIfCancelled(jobId, 'master ${index + 1} of ${set.masters.length}');
      final master = set.masters[index];
      await _reportProgress(
        jobId,
        // Drafting occupies the first four fifths of the job; delivery and the
        // report take the rest.
        0.8 * index / (set.masters.isEmpty ? 1 : set.masters.length),
        'Drafting ${master.name}',
      );
      reports.add(
        await _draftOneMaster(
          jobId: jobId,
          sessionId: sessionId,
          master: master,
          renderId: renderId,
          directory: baseDirectory,
        ),
      );
    }

    // PER-MASTER ACCOUNTING, IN TWO READINGS. Only the masters whose pixels
    // this pass actually read go to a destination; a truncated or vanished FITS
    // is excluded and named in the report, because copying it out would put a
    // file the pipeline has just called unreadable in the operator's hands
    // under the name of the night's result. The excluded master costs nobody
    // else's draft: the rest of the set still delivers.
    //
    // `pixelsWereRead` is the reading taken while the draft was composed, which
    // is minutes before anything is copied. `_stageForDelivery` takes the
    // second reading, of the files as they are NOW, and withholds any master
    // that is no longer the file this pass measured. It runs HERE, before the
    // night report is written, because that report is itself one of the
    // delivered artifacts and has to carry the exclusion it caused; the instant
    // between this reading and the copy is covered by every transport verifying
    // what landed against the checksum this reading took.
    final staging = await _stageForDelivery(jobId, reports);
    reports = staging.reports;

    final linearMasters = <String>[
      for (final master in reports)
        if (master.deliverable) master.master.masterFitsPath,
    ];
    final draftRenders = <String>[
      for (final master in reports)
        if (master.draftRenderPath != null) master.draftRenderPath!,
    ];
    final excluded = <String>[
      for (final master in reports)
        if (master.notDeliveredBecause != null)
          '${master.master.name} was not delivered: '
              '${master.notDeliveredBecause}.',
    ];

    _stopIfCancelled(jobId, 'the night report');
    await _reportProgress(jobId, 0.85, 'Writing the night report');

    // THE COPY DELIVERY ITSELF SHIPS, UNDER THIS PASS'S OWN NAME. The night
    // report is one of the delivered artifacts, so it has to be on disk before
    // delivery runs — which means this copy can never carry delivery's own
    // outcome, nor the notification that follows it. The rig's copy
    // ([_rigReportName]) carries both, and is a different file: this one is
    // never rewritten, because delivery reads it again on every retry and
    // verifies what landed against the checksum it took from these bytes.
    //
    // It therefore states the gap instead of implying one. `running` was the
    // row's word borrowed for a moment the row's vocabulary cannot describe:
    // printed beside a `finishedAt` and two null outcome blocks it read as a
    // job that had stopped without finishing — the one thing that had not
    // happened — while the headline over it announced the drafts as ready.
    // `delivering` plus `pending` says what is true: the drafting is over,
    // these are its masters and drafts, the copying is still going, and the
    // rig's copy carries how it ended.
    var report = DawnJobReport(
      jobId: jobId,
      kind: kind.wire,
      sessionId: sessionId,
      startedAt: startedAt,
      finishedAt: _clock(),
      state: DawnJobReport.deliveringState,
      masters: reports,
      withoutFile: set.withoutFile,
      delivery: null,
      deliveryProblems: excluded,
      notification: null,
      failure: null,
      pending: DawnReportPending.beforeDelivery,
    );
    final reportPath = await _writeReport(
      baseDirectory,
      _passReportName(jobId, pass),
      report,
    );

    _stopIfCancelled(jobId, 'delivery');
    await _reportProgress(jobId, 0.9, 'Delivering the night');
    final delivered = await _deliver(
      jobId: jobId,
      linearMasters: linearMasters,
      draftRenders: draftRenders,
      reportPath: reportPath,
      described: staging.verified,
    );

    // A stop that landed WHILE delivery was running ends the job here, as the
    // stop it is. `_stopIfCancelled` above only covers the instant before the
    // pass starts; a stop that arrived while the files were being copied used
    // to fall straight through to `done`, so the row, the report and the
    // morning notification all announced a finished night over a delivery the
    // operator had halted part-way. The report is still written — with the
    // delivery counts, so what is outstanding is on the record — and the row
    // is marked cancelled rather than done. Nothing is lost: the files the
    // pass did not reach are owed in the journal and the retry sweep takes
    // them.
    if (_cancelRequested.contains(jobId)) {
      final pending = delivered.report?.stoppedPending ?? 0;
      final stoppedBecause = pending == 0
          ? 'Stopped on request during delivery.'
          : 'Stopped on request during delivery; $pending file'
                '${pending == 1 ? '' : 's'} are still owed and the retry '
                'sweep resumes them.';
      final stoppedReport = DawnJobReport(
        jobId: jobId,
        kind: kind.wire,
        sessionId: sessionId,
        startedAt: startedAt,
        finishedAt: _clock(),
        state: DarkroomJobState.cancelled.wire,
        masters: reports,
        withoutFile: set.withoutFile,
        delivery: delivered.report,
        deliveryProblems: [...excluded, ...delivered.problems],
        notification: null,
        failure: stoppedBecause,
      );
      final stoppedPath = await _writeReport(
        baseDirectory,
        _rigReportName(jobId),
        stoppedReport,
      );
      final cancelled = await _jobs.markCancelled(
        jobId,
        reason: stoppedBecause,
        now: _clock(),
      );
      return DawnJobOutcome(
        jobId: jobId,
        state: cancelled.state,
        report: stoppedReport,
        reportPath: stoppedPath,
        failure: cancelled.errorText,
      );
    }

    report = DawnJobReport(
      jobId: jobId,
      kind: kind.wire,
      sessionId: sessionId,
      startedAt: startedAt,
      finishedAt: _clock(),
      state: DarkroomJobState.done.wire,
      masters: reports,
      withoutFile: set.withoutFile,
      delivery: delivered.report,
      deliveryProblems: [...excluded, ...delivered.problems],
      notification: null,
      failure: null,
    );

    // A pass that rendered NO draft did not do the thing a Darkroom pass is
    // for, so it does not end `done`. Recorded as `done` with an empty
    // `error_text` the outcome was invisible everywhere: the Session Review
    // banner paints only an ending the operator has to act on, so a night whose
    // masters were all unreadable read as "a clean night — no problems
    // detected" with nothing on the screen saying the drafting and the delivery
    // had not produced a draft. Ending it `failed` is what puts the reason on
    // the row, in the banner, and in the report — and no queue re-runs it,
    // because `drainQueue` only takes rows still `queued`.
    final zeroDraft = report.draftsRendered == 0
        ? _zeroDraftFailure(report)
        : null;
    if (zeroDraft != null) {
      report = report.withEnding(
        state: DarkroomJobState.failed.wire,
        failure: zeroDraft,
      );
    }

    await _reportProgress(jobId, 0.95, 'Sending the morning report');
    // The morning notification still goes out on a zero-draft pass: its
    // headline is already written for the empty hand ("no draft was rendered"),
    // and the pass the operator most needs told about is the one that produced
    // nothing.
    final decision = kind == DarkroomJobKind.dawn
        ? await _announce(jobId, report)
        : const DawnNotificationDecision(
            sent: false,
            reason:
                'This pass was started by hand, so it does not send a morning '
                'notification.',
          );

    report = DawnJobReport(
      jobId: jobId,
      kind: kind.wire,
      sessionId: sessionId,
      startedAt: startedAt,
      finishedAt: _clock(),
      state: zeroDraft == null
          ? DarkroomJobState.done.wire
          : DarkroomJobState.failed.wire,
      masters: reports,
      withoutFile: set.withoutFile,
      delivery: delivered.report,
      deliveryProblems: [...excluded, ...delivered.problems],
      notification: decision,
      failure: zeroDraft,
    );

    // The row is closed BEFORE the report that announces the ending is
    // written. The report is the artifact the operator reads; a report saying
    // `done` over a row that never got there is a contradiction they have no
    // way to resolve. When the mark cannot be made the report is rewritten as
    // the stop it is, and the failure path records it.
    _stage[jobId] = 'closing the job row';
    try {
      if (zeroDraft == null) {
        await _markDone(jobId, _completionNote(report));
      } else {
        // `markFailed` writes no note, and the row's note still names the last
        // stage that ran ("Sending the morning report") — which the Session
        // Review banner reads as the stage that stopped. The completion note
        // goes on while the row is still `running`, at the progress the attempt
        // actually reached, so the banner's second sentence is the ending.
        await _jobs.updateProgress(jobId, 0.95, note: _completionNote(report));
        await _markFailed(jobId, zeroDraft);
      }
    } catch (error) {
      await _writeReport(
        baseDirectory,
        _rigReportName(jobId),
        report.withEnding(
          state: DarkroomJobState.failed.wire,
          failure: _failureSentence('closing the job row', error),
        ),
      );
      rethrow;
    }
    // The rig's copy, carrying the two outcomes the delivered copy was written
    // too early to hold. It is a different file from the one delivery took,
    // and delivery is never handed this name — which is why the delivered copy
    // can name this one as where its `delivery` and `notification` blocks live
    // without the two ever fighting over one set of bytes.
    final finalPath = await _writeReport(
      baseDirectory,
      _rigReportName(jobId),
      report,
    );

    return DawnJobOutcome(
      jobId: jobId,
      state: zeroDraft == null
          ? DarkroomJobState.done
          : DarkroomJobState.failed,
      report: report,
      reportPath: finalPath,
      failure: zeroDraft,
    );
  }

  /// Why a pass that rendered no draft ended where it did, built only from
  /// reasons already on the record.
  ///
  /// Each master carries the failure that stopped its own draft and the
  /// resolver names every master it could not hand over a file for; those
  /// sentences are the reason, so the ending repeats them rather than composing
  /// a cause of its own. When neither has anything to say — a session with no
  /// integrated master at all — that is what it says.
  static String _zeroDraftFailure(DawnJobReport report) {
    final reasons = <String>[
      for (final master in report.masters)
        if (master.failure != null) '${master.master.name}: ${master.failure}',
      for (final missing in report.withoutFile)
        '${missing.name}: ${missing.reason}',
    ];
    if (reasons.isEmpty) {
      return 'The Darkroom pass rendered no draft. This night has no '
          'integrated master to draft from — integrate it in Session Review, '
          'then run the pass again.';
    }
    return 'The Darkroom pass rendered no draft: ${reasons.join('; ')}.';
  }

  /// Compose, persist and render one master's first draft.
  ///
  /// A master that cannot be drafted produces a report line naming the reason
  /// and the job continues: one unreadable master must not cost the operator
  /// the drafts of every other filter. Whether the master itself is delivered
  /// is decided by the caller from [DawnMasterReport.deliverable], never here —
  /// this method's business is the draft. What it does contribute to that
  /// decision is [DawnMasterReport.sourceAtRead]: the file as it stood at the
  /// instant these pixels were read, which delivery staging compares against.
  Future<DawnMasterReport> _draftOneMaster({
    required int jobId,
    required int sessionId,
    required DawnMaster master,
    required String renderId,
    required String directory,
  }) async {
    final row = await _masters.getById(master.masterId);
    final stats = row == null
        ? DawnMasterStats.unrecorded
        : DawnMasterStats.parse(row.statsJson);
    final targetName = await _targetName(master.targetId);

    // The file as it is at the moment the pass is about to read its pixels —
    // size, modification time and the SHA-256 of the bytes. Delivery stages the
    // same path minutes later and compares the two; see `_stageForDelivery`.
    //
    // A master whose bytes cannot be read here still gets its draft attempted,
    // because the engine reads the file itself and its failure is the more
    // precise sentence. What is lost is the identity to compare against, so the
    // reading is recorded as absent and staging says exactly that rather than
    // delivering an unchecked file.
    DawnSourceStat? sourceAtRead;
    try {
      sourceAtRead = await DawnSourceStat.of(master.masterFitsPath);
    } on DeliveryFailure catch (failure) {
      _logger?.warning(
        'A master could not be read to record what the pass drafted from, so '
        'delivery has nothing to check it against',
        source: 'DawnAutopilotService',
        fields: {
          'jobId': jobId,
          'master': master.name,
          'path': master.masterFitsPath,
          'error': failure.message,
        },
      );
    }

    DawnMasterReport failed(String reason) => DawnMasterReport(
      master: master,
      targetName: targetName,
      stats: stats,
      draft: null,
      recipeId: null,
      draftRenderPath: null,
      failure: reason,
      sourceAtRead: sourceAtRead,
    );

    final photometry = row == null
        ? const DawnPhotometry.unavailable(
            'the master library row is gone, so its astrometry cannot be read',
          )
        : await _photometry.resolve(
            master: master,
            wcs: overlayFromMasterWcs(
              crval1: row.wcsCrval1,
              crval2: row.wcsCrval2,
              crpix1: row.wcsCrpix1,
              crpix2: row.wcsCrpix2,
              cd11: row.wcsCd1_1,
              cd12: row.wcsCd1_2,
              cd21: row.wcsCd2_1,
              cd22: row.wcsCd2_2,
            ),
          );

    final DawnDraft draft;
    try {
      draft = await _drafts.build(
        master: master,
        recipeId: 'job-$jobId-master-${master.masterId}',
        photometry: photometry,
        renderId: renderId,
      );
    } on DawnDraftException catch (error) {
      return failed(error.message);
    } on DarkroomSeamException catch (error) {
      return failed(error.message);
    }

    if (draft.isEmpty) {
      return DawnMasterReport(
        master: master,
        targetName: targetName,
        stats: stats,
        draft: draft,
        recipeId: null,
        draftRenderPath: null,
        failure:
            'no operation in this build could be measured from these pixels, '
            'so the draft would have been an empty stack',
        sourceAtRead: sourceAtRead,
      );
    }

    final recipeId = await _persistDraftRecipe(
      sessionId: sessionId,
      master: master,
      name: _draftName(targetName: targetName, master: master),
      stepsJson: draft.encodeStepsJson(),
      draftNotes: draft.notes,
    );

    final draftPath = p.join(
      directory,
      'job_${jobId}_master_${master.masterId}_draft.jpg',
    );
    try {
      await _darkroom.renderExport(
        recipeJson: draft.encodeRecipeJson('$recipeId'),
        args: {
          'masterPath': master.masterFitsPath,
          'renderId': renderId,
          'stage': {'kind': 'final'},
          'outputs': [
            {'format': 'jpeg', 'path': draftPath, 'quality': 92},
          ],
          'sidecarPath': '$draftPath.skrecipe',
          'writeSidecar': true,
          // A draft whose stack never left the linear stage has no display
          // mapping of its own; this asks the engine for its own auto stretch
          // and the reply states that it did so. It changes nothing when the
          // draft ends stretched, which is the normal case.
          'screenTransfer': true,
          'catalogStars': photometry.stars,
        },
      );
    } on DarkroomSeamException catch (error) {
      return DawnMasterReport(
        master: master,
        targetName: targetName,
        stats: stats,
        draft: draft,
        recipeId: recipeId,
        draftRenderPath: null,
        failure:
            'the recipe was saved but the draft image could not be rendered: '
            '${error.message}',
        sourceAtRead: sourceAtRead,
      );
    }

    return DawnMasterReport(
      master: master,
      targetName: targetName,
      stats: stats,
      draft: draft,
      recipeId: recipeId,
      draftRenderPath: draftPath,
      failure: null,
      sourceAtRead: sourceAtRead,
    );
  }

  /// The name a first draft carries, from the target and the filter it covers.
  ///
  /// A library where every autopilot row reads `Draft` is a library the
  /// operator cannot pick a night out of. The target names the field and the
  /// filter names the channel; with no target row the master's own name
  /// already carries the filter, so it is used whole rather than repeated.
  static String _draftName({
    required String? targetName,
    required DawnMaster master,
  }) {
    final target = targetName?.trim();
    if (target == null || target.isEmpty) return '${master.name} draft';
    final filter = master.filter?.trim();
    if (filter == null || filter.isEmpty) return '$target draft';
    return '$target $filter draft';
  }

  /// Write this pass's draft for [master], superseding the row a dead attempt
  /// left behind rather than adding a second one.
  ///
  /// **Why supersede and not delete.** The recipes table records no job id, so
  /// "the rows the dead attempt created" can only be identified by what they
  /// are: the autopilot's own root draft over this master, for this session.
  /// That row is re-derived from the same master by the resumed attempt, so
  /// rewriting its steps says exactly what happened — one draft per master,
  /// carrying this attempt's measurements. Deleting instead would break every
  /// deep link the earlier attempt's notification already sent, and
  /// [RecipesDao.deleteRecipe] refuses a row with branches anyway.
  ///
  /// **A branched row is never touched.** Once the operator has branched from a
  /// draft, its step list is the base their branch's `divergence_index` counts
  /// into; rewriting it would leave the branch describing a lineage that never
  /// happened. Those get a fresh row, which is the honest record of a second
  /// draft existing.
  ///
  /// The write is three statements — the steps, the name, then the draft's own
  /// account — because the DAO exposes them separately and none is worth a
  /// transaction the DAO does not offer: the steps are what the draft IS, and a
  /// name or an account that lags them by a statement is describing the same
  /// pass a moment later.
  ///
  /// [draftNotes] rides with the row rather than only into the night report.
  /// The report is a file on disk that the editor never opens, so until this
  /// was persisted the dawn draft arrived in the Darkroom with every reason it
  /// had recorded — including why a mono master got no colour calibration —
  /// stripped off.
  Future<int> _persistDraftRecipe({
    required int sessionId,
    required DawnMaster master,
    required String name,
    required String stepsJson,
    required List<DawnDraftNote> draftNotes,
  }) async {
    final now = _clock();
    for (final existing in await _recipes.listForMaster(
      master.masterFitsPath,
    )) {
      final id = existing.id;
      if (id == null) continue;
      if (existing.createdBy != RecipeAuthor.autopilot) continue;
      if (existing.sessionId != sessionId) continue;
      if (existing.parentRecipeId != null) continue;
      if ((await _recipes.childrenOf(id)).isNotEmpty) continue;
      await _recipes.updateSteps(
        id,
        stepsJson,
        schemaVersion: kRecipeSchemaVersion,
        now: now,
      );
      await _recipes.rename(id, name, now: now);
      await _recipes.setDraftNotes(id, _recipeNotes(draftNotes), now: now);
      return id;
    }
    return _recipes.create(
      targetId: master.targetId,
      sessionId: sessionId,
      masterId: master.masterId,
      baseMasterPath: master.masterFitsPath,
      name: name,
      stepsJson: stepsJson,
      createdBy: RecipeAuthor.autopilot,
      draftNotes: _recipeNotes(draftNotes),
      schemaVersion: kRecipeSchemaVersion,
      createdAt: now,
    );
  }

  /// The draft's account in the shape the recipe row stores.
  ///
  /// Every note is carried, `included` ones as well: the account is the record
  /// of what the composing pass DECIDED, and a row that carries one is a row
  /// the registry composed — which is how the editor can say a stack was
  /// drafted rather than written by hand, however many operations it left out.
  static List<RecipeDraftNote> _recipeNotes(List<DawnDraftNote> notes) => [
    for (final note in notes)
      RecipeDraftNote(
        opId: note.opId,
        outcome: note.outcome,
        reason: note.reason,
      ),
  ];

  /// Take the second reading of every master this pass would deliver, and
  /// withhold the ones that are no longer the file the pass measured.
  ///
  /// **Why a second reading exists at all.** The draft stage opens a master,
  /// reads its pixels and composes from them; delivery copies the bytes that
  /// are on disk when it runs, which is a separate instant. Between the two the
  /// file can be truncated, replaced or removed — by a disk filling up, by an
  /// operator tidying a captures folder, by a sync tool — and the pass's draft
  /// verdict says nothing about that. Without this reading such a master rode
  /// out under the night's name with a checksum of bytes nothing had measured,
  /// and the report called the delivery clean.
  ///
  /// **What counts as changed.** The bytes. Size and modification time are
  /// checked first because they are free and because a difference in either
  /// already proves the file changed — but they are metadata a writer chooses,
  /// and a same-sized replacement under a restored mtime (`rsync --times`,
  /// `cp -p`, a restore, a two-second-granularity share) matched on both while
  /// carrying another master's pixels. So when the metadata agrees the SHA-256
  /// the draft stage recorded is compared against the file as it stands now,
  /// and that is the comparison the verdict turns on. A master that cannot be
  /// stat-ed, or whose bytes cannot be read, in either reading is named for
  /// that instead of being guessed at.
  ///
  /// Only masters the draft stage already cleared are read again: one that
  /// failed there is out for its own reason and re-reading it would replace a
  /// precise sentence with a vaguer one.
  ///
  /// **The hash is taken once.** A master that clears this check is returned as
  /// a described [DeliveryFile] carrying the digest just computed, and [_deliver]
  /// takes it instead of hashing the same bytes a second time. So the content
  /// check costs one extra streamed read per master over the whole pass, not
  /// two. Measured on this machine with `sha256OfFile` compiled AOT: 0.16 GB/s
  /// — 48 ms for an 8.3 MB master, 770 ms for a 132.7 MB one, about 25 s for a
  /// 4 GB one, against a pass that spends minutes rendering each of them.
  Future<({List<DawnMasterReport> reports, Map<String, DeliveryFile> verified})>
  _stageForDelivery(int jobId, List<DawnMasterReport> reports) async {
    final staged = <DawnMasterReport>[];
    final verified = <String, DeliveryFile>{};
    for (final report in reports) {
      if (!report.pixelsWereRead) {
        staged.add(report);
        continue;
      }
      final path = report.master.masterFitsPath;
      final atRead = report.sourceAtRead;
      final metadata = await FileStat.stat(path);
      final outcome = await _stageOneMaster(
        path: path,
        atRead: atRead,
        metadata: metadata,
      );
      final refusal = outcome.refusal;
      if (refusal == null) {
        final file = outcome.file;
        if (file != null) verified[path] = file;
        staged.add(report);
        continue;
      }
      _logger?.warning(
        'A master changed between the draft that measured it and delivery, so '
        'it is withheld from every destination',
        source: 'DawnAutopilotService',
        fields: {
          'jobId': jobId,
          'master': report.master.name,
          'path': path,
          'bytesAtRead': atRead?.bytes,
          'digestAtRead': atRead?.digest,
          'bytesAtStaging': metadata.type == FileSystemEntityType.notFound
              ? null
              : metadata.size,
          'reason': refusal,
        },
      );
      staged.add(report.withheldAtStaging(refusal));
    }
    return (reports: staged, verified: verified);
  }

  /// Read one master again: why it may not be delivered, or the described file
  /// delivery should take when it may.
  ///
  /// [metadata] is the free reading; the bytes are only hashed when it agrees
  /// with [atRead], since a metadata difference has already settled the
  /// question and hashing a 4 GB master to confirm it would cost seconds for
  /// nothing. When the hash is taken it is returned as a [DeliveryFile] so the
  /// delivery stage does not read the same bytes again.
  Future<({String? refusal, DeliveryFile? file})> _stageOneMaster({
    required String path,
    required DawnSourceStat? atRead,
    required FileStat metadata,
  }) async {
    ({String? refusal, DeliveryFile? file}) refuse(String reason) =>
        (refusal: reason, file: null);

    if (metadata.type == FileSystemEntityType.notFound) {
      return refuse(
        'it is no longer on disk at $path, so the pass has nothing to '
        'deliver under this name',
      );
    }
    if (atRead == null) {
      return refuse(
        'the pass could not measure $path when it read its pixels, so '
        'there is nothing to check the ${metadata.size} bytes now on disk '
        'against',
      );
    }
    if (atRead.bytes != metadata.size ||
        !atRead.modified.isAtSameMomentAs(metadata.modified)) {
      return refuse(
        'the file changed after the pass read it ($path was '
        '${atRead.bytes} bytes, modified '
        '${atRead.modified.toUtc().toIso8601String()}, when its pixels '
        'were read and is ${metadata.size} bytes, modified '
        '${metadata.modified.toUtc().toIso8601String()}, now), so what is '
        'on disk is not what this pass measured',
      );
    }
    final DawnSourceStat? now;
    try {
      now = await DawnSourceStat.of(path);
    } on DeliveryFailure catch (failure) {
      return refuse(
        'the file is still ${metadata.size} bytes at $path but its bytes '
        'could not be read to check them against the pass: '
        '${failure.message}',
      );
    }
    if (now == null) {
      return refuse(
        'it is no longer on disk at $path, so the pass has nothing to '
        'deliver under this name',
      );
    }
    if (!atRead.matches(now)) {
      return refuse(
        'the file changed after the pass read it ($path is still '
        '${metadata.size} bytes, modified '
        '${metadata.modified.toUtc().toIso8601String()}, but its contents '
        'now hash to ${now.digest} where the pass read ${atRead.digest}), '
        'so what is on disk is not what this pass measured',
      );
    }
    return (
      refusal: null,
      file: DeliveryFile(
        sourcePath: File(path).absolute.path,
        bytes: now.bytes,
        checksum: now.digest,
      ),
    );
  }

  /// Hand the night's artifacts to delivery.
  ///
  /// Never throws and never fails the job: [DeliveryService] answers with a
  /// report rather than an exception, and a source file that vanished between
  /// integration and delivery is reported here as the problem it is.
  ///
  /// **One missing file costs only itself.** [DeliveryArtifactSet.build] stats
  /// and hashes every source and raises on the first it cannot read, which
  /// would take the good drafts and the night report down with one master that
  /// went missing after it was drafted. Each artifact is described on its own
  /// here, so the set that reaches delivery is exactly the files that are
  /// there, and the ones that are not are named. The set keeps
  /// [DeliveryArtifactSet.build]'s order — by artifact class, then by the order
  /// listed — so two runs of one job deliver in the same order.
  ///
  /// **A master staging already hashed is not hashed again.** [described]
  /// carries the readings `_stageForDelivery` just took to prove each master is
  /// still the file the pass drafted from, which are exactly the size and
  /// SHA-256 an artifact description holds. Re-reading a 4 GB master to compute
  /// the same number twice in the same second buys nothing: a source that
  /// changes after staging still fails, because every transport verifies what
  /// landed against this checksum.
  Future<({DeliveryRunReport? report, List<String> problems})> _deliver({
    required int jobId,
    required List<String> linearMasters,
    required List<String> draftRenders,
    required String? reportPath,
    Map<String, DeliveryFile> described = const {},
  }) async {
    final sources = <ArtifactContent, List<String>>{
      ArtifactContent.linearMasters: linearMasters,
      ArtifactContent.draftRender: draftRenders,
      if (reportPath != null) ArtifactContent.nightReport: [reportPath],
    };
    final artifacts = <DeliveryArtifact>[];
    final problems = <String>[];
    for (final content in ArtifactContent.values) {
      for (final path in sources[content] ?? const <String>[]) {
        try {
          final already = described[path];
          artifacts.add(
            already == null
                ? await DeliveryArtifact.describeArtifact(
                    content: content,
                    path: path,
                  )
                : DeliveryArtifact(
                    content: content,
                    sourcePath: already.sourcePath,
                    bytes: already.bytes,
                    checksum: already.checksum,
                  ),
          );
        } on DeliveryFailure catch (error) {
          problems.add(
            '${p.basename(path)} was not delivered: '
            '${error.message}.',
          );
          _logger?.warning(
            'A dawn artifact could not be handed to delivery; the rest of the '
            'set still goes',
            source: 'DawnAutopilotService',
            fields: {
              'jobId': jobId,
              'path': path,
              'content': content.wire,
              'error': error.message,
            },
          );
        }
      }
    }
    if (artifacts.isEmpty) {
      return (
        report: null,
        problems: <String>[
          ...problems,
          'Nothing was delivered: this job produced no file that could be '
              'read at delivery time.',
        ],
      );
    }

    final report = await _delivery.deliverJobArtifacts(
      DeliveryArtifactSet(jobId: jobId, artifacts: artifacts),
      isCancelled: () => _cancelRequested.contains(jobId),
    );
    return (
      report: report,
      problems: <String>[
        ...problems,
        // Pass-level problems first: an unreadable destination list means the
        // per-destination list below is empty for a reason, not because
        // nothing is configured.
        ...report.problems,
        for (final destination in report.destinations) ...destination.problems,
      ],
    );
  }

  /// Send the morning message, letting a notification failure be a line in the
  /// report rather than the end of a job whose artifacts already exist.
  Future<DawnNotificationDecision> _announce(
    int jobId,
    DawnJobReport report,
  ) async {
    try {
      return await _notifier.announce(report);
    } catch (error) {
      _logger?.warning(
        'The morning notification could not be sent',
        source: 'DawnAutopilotService',
        fields: {'jobId': jobId, 'error': '$error'},
      );
      return DawnNotificationDecision(
        sent: false,
        reason: 'The morning message could not be sent: $error',
      );
    }
  }

  /// The name of the report copy the rig keeps: the job's own record, carrying
  /// the delivery and notification outcomes, and the file every reader that
  /// asks "what did job N do" opens.
  ///
  /// Delivery is never handed this name. A second pass over the same job
  /// rewrites it, which is what makes it the CURRENT account of job N rather
  /// than the first one's.
  static String _rigReportName(int jobId) => 'job_${jobId}_report.json';

  /// The name of the report copy one pass hands to delivery.
  ///
  /// **The report describes a pass, so the pass is its identity.** A watched
  /// folder or an SFTP incoming directory copies and never overwrites: an
  /// artifact whose bytes differ from a file already sitting at its delivered
  /// name is refused with [DeliveryFailureKind.destinationConflict], which no
  /// retry can clear. Every other artifact survives a re-run because its bytes
  /// are stable — the same master FITS, the same draft JPEG, re-verified as
  /// already-there. A report cannot be: it carries this pass's clocks and this
  /// pass's render, so a second pass's report is never the first's bytes.
  ///
  /// One name per JOB therefore left a crash-resumed pass unable to deliver
  /// its report at all. A dead process leaves the row `running`, the open-time
  /// recovery re-queues it, [drainQueue] re-runs it — and the re-run's report
  /// met the first pass's copy at the destination, went terminal, and the
  /// morning report then said a file had not arrived that never could.
  ///
  /// One name per PASS is the identity the file actually has, and it is a name
  /// the destination has not been handed. A folder that holds two of them held
  /// two passes; the numbering says which is which. The `_report.json` suffix
  /// is kept so a downstream script matching `job_*_report.json` still sees
  /// them.
  static String _passReportName(int jobId, int pass) =>
      'job_${jobId}_pass${pass}_report.json';

  /// Write a night report as [fileName] beside the drafts, returning its path
  /// or null when the disk refused it.
  Future<String?> _writeReport(
    String directory,
    String fileName,
    DawnJobReport report,
  ) async {
    final path = p.join(directory, fileName);
    try {
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
      );
      return path;
    } on FileSystemException catch (error) {
      _logger?.warning(
        'The night report could not be written',
        source: 'DawnAutopilotService',
        fields: {'jobId': report.jobId, 'path': path, 'error': error.message},
      );
      return null;
    }
  }

  /// The directory the job's drafts and report land in, created if absent.
  Future<String> _darkroomDirectory() async {
    final base = await _outputDirectory();
    final directory = p.join(base, 'darkroom');
    await Directory(directory).create(recursive: true);
    return directory;
  }

  Future<String?> _targetName(int? targetId) async {
    if (targetId == null) return null;
    final target = await _targets.getTargetById(targetId);
    return target?.name;
  }

  /// Advance the job's progress, treating a row that has left this executor as
  /// the stop it is.
  ///
  /// The note doubles as the stage a failure sentence names, so the two can
  /// never describe different steps.
  Future<void> _reportProgress(int jobId, double progress, String note) async {
    _stage[jobId] = note.isEmpty
        ? 'running the dawn pass'
        : '${note[0].toLowerCase()}${note.substring(1)}';
    await _jobs.updateProgress(jobId, progress.clamp(0.0, 1.0), note: note);
  }

  void _stopIfCancelled(int jobId, String where) {
    if (_cancelRequested.contains(jobId)) throw _DawnCancelled(where);
  }

  /// The one line the job row carries after it finishes: what was drafted,
  /// what was held back, and where the first draft image is, because the row
  /// has no artifact column.
  static String _completionNote(DawnJobReport report) {
    final withheld = report.masters.where((m) => !m.deliverable).length;
    final tail = withheld == 0
        ? ''
        : '; $withheld master${withheld == 1 ? '' : 's'} '
              '${withheld == 1 ? 'was' : 'were'} not delivered — see the '
              'night report';
    final first = report.masters.firstWhere(
      (master) => master.hasDraft,
      orElse: () => report.masters.isEmpty ? _noMasters : report.masters.first,
    );
    final path = first.draftRenderPath;
    if (path == null) {
      // A FINISHED sentence, because `draftRenderPath == null` here means
      // `draftsRendered == 0`, which is the ending that now fails — and the
      // Session Review banner prints a failed row's note as the pass's own
      // second sentence. It frames a note without terminal punctuation as the
      // stage the pass stopped at ("It was <note> when it stopped"), which for
      // a pass that ran every stage would name a stop that never happened.
      // It also does not repeat the failure line above it: that names which
      // master stopped and why, so this one points at the artifact instead.
      return 'No draft came out of the pass; the night report carries the '
          'per-master detail.';
    }
    return '${report.draftsRendered} '
        'draft${report.draftsRendered == 1 ? '' : 's'} ready; '
        'first at $path$tail';
  }

  static const DawnMasterReport _noMasters = DawnMasterReport(
    master: DawnMaster(
      masterId: 0,
      targetId: null,
      name: 'no master',
      filter: null,
      masterFitsPath: '',
      channels: 0,
      width: 0,
      height: 0,
      frameCount: 0,
      totalIntegrationSeconds: 0.0,
    ),
    targetName: null,
    stats: DawnMasterStats.unrecorded,
    draft: null,
    recipeId: null,
    draftRenderPath: null,
    failure: 'the session produced no linear master',
  );
}
