import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../database/database.dart' as db;
import '../../models/scheduler/target_constraint.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import '../../utils/resilient_poll_stream.dart';
import 'integration_goal_service.dart'
    show targetConstraintsSchemaSql, targetConstraintsTargetIndexSql;

/// Persistence + change-notification for hard target constraints.
///
/// The `target_constraints` table is created out-of-band with raw SQL
/// (see `integration_goal_service.dart` for the shared DDL constants), so
/// drift's reactive `watch()` machinery can't see it. We layer a simple
/// broadcast `StreamController` on top so the scheduler provider can drive
/// `requestReevaluation()` whenever the operator adds, edits, deletes, or
/// toggles a constraint.
class TargetConstraintService {
  final db.SkotiqDatabase _db;
  bool _schemaEnsured = false;
  final StreamController<void> _mutations = StreamController<void>.broadcast();

  /// Non-null on a remote SLAVE: constraints live in the HOST DB, so reads and
  /// mutations route over `/api/target-constraints` instead of the slave's
  /// empty local table. Null on the host (FfiBackend) / tests — local path
  /// unchanged.
  final NetworkBackend? _remote;

  TargetConstraintService(this._db, {NetworkBackend? remote})
    : _remote = remote;

  Future<void> _ensureSchema() async {
    if (_schemaEnsured) return;
    await _db.customStatement(targetConstraintsSchemaSql);
    await _db.customStatement(targetConstraintsTargetIndexSql);
    _schemaEnsured = true;
  }

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
    await _ensureSchema();
    final id = await _db.customInsert(
      'INSERT INTO target_constraints (target_id, kind, payload_json, enabled) VALUES (?, ?, ?, ?)',
      variables: [
        Variable.withInt(constraint.targetId),
        Variable.withString(constraint.kind.name),
        Variable.withString(constraint.encodePayload()),
        Variable.withInt(constraint.enabled ? 1 : 0),
      ],
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
    await _ensureSchema();
    await _db.customStatement(
      'UPDATE target_constraints SET kind = ?, payload_json = ?, enabled = ? WHERE id = ?',
      [
        constraint.kind.name,
        constraint.encodePayload(),
        constraint.enabled ? 1 : 0,
        constraint.id,
      ],
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
    await _ensureSchema();
    await _db.customStatement(
      'UPDATE target_constraints SET enabled = ? WHERE id = ?',
      [enabled ? 1 : 0, constraintId],
    );
    _notifyMutated();
  }

  Future<void> delete(int constraintId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.deleteTargetConstraint(constraintId);
      _notifyMutated();
      return;
    }
    await _ensureSchema();
    await _db.customStatement('DELETE FROM target_constraints WHERE id = ?', [
      constraintId,
    ]);
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
    await _ensureSchema();
    await _db.customStatement(
      'DELETE FROM target_constraints WHERE target_id = ?',
      [targetId],
    );
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
    await _ensureSchema();
    await _db.customStatement('DELETE FROM target_constraints');
    _notifyMutated();
  }

  Future<List<TargetConstraint>> listForTarget(int targetId) async {
    final remote = _remote;
    if (remote != null) {
      return remote.getTargetConstraints(targetId: targetId);
    }
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, target_id, kind, payload_json, enabled FROM target_constraints WHERE target_id = ?',
          variables: [Variable.withInt(targetId)],
        )
        .get();
    return rows.map(_rowToConstraint).toList();
  }

  Future<List<TargetConstraint>> listAll() async {
    final remote = _remote;
    if (remote != null) {
      return remote.getTargetConstraints();
    }
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, target_id, kind, payload_json, enabled FROM target_constraints',
        )
        .get();
    return rows.map(_rowToConstraint).toList();
  }

  /// Live stream of every constraint. Emits an initial snapshot then a
  /// fresh list after every mutation made through this service.
  Stream<List<TargetConstraint>> watchAll() async* {
    final remote = _remote;
    if (remote != null) {
      // The host owns the constraints; poll it on a fixed tick with a
      // change-guard (mirrors database_provider's _pollRemote). Host-side
      // edits surface within the interval; our own mutations are picked up by
      // the next poll.
      yield* resilientDistinctPoll(
        fetch: remote.getTargetConstraints,
        unchanged: _constraintListEquals,
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

  TargetConstraint _rowToConstraint(QueryRow row) {
    return TargetConstraint.fromRow(
      id: row.read<int>('id'),
      targetId: row.read<int>('target_id'),
      kindName: row.read<String>('kind'),
      payloadJson: row.read<String>('payload_json'),
      enabled: row.read<int>('enabled') == 1,
    );
  }
}

final targetConstraintServiceProvider = Provider<TargetConstraintService>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  final svc = TargetConstraintService(
    ref.watch(databaseProvider),
    remote: backend is NetworkBackend ? backend : null,
  );
  ref.onDispose(() => svc.dispose());
  return svc;
});
