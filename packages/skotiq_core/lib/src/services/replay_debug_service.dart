import 'dart:async';

import 'package:drift/drift.dart' as drift;

import '../database/database.dart' as db;
import '../models/replay_decision.dart';

/// Replay Debug — persistence + reactive query layer for the
/// `sequence_decisions` table.
///
/// Reads and writes go through [db.SequenceDecisionsDao]. The service:
///   * Broadcasts a manual change-notification on every mutation so
///     [watchByRun] subscribers see updates without polling.
///   * Returns immutable [ReplayDecision] records.
///
/// The Rust bridge subscribes to the executor's decision channel and
/// publishes `SequencerEvent::DecisionLogged` events; the Dart-side
/// `SequenceExecutor` calls [persistFromBridgeEvent] for every event
/// so the DB and the live stream stay in lockstep.
class ReplayDebugService {
  ReplayDebugService(this._db);

  final db.SkotiqDatabase _db;

  // Change-notification fan-out.
  //
  // Each subscriber listens on its own stream over the broadcast bus so
  // multiple replay screens (desktop + web-remote viewers) all see fresh
  // data after a write. The `_notify()` call after every mutation flushes
  // a tick that downstream stream-builders rebuild on.
  final _changeBus = StreamController<void>.broadcast();
  void _notify() {
    if (!_changeBus.isClosed) {
      _changeBus.add(null);
    }
  }

  /// Visible for tests. Closes the broadcast bus.
  Future<void> dispose() async {
    await _changeBus.close();
  }

  // Writes.

  /// Persist a decision built from a Rust bridge event. Returns the
  /// inserted row id.
  Future<int> persistFromBridgeEvent({
    required String timestampIso,
    required String categoryWireKey,
    required String summary,
    required String detailsJson,
    String? nodeId,
    int? sequenceRunId,
  }) async {
    final decision = ReplayDecision.fromBridgeEvent(
      timestampIso: timestampIso,
      categoryWireKey: categoryWireKey,
      summary: summary,
      detailsJson: detailsJson,
      nodeId: nodeId,
      sequenceRunId: sequenceRunId,
    );
    return persist(decision);
  }

  /// Persist an already-constructed [ReplayDecision]. Returns the
  /// assigned row id (SQLite's `last_insert_rowid()`).
  Future<int> persist(ReplayDecision decision) async {
    final columns = decision.toInsertColumns();
    final newId = await _db.sequenceDecisionsDao.insertDecision(
      db.SequenceDecisionsCompanion.insert(
        sequenceRunId: drift.Value(columns['sequence_run_id'] as int?),
        timestampUnixMs: columns['timestamp_unix_ms']! as int,
        category: columns['category']! as String,
        summary: columns['summary']! as String,
        detailsJson: drift.Value(columns['details_json']! as String),
        nodeId: drift.Value(columns['node_id'] as String?),
      ),
    );
    _notify();
    return newId;
  }

  /// Delete all decisions for a specific run. Used by the "Clear log"
  /// operation in the replay screen and by tests that want a clean
  /// baseline.
  Future<int> deleteForRun(int sequenceRunId) async {
    final removed = await _db.sequenceDecisionsDao.deleteForRun(sequenceRunId);
    if (removed > 0) _notify();
    return removed;
  }

  /// Delete every persisted decision across all runs. Returns the number
  /// of rows removed. Used by the "Clear all replay history" affordance and
  /// the host `POST /api/sequencer/replay-debug/clear` endpoint. Unlike the
  /// far-future [pruneOlderThan] trick this cannot miss rows whose timestamp
  /// sits in the future because of clock skew.
  Future<int> deleteAll() async {
    final removed = await _db.sequenceDecisionsDao.deleteAll();
    if (removed > 0) _notify();
    return removed;
  }

  /// Replay Debug — retention policy: prune rows older than
  /// the configured cut-off. Returns the number of pruned rows.
  /// `cutoff` is interpreted as "remove rows with timestamp_unix_ms
  /// strictly older than this instant". Idempotent.
  Future<int> pruneOlderThan(DateTime cutoff) async {
    final removed = await _db.sequenceDecisionsDao.deleteOlderThan(
      cutoff.toUtc().millisecondsSinceEpoch,
    );
    if (removed > 0) _notify();
    return removed;
  }

  // Reads.

  /// One-shot fetch of every decision for a given run, ordered
  /// chronologically (ascending by timestamp). Returns an empty list
  /// when there are no rows.
  Future<List<ReplayDecision>> listByRun(int sequenceRunId) async {
    final rows = await _db.sequenceDecisionsDao.decisionsForRun(sequenceRunId);
    return rows.map(_toDecision).toList(growable: false);
  }

  /// One-shot fetch of every decision in a category for a run.
  /// Convenience wrapper for the filter chip path on the replay screen.
  Future<List<ReplayDecision>> listByRunAndCategory(
    int sequenceRunId,
    DecisionCategory category,
  ) async {
    final rows = await _db.sequenceDecisionsDao.decisionsForRun(
      sequenceRunId,
      category: category.wireKey,
    );
    return rows.map(_toDecision).toList(growable: false);
  }

  static ReplayDecision _toDecision(db.SequenceDecisionRow row) =>
      ReplayDecision.fromDbRow({
        'id': row.id,
        'sequence_run_id': row.sequenceRunId,
        'timestamp_unix_ms': row.timestampUnixMs,
        'category': row.category,
        'summary': row.summary,
        'details_json': row.detailsJson,
        'node_id': row.nodeId,
      });

  /// Reactive query — emits the full chronological list for the
  /// supplied run on every mutation. Emits immediately with the
  /// current state so a fresh subscriber doesn't have to wait for
  /// the first event.
  ///
  /// Returns a multi-subscription stream backed by a personal
  /// controller per call: the broadcast `_changeBus` only notifies
  /// "something changed"; each `watchByRun` listener owns the read
  /// + emit loop. This pattern matches the v29 notes journal stream
  /// and keeps each subscriber's lifecycle independent — cancelling
  /// one does NOT detach the others from the change bus.
  Stream<List<ReplayDecision>> watchByRun(int sequenceRunId) {
    late StreamController<List<ReplayDecision>> controller;
    StreamSubscription<void>? sub;
    Future<void> push() async {
      if (controller.isClosed) return;
      try {
        controller.add(await listByRun(sequenceRunId));
      } catch (e, st) {
        if (!controller.isClosed) {
          controller.addError(e, st);
        }
      }
    }

    controller = StreamController<List<ReplayDecision>>(
      onListen: () {
        // Initial emission.
        push();
        sub = _changeBus.stream.listen((_) => push());
      },
      onCancel: () async {
        await sub?.cancel();
        sub = null;
      },
    );
    return controller.stream;
  }

  /// Counts every persisted decision across all runs.
  ///
  /// Used by the "Clear all replay history" confirmation so it can state the
  /// size of what it is about to destroy instead of asking the operator to
  /// agree to an unknown quantity.
  Future<int> countAll() async {
    return _db.sequenceDecisionsDao.countAll();
  }

  /// Counts decisions for a run (used by the History list to display
  /// a "X decisions" badge next to each run).
  Future<int> countByRun(int sequenceRunId) async {
    return _db.sequenceDecisionsDao.countForRun(sequenceRunId);
  }
}
