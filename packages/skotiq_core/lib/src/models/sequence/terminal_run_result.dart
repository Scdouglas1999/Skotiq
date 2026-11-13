import 'sequence_models.dart' show SequenceExecutionState;
import 'sequence_run_status.dart';

/// Immutable, one-shot result of a fully-finalized sequence run.
///
/// The executor publishes exactly one of these to
/// `sequenceTerminalRunResultProvider` AFTER durable finalization (finishRun +
/// endSession) succeeds — i.e. after `currentRunIdProvider` and the durable
/// session have already been cleared. It carries a SNAPSHOT of the ids the
/// finished run owned so the auto-opening Session Report and its run-scoped
/// Journal resolve against the completed run instead of racing the live
/// providers that finalization has (correctly) just cleared.
///
/// [generation] is unique and monotonic per terminal event, giving consumers
/// event-consumption semantics: a screen reacts to the transition into a new
/// result, so a fresh mount (which only observes subsequent changes) never
/// reopens an already-consumed report.
class SequenceTerminalRunResult {
  const SequenceTerminalRunResult({
    required this.generation,
    required this.outcome,
    required this.runStatus,
    required this.runId,
    required this.dbSessionId,
    this.isCalibration = false,
  });

  final bool isCalibration;

  /// Unique, monotonically increasing id for this terminal event.
  final int generation;

  /// The settled UI state the run ended in: `completed`, `failed`, or `idle`
  /// (a stop / abort).
  final SequenceExecutionState outcome;

  /// The durable run-row status recorded for this run.
  final SequenceRunStatus runStatus;

  /// The finished run's `sequence_runs.id`, captured before finalization
  /// cleared `currentRunIdProvider`. Null when the run never got a row.
  final int? runId;

  /// The finished run's `sessions.id`, captured before finalization ended the
  /// durable session. Null when the run never opened a session.
  final int? dbSessionId;
}
