import 'package:drift/drift.dart';

import '../../models/darkroom/darkroom_job.dart' show kDarkroomJobMaxAttempts;
import '../database.dart';
import '../integration_stage_marker.dart';
import '../session_orphan_sweep.dart';

/// Puts right what a previous process left unfinished when it died: sequence
/// runs and imaging sessions still marked live, Darkroom jobs still marked
/// running, a post-session pass interrupted part-way, and session statistics
/// that were only ever held in memory.
///
/// Call it once per process, on a database that is open and at the current
/// schema, before anything in this process starts a run, a session or a
/// Darkroom job or reads their state. Everything it closes is identified by
/// "marked live at start-up", so a second call later in the same process
/// would close this process's own work.
///
/// It never throws for the post-session report; a failure of the run, session
/// or Darkroom-job sweeps propagates.
Future<void> recoverFromPreviousProcessExit(SkotiqDatabase db) =>
    db._recoverFromPreviousProcessExit();

extension _CrashRecovery on SkotiqDatabase {
  Future<void> _recoverFromPreviousProcessExit() async {
    // Close out runs a previous process left mid-flight.
    //
    // A `sequence_runs` row is only 'running' while THIS process's
    // executor is driving it — that executor state lives in memory, so
    // nothing can still be running at the moment the database opens. Any
    // row still marked 'running' here is residue from a process that died
    // mid-run: a crash, a force quit, or the power cut at 3am that this
    // kind of software has to expect.
    //
    // Left alone, such a row is permanent: the run list keeps reporting
    // a run "running" while /api/status reports the sequencer idle, and a
    // stale row blocks the next run from starting.
    //
    // `ended_at` stays NULL. When the run actually stopped is unknown,
    // and stamping "now" would invent a duration spanning the whole
    // downtime. 'paused' is a LIVE status too — written while an executor
    // holds the run — so a process that died mid-pause leaves the same
    // stale row as one that died mid-exposure.
    final interrupted = await customUpdate(
      "UPDATE sequence_runs SET status = 'interrupted' "
      "WHERE status IN ('running', 'paused')",
      updates: {sequenceRuns},
      updateKind: UpdateKind.update,
    );
    if (interrupted > 0) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Marked $interrupted sequence '
        "run${interrupted == 1 ? '' : 's'} left live by a previous "
        "process as 'interrupted'.",
      );
    }

    // Close out imaging sessions a previous process left `active`, by the
    // same rule as the runs above and BEFORE the statistics rebuild below,
    // so a night this sweep closes gets its counters rebuilt in the same
    // open. Left standing, one such row detaches every later night:
    // `startSession` refuses to open a second session while it stands, so
    // every frame registers with `session_id` NULL and the session-end
    // hooks never fire. See [_closeOrphanedImagingSessions].
    await _closeOrphanedImagingSessions();

    // Close out Darkroom jobs a previous process left mid-flight, for the
    // same reason and by the same rule as the sequence runs above: a
    // 'running' row at open belongs to a process that is gone.
    final interruptedDarkroomJobs = await _recoverInterruptedDarkroomJobs();

    // Report a post-session pass a previous process died inside. The
    // integrate runs BEFORE any Darkroom job row exists, so the recovery
    // above cannot see it and the night would otherwise go silent with a
    // truncated master sitting on disk looking finished. What the recovery
    // DID find is handed over, because a Darkroom job left running is what
    // separates a kill during the draft from a kill during the integrate.
    //
    // This block may fail, and the try/catch is the whole point. Everything in
    // this block is a POST-MORTEM: it explains a night that already
    // happened. None of it is required for the database to work, and all
    // of it writes rows keyed to sessions and jobs whose ids come from a
    // marker file a dead process left behind — ids the current database
    // may no longer contain. Under `PRAGMA foreign_keys = ON` such a write
    // throws, and a throw HERE is not one failed report: drift records the
    // failure against the connection and refuses every later open, while
    // the marker that caused it stays on disk to cause it again. That
    // turns an undamaged database into an install that never starts.
    //
    // So the report is allowed to fail. What must not fail is the open.
    try {
      final reportedSession = await _reportInterruptedIntegration(
        interruptedDarkroomJobs,
      );

      // The report above is written once per interruption, from a marker
      // the first report consumes — so a job that dies repeatedly keeps
      // the record its FIRST death wrote, which promised a re-queue the
      // cap has since cancelled. Correct those here, now that the recovery
      // has said which jobs it ended for good.
      await _supersedeRetryPromiseForCappedJobs(
        interruptedDarkroomJobs,
        reportedSessionId: reportedSession,
      );
    } catch (error, stackTrace) {
      // ignore: avoid_print
      print(
        '[skotiq_db] WARNING: reporting an interrupted post-session '
        'pass failed ($error). The database opens anyway — this report is '
        'a courtesy, not a precondition. Discarding the marker that drove '
        'it so the failure cannot repeat at every launch.\n$stackTrace',
      );
      await _discardIntegrationMarkerAfterFailedReport();
    }

    // Rebuild session statistics that a dead process never got to write.
    //
    // `imaging_sessions.total_exposures` / `total_integration_secs` are
    // denormalised counters accumulated IN MEMORY by SessionService and
    // flushed when the session ends. A session that never ends cleanly
    // therefore keeps zeros forever — even though every frame it captured
    // is safely in `captured_images` with the right `session_id`.
    //
    // Analytics sums those counters, so the loss is user-visible and
    // permanent without this rebuild.
    //
    // `successful_exposures` is rebuilt alongside the total because it is
    // what the Analytics history view counts; rebuilding only the total
    // leaves every historical night reading "0 frames / 0.0h" there.
    //
    // Only sessions that under-report AND demonstrably have frames are
    // touched, so a correctly-written richer count is never overwritten (a
    // clean session's total legitimately also counts FAILED exposures,
    // which leave no image row). `failed_exposures` is left alone — a
    // failure writes no frame, so the rows on disk cannot say how many
    // there were.
    final rebuilt = await customUpdate(
      'UPDATE imaging_sessions SET '
      'total_exposures = (SELECT COUNT(*) FROM captured_images c '
      'WHERE c.session_id = imaging_sessions.id), '
      'successful_exposures = (SELECT COUNT(*) FROM captured_images c '
      'WHERE c.session_id = imaging_sessions.id), '
      'total_integration_secs = (SELECT IFNULL(SUM(c.exposure_duration), 0) '
      'FROM captured_images c WHERE c.session_id = imaging_sessions.id) '
      'WHERE (total_exposures = 0 OR successful_exposures = 0) '
      'AND EXISTS ('
      'SELECT 1 FROM captured_images c WHERE c.session_id = '
      'imaging_sessions.id)',
      updates: {imagingSessions},
      updateKind: UpdateKind.update,
    );
    if (rebuilt > 0) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Rebuilt statistics for $rebuilt imaging '
        'session${rebuilt == 1 ? '' : 's'} from the frames actually '
        'on record.',
      );
    }
  }

  /// Close out imaging sessions a previous process left `active`.
  ///
  /// The sibling of the `sequence_runs` sweep above and of
  /// [_recoverInterruptedDarkroomJobs], by the same rule: an `imaging_sessions`
  /// row is only `active` while THIS process's [SessionService] is driving it,
  /// and that state lives in memory, so nothing can still be running at the
  /// moment the database opens. Any `active` row here belongs to a process that
  /// is gone.
  ///
  /// **What the missing sibling cost.** `SessionsDao.startSession` refuses to
  /// open a second row while an older one is `active`, and every caller treats
  /// that refusal as "no session row" rather than as a failure. So one daemon
  /// stop mid-run — a cloud call at 2am, the updater, a power blip — detached
  /// every LATER night: measured on the release bundle, night two's twelve
  /// frames all registered with `session_id` NULL, the session-end hooks that
  /// key on the session id (post-session integration, the dawn Darkroom pass)
  /// logged "no active sequence id recorded" and never fired, no masters and no
  /// drafts were produced, and `GET /api/sessions/active` kept serving the dead
  /// run's counters while the live run captured.
  ///
  /// Runs on both hosts: the GUI and the headless daemon share one start-up
  /// step list.
  ///
  /// The close itself — status, back-dated `end_time`, appended note — is
  /// [kCloseOrphanedSessionsSql], shared with the sequence-start close in
  /// [SessionService] so the two cannot drift.
  Future<void> _closeOrphanedImagingSessions() async {
    final orphans = await customSelect(
      kSelectOrphanedSessionsSql,
      readsFrom: {imagingSessions},
    ).get();
    if (orphans.isEmpty) return;

    final found = DateTime.now();
    final note = interruptedSessionNote(
      cause: kInterruptedBySessionShutdownCause,
      found: found,
    );
    await customUpdate(
      kCloseOrphanedSessionsSql,
      variables: [
        Variable<int>(found.toUtc().millisecondsSinceEpoch ~/ 1000),
        Variable<String>(note),
        Variable<String>(note),
      ],
      updates: {imagingSessions},
      updateKind: UpdateKind.update,
    );

    final named = orphans
        .map((row) {
          final id = row.data['id'] as int;
          final name = row.data['name'] as String?;
          return name == null || name.isEmpty ? '#$id' : '#$id "$name"';
        })
        .join(', ');
    // ignore: avoid_print
    print(
      '[skotiq_db] Imaging session${orphans.length == 1 ? '' : 's'} left '
      "open by a previous process, now recorded as "
      "'$kInterruptedSessionStatus': $named.",
    );
  }

  /// Close out Darkroom jobs a previous process left mid-flight.
  ///
  /// A `darkroom_jobs` row is only 'running' while THIS process's executor is
  /// driving it — that executor state lives in memory, so nothing can still be
  /// running at the moment the database opens. Any row still marked 'running'
  /// here is residue from a process that died mid-job: a crash, a force quit,
  /// or safing that ran out its shutdown budget. Left alone, such a row is
  /// permanent: the queue reports work in flight that nothing is driving, and
  /// the night's masters are never produced.
  ///
  /// Recovered rows go back to 'queued' with `started_at` cleared and a note
  /// saying what happened. `progress` is left where the dead process left it,
  /// so the report can state how far that attempt got, and `attempts` is left
  /// alone — it counts starts, and the restart will increment it.
  ///
  /// A job that has already used its [kDarkroomJobMaxAttempts] starts is moved
  /// to 'failed' instead: a job that kills the process must not re-queue itself
  /// forever. Its `note` is replaced along with its state, because the note the
  /// dead attempt left — the step it was on, or the re-queue line a previous
  /// recovery wrote — describes work that is over and would read on a failed
  /// row as though it were still going.
  ///
  /// The retry-limit sentence is built from the ROW: the attempt number comes
  /// out of `attempts`, in SQL, so one statement still covers every residual
  /// row. It used to be a constant reading "on attempt 3 of 3" while its own
  /// `WHERE` selects `attempts >= 3`, so a row that had been started five times
  /// was told it died on its third — a number nothing in the row supports.
  ///
  /// Returns what was found BEFORE either write, because those rows are the
  /// evidence of WHICH STAGE of the night the process died in:
  /// [_reportInterruptedIntegration] runs next over a marker that covers the
  /// integrate AND the Darkroom pass, and a session with a Darkroom job left
  /// running is a session whose integration had already finished.
  Future<List<_InterruptedDarkroomJob>>
  _recoverInterruptedDarkroomJobs() async {
    final residue = await customSelect(
      'SELECT id, session_id, kind, created_at, progress, attempts '
      'FROM darkroom_jobs WHERE state = ?',
      variables: [const Variable<String>('running')],
    ).get();
    final interrupted = [
      for (final row in residue)
        _InterruptedDarkroomJob(
          jobId: row.data['id'] as int,
          sessionId: row.data['session_id'] as int?,
          kind: row.data['kind'] as String?,
          createdAtEpochSeconds: row.data['created_at'] as int?,
          progress: (row.data['progress'] as num).toDouble(),
          attempts: row.data['attempts'] as int,
        ),
    ];

    final failed = await customUpdate(
      "UPDATE darkroom_jobs SET state = 'failed', finished_at = ?, "
      "error_text = 'Interrupted by a process exit on attempt ' || attempts || "
      "'; the limit is ' || ? || ' starts, so it is not retried.', "
      'note = ? WHERE state = ? AND attempts >= ?',
      variables: [
        Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
        const Variable<int>(kDarkroomJobMaxAttempts),
        const Variable<String>(
          'Stopped at the retry limit; this job is not re-queued.',
        ),
        const Variable<String>('running'),
        const Variable<int>(kDarkroomJobMaxAttempts),
      ],
      updateKind: UpdateKind.update,
    );
    final requeued = await customUpdate(
      "UPDATE darkroom_jobs SET state = 'queued', started_at = NULL, "
      'note = ? WHERE state = ?',
      variables: [
        const Variable<String>(
          'Re-queued: the previous process exited while this job was running.',
        ),
        const Variable<String>('running'),
      ],
      updateKind: UpdateKind.update,
    );
    if (failed > 0 || requeued > 0) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Darkroom jobs left running by a previous process: '
        're-queued $requeued, failed $failed at the attempt limit.',
      );
    }
    return interrupted;
  }

  /// Whether [sessionId] already carries a narrator event under [dedupeKey].
  ///
  /// The session-scoped half of [NarratorEventsDao.hasDedupeKey]'s rule, asked
  /// in SQL like the rest of this file. No time window is needed: every night gets a fresh session id, so
  /// a key can only collide with an earlier event of the SAME night — which is
  /// exactly the duplicate worth suppressing.
  Future<bool> _narratorEventExists(int sessionId, String dedupeKey) async {
    final rows = await customSelect(
      'SELECT 1 FROM narrator_events WHERE session_id = ? AND dedupe_key = ? '
      'LIMIT 1',
      variables: [Variable<int>(sessionId), Variable<String>(dedupeKey)],
      readsFrom: {narratorEvents},
    ).get();
    return rows.isNotEmpty;
  }

  /// Consume the integration marker after the post-mortem report it feeds
  /// failed, naming what it said in the log first.
  ///
  /// The report is a courtesy — it tells the operator a night was interrupted —
  /// and the marker that drives it is re-read at every open. So a report that
  /// throws does not fail once: it fails identically on every launch, out of
  /// `beforeOpen`, which drift treats as a fatal migration error and refuses to
  /// open past. Discarding the marker costs one night's warning; keeping it
  /// costs the whole database. The marker's contents go to the log so the
  /// warning is not lost, only relocated.
  Future<void> _discardIntegrationMarkerAfterFailedReport() async {
    try {
      final directory = await databaseDirectory();
      if (directory == null) return;
      final interrupted = await readIntegrationMarker(directory);
      if (interrupted != null) {
        // ignore: avoid_print
        print(
          '[skotiq_db] The discarded marker recorded: session '
          '${interrupted.sessionId}, stage ${interrupted.stage.name}, started '
          '${interrupted.startedAtUtc.toIso8601String()} UTC, intended masters '
          '${interrupted.intendedMasterPaths.isEmpty ? '(none recorded)' : interrupted.intendedMasterPaths.join('; ')}.',
        );
      }
      await clearIntegrationMarker(directory);
    } catch (error) {
      // ignore: avoid_print
      print(
        '[skotiq_db] WARNING: the interrupted-pass marker could not be '
        'discarded either ($error). It will be read again at the next open; '
        'delete $kIntegrationMarkerName beside the database by hand if '
        'startup keeps failing.',
      );
    }
  }

  /// Report a post-session pass that a previous process died in the middle of,
  /// then clear its marker.
  ///
  /// The integrate leaves no `darkroom_jobs` row to recover — the Darkroom job
  /// is enqueued only after the masters exist — so the marker file written by
  /// `markIntegrationStarted` is the whole record that the night was
  /// interrupted. It is turned into two durable, operator-visible things:
  ///
  ///  - a line appended to the session's notes, which Session Review and the
  ///    session wire snapshot both carry, and
  ///  - a `warning` Night Narrator event on that session, which is what the
  ///    morning feed reads.
  ///
  /// The intended master files are named in both, EACH WITH WHAT IT ACTUALLY
  /// IS. A FITS truncated by a kill is present and non-empty and looks
  /// finished, so an operator told only "the integration was interrupted"
  /// would open one and trust it — and an operator told every present file is
  /// truncated would delete the ones that are whole. Each file is opened and
  /// measured against its own header before it is described.
  ///
  /// Re-running the integration is deliberately NOT automatic: the subs are
  /// still on disk and still graded, so nothing is lost by waiting, whereas a
  /// pass that re-launches itself at every open is how a crash-on-integrate
  /// takes the app down repeatedly. The report says the night needs a re-run;
  /// the operator asks for it.
  ///
  /// WHICH STAGE the kill landed in has two sources, and they answer two
  /// different questions.
  ///
  /// [interruptedJobs] — the `darkroom_jobs` rows
  /// `_recoverInterruptedDarkroomJobs` found still `running`, captured before
  /// it re-queued them — answers "was a Darkroom pass in flight?". A row still
  /// running for the marker's session is a pass the machine died inside, and
  /// its own recovery already owns it.
  ///
  /// [InterruptedIntegration.stage] answers "had the masters finished?", which
  /// no row can. The marker's window covers the integrate AND the Darkroom pass
  /// that follows it (one `finally` clears it after both), and between them
  /// sits a seam the pass cannot close from one transaction: the masters are
  /// finalized bucket by bucket inside `PostSessionIntegrationService`, and the
  /// `darkroom_jobs` row is inserted afterwards. A kill in that seam left NO
  /// row at all, so every one of them was reported as an interrupted integrate
  /// — a night whose four masters were whole, registered and named as intact in
  /// the same sentence that told the operator to run the integration again, and
  /// which said nothing about the drafts, the night report, the delivery and
  /// the morning message that had never been queued. The marker now records
  /// that seam as it is crossed, so this open reads it instead of guessing.
  ///
  /// A pass that was OWED is not merely reported: a `queued` dawn job is
  /// inserted for it, which is the state the crash-requeue machinery already
  /// knows how to finish — `resumeDarkroomWork` drains the queue at every
  /// startup. That is not the same as re-running an integration, which stays
  /// manual: the integrate is the expensive, crash-prone stretch that must not
  /// re-launch itself at every open, while the owed pass is the cheap half that
  /// was already decided and never got to start.
  ///
  /// The marker is deleted last, so a process that dies between reading it and
  /// writing the report finds it again at the next open. The owed pass is
  /// enqueued BEFORE the report, so a process that dies in between finds the
  /// marker again, sees the job it already inserted, and does not insert a
  /// second one.
  ///
  /// Returns the session it reported on, or null when there was nothing to
  /// report. [_supersedeRetryPromiseForCappedJobs] runs next and needs to know:
  /// a session reported HERE already carries this open's verdict, terminal
  /// branch included, and a second record of the same event would only repeat
  /// it.
  Future<int?> _reportInterruptedIntegration(
    List<_InterruptedDarkroomJob> interruptedJobs,
  ) async {
    final directory = await databaseDirectory();
    if (directory == null) return null;
    final interrupted = await readIntegrationMarker(directory);
    if (interrupted == null) return null;

    // The marker names its session by id, and that row can be gone by the time
    // this runs: the operator deleted the night from the sessions list after
    // the crash, the integrity quarantine rotated the damaged file aside and
    // left this marker beside a FRESH database that never held the session, or
    // a replace-mode restore swapped in a backup predating it. The report below
    // INSERTs a `narrator_events` row keyed to that id under
    // `PRAGMA foreign_keys = ON`, so a missing session turns a post-mortem note
    // into a foreign-key failure thrown out of `beforeOpen` — which drift
    // remembers, so every later open fails the same way while the marker sits
    // on disk producing it again. The database is undamaged and unopenable.
    //
    // A night that is no longer on record has nothing to carry the report, so
    // the marker is consumed and the finding goes to the log instead.
    final sessionRow = await customSelect(
      'SELECT 1 FROM imaging_sessions WHERE id = ? LIMIT 1',
      variables: [Variable<int>(interrupted.sessionId)],
      readsFrom: {imagingSessions},
    ).get();
    if (sessionRow.isEmpty) {
      // ignore: avoid_print
      print(
        '[skotiq_db] A post-session pass was interrupted for session '
        '${interrupted.sessionId} (started '
        '${interrupted.startedAtUtc.toIso8601String()} UTC), but that session '
        'is no longer in the database, so there is no night to report it on. '
        'Discarding the marker. Master files it intended to write: '
        '${interrupted.intendedMasterPaths.isEmpty ? '(none recorded)' : interrupted.intendedMasterPaths.join('; ')}.',
      );
      await clearIntegrationMarker(directory);
      return null;
    }

    _InterruptedDarkroomJob? darkroomPass;
    for (final job in interruptedJobs) {
      if (job.isPassFor(interrupted.sessionId, interrupted.startedAtUtc)) {
        darkroomPass = job;
        break;
      }
    }

    // Whether the integrate had finished, from the marker's own record of the
    // seam rather than from an absence of rows. `darkroomPass` still wins over
    // it: a row the machine died inside is a pass that HAD started, whatever
    // the marker last managed to write before the kill.
    final integrateFinished =
        darkroomPass == null &&
        interrupted.stage != PostSessionPassStage.integrating;

    // Each intended file is MEASURED before anything is said about it. The
    // pass writes its masters one after another, so an interruption leaves
    // some of them whole; calling every present file "truncated — delete it"
    // told the operator to throw away finished data, and the one that really
    // was half-written was buried in the same sentence as the ones that were
    // not.
    final present = await interrupted.presentMasterFiles();
    final incomplete = present.where((file) => !file.complete).toList();
    final whole = present.where((file) => file.complete).toList();
    // Paths the marker named that are not on disk at all. Before the integrate
    // finished this is the ordinary case — the pass had not reached them yet —
    // and after it finished it is a file that went missing since, which the
    // library still points at.
    final absent = integrateFinished
        ? [
            for (final path in interrupted.intendedMasterPaths)
              if (!present.any((file) => file.path == path)) path,
          ]
        : const <String>[];
    final sentences = <String>[];
    if (present.isEmpty && darkroomPass == null && !integrateFinished) {
      // Only the integrate can leave a master half-written, and only then is
      // "nothing on disk is half-finished" news. A kill during the DRAFT hit a
      // stage that writes no master at all, so saying it there would answer a
      // question the operator did not ask about a file that was never in
      // danger.
      sentences.add(
        'No master file had been written yet, so nothing on disk is '
        'half-finished.',
      );
    }
    if (incomplete.isNotEmpty) {
      sentences.add(
        'These master files are incomplete — delete them before re-running: '
        '${incomplete.map((f) => '${f.path} (${f.detail})').join('; ')}.',
      );
    }
    if (absent.isNotEmpty) {
      sentences.add(
        'These master files finished and are no longer on disk, so whatever '
        'the library still says about them, they are gone: '
        '${absent.join('; ')}.',
      );
    }
    for (final file in whole) {
      final registered = await _masterIsRegistered(file.path);
      sentences.add(
        registered
            ? '${file.path} is a complete FITS (${file.detail}) and the master '
                  'library already holds a row for it, so that one arrived '
                  'intact.'
            : '${file.path} is a complete FITS (${file.detail}) but no master '
                  'row records it, so it is finished on disk and missing from '
                  'the library. Re-running the integration writes it again; '
                  'nothing here says it is damaged.',
      );
    }
    final orphanText = sentences.join(' ');
    final startedAt = interrupted.startedAtUtc.toIso8601String();

    // The pass that was OWED and the pass that had already been queued share
    // one marker stage, because the marker is written before the insert and
    // never again — the ROW is what says which of the two happened.
    final queuedJobId = integrateFinished
        ? await _darkroomJobForPass(
            interrupted.sessionId,
            interrupted.startedAtUtc,
          )
        : null;
    final passIsOwed =
        integrateFinished &&
        interrupted.stage == PostSessionPassStage.darkroomPassOwed &&
        queuedJobId == null;

    // Nothing is outstanding and nothing on disk moved: the masters finished,
    // and either no pass was owed or the pass already has a row that says how
    // it ended. Consuming the marker in silence is the honest answer — a
    // `warning` for a night that lost nothing is how an operator learns to
    // scroll past the ones that did.
    if (integrateFinished &&
        !passIsOwed &&
        incomplete.isEmpty &&
        absent.isEmpty) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Session ${interrupted.sessionId}: the post-session '
        'integration had finished when the previous process exited '
        '${queuedJobId == null ? 'and no Darkroom pass was owed' : '(Darkroom '
                  'job #$queuedJobId carries the pass)'}; nothing is outstanding.',
      );
      await clearIntegrationMarker(directory);
      return null;
    }

    // The pass is enqueued BEFORE the report so the report can state what
    // actually happened to it, and so a death in between is idempotent: the
    // next open finds the marker, finds this row, and takes the branch above.
    final owedJobId = passIsOwed
        ? await _enqueueOwedDarkroomPass(interrupted.sessionId)
        : null;

    final String headline;
    if (darkroomPass != null) {
      headline = 'The Darkroom pass was interrupted before it finished.';
    } else if (integrateFinished) {
      headline = passIsOwed
          ? 'The Darkroom pass for this night never started.'
          : 'The post-session integration finished, but its master files no '
                'longer match the library.';
    } else {
      headline =
          'The post-session integration was interrupted before it '
          'finished.';
    }

    final body = <String>[
      if (darkroomPass != null)
        'Skotiq closed while Darkroom job #${darkroomPass.jobId} was '
            'drafting this session, '
            '${(darkroomPass.progress * 100).round()}% of the way through (the '
            'pass started at $startedAt UTC). The integration itself had '
            'already finished — the Darkroom job is queued only once the '
            'masters exist.'
      else if (integrateFinished)
        'The integration finished: every master it set out to write was on '
            'disk and in the library when Skotiq closed (the pass started '
            'at $startedAt UTC).'
      else
        'Skotiq closed while integrating this session (started '
            '$startedAt UTC).',
      if (passIsOwed)
        'What had not happened yet is the Darkroom pass — the drafts, the '
            'night report, the delivery and the morning message. It had not '
            'been queued when the process exited.',
      if (orphanText.isNotEmpty) orphanText,
      if (darkroomPass != null && darkroomPass.willRetry)
        'The job is re-queued, so the drafts, the night report and the '
            'delivery it owes are still owed; re-running the integration is '
            'not what this night needs.'
      else if (darkroomPass != null)
        'That was start ${darkroomPass.attempts} of at most '
            '$kDarkroomJobMaxAttempts, so the job is marked failed rather than '
            're-queued: the drafts, the night report and the delivery are not '
            'coming from this pass; build the target\'s masters in the '
            'Darkroom instead. The masters are untouched.'
      else if (passIsOwed && owedJobId != null)
        'It is queued now as Darkroom job #$owedJobId and runs at this '
            'startup. Do not run the integration again — it is the one part of '
            'this night that did finish.'
      else if (passIsOwed)
        'It could not be queued here either, so the drafts, the night report '
            'and the delivery are not coming from this pass; build the '
            'target\'s masters in the Darkroom instead. Do not run the '
            'integration again — it is the one part of this night that did '
            'finish.'
      else if (integrateFinished)
        'The subs are all still on disk and still graded, so re-run the '
            'integration only for the masters named above; the rest of the '
            'library is untouched.'
      else
        'The subs are all still on disk and still graded, so run the '
            'integration again when you are ready.',
    ].join(' ');

    // One interruption, one record. The key below has always been WRITTEN and
    // never read: the "reported once" promise rested entirely on the marker
    // delete at the end of this method, and that delete is a file operation
    // that can fail — a read-only directory, a full disk — and is deliberately
    // the LAST thing here, so a process killed between the insert and the
    // delete leaves the marker standing over an event that already landed.
    // Either way the next open re-reports, and the operator's feed carries the
    // same warning about the same night twice, three times, once per launch.
    // The key is what makes the record idempotent; consulting it is what makes
    // the promise true.
    final dedupeKey = '$kInterruptedPassEventType:$startedAt';
    if (await _narratorEventExists(interrupted.sessionId, dedupeKey)) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Session ${interrupted.sessionId}: this interruption '
        'is already on record ($dedupeKey); consuming the marker without '
        'repeating the warning.',
      );
      await clearIntegrationMarker(directory);
      return interrupted.sessionId;
    }

    await customUpdate(
      'UPDATE imaging_sessions SET notes = '
      "CASE WHEN notes IS NULL OR notes = '' THEN ? "
      "ELSE notes || char(10) || ? END WHERE id = ?",
      variables: [
        Variable<String>('$headline $body'),
        Variable<String>('$headline $body'),
        Variable<int>(interrupted.sessionId),
      ],
      updates: {imagingSessions},
      updateKind: UpdateKind.update,
    );

    await customInsert(
      'INSERT INTO narrator_events('
      'session_id, timestamp, event_type, category, severity, headline, '
      'body, dedupe_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(interrupted.sessionId),
        Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
        const Variable<String>(kInterruptedPassEventType),
        const Variable<String>('quality'),
        const Variable<String>('warning'),
        Variable<String>(headline),
        Variable<String>(body),
        // Session-scoped and stamped with the start instant, so re-reporting
        // the same interruption cannot duplicate the event while two separate
        // interrupted nights each keep their own. Checked above, not merely
        // recorded.
        Variable<String>(dedupeKey),
      ],
    );

    // ignore: avoid_print
    print('[skotiq_db] Session ${interrupted.sessionId}: $headline $body');

    await clearIntegrationMarker(directory);
    return interrupted.sessionId;
  }

  /// Correct the durable interruption record of every job this open just ended
  /// at the retry limit.
  ///
  /// **What was wrong.** The interruption record is written ONCE, by
  /// [_reportInterruptedIntegration], from the marker the dead process left —
  /// and the marker is consumed by that first report. A job that dies three
  /// times therefore produces exactly one record, written after the FIRST
  /// death, when the job still had starts left and the record could honestly
  /// say "the job is re-queued, so the drafts, the night report and the
  /// delivery it owes are still owed". By the third death the cap has moved the
  /// row to `failed` and nothing is re-queued — but the record, which is what
  /// Session Review's banner and the morning feed both read, still promises the
  /// retry. The night was left waiting for drafts that were never coming.
  ///
  /// **What this writes.** For each job the cap just failed: a second
  /// `warning` event of the same type, which is how a reader that takes the
  /// NEWEST interruption record for a session sees the terminal truth instead
  /// of the promise, plus the same sentence appended to the session's notes.
  /// The earlier record is left standing rather than rewritten — it was true
  /// when it was written, and the feed is a record of what happened in order —
  /// so the correction names it and revokes it out loud.
  ///
  /// **Once per job, by construction.** Only rows found `running` reach here,
  /// and the cap has already moved these to `failed`, so no later open can find
  /// the same job again. A session [_reportInterruptedIntegration] just
  /// reported is skipped: that report took the same terminal branch a moment
  /// ago, and repeating it would put the identical verdict on the feed twice.
  Future<void> _supersedeRetryPromiseForCappedJobs(
    List<_InterruptedDarkroomJob> interruptedJobs, {
    required int? reportedSessionId,
  }) async {
    for (final job in interruptedJobs) {
      // A job with starts left was re-queued, so the promise it is under still
      // stands and there is nothing to revoke.
      if (job.willRetry) continue;
      final sessionId = job.sessionId;
      // A job queued outside a session has no night to carry a record.
      if (sessionId == null) continue;
      if (sessionId == reportedSessionId) continue;

      // Keyed on the JOB: one job reaches the cap once, and this is the record
      // of that. The rule is checked rather than assumed, by the same argument
      // as the report above — "once by construction" is a property of the code
      // paths reaching here, and the key costs one indexed lookup to hold it
      // true whatever else learns to put a row back into `running`.
      final dedupeKey =
          '$kInterruptedPassEventType:job:${job.jobId}:retry-limit';
      if (await _narratorEventExists(sessionId, dedupeKey)) continue;

      final standing = await customSelect(
        'SELECT count(*) AS rows FROM narrator_events '
        'WHERE session_id = ? AND event_type = ?',
        variables: [
          Variable<int>(sessionId),
          const Variable<String>(kInterruptedPassEventType),
        ],
        readsFrom: {narratorEvents},
      ).getSingle();
      final hadPromise = standing.read<int>('rows') > 0;

      const headline =
          'The Darkroom pass for this night stopped at the retry limit.';
      // Each sentence stands on its own, because the middle one is conditional:
      // a body whose last sentence leans on a clause the first shape does not
      // print is the same broken-sentence defect the pass banner carried.
      final body = <String>[
        'Darkroom job #${job.jobId} has now been started ${job.attempts} '
            'times, which is the limit of $kDarkroomJobMaxAttempts, so it is '
            'marked failed and is not re-queued.',
        if (hadPromise)
          'The earlier notice on this night said the job was re-queued; that '
              're-queue is over.',
        'The drafts, the night report and the delivery this pass owes are not '
            'coming from this pass; build the target\'s masters in the '
            'Darkroom instead. The subs and any masters already integrated '
            'are untouched.',
      ].join(' ');

      await customUpdate(
        'UPDATE imaging_sessions SET notes = '
        "CASE WHEN notes IS NULL OR notes = '' THEN ? "
        "ELSE notes || char(10) || ? END WHERE id = ?",
        variables: [
          Variable<String>('$headline $body'),
          Variable<String>('$headline $body'),
          Variable<int>(sessionId),
        ],
        updates: {imagingSessions},
        updateKind: UpdateKind.update,
      );

      await customInsert(
        'INSERT INTO narrator_events('
        'session_id, timestamp, event_type, category, severity, headline, '
        'body, dedupe_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable<int>(sessionId),
          Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
          const Variable<String>(kInterruptedPassEventType),
          const Variable<String>('quality'),
          const Variable<String>('warning'),
          const Variable<String>(headline),
          Variable<String>(body),
          Variable<String>(dedupeKey),
        ],
      );

      // ignore: avoid_print
      print('[skotiq_db] Session $sessionId: $headline $body');
    }
  }

  /// The newest `darkroom_jobs` row THIS pass created for [sessionId], or null
  /// when it never got one.
  ///
  /// Identity, not order: a session carries jobs from earlier nights' passes
  /// and from every "process now" the operator has pressed on it, and none of
  /// those is the pass this marker is about. The marker's own start instant is
  /// the divider, floored to the second `created_at` is stored in — a job
  /// inserted 200 ms after the marker was written shares that second and is
  /// still this pass's.
  Future<int?> _darkroomJobForPass(int sessionId, DateTime startedAtUtc) async {
    final rows = await customSelect(
      'SELECT id FROM darkroom_jobs WHERE session_id = ? AND created_at >= ? '
      'ORDER BY created_at DESC, id DESC LIMIT 1',
      variables: [
        Variable<int>(sessionId),
        Variable<int>(startedAtUtc.millisecondsSinceEpoch ~/ 1000),
      ],
    ).get();
    return rows.isEmpty ? null : rows.first.data['id'] as int;
  }

  /// Queue the Darkroom pass this night was owed and never got, returning the
  /// new job id, or null when the insert did not land.
  ///
  /// A `queued` row is the one state the rest of the system already knows how
  /// to finish: `resumeDarkroomWork` drains the queue at every startup, so the
  /// pass this open just discovered runs in this same launch without a second
  /// mechanism existing to run it.
  ///
  /// Written as `dawn` because that is the pass that was owed — the kind
  /// decides whether the morning message goes out, and the morning message is
  /// one of the four things this night never got.
  ///
  /// The failure is caught rather than thrown: this runs in `beforeOpen`, and a
  /// database that refuses one INSERT must still open. It is not swallowed —
  /// the caller reads the null and the report tells the operator the pass is
  /// owed and was not queued, which is the sentence that gets them to press
  /// Process now.
  Future<int?> _enqueueOwedDarkroomPass(int sessionId) async {
    try {
      return await customInsert(
        'INSERT INTO darkroom_jobs('
        'session_id, kind, state, progress, note, attempts, created_at'
        ') VALUES (?, ?, ?, 0.0, ?, 0, ?)',
        variables: [
          Variable<int>(sessionId),
          const Variable<String>('dawn'),
          const Variable<String>('queued'),
          const Variable<String>(
            'Queued at startup: the integration finished but the previous '
            'process exited before this pass was queued.',
          ),
          Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
        ],
      );
    } catch (error) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Session $sessionId: the owed Darkroom pass could not '
        'be queued ($error); the night report says so.',
      );
      return null;
    }
  }

  /// Whether the master library already holds a row pointing at [path].
  ///
  /// The difference between "this file is finished" and "this file is finished
  /// AND the app knows about it": the integration writes the FITS and then
  /// records it, so a kill between the two leaves a whole master nothing
  /// references. That is a real thing to tell the operator, and it is not the
  /// same thing as a damaged file.
  Future<bool> _masterIsRegistered(String path) async {
    final rows = await customSelect(
      'SELECT 1 FROM integrated_masters WHERE master_fits_path = ? LIMIT 1',
      variables: [Variable<String>(path)],
    ).get();
    return rows.isNotEmpty;
  }
}

