/// The status of a sequence run, as its `sequence_runs.status` row stores it.
///
/// A finished imaging session's `status` takes the same value from the run
/// that ended it.
enum SequenceRunStatus {
  /// Under way.
  running('running'),

  /// Under way, held at the operator's request.
  paused('paused'),

  /// Ran every planned step.
  completed('completed'),

  /// Ended on an error the sequencer could not recover from.
  failed('failed'),

  /// Ended by the native side itself: a trigger's park, a watchdog, a safety
  /// rule.
  aborted('aborted'),

  /// Stopped by the operator with no checkpoint kept.
  stopped('stopped'),

  /// Stopped by the operator with the checkpoint kept, so it can be resumed.
  stoppedResumable('paused-stopped'),

  /// Left live by a process that died; reconciled at the next start.
  interrupted('interrupted');

  const SequenceRunStatus(this.token);

  /// The stored spelling.
  final String token;

  /// The status [token] spells, or null for a value that is not a run status
  /// (a session's `active` or `error`, or one a newer build wrote).
  static SequenceRunStatus? tryParse(String? token) {
    for (final status in values) {
      if (status.token == token) return status;
    }
    return null;
  }

  /// The run is still held by an executor.
  bool get isLive => this == running || this == paused;

  /// The operator ended the run: the one ending that is not a fault.
  bool get stoppedByOperator => this == stopped || this == stoppedResumable;

  /// The run ended on a stop, the operator's or the native side's own.
  bool get endedByStop => stoppedByOperator || this == aborted;
}
