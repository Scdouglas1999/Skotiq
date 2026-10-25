import 'dart:async';

import '../../../database/daos/sequence_runs_dao.dart';
import '../../../services/logging_service.dart';
import '../../sequence_stats_provider.dart' show SequenceRunStats;

/// The live statistics of the running run: the in-memory record the live
/// surfaces watch, its incremental persistence, and the seal that hands it to
/// the final `finishRun` write.
///
/// Invariant: once [sealAndDrain] has started, no incremental write is
/// submitted and every one submitted before it has settled, so nothing lands
/// after the final stats JSON. [reopen] lifts the seal for the next run.
class RunStatsLedger {
  RunStatsLedger({
    required SequenceRunStats? Function() readStats,
    required void Function(SequenceRunStats stats) publishStats,
    required int? Function() readRunId,
    required SequenceRunsDao Function() runsDao,
    required LoggingService Function() logger,
  }) : _readStats = readStats,
       _publishStats = publishStats,
       _readRunId = readRunId,
       _runsDao = runsDao,
       _logger = logger;

  final SequenceRunStats? Function() _readStats;
  final void Function(SequenceRunStats stats) _publishStats;
  final int? Function() _readRunId;
  final SequenceRunsDao Function() _runsDao;
  final LoggingService Function() _logger;

  bool _sealed = false;
  final Set<Future<void>> _pendingWrites = <Future<void>>{};

  bool get isSealed => _sealed;

  /// The live run's stats, or null when no run is live.
  SequenceRunStats? get current => _readStats();

  /// Apply [mutate] to the live stats and, when [persist] is true, write them
  /// to the run row. A no-op once sealed or when no run is live.
  ///
  /// [persist] = false is for facts established at run start that cannot
  /// change during the run: the final `finishRun` write carries them, and an
  /// extra write is one more chance to land after the seal.
  void update(
    void Function(SequenceRunStats stats) mutate, {
    bool persist = true,
  }) {
    if (_sealed) return;
    final stats = _readStats();
    if (stats == null) return;
    mutate(stats);
    // A fresh copy, so the provider's identity check notifies its listeners.
    _publishStats(stats.copy());
    if (persist) _persist();
  }

  void _persist() {
    if (_sealed) return;
    final runId = _readRunId();
    final stats = _readStats();
    if (runId == null || stats == null) return;
    final write = _runsDao().updateStats(runId, stats.toJson());
    _pendingWrites.add(write);
    // Handled here: a write that fails mid-night must not reach the zone as an
    // unhandled error, and only writes still pending at the seal are drained.
    final logger = _logger();
    unawaited(
      write
          .catchError((Object e) {
            logger.warning(
              'Failed to persist live run stats for run $runId: $e',
              source: 'SequenceExecutor',
            );
          })
          .whenComplete(() => _pendingWrites.remove(write)),
    );
  }

  /// Seal the stats, then wait for every write submitted before the seal.
  /// Write errors are already logged and do not block the final write.
  /// Idempotent, so a finalization retry can call it again.
  Future<void> sealAndDrain() async {
    _sealed = true;
    if (_pendingWrites.isEmpty) return;
    final batch = _pendingWrites.toList();
    _pendingWrites.clear();
    await Future.wait(batch.map((w) => w.catchError((Object _) {})));
  }

  /// Lift the seal and forget the previous run's writes, for a new run.
  void reopen() {
    _sealed = false;
    _pendingWrites.clear();
  }
}