/// A `darkroom_jobs` row a dead process left `running`, read at open BEFORE the
/// recovery rewrites it.
///
/// It is the evidence of which STAGE of the post-session pass the kill landed
/// in: the integrate enqueues the Darkroom job only after the masters exist, so
/// a row here means the integration for that session had finished and the
/// DRAFT is what stopped.
class _InterruptedDarkroomJob {
  /// `darkroom_jobs.id`, named in the report so the operator can find the row.
  final int jobId;

  /// The session the job was processing, or null for a job queued outside one
  /// — which no session-scoped marker can match.
  final int? sessionId;

  /// `dawn` or `manual`. The pass a post-session marker covers is always
  /// `dawn` — `AutoIntegrationService` runs it through
  /// `DawnAutopilotService.runDawnForSession` — while `manual` is the
  /// operator's separate "Process now", which writes no marker at all.
  final String? kind;

  /// `darkroom_jobs.created_at`, whole seconds since the epoch, or null on a
  /// row that carries none.
  final int? createdAtEpochSeconds;

  /// Fraction complete `0.0 .. 1.0` as the dead attempt last reported it. Left
  /// where it was by the recovery precisely so this can be stated.
  final double progress;

  /// How many times the job had been started, including the attempt that died.
  final int attempts;

  const _InterruptedDarkroomJob({
    required this.jobId,
    required this.sessionId,
    required this.kind,
    required this.createdAtEpochSeconds,
    required this.progress,
    required this.attempts,
  });

