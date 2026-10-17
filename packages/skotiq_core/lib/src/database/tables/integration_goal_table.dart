/// Schema for the `integration_goals` table.
///
/// This table is managed with raw CREATE TABLE statements (see
/// `database.dart` migration v27 and
/// `services/scheduler/integration_goal_service.dart`) rather than a drift
/// `Table` class. The dynamic scheduler was added without running
/// `melos run generate`, so registering this in `@DriftDatabase` would
/// require regenerating `database.g.dart`. The raw-SQL service produces
/// identical row layouts; the next time generate runs, this file can be
/// converted to a real drift table without a data migration.
///
/// Columns:
///   id                INTEGER PRIMARY KEY AUTOINCREMENT
///   target_id         INTEGER NOT NULL  (FK targets.id, ON DELETE CASCADE)
///   filter            TEXT NOT NULL
///   exposure_seconds  REAL NOT NULL
///   frame_count       INTEGER NOT NULL
///   priority          INTEGER NOT NULL DEFAULT 5
///   created_at        INTEGER NOT NULL  (unix seconds, UTC)
///   UNIQUE(target_id, filter, exposure_seconds)
///
/// Index: idx_integration_goals_target (target_id)
library;
