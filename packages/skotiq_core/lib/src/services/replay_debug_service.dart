import 'dart:async';

import 'package:drift/drift.dart' as drift;

import '../database/database.dart' as db;
import '../models/replay_decision.dart';

/// Replay Debug — persistence + reactive query layer for the
/// `sequence_decisions` table.
///
/// Uses raw SQL (the table lives outside the `@DriftDatabase` declaration
/// to avoid forcing a codegen pass on every CI run — same convention
/// the v29 `notes_journal` table follows). The service:
///   * Lazily ensures the schema on first access via [_ensureSchema].
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

  /// Idempotent schema bootstrap. Matches the migration block in
  /// `database.dart` v31 plus the fresh-install bootstrap so a service
  /// constructed against a pre-v31 connection still works.
  static const String schemaCreateTableSql =
      'CREATE TABLE IF NOT EXISTS sequence_decisions ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'sequence_run_id INTEGER,'
      'timestamp_unix_ms INTEGER NOT NULL,'
      'category TEXT NOT NULL,'
      'summary TEXT NOT NULL,'
      'details_json TEXT NOT NULL DEFAULT \'{}\','
      'node_id TEXT)';

  static const String schemaRunIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_run '
      'ON sequence_decisions (sequence_run_id)';
  static const String schemaTimestampIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_timestamp '
      'ON sequence_decisions (timestamp_unix_ms)';
  static const String schemaCategoryIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_category '
      'ON sequence_decisions (category)';
  static const String schemaRunTimestampIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_run_ts '
      'ON sequence_decisions (sequence_run_id, timestamp_unix_ms)';

  bool _schemaEnsured = false;
  Future<void> _ensureSchema() async {
    if (_schemaEnsured) return;
    await _db.customStatement(schemaCreateTableSql);
    await _db.customStatement(schemaRunIndexSql);
    await _db.customStatement(schemaTimestampIndexSql);
    await _db.customStatement(schemaCategoryIndexSql);
    await _db.customStatement(schemaRunTimestampIndexSql);
    _schemaEnsured = true;
  }

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
    await _ensureSchema();
    final columns = decision.toInsertColumns();
    // Use `customStatement` (rather than `customInsert`) because the
    // former cleanly bind-passes a `List<Object?>` whose nullable
    // entries Drift maps to SQLite `NULL`. `customInsert` requires
    // typed `drift.Variable` instances which do not have a clean
    // nullable representation across versions.
    await _db.customStatement(
      'INSERT INTO sequence_decisions '
      '(sequence_run_id, timestamp_unix_ms, category, summary, details_json, node_id) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>[
        columns['sequence_run_id'],
        columns['timestamp_unix_ms'],
        columns['category'],
        columns['summary'],
        columns['details_json'],
        columns['node_id'],
      ],
    );
    final newIdRow = await _db
        .customSelect('SELECT last_insert_rowid() AS id')
        .getSingle();
    final newId = (newIdRow.data['id'] as int?) ?? 0;
    _notify();
    return newId;
  }

  /// Delete all decisions for a specific run. Used by the "Clear log"
  /// operation in the replay screen and by tests that want a clean
  /// baseline.
  Future<int> deleteForRun(int sequenceRunId) async {
    await _ensureSchema();
    final removed = await _db.customUpdate(
      'DELETE FROM sequence_decisions WHERE sequence_run_id = ?',
      variables: [drift.Variable.withInt(sequenceRunId)],
      updateKind: drift.UpdateKind.delete,
    );
    if (removed > 0) _notify();
    return removed;
  }

  /// Delete every persisted decision across all runs. Returns the number
  /// of rows removed. Used by the "Clear all replay history" affordance and
  /// the host `POST /api/sequencer/replay-debug/clear` endpoint. Unlike the
  /// far-future [pruneOlderThan] trick this cannot miss rows whose timestamp
  /// sits in the future because of clock skew.
  Future<int> deleteAll() async {
    await _ensureSchema();
    final removed = await _db.customUpdate(
      'DELETE FROM sequence_decisions',
      updateKind: drift.UpdateKind.delete,
    );
    if (removed > 0) _notify();
    return removed;
  }

  /// Replay Debug — retention policy: prune rows older than
  /// the configured cut-off. Returns the number of pruned rows.
  /// `cutoff` is interpreted as "remove rows with timestamp_unix_ms
  /// strictly older than this instant". Idempotent.
  Future<int> pruneOlderThan(DateTime cutoff) async {
    await _ensureSchema();
    final removed = await _db.customUpdate(
      'DELETE FROM sequence_decisions WHERE timestamp_unix_ms < ?',
      variables: [
        drift.Variable.withInt(cutoff.toUtc().millisecondsSinceEpoch),
      ],
      updateKind: drift.UpdateKind.delete,
    );
    if (removed > 0) _notify();
    return removed;
  }

  // Reads.

  /// One-shot fetch of every decision for a given run, ordered
  /// chronologically (ascending by timestamp). Returns an empty list
  /// when there are no rows.
  Future<List<ReplayDecision>> listByRun(int sequenceRunId) async {
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, sequence_run_id, timestamp_unix_ms, category, summary, '
          'details_json, node_id '
          'FROM sequence_decisions '
          'WHERE sequence_run_id = ? '
          'ORDER BY timestamp_unix_ms ASC, id ASC',
          variables: [drift.Variable.withInt(sequenceRunId)],
        )
        .get();
    return rows
        .map((r) => ReplayDecision.fromDbRow(r.data))
        .toList(growable: false);
  }

  /// One-shot fetch of every decision in a category for a run.
  /// Convenience wrapper for the filter chip path on the replay screen.
  Future<List<ReplayDecision>> listByRunAndCategory(
    int sequenceRunId,
    DecisionCategory category,
  ) async {
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, sequence_run_id, timestamp_unix_ms, category, summary, '
          'details_json, node_id '
          'FROM sequence_decisions '
          'WHERE sequence_run_id = ? AND category = ? '
          'ORDER BY timestamp_unix_ms ASC, id ASC',
          variables: [
            drift.Variable.withInt(sequenceRunId),
            drift.Variable.withString(category.wireKey),
          ],
        )
        .get();
    return rows
        .map((r) => ReplayDecision.fromDbRow(r.data))
        .toList(growable: false);
  }

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
    await _ensureSchema();
    final rows = await _db
        .customSelect('SELECT COUNT(*) AS n FROM sequence_decisions')
        .get();
    if (rows.isEmpty) return 0;
    return (rows.first.data['n'] as int?) ?? 0;
  }

  /// Counts decisions for a run (used by the History list to display
  /// a "X decisions" badge next to each run).
  Future<int> countByRun(int sequenceRunId) async {
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM sequence_decisions WHERE sequence_run_id = ?',
          variables: [drift.Variable.withInt(sequenceRunId)],
        )
        .get();
    if (rows.isEmpty) return 0;
    return (rows.first.data['n'] as int?) ?? 0;
  }
}
