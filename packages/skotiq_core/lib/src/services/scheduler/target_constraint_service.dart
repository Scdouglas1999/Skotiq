import 'dart:async';

import 'package:drift/drift.dart' show Value;

import '../../database/database.dart' as db;
import '../../models/scheduler/target_constraint.dart';
import '../../utils/resilient_poll_stream.dart';
import '../../backend/remote_host.dart';

/// Persistence + change-notification for hard target constraints.
///
/// A broadcast `StreamController` fires on every write made through this
/// service, on the host and on a slave alike, so the scheduler provider can
/// drive `requestReevaluation()` whenever the operator adds, edits, deletes,
/// or toggles a constraint.
class TargetConstraintService {
  final db.SkotiqDatabase _db;
  final StreamController<void> _mutations = StreamController<void>.broadcast();

  /// Non-null on a remote SLAVE: constraints live in the HOST DB, so reads and
  /// mutations route over `/api/target-constraints` instead of the slave's
  /// empty local table. Null on the host (FfiBackend) / tests — local path
  /// unchanged.
  final HostPlanningData? _remote;

  TargetConstraintService(this._db, {HostPlanningData? remote})
    : _remote = remote;

  void _notifyMutated() {
    if (!_mutations.isClosed) _mutations.add(null);
  }

  Future<void> dispose() async {
    await _mutations.close();
  }

  /// Insert a constraint and return its row id.
  Future<int> insert(TargetConstraint constraint) async {
    final remote = _remote;
    if (remote != null) {
      final id = await remote.insertTargetConstraint(constraint);
      _notifyMutated();
      return id;
    }
    final id = await _db.planningDao.insertTargetConstraint(
      db.TargetConstraintsCompanion.insert(
        targetId: constraint.targetId,
        kind: constraint.kind.name,
        payloadJson: constraint.encodePayload(),
        enabled: Value(constraint.enabled ? 1 : 0),
      ),
    );
    _notifyMutated();
    return id;
  }

  /// Update an existing constraint in place. The constraint's [id] must
  /// be non-null.
  Future<void> update(TargetConstraint constraint) async {
    if (constraint.id == null) {
      throw StateError(
        'TargetConstraintService.update requires a persisted id',
      );
    }
    final remote = _remote;
    if (remote != null) {
      await remote.updateTargetConstraint(constraint);
      _notifyMutated();
      return;
    }
    await _db.planningDao.updateTargetConstraint(
      constraint.id!,
      kind: constraint.kind.name,
      payloadJson: constraint.encodePayload(),
      enabled: constraint.enabled,
    );
    _notifyMutated();
  }

  Future<void> setEnabled(int constraintId, bool enabled) async {
    final remote = _remote;
    if (remote != null) {
      await remote.setTargetConstraintEnabled(constraintId, enabled);
      _notifyMutated();
      return;
    }
    await _db.planningDao.setTargetConstraintEnabled(constraintId, enabled);
    _notifyMutated();
  }

  Future<void> delete(int constraintId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteTargetConstraint(constraintId);
      _notifyMutated();
      return;
    }
    await _db.planningDao.deleteTargetConstraint(constraintId);
    _notifyMutated();
  }

  /// Remove every constraint attached to [targetId]. Paired with
  /// `IntegrationGoalService.deleteForTarget` by the scheduler queue's
  /// per-row delete action.
  Future<void> deleteForTarget(int targetId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteTargetConstraintsForTarget(targetId);
      _notifyMutated();
      return;
    }
    await _db.planningDao.deleteTargetConstraintsForTarget(targetId);
    _notifyMutated();
  }

  /// Truncate the whole table. Backs the scheduler queue's "Clear all"
  /// action.
  Future<void> deleteAll() async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteAllTargetConstraints();
      _notifyMutated();
      return;
    }
    await _db.planningDao.deleteAllTargetConstraints();
    _notifyMutated();
  }

  Future<List<TargetConstraint>> listForTarget(int targetId) async {
    final remote = _remote;
    if (remote != null) {
      return remote.getTargetConstraints(targetId: targetId);
    }
    final rows = await _db.planningDao.targetConstraintsForTarget(targetId);
    return rows.map(targetConstraintFromRow).toList();
  }

  Future<List<TargetConstraint>> listAll() async {
    final remote = _remote;
    if (remote != null) {
      return remote.getTargetConstraints();
    }
    final rows = await _db.planningDao.allTargetConstraints();
    return rows.map(targetConstraintFromRow).toList();
  }

  /// Live stream of every constraint. Emits an initial snapshot then a
  /// fresh list after every mutation made through this service.
  Stream<List<TargetConstraint>> watchAll() async* {
    final remote = _remote;
    if (remote != null) {
      // The host owns the constraints; poll it on a fixed tick with a
      // change-guard. Host-side edits surface within the interval; our own
      // mutations are picked up by the next poll.
      yield* resilientDistinctPoll(
        fetch: remote.getTargetConstraints,
        unchanged: _constraintListEquals,
        interval: const Duration(seconds: 10),
      );
      return;
    }
    yield await listAll();
    await for (final _ in _mutations.stream) {
      yield await listAll();
    }
  }

  static bool _constraintListEquals(
    List<TargetConstraint> a,
    List<TargetConstraint> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The constraint a stored `target_constraints` row describes.
TargetConstraint targetConstraintFromRow(db.TargetConstraintRow row) =>
    TargetConstraint.fromRow(
      id: row.id,
      targetId: row.targetId,
      kindName: row.kind,
      payloadJson: row.payloadJson,
      enabled: row.enabled == 1,
    );
