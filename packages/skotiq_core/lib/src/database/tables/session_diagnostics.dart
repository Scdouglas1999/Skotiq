import 'package:drift/drift.dart';

import 'imaging_sessions.dart';

/// Per-session snapshot of the diagnostics that the post-session report needs
/// but that today only live in volatile in-memory Riverpod providers
/// (`recoveryHistoryProvider`, `opticalTrainBaselineProvider`,
/// `opticalTrainCurrentSnapshotProvider`).
///
/// Without this row a *historical* run report can only show live values —
/// which are the NEXT run's values, or empty after a restart. Persisting the
/// recovery loops and the pre/post optical-train snapshots keyed to the
/// session lets the report dialog reload exactly THAT session's diagnostics.
///
/// One row per session ([sessionId] is the primary key), upserted at session
/// end. All payloads are JSON text so the schema is decoupled from the
/// model shapes (`RecoveryHistoryEntry.toJson`,
/// `OpticalTrainBaseline.toJson`) and stays additive-friendly.
@DataClassName('SessionDiagnostic')
class SessionDiagnostics extends Table {
  /// FK to the owning session. Cascade-deletes with the session. Primary key
  /// because there is exactly one diagnostics blob per session.
  IntColumn get sessionId =>
      integer().references(ImagingSessions, #id, onDelete: KeyAction.cascade)();

  /// JSON-encoded `List<RecoveryHistoryEntry>` for the run. `'[]'` when the
  /// run had no recovery loops.
  TextColumn get recoveryHistoryJson =>
      text().withDefault(const Constant('[]'))();

  /// JSON-encoded optical-train baseline snapshot captured at run start, or
  /// null when no baseline existed (first-ever run).
  TextColumn get opticalTrainBaselineJson => text().nullable()();

  /// JSON-encoded optical-train snapshot captured at session end ("current"),
  /// or null when the post-session pipeline produced no reading.
  TextColumn get opticalTrainCurrentJson => text().nullable()();

  /// When this diagnostics row was last written.
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {sessionId};
}
