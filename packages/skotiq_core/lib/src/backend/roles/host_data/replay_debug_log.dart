import 'package:skotiq_core/skotiq_core.dart';

/// The sequencer decision log of a linked imaging host and its logging settings.
abstract interface class ReplayDebugLog {
  /// Chronological decision list for [runId] from the host. Mirrors the
  /// local `ReplayDebugService.listByRun` ordering.
  Future<List<ReplayDecision>> listDecisions(int runId);

  /// Authoritative one-shot count of decisions for [runId] from the host.
  Future<int> countDecisions(int runId);

  /// Authoritative count of every decision the host holds, across all runs.
  ///
  /// Same endpoint as [replayCountDecisions] with the run filter omitted. A
  /// host too old to understand that answers 400, which surfaces here as a
  /// thrown error — the caller states that it does not know the size rather
  /// than showing a made-up one.
  Future<int> countAllDecisions();

  /// Read the host's authoritative replay settings (enabled + retention).
  Future<ReplayDebugSettings> getSettings();

  /// Ask the host to persist its `replay_debug.enabled` setting AND mirror
  /// the flag into the host executor as one authority-preserving operation
  /// (the host handler rolls the persist back if the executor update
  /// fails). Never touches the remote client's local database.
  Future<void> setEnabled(bool enabled);

  /// Ask the host to persist its `replay_debug.retention_days` setting.
  Future<void> setRetentionDays(int days);

  /// Ask the host to delete every decision row. Returns the number removed.
  Future<int> clearHistory();
}
