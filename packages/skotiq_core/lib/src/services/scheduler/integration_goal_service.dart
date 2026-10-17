import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../database/database.dart' as db;
import '../../models/scheduler/integration_goal.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import 'scheduler_queue_service.dart' show schedulerRemovedTargetsSchemaSql;
import '../../utils/resilient_poll_stream.dart';

/// SQL schema for the three scheduler tables.
///
/// Tables are managed outside drift's `@DriftDatabase` declaration (which
/// would require codegen) by issuing raw `CREATE TABLE IF NOT EXISTS`
/// statements on first access. Schema is additive only; no migrations are
/// needed because the tables are new and operator data is not at risk.
const _integrationGoalsSchema = '''
CREATE TABLE IF NOT EXISTS integration_goals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
  filter TEXT NOT NULL,
  exposure_seconds REAL NOT NULL,
  frame_count INTEGER NOT NULL,
  priority INTEGER NOT NULL DEFAULT 5,
  created_at INTEGER NOT NULL,
  UNIQUE(target_id, filter, exposure_seconds)
)
''';

const _targetConstraintsSchema = '''
CREATE TABLE IF NOT EXISTS target_constraints (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1
)
''';

const _horizonProfilesSchema = '''
CREATE TABLE IF NOT EXISTS horizon_profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  samples_json TEXT NOT NULL
)
''';

const _integrationGoalsTargetIndex =
    'CREATE INDEX IF NOT EXISTS idx_integration_goals_target ON integration_goals (target_id)';
const _targetConstraintsTargetIndex =
    'CREATE INDEX IF NOT EXISTS idx_target_constraints_target ON target_constraints (target_id)';

/// Persistence + business-logic for integration goals.
///
/// Persists `IntegrationGoal` rows in the database and computes per-goal
/// "remaining frames" by counting matching rows in `captured_images` for
/// the same `(target_id, filter)`. The captured-image match is filter-name
/// case-insensitive because users sometimes type 'Lum' and the wheel
/// reports 'L', etc.
class IntegrationGoalService {
  final db.SkotiqDatabase _db;
  bool _schemaEnsured = false;
  // Manual change-notification channel for the raw `integration_goals`
  // table: drift's reactive `watch()` only fires for tables it knows about
  // via codegen, and this table is created out-of-band with raw SQL.
  // Every mutation method below calls `_notifyMutated()` so subscribers of
  // [watchAll] see the change immediately.
  final StreamController<void> _mutations = StreamController<void>.broadcast();

  /// When non-null this service is running on a remote SLAVE: the goals live
  /// in the HOST DB, not the slave's empty local SQLite, so every read/write
  /// routes over `/api/integration-goals`. Null on the host (FfiBackend) and
  /// in tests — the local-DB path below is then taken verbatim, unchanged.
  final NetworkBackend? _remote;

  IntegrationGoalService(this._db, {NetworkBackend? remote}) : _remote = remote;

  void _notifyMutated() {
    if (!_mutations.isClosed) _mutations.add(null);
  }

  Future<void> dispose() async {
    await _mutations.close();
  }

  Future<void> _ensureSchema() async {
    if (_schemaEnsured) return;
    await _db.customStatement(_integrationGoalsSchema);
    await _db.customStatement(_integrationGoalsTargetIndex);
    _schemaEnsured = true;
  }

  /// Putting work on a target puts it back in the scheduler queue.
  ///
  /// An earlier "Remove from scheduler" left the target INELIGIBLE
  /// (`SchedulerQueueService`), and a new goal on it is the operator asking for
  /// it to be imaged again — otherwise the goal they just typed would sit there
  /// while the autopilot went on ignoring the target. Enforced here, in the one
  /// place goals are written, so the slave gets it too: its upsert runs on the
  /// host through `/api/integration-goals`.
  Future<void> _readmitToSchedulerQueue(int targetId) async {
    await _db.customStatement(schedulerRemovedTargetsSchemaSql);
    await _db.customStatement(
      'DELETE FROM scheduler_removed_targets WHERE target_id = ?',
      [targetId],
    );
  }

