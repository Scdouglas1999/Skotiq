/// The one honest close for an `imaging_sessions` row left `active` by a
/// process that is no longer driving it.
///
/// **Why one rule shared by two callers.** The row is closed from two places
/// and they must not drift: the boot sweep in `beforeOpen`, which runs before
/// anything in the process can open a session, and [SessionService] at
/// sequence start, which runs it when this process holds no live session of
/// its own. Both are answering the same question — "this row says a night is
/// in progress and no executor is driving it; what is true?" — so both write
/// the same status, the same end time and the same note.
///
/// **What went wrong without it.** `SessionsDao.startSession` refuses to open a
/// second row while an older one is `active`, and every caller of that method
/// treats the refusal as "no session row". A daemon stopped mid-run (a cloud
/// call at 2am, the updater, a power blip) therefore left row N `active`
/// forever, and from the next launch onward EVERY frame of EVERY night
/// registered with `session_id` NULL: the session-end hooks that key on the
/// session id — post-session integration, the dawn Darkroom pass — never fired,
/// no masters and no drafts were made, and `GET /api/sessions/active` kept
/// serving the dead run's frozen counters while a live run captured.
///
/// **The frames already stranded are left where they are.** A database that ran
/// the old code carries `captured_images` rows with `session_id` NULL, and the
/// sweep does not adopt them. It cannot: while row N stood open every later
/// night's frames landed NULL, so the only clue to which night a stranded frame
/// belongs is its `captured_at` — and the abandoned session's window covers all
/// of them, which would file three separate nights under the one row that was
/// stuck. Attaching by proximity would turn a visible gap into a confident
/// wrong answer, and every per-night figure built on it (integration time,
/// efficiency, the History card) would inherit the guess.
///
/// They stay reachable rather than lost: `ImagesDao.watchStandaloneImages` —
/// what Analytics' Session tab lists as sessionless captures, alongside single
/// frames taken outside any sequence — reads exactly this set, and each row
/// keeps its file path, target, filter and timestamp. What they cannot do is
/// re-enter a session-keyed pass; an operator who wants masters from such a
/// night integrates those frames by hand. From this sweep forward the set stops
/// growing, which is the half that was actually in reach.
library;

/// What a session that a process abandoned reads as.
///
/// The same word `sequence_runs` uses for the same event, written by the sweep
/// in the same `beforeOpen` block — a run and the night around it were
/// interrupted by one process exit and an operator reading History should not
/// have to learn two vocabularies for it. Deliberately NOT 'completed' (the
/// night did not finish) and not 'aborted' (nobody asked it to stop).
const String kInterruptedSessionStatus = 'interrupted';

/// Closes every `imaging_sessions` row still `active`.
///
/// `end_time` is the session's LAST ACTUAL ACTIVITY — the newest
/// `captured_images.captured_at` for the session — not the wall clock of the
/// recovery, which is the same rule and the same reason as
/// `SessionsDao.abortSession`: a night abandoned on Wednesday and found on
/// Friday was stamped with Friday's clock, so its History card and every
/// efficiency figure derived from it reported a 60-hour night. A session with
/// no frames captured nothing, so it collapses to `start_time` (zero duration)
/// rather than inventing an end. Clamped to `[start_time, now]` so a bad clock
/// or a future-dated frame cannot produce a negative or still-growing
/// duration.
///
/// Bound values, in order: the recovery instant in unix seconds, then the note
/// twice (the `CASE` appends it to existing notes rather than replacing them —
/// the interrupted-integration report writes into the same column).
const String kCloseOrphanedSessionsSql =
    'UPDATE imaging_sessions SET '
    "status = '$kInterruptedSessionStatus', "
    'end_time = MAX(start_time, MIN(?, COALESCE('
    '(SELECT MAX(c.captured_at) FROM captured_images c '
    'WHERE c.session_id = imaging_sessions.id), start_time))), '
    "notes = CASE WHEN notes IS NULL OR notes = '' THEN ? "
    "ELSE notes || char(10) || ? END "
    "WHERE status = 'active'";

/// Reads every row the sweep is about to close, so the caller can log which
/// nights it touched and a test can assert on them.
const String kSelectOrphanedSessionsSql =
    'SELECT id, name, start_time FROM imaging_sessions '
    "WHERE status = 'active' ORDER BY id ASC";

/// The sentence written onto the closed session, naming what ended it.
///
/// [cause] completes "This night was still open when ..." and is supplied by
/// whichever caller found the row, because they know different things: the boot
/// sweep knows only that the previous process is gone, while the sequence-start
/// close knows a new run is being opened on top of it.
///
/// The note states the end-time rule outright. A reader who sees a session that
/// ran 09:12 to 09:19 and knows the rig was on all night would otherwise
/// conclude the row was truncated by a bug rather than by the last frame.
String interruptedSessionNote({
  required String cause,
  required DateTime found,
}) {
  final at = found.toUtc().toIso8601String();
  return 'This night was still open when $cause, so it is recorded as '
      'interrupted rather than completed (found at $at UTC). Its end time is '
      'the last frame it captured, or its start time when it captured none — '
      'not the moment it was found, which would have counted the whole '
      'downtime as imaging.';
}

/// The line appended when an operator resumes a night the sweep had closed.
///
/// The interruption note is left standing rather than deleted, for the reason
/// the Darkroom retry-limit correction leaves its predecessor standing: it was
/// true when it was written, and the notes column is a record in order. This
/// says the gap ended, so the row does not read as closed while it is live.
String resumedSessionNote(DateTime resumedAt) =>
    'Resumed at ${resumedAt.toUtc().toIso8601String()} UTC from Continue '
    'Session. The interruption above stands for the gap; frames captured from '
    'here belong to this session again.';

/// What the boot sweep in `beforeOpen` passes as [interruptedSessionNote]'s
/// cause: a previous process opened this row and is gone.
const String kInterruptedBySessionShutdownCause =
    'Skotiq closed without ending it';

/// What the sequence-start close passes: this process is opening tonight's
/// session and found last night's still standing.
const String kInterruptedByNewSequenceCause =
    'a new sequence started and no run was driving it';
