/// Schema for the `horizon_profiles` table.
///
/// Managed with raw CREATE TABLE statements (see `database.dart` migration
/// v27 and `services/scheduler/integration_goal_service.dart`). See the
/// integration_goal_table doc for rationale.
///
/// Columns:
///   id           INTEGER PRIMARY KEY AUTOINCREMENT
///   name         TEXT NOT NULL
///   samples_json TEXT NOT NULL  (JSON array of `{"az": <deg>, "alt": <deg>}`)
library;
