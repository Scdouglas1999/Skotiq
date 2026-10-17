/// Schema for the `projects` and `project_targets` tables.
///
/// These tables are managed with raw CREATE TABLE statements (see
/// `database.dart` migration v40 — the `_createProjectsTables()` helper — and
/// `services/planning/project_service.dart`'s `ProjectService`) rather than
/// drift `Table` classes. The multi-night planner was added without running
/// `melos run generate`, so registering these in `@DriftDatabase` would
/// require regenerating `database.g.dart`. This mirrors the dominant v27+
/// scheduler-stack convention (`integration_goals`, `target_constraints`,
/// `horizon_profiles`, `stacked_results`): the raw-SQL service produces
/// identical row layouts, so the next time generate runs these files can be
/// converted to real drift tables without a data migration.
///
/// A `Project` groups several targets into a single multi-night imaging
/// campaign; the planner rolls each member target's per-filter integration
/// goals up into a project-level accrued-vs-remaining view. See the
/// `Project` / `ProjectTarget` models in `models/planning/project.dart`.
///
/// DESIGN NOTE — accrued progress is intentionally NOT denormalized into
/// these tables. The amount of integration actually captured for a target is
/// derived on demand from `captured_images` (joined through the scheduler /
/// `TargetProgressService` / `CampaignRollupService` stack), which is the
/// single source of truth. Caching a frame/second tally here would create a
/// second copy that silently drifts out of sync whenever a frame is rejected,
/// deleted, or re-graded — a class of stale-cache bug the project deliberately
/// avoids. These tables store only membership and authoring metadata.
///
/// `projects` columns:
///   id          INTEGER PRIMARY KEY AUTOINCREMENT
///   name        TEXT NOT NULL
///   description TEXT
///   color_argb  INTEGER            (nullable 32-bit ARGB accent; null = none)
///   created_at  INTEGER NOT NULL   (unix seconds, UTC)
///   updated_at  INTEGER NOT NULL   (unix seconds, UTC)
///
/// `project_targets` columns:
///   id                INTEGER PRIMARY KEY AUTOINCREMENT
///   project_id        INTEGER NOT NULL  (FK projects.id, ON DELETE CASCADE)
///   target_id         INTEGER NOT NULL  (FK targets.id,  ON DELETE CASCADE)
///   priority_override INTEGER            (nullable; null = inherit target priority)
///   added_at          INTEGER NOT NULL   (unix seconds, UTC)
///   UNIQUE(project_id, target_id)
///
/// Indexes:
///   idx_project_targets_project (project_id)
///   idx_project_targets_target  (target_id)
///
/// The active project is tracked out-of-band in `app_settings` under the
/// `planning.active_project_id` key (empty string = no active project), seeded
/// by `_ensureDefaultSettings()`.
library;
