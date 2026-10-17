part of '../database.dart';

extension _SkotiqDatabaseMigrationV32ToV40 on SkotiqDatabase {
  Future<void> _upgradeSchemaV32ToV40(Migrator m, int from) async {
    // Version 32: Frame-Failure Forensics persistence.
    //
    // Adds the `frame_forensics` table where every rejected frame's
    // classified cause + evidence + environment snapshot is persisted.
    // Raw DDL (matching the v27/v28/v29/v30/v31 convention) so the
    // migration lands without forcing a drift codegen pass — the
    // accompanying `ForensicsService` performs all reads/writes via
    // `customSelect`/`customStatement`.
    //
    // Schema design:
    //   * `id` is a UUID string so cross-process inserts don't fight
    //     for an integer sequence (the same convention used by
    //     `notes_journal`).
    //   * `captured_image_id` is a soft FK to `captured_images.id` —
    //     enforced when the row is created from a `FrameRejected`
    //     event with a known capture id; otherwise `NULL` (the FITS
    //     might be rejected before the row lands).
    //   * `reject_path` is the on-disk path the FITS landed at so the
    //     dashboard can offer a "Show file" link without a JOIN.
    //   * `likely_cause` is the wire-stable snake_case label from
    //     `LikelyCause.label`; never NULL — `unknown` is the explicit
    //     "we don't know" value, NOT a NULL.
    //   * `evidence_json` / `environment_json` store the structured
    //     payload as JSON so future heuristic columns can be added
    //     without breaking forward / backward compat.
    if (from < 32) {
      await _createFrameForensicsTable();
    }

    // Version 33: Replay Debug — `sequence_decisions` table.
    //
    // The Rust executor emits a structured `DecisionEvent` for every
    // material decision (scheduler pick, trigger firing, recovery
    // transition, frame verdict, adaptive swap, plugin invocation,
    // manual operator action, system lifecycle). The Dart side
    // subscribes to the bridge's typed `SequencerEvent::DecisionLogged`
    // event and persists each row here so the Replay screen can
    // scrub chronologically through the whole night the next
    // morning — a step change from "open log file in Notepad".
    //
    // Storage notes:
    //   * `sequence_run_id` is a soft INT pointer to the
    //     `sequence_runs` row when the decision was emitted inside
    //     a tracked run; NO FK so deleting an old run record does
    //     NOT cascade-delete the decision log (the analytics
    //     value persists past the run row).
    //   * `timestamp_unix_ms` is millis since epoch (UTC) — kept
    //     in milliseconds for indexable range queries and to
    //     match the existing pattern in the notes_journal table.
    //   * `category` is the snake_case wire key (`scheduler_pick`,
    //     `trigger_fired`, …). Wire-stable; see
    //     `DecisionCategory` in
    //     `packages/skotiq_core/lib/src/models/replay_decision.dart`.
    //   * `details_json` carries the opaque structured payload
    //     the Rust emit site authored — defaults to `'{}'` so a
    //     row with no extra context still parses to an empty map
    //     on read.
    if (from < 33) {
      await customStatement(
        'CREATE TABLE IF NOT EXISTS sequence_decisions ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'sequence_run_id INTEGER,'
        'timestamp_unix_ms INTEGER NOT NULL,'
        'category TEXT NOT NULL,'
        'summary TEXT NOT NULL,'
        'details_json TEXT NOT NULL DEFAULT \'{}\','
        'node_id TEXT)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_run '
        'ON sequence_decisions (sequence_run_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_timestamp '
        'ON sequence_decisions (timestamp_unix_ms)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_category '
        'ON sequence_decisions (category)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sequence_decisions_run_ts '
        'ON sequence_decisions (sequence_run_id, timestamp_unix_ms)',
      );
      // Seed the user-tunable retention setting if it's not
      // already present. Default 90 days matches the design spec.
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) "
        "VALUES ('replay_debug.enabled', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) "
        "VALUES ('replay_debug.retention_days', '90')",
      );
    }

    // Version 34: Smart Night guide RMS history.
    //
    // This append-only table feeds the Smart Night exposure
    // calculator's mount-tracking ceiling once enough guided
    // sessions exist for the active mount.
    if (from < 34) {
      await _createGuideRmsHistoryTable();
    }

    // Version 35: Promote safety monitor to a first-class equipment-profile
    // device, so a connected safety monitor persists with the profile instead
    // of being re-selected every session. The column is nullable so existing
    // profiles upgrade cleanly without backfill.
    if (from < 35) {
      final hasSafetyMonitorId = await _columnExists(
        'equipment_profiles',
        'safety_monitor_id',
      );
      if (!hasSafetyMonitorId) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN safety_monitor_id TEXT',
        );
      }
    }

    // Version 36: Promote switch device to a first-class equipment-profile
    // device, mirroring v35's safety-monitor promotion. Without this column a
    // connected switch device has to be re-selected manually every session,
    // because no profile column persists it. The column is nullable so
    // existing profiles upgrade cleanly without backfill.
    if (from < 36) {
      final hasSwitchId = await _columnExists(
        'equipment_profiles',
        'switch_id',
      );
      if (!hasSwitchId) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN switch_id TEXT',
        );
      }
    }

    // Version 37 : Sidecar thumbnail caching for captured images.
    //
    // Mobile/Pi gallery load is otherwise dominated by 200+ cold FITS reads,
    // one per thumbnail request. A `.thumb.jpg` written next to each FITS at
    // capture time and served with ETag headers takes that off the hot path.
    // The `thumbnail_path` column records the sidecar's on-disk path so the
    // GET handler does not have to probe the filesystem on every call.
    // Nullable for backward compatibility — legacy rows are healed lazily on
    // first read or via the explicit `/api/images/backfill-thumbnails` job.
    if (from < 37) {
      await _ensureCapturedImagesThumbnailPathColumn();
    }

    // Version 38 (Stack-and-Share Loop, C3): provenance record for every
    // stacked master produced by the share loop. Nothing recorded stacked
    // results before this — re-sharing or auditing an integration relied on
    // ephemeral in-memory state that vanished on app restart. The table is
    // managed with raw DDL (the dominant v27+ convention) so adding it does
    // not require a Drift codegen pass; `StackedResultsDao` reads/writes it
    // via `customSelect`/`customStatement`. The same helper runs from
    // `onCreate` so fresh installs get the table too.
    if (from < 38) {
      await _createStackedResultsTable();
    }

    // Version 39 (OSC / Color Stacking, C11): record colour provenance on
    // every stacked master. Before this the share loop was mono-only, so
    // `stacked_results` could not distinguish a single-channel monochrome
    // integration from an interleaved-RGB OSC stack. Two columns are added:
    // `is_color` (0/1 boolean) and `channels` (1 for mono, 3 for RGB). The
    // `_createStackedResultsTable()` helper already declares both for fresh
    // installs, but `CREATE TABLE IF NOT EXISTS` will not retrofit columns
    // onto a pre-v39 table — so we ALTER in place here, guarded by
    // `_columnExists` so the migration is re-runnable. `NOT NULL DEFAULT`
    // backfills existing rows to mono (is_color=0, channels=1), matching the
    // [StackAndShareResult] model defaults.
    if (from < 39) {
      if (!await _columnExists('stacked_results', 'is_color')) {
        await customStatement(
          'ALTER TABLE stacked_results '
          'ADD COLUMN is_color INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!await _columnExists('stacked_results', 'channels')) {
        await customStatement(
          'ALTER TABLE stacked_results '
          'ADD COLUMN channels INTEGER NOT NULL DEFAULT 1',
        );
      }
    }

    // Version 40 (Multi-Night & Forecast Planning, C3): the `projects` and
    // `project_targets` tables that let an operator group several targets
    // into a single multi-night campaign. Both are managed with raw DDL —
    // the dominant v27+ scheduler-stack convention (`integration_goals`,
    // `target_constraints`, `horizon_profiles`, `stacked_results`) — so
    // adding them does not require a Drift codegen pass;
    // `services/planning/project_service.dart`'s `ProjectService`
    // reads/writes them via
    // `customSelect`/`customInsert`/`customStatement`. The same helper runs
    // from `onCreate` so fresh installs get the tables too.
    //
    // DELIBERATELY NOT denormalized: the accrued progress for a target
    // (frames/seconds actually captured) is NOT stored on these tables. It
    // is derived on demand from `captured_images` via the
    // `TargetProgressService` / `CampaignRollupService` stack, which is the
    // single source of truth. Caching a tally here would silently drift out
    // of sync whenever a frame is rejected, deleted, or re-graded.
    if (from < 40) {
      await _createProjectsTables();
    }
  }
}