  /// Whether the recovery re-queued this job rather than failing it, by the
  /// same rule the recovery's own `WHERE` clause applies.
  bool get willRetry => attempts < kDarkroomJobMaxAttempts;

  /// Whether this row is the Darkroom pass the marker written at
  /// [markerStartedAtUtc] for [markerSessionId] was covering.
  ///
  /// Identity, not "same session". A night carries the operator's "Process
  /// now" presses as well as its own automatic pass, and a `manual` row that
  /// was already running when the integrate started is indistinguishable from
  /// this pass's row by session alone. Reading one as the other asserts the
  /// integrate had finished — because a pass row only exists once the masters
  /// do — and tells the operator not to re-run the integration, on a night
  /// whose marker says the masters were still being written and may be
  /// half-finished on disk.
  ///
  /// Two conditions, both from the row: the marker's pass is always `dawn`
  /// (`runDawnForSession`), and it cannot predate the marker that covers it.
  /// The instant is floored to the second `created_at` is stored in, so a job
  /// inserted milliseconds after the marker still counts as this pass's.
  bool isPassFor(int markerSessionId, DateTime markerStartedAtUtc) {
    if (sessionId != markerSessionId) return false;
    if (kind != 'dawn') return false;
    final createdAt = createdAtEpochSeconds;
    if (createdAt == null) return false;
    return createdAt >= markerStartedAtUtc.millisecondsSinceEpoch ~/ 1000;
  }
}
