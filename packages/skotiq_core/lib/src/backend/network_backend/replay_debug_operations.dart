part of '../network_backend.dart';

/// Replay Debug — remote-client accessors for the host's decision
/// log + retention policy.
///
/// These are NetworkBackend-specific (not part of the abstract
/// [SkotiqBackend] role) because they only make sense against a host:
/// a remote client reads the HOST's `sequence_decisions` table and
/// `app_settings` over REST instead of its own empty local database. The
/// authority-branching providers in `replay_debug_provider.dart` call
/// these only after asserting `backend is NetworkBackend`.
///
/// Every method fails loud: a 404 from an older host (no replay endpoints)
/// surfaces as a thrown error, never a false-empty list or fabricated
/// default, and each response is strictly decoded via the centralized
/// [ReplayDecision.fromWireJson] / [ReplayDebugSettings.fromWireJson]
/// codecs so a malformed payload throws rather than yielding a
/// plausible-but-wrong row.
mixin _NetworkBackendReplayDebugOperations on _NetworkBackendTransport {
  /// Chronological decision list for [runId] from the host. Mirrors the
  /// local `ReplayDebugService.listByRun` ordering.
  Future<List<ReplayDecision>> replayListDecisions(int runId) async {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
    final response = await _get('sequencer/replay-debug/decisions', {
      'runId': runId,
    });
    final decisions = _rowsFromJson(
      response['items'],
      (row) => ReplayDecision.fromWireJson(row),
    );
    final total = response['total'];
    if (total is! int || total < 0 || total != decisions.length) {
      throw FormatException(
        'GET /api/sequencer/replay-debug/decisions returned an invalid '
        '`total` ($total) for ${decisions.length} items',
      );
    }
    final seenIds = <int>{};
    DateTime? previousTimestamp;
    for (var index = 0; index < decisions.length; index++) {
      final decision = decisions[index];
      if (decision.sequenceRunId != runId) {
        throw FormatException(
          'GET /api/sequencer/replay-debug/decisions row $index belongs to '
          'run ${decision.sequenceRunId}, expected $runId',
        );
      }
      final id = decision.id!;
      if (!seenIds.add(id)) {
        throw FormatException(
          'GET /api/sequencer/replay-debug/decisions contains duplicate id $id',
        );
      }
      if (previousTimestamp != null &&
          decision.timestamp.isBefore(previousTimestamp)) {
        throw FormatException(
          'GET /api/sequencer/replay-debug/decisions is not chronological at '
          'row $index',
        );
      }
      previousTimestamp = decision.timestamp;
    }
    return decisions;
  }

  /// Authoritative one-shot count of decisions for [runId] from the host.
  Future<int> replayCountDecisions(int runId) async {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
    final response = await _get('sequencer/replay-debug/decisions/count', {
      'runId': runId,
    });
    final count = response['count'];
    if (count is! int || count < 0) {
      throw FormatException(
        'GET /api/sequencer/replay-debug/decisions/count returned a non-integer '
        '`count` (${count.runtimeType})',
      );
    }
    return count;
  }

  /// Authoritative count of every decision the host holds, across all runs.
  ///
  /// Same endpoint as [replayCountDecisions] with the run filter omitted. A
  /// host too old to understand that answers 400, which surfaces here as a
  /// thrown error — the caller states that it does not know the size rather
  /// than showing a made-up one.
  Future<int> replayCountAllDecisions() async {
    final response = await _get('sequencer/replay-debug/decisions/count');
    final count = response['count'];
    if (count is! int || count < 0) {
      throw FormatException(
        'GET /api/sequencer/replay-debug/decisions/count returned a '
        'non-integer `count` (${count.runtimeType})',
      );
    }
    return count;
  }

  /// Read the host's authoritative replay settings (enabled + retention).
  Future<ReplayDebugSettings> replayGetSettings() async {
    final response = await _get('sequencer/replay-debug/settings');
    return ReplayDebugSettings.fromWireJson(response);
  }

  /// Ask the host to persist its `replay_debug.enabled` setting AND mirror
  /// the flag into the host executor as one authority-preserving operation
  /// (the host handler rolls the persist back if the executor update
  /// fails). Never touches the remote client's local database.
  Future<void> replaySetEnabled(bool enabled) async {
    final response = await _post('sequencer/replay-debug/settings/enabled', {
      'enabled': enabled,
    });
    if (response['status'] != 'ok' || response['enabled'] != enabled) {
      throw const FormatException(
        'POST /api/sequencer/replay-debug/settings/enabled returned an '
        'invalid acknowledgement',
      );
    }
  }

  /// Ask the host to persist its `replay_debug.retention_days` setting.
  Future<void> replaySetRetentionDays(int days) async {
    if (days < 1 || days > 3650) {
      throw ArgumentError.value(days, 'days', 'must be between 1 and 3650');
    }
    final response = await _post('sequencer/replay-debug/settings/retention', {
      'days': days,
    });
    if (response['status'] != 'ok' || response['retentionDays'] != days) {
      throw const FormatException(
        'POST /api/sequencer/replay-debug/settings/retention returned an '
        'invalid acknowledgement',
      );
    }
  }

  /// Ask the host to delete every decision row. Returns the number removed.
  Future<int> replayClearHistory() async {
    final response = await _post('sequencer/replay-debug/clear');
    final removed = response['removed'];
    if (removed is! int || removed < 0) {
      throw FormatException(
        'POST /api/sequencer/replay-debug/clear returned a non-integer '
        '`removed` (${removed.runtimeType})',
      );
    }
    return removed;
  }
}
