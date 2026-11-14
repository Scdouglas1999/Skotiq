import '../../../models/replay_decision.dart';

/// The sequencer decision log of a linked imaging host and its logging settings.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostReplayDebug {
  Future<List<ReplayDecision>> replayListDecisions(int runId);

  Future<int> replayCountDecisions(int runId);

  Future<int> replayCountAllDecisions();

  Future<ReplayDebugSettings> replayGetSettings();

  Future<void> replaySetEnabled(bool enabled);

  Future<void> replaySetRetentionDays(int days);

  Future<int> replayClearHistory();
}
