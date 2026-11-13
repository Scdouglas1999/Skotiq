import 'dart:async';

import 'package:drift/drift.dart' show Value;

import '../../database/database.dart' as db;
import '../../models/scheduler/integration_goal.dart';
import '../../utils/resilient_poll_stream.dart';
import '../../backend/remote_host.dart';

/// Persistence + business-logic for integration goals.
///
/// Persists `IntegrationGoal` rows in the database and computes per-goal
/// "remaining frames" by counting matching rows in `captured_images` for
/// the same `(target_id, filter)`. The captured-image match is filter-name
/// case-insensitive because users sometimes type 'Lum' and the wheel
/// reports 'L', etc.
class IntegrationGoalService {
  final db.SkotiqDatabase _db;
  // Every mutation method below calls `_notifyMutated()` so subscribers of
  // [watchAll] see the change immediately, on the host and on a slave alike.
  final StreamController<void> _mutations = StreamController<void>.broadcast();

  /// When non-null this service is running on a remote SLAVE: the goals live
  /// in the HOST DB, not the slave's empty local SQLite, so every read/write
  /// routes over `/api/integration-goals`. Null on the host (FfiBackend) and
  /// in tests — the local-DB path below is then taken verbatim, unchanged.
  final HostPlanningData? _remote;

  IntegrationGoalService(this._db, {HostPlanningData? remote}) : _remote = remote;

  void _notifyMutated() {
    if (!_mutations.isClosed) _mutations.add(null);
  }

  Future<void> dispose() async {
    await _mutations.close();
  }

  /// Putting work on a target puts it back in the scheduler queue.
  ///
  /// An earlier "Remove from scheduler" left the target INELIGIBLE
  /// (`SchedulerQueueService`), and a new goal on it is the operator asking for
  /// it to be imaged again — otherwise the goal they just typed would sit there
  /// while the autopilot went on ignoring the target. Enforced here, in the one
  /// place goals are written, so the slave gets it too: its upsert runs on the
  /// host through `/api/integration-goals`.
  Future<void> _readmitToSchedulerQueue(int targetId) =>
      _db.planningDao.readmitToSchedulerQueue(targetId);

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
    final dao = _db.planningDao;
    await _readmitToSchedulerQueue(goal.targetId);
    final existingId = await dao.integrationGoalId(
      targetId: goal.targetId,
      filter: goal.filter,
      exposureSeconds: goal.exposureSeconds,
    );
    if (existingId != null) {
      await dao.updateIntegrationGoal(
        existingId,
        frameCount: goal.frameCount,
        priority: goal.priority,
      );
      await _replaceOldTotalGoal(goal.targetId);
      _notifyMutated();
      return existingId;
    }
    final inserted = await dao.insertIntegrationGoal(
      db.IntegrationGoalsCompanion.insert(
        targetId: goal.targetId,
        filter: goal.filter,
        exposureSeconds: goal.exposureSeconds,
        frameCount: goal.frameCount,
        priority: Value(goal.priority),
        createdAt: goal.createdAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    await _replaceOldTotalGoal(goal.targetId);
    _notifyMutated();
    return inserted;
  }

  /// A per-filter goal replaces the target's old single hours goal
  /// (`targets.goal_integration_secs`), which only counts while the target has
  /// no per-filter goal; clearing it keeps it from coming back if the filter
  /// goals are deleted later.
  Future<void> _replaceOldTotalGoal(int targetId) async {
    final target = await _db.targetsDao.getTargetById(targetId);
    if (target == null || target.goalIntegrationSecs <= 0) return;
    await _db.targetsDao.updateProgress(targetId, goalIntegrationSecs: 0);
  }

  Future<void> delete(int goalId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteIntegrationGoal(goalId);
      _notifyMutated();
      return;
    }
    await _db.planningDao.deleteIntegrationGoal(goalId);
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
    await _db.planningDao.deleteIntegrationGoalsForTarget(targetId);
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
    await _db.planningDao.deleteAllIntegrationGoals();
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
    final rows = await _db.planningDao.integrationGoalsForTarget(targetId);
    return rows.map(_rowToGoal).toList();
  }

  Future<List<IntegrationGoal>> listAll() async {
    final remote = _remote;
    if (remote != null) {
      return remote.getIntegrationGoals();
    }
    final rows = await _db.planningDao.allIntegrationGoals();
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
    return _db.planningDao.acceptedLightFrameCount(
      targetId: targetId,
      filter: filter,
    );
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

  IntegrationGoal _rowToGoal(db.IntegrationGoalRow row) {
    return IntegrationGoal(
      id: row.id,
      targetId: row.targetId,
      filter: row.filter,
      exposureSeconds: row.exposureSeconds,
      frameCount: row.frameCount,
      priority: row.priority,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.createdAt * 1000,
        isUtc: true,
      ),
    );
  }
}