  /// Insert a new integration goal. The (target_id, filter, exposure)
  /// uniqueness constraint replaces an existing row with the same key so
  /// the operator can iteratively tune one filter's goal without leaving
  /// duplicates.
  Future<int> upsert(IntegrationGoal goal) async {
    final remote = _remote;
    if (remote != null) {
      final id = await remote.upsertIntegrationGoal(goal);
      _notifyMutated();
      return id;
    }
    await _ensureSchema();
    await _readmitToSchedulerQueue(goal.targetId);
    final existing = await _db
        .customSelect(
          'SELECT id FROM integration_goals WHERE target_id = ? AND filter = ? AND exposure_seconds = ?',
          variables: [
            Variable.withInt(goal.targetId),
            Variable.withString(goal.filter),
            Variable.withReal(goal.exposureSeconds),
          ],
        )
        .getSingleOrNull();
    if (existing != null) {
      final id = existing.read<int>('id');
      await _db.customStatement(
        'UPDATE integration_goals SET frame_count = ?, priority = ? WHERE id = ?',
        [goal.frameCount, goal.priority, id],
      );
      _notifyMutated();
      return id;
    }
    final inserted = await _db.customInsert(
      'INSERT INTO integration_goals (target_id, filter, exposure_seconds, frame_count, priority, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withInt(goal.targetId),
        Variable.withString(goal.filter),
        Variable.withReal(goal.exposureSeconds),
        Variable.withInt(goal.frameCount),
        Variable.withInt(goal.priority),
        Variable.withInt(goal.createdAt.toUtc().millisecondsSinceEpoch ~/ 1000),
      ],
    );
    _notifyMutated();
    return inserted;
  }

  Future<void> delete(int goalId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteIntegrationGoal(goalId);
      _notifyMutated();
      return;
    }
    await _ensureSchema();
    await _db.customStatement('DELETE FROM integration_goals WHERE id = ?', [
      goalId,
    ]);
    _notifyMutated();
  }

  /// Remove every integration goal attached to [targetId]. Used by the
  /// scheduler queue's per-row delete and clear-all actions; the target
  /// itself stays in the catalog.
  Future<void> deleteForTarget(int targetId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteIntegrationGoalsForTarget(targetId);
      _notifyMutated();
      return;
    }
    await _ensureSchema();
    await _db.customStatement(
      'DELETE FROM integration_goals WHERE target_id = ?',
      [targetId],
    );
    _notifyMutated();
  }

  /// Remove every integration goal in the database. Used by the scheduler
  /// queue's clear-all action.
  Future<void> deleteAll() async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteAllIntegrationGoals();
      _notifyMutated();
      return;
    }
    await _ensureSchema();
    await _db.customStatement('DELETE FROM integration_goals');
    _notifyMutated();
  }

  /// Live stream of every integration goal. Emits an initial snapshot
  /// immediately, then a fresh list on every insert / update / delete the
  /// service itself performs. Used by the scheduler provider to wake the
  /// engine on operator edits without polling.
  Stream<List<IntegrationGoal>> watchAll() async* {
    final remote = _remote;
    if (remote != null) {
      // On a slave the host owns the goals; there is no local mutation stream
      // to listen to, so poll the host on a fixed tick. A change-guard
      // suppresses unchanged re-fetches (mirrors database_provider's
      // _pollRemote). Our own optimistic mutations are picked up by the next
      // poll within the interval.
      yield* resilientDistinctPoll(
        fetch: remote.getIntegrationGoals,
        unchanged: _goalListEquals,
        interval: const Duration(seconds: 10),
      );
      return;
    }
    await _ensureSchema();
    yield await listAll();
    await for (final _ in _mutations.stream) {
      yield await listAll();
    }
  }

  Future<List<IntegrationGoal>> listForTarget(int targetId) async {
    final remote = _remote;
    if (remote != null) {
      return remote.getIntegrationGoals(targetId: targetId);
    }
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, target_id, filter, exposure_seconds, frame_count, priority, created_at '
          'FROM integration_goals WHERE target_id = ? ORDER BY priority DESC, filter ASC',
          variables: [Variable.withInt(targetId)],
        )
        .get();
    return rows.map(_rowToGoal).toList();
  }

  Future<List<IntegrationGoal>> listAll() async {
    final remote = _remote;
    if (remote != null) {
      return remote.getIntegrationGoals();
    }
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, target_id, filter, exposure_seconds, frame_count, priority, created_at FROM integration_goals',
        )
        .get();
    return rows.map(_rowToGoal).toList();
  }

  static bool _goalListEquals(
    List<IntegrationGoal> a,
    List<IntegrationGoal> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Compute the captured-frame count for one (target, filter) pair.
  ///
  /// Counts only frames with frame_type='light' and is_accepted=1 so
  /// rejected subs do not artificially advance the goal. Filter matching
  /// is case-insensitive.
  Future<int> capturedFrameCount({
    required int targetId,
    required String filter,
  }) async {
    final remote = _remote;
    if (remote != null) {
      // Counts MUST come from the host's captured_images, never the slave's
      // empty local DB, or every goal looks 0/N and ranking/dwell is wrong.
      return remote.getCapturedFrameCount(targetId: targetId, filter: filter);
    }
    final rows = await _db
        .customSelect(
          "SELECT COUNT(*) AS c FROM captured_images "
          "WHERE target_id = ? AND frame_type = 'light' AND is_accepted = 1 "
          "AND LOWER(filter) = LOWER(?)",
          variables: [Variable.withInt(targetId), Variable.withString(filter)],
        )
        .get();
    if (rows.isEmpty) return 0;
    return rows.first.read<int>('c');
  }

  /// Return all goals for a target paired with their captured counts.
  Future<List<IntegrationGoalProgress>> progressForTarget(int targetId) async {
    final goals = await listForTarget(targetId);
    final out = <IntegrationGoalProgress>[];
    for (final g in goals) {
      final captured = await capturedFrameCount(
        targetId: g.targetId,
        filter: g.filter,
      );
      out.add(IntegrationGoalProgress(goal: g, capturedCount: captured));
    }
    return out;
  }

  IntegrationGoal _rowToGoal(QueryRow row) {
    return IntegrationGoal(
      id: row.read<int>('id'),
      targetId: row.read<int>('target_id'),
      filter: row.read<String>('filter'),
      exposureSeconds: row.read<double>('exposure_seconds'),
      frameCount: row.read<int>('frame_count'),
      priority: row.read<int>('priority'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('created_at') * 1000,
        isUtc: true,
      ),
    );
  }
}

final integrationGoalServiceProvider = Provider<IntegrationGoalService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = IntegrationGoalService(
    ref.watch(databaseProvider),
    remote: backend is NetworkBackend ? backend : null,
  );
  ref.onDispose(() => service.dispose());
  return service;
});

/// Re-used DDL strings exported so the scheduler engine init can ensure
/// all three tables exist in one place.
const String integrationGoalsSchemaSql = _integrationGoalsSchema;
const String integrationGoalsTargetIndexSql = _integrationGoalsTargetIndex;
const String targetConstraintsSchemaSql = _targetConstraintsSchema;
const String targetConstraintsTargetIndexSql = _targetConstraintsTargetIndex;
const String horizonProfilesSchemaSql = _horizonProfilesSchema;
