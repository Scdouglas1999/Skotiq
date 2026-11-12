import 'run_record.dart';

/// A run that ended this session: which plan it ran and when it ended.
class LastEndedRun {
  const LastEndedRun({
    required this.sequenceId,
    required this.endedAt,
    this.planLoadedOnHost,
  });

  /// The plan's id in the app that ran it. A plan's id is made when the plan
  /// is opened and is not part of its document, so the host's id for a plan
  /// and a linked client's id for the same plan differ.
  final String sequenceId;
  final DateTime endedAt;

  /// On a linked client, whether the host still has that plan loaded, as the
  /// host says; null in the app that ran the plan and from a host that does
  /// not say.
  final bool? planLoadedOnHost;

  /// Whether the plan this run ran is still the one loaded, [loadedSequenceId]
  /// being this app's.
  bool ranLoadedPlan(String? loadedSequenceId) =>
      planLoadedOnHost ?? sequenceId == loadedSequenceId;
}

/// When the current or last run started, as this app saw it start (on a
/// linked client, as the host saw it); null before any run this session.
/// Frames captured before it belong to earlier runs.
final runStartedAtProvider = runRecordProvider.select((run) => run.startedAt);

/// The last run that ended this session, whether it completed, failed, was
/// stopped or ended at dawn; null before any, and cleared when the next run
/// starts. On a linked client it is the host's.
final lastEndedRunProvider = runRecordProvider.select((run) => run.lastEnded);
