import '../../database/database.dart' show ImagingSession;
import '../sequence/sequence_run_status.dart';

/// The status of an imaging session, as its `imaging_sessions.status` row
/// stores it.
///
/// A session a sequence run ended takes that run's ending; a session ended by
/// hand, by the session service or by the start-up sweep takes one of its own.
enum SessionStatus {
  /// Recording frames now.
  active('active'),

  completed('completed'),

  /// The run that held it hit an error it could not recover from.
  failed('failed'),

  /// Ended on an error by the session service or a client of the host's API.
  error('error'),

  /// Ended by the native side itself, by the operator abandoning the session,
  /// or when another session took its place.
  aborted('aborted'),

  /// The operator stopped the run, with no checkpoint kept.
  stopped('stopped'),

  /// The operator stopped the run, with the checkpoint kept.
  stoppedResumable('paused-stopped'),

  /// Left active by a process that died; closed at the next start. The word
  /// `sequence_runs` uses for the same event: a run and the night around it
  /// are interrupted by one process exit. Not [completed] (the night did not
  /// finish) and not [aborted] (nobody asked it to stop).
  interrupted('interrupted');

  const SessionStatus(this.token);

  /// The stored spelling.
  final String token;

  /// The status [token] spells, or null for a value no build writes.
  static SessionStatus? tryParse(String? token) {
    for (final status in values) {
      if (status.token == token) return status;
    }
    return null;
  }

  /// The status a session ends with when the run holding it ended as [run].
  static SessionStatus endedBy(SequenceRunStatus run) => switch (run) {
    SequenceRunStatus.completed => completed,
    SequenceRunStatus.failed => failed,
    SequenceRunStatus.aborted => aborted,
    SequenceRunStatus.stopped => stopped,
    SequenceRunStatus.stoppedResumable => stoppedResumable,
    SequenceRunStatus.interrupted => interrupted,
    SequenceRunStatus.running ||
    SequenceRunStatus.paused => throw ArgumentError(
      'A session ends only on a finished run, not a ${run.token} one.',
    ),
  };

  /// The run ending this session status is, or null for the statuses only a
  /// session has.
  SequenceRunStatus? get runEnding => switch (this) {
    completed => SequenceRunStatus.completed,
    failed => SequenceRunStatus.failed,
    aborted => SequenceRunStatus.aborted,
    stopped => SequenceRunStatus.stopped,
    stoppedResumable => SequenceRunStatus.stoppedResumable,
    interrupted => SequenceRunStatus.interrupted,
    active || error => null,
  };
}

/// A session row's status, typed.
extension ImagingSessionStatus on ImagingSession {
  /// Null for a value no build writes.
  SessionStatus? get sessionStatus => SessionStatus.tryParse(status);
}
