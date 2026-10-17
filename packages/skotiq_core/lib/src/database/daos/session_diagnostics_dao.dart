import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/session_diagnostics.dart';

part 'session_diagnostics_dao.g.dart';

/// DAO for the per-session diagnostics snapshot (recovery history +
/// optical-train baseline/current), so a historical run report can reload the
/// diagnostics of THAT session instead of the live providers.
@DriftAccessor(tables: [SessionDiagnostics])
class SessionDiagnosticsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$SessionDiagnosticsDaoMixin {
  SessionDiagnosticsDao(super.db);

  /// Upsert the diagnostics blob for [sessionId]. One row per session, so a
  /// re-save (e.g. the post-session pipeline writing the optical-train current
  /// snapshot after the recovery history was already flushed) replaces the
  /// existing row.
  Future<void> upsert({
    required int sessionId,
    required String recoveryHistoryJson,
    String? opticalTrainBaselineJson,
    String? opticalTrainCurrentJson,
  }) async {
    await into(sessionDiagnostics).insertOnConflictUpdate(
      SessionDiagnosticsCompanion.insert(
        sessionId: Value(sessionId),
        recoveryHistoryJson: Value(recoveryHistoryJson),
        opticalTrainBaselineJson: Value(opticalTrainBaselineJson),
        opticalTrainCurrentJson: Value(opticalTrainCurrentJson),
        recordedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Load the diagnostics row for a session, or null when none was persisted
  /// (e.g. a session that predates this table or had no diagnostics at all).
  Future<SessionDiagnostic?> getForSession(int sessionId) {
    return (select(
      sessionDiagnostics,
    )..where((d) => d.sessionId.equals(sessionId))).getSingleOrNull();
  }

  /// Delete the diagnostics row for a session.
  Future<int> deleteForSession(int sessionId) {
    return (delete(
      sessionDiagnostics,
    )..where((d) => d.sessionId.equals(sessionId))).go();
  }
}
