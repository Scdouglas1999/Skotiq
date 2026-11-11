import 'package:skotiq_core/skotiq_core.dart';

/// [ReplayDebugLog] on a linked host.
final class RemoteReplayDebugLog implements ReplayDebugLog {
  RemoteReplayDebugLog(this._host);

  final NetworkBackend _host;

  @override
  Future<List<ReplayDecision>> listDecisions(int runId) =>
      _host.replayListDecisions(runId);

  @override
  Future<int> countDecisions(int runId) => _host.replayCountDecisions(runId);

  @override
  Future<int> countAllDecisions() => _host.replayCountAllDecisions();

  @override
  Future<ReplayDebugSettings> getSettings() => _host.replayGetSettings();

  @override
  Future<void> setEnabled(bool enabled) => _host.replaySetEnabled(enabled);

  @override
  Future<void> setRetentionDays(int days) => _host.replaySetRetentionDays(days);

  @override
  Future<int> clearHistory() => _host.replayClearHistory();
}
