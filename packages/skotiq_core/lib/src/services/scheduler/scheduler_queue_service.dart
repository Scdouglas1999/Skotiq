import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../database/database.dart' as db;
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';

/// Membership of the scheduler queue.
///
/// Queue membership is its own row, because deleting a target's integration
/// goals does not remove it: a goal-less target is a legal free-form candidate
/// (the contract a wheel-less OSC rig with no goal rows depends on), so the
/// autopilot would go on picking a target the operator had just removed.
/// Removal records that the target is out of the queue and
/// [SchedulerCandidateLoader] drops it before the engine scores it: removed
/// means INELIGIBLE, not merely goal-less.
///
/// The row is the whole state — no payload, no enabled flag. Re-admission is
/// deleting it, which the operator does by putting work back on the target
/// (the integration-goals editor calls [readmit] when it saves a goal).
class SchedulerQueueService {
  /// Managed with a raw `CREATE TABLE IF NOT EXISTS` on first access, like the
  /// three sibling scheduler tables (see `integration_goal_service.dart` for
  /// why they live outside drift's codegen).
  static const _schema = '''
CREATE TABLE IF NOT EXISTS scheduler_removed_targets (
  target_id INTEGER PRIMARY KEY REFERENCES targets(id) ON DELETE CASCADE,
  removed_at INTEGER NOT NULL
)
''';

  final db.SkotiqDatabase _db;
  bool _schemaEnsured = false;

  /// When non-null this service runs on a remote SLAVE: the queue lives in the
  /// HOST DB, so every read/write routes over `/api/scheduler/removed-targets`.
  /// Null on the host (FfiBackend) and in tests.
  final NetworkBackend? _remote;

  SchedulerQueueService(this._db, {NetworkBackend? remote}) : _remote = remote;

  Future<void> _ensureSchema() async {
    if (_schemaEnsured) return;
    await _db.customStatement(_schema);
    _schemaEnsured = true;
  }

  /// Take [targetId] out of the scheduler queue.
  ///
  /// Selected FROM `targets` rather than inserted verbatim so a target that is
  /// no longer in the catalog is a no-op instead of a foreign-key failure: it
  /// cannot be loaded as a candidate either way, and this call sits in the
  /// middle of the queue-row cleanup, which must not abort on it.
  Future<void> remove(int targetId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.removeSchedulerQueueTarget(targetId);
      return;
    }
    await _ensureSchema();
    await _db.customStatement(
      'INSERT OR REPLACE INTO scheduler_removed_targets (target_id, removed_at) '
      'SELECT id, ? FROM targets WHERE id = ?',
      [DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000, targetId],
    );
  }

  /// Empty the queue: every target in the catalog right now leaves it.
  ///
  /// Deliberately a snapshot of today's catalog rather than a standing rule —
  /// a target the operator adds after clearing is a new queue entry, not one
  /// they already declined.
  Future<void> removeAll() async {
    final remote = _remote;
    if (remote != null) {
      await remote.clearSchedulerQueue();
      return;
    }
    await _ensureSchema();
    await _db.customStatement(
      'INSERT OR REPLACE INTO scheduler_removed_targets (target_id, removed_at) '
      'SELECT id, ? FROM targets',
      [DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000],
    );
  }

  /// Put [targetId] back in the queue. A no-op when it never left.
  Future<void> readmit(int targetId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.readmitSchedulerQueueTarget(targetId);
      return;
    }
    await _ensureSchema();
    await _db.customStatement(
      'DELETE FROM scheduler_removed_targets WHERE target_id = ?',
      [targetId],
    );
  }

  /// Ids the autopilot must not pick. Read once per candidate load.
  Future<Set<int>> removedTargetIds() async {
    final remote = _remote;
    if (remote != null) return remote.getSchedulerQueueRemovedTargets();
    await _ensureSchema();
    final rows = await _db
        .customSelect('SELECT target_id FROM scheduler_removed_targets')
        .get();
    return rows.map((row) => row.read<int>('target_id')).toSet();
  }
}

final schedulerQueueServiceProvider = Provider<SchedulerQueueService>((ref) {
  final backend = ref.watch(backendProvider);
  return SchedulerQueueService(
    ref.watch(databaseProvider),
    remote: backend is NetworkBackend ? backend : null,
  );
});

/// Re-used DDL string so a caller that reads the table directly can ensure it
/// exists first, the same way the other scheduler tables are handled.
const String schedulerRemovedTargetsSchemaSql = SchedulerQueueService._schema;
