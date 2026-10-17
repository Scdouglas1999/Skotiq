/// Schema for the `target_constraints` table.
///
/// Managed with raw CREATE TABLE statements (see `database.dart` migration
/// v27 and `services/scheduler/integration_goal_service.dart`). See the
/// integration_goal_table doc for rationale.
///
/// Columns:
///   id            INTEGER PRIMARY KEY AUTOINCREMENT
///   target_id     INTEGER NOT NULL  (FK targets.id, ON DELETE CASCADE)
///   kind          TEXT NOT NULL     ('timeWindow' | 'moonIlluminationMax'
///                                    | 'moonSeparationMin' | 'customHorizon'
///                                    | 'scheduledWindow')
///   payload_json  TEXT NOT NULL     (kind-specific JSON payload)
///   enabled       INTEGER NOT NULL DEFAULT 1
///
/// Index: idx_target_constraints_target (target_id)
library;
