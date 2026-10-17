/// Schema documentation for the post-session integration tables:
/// `integrated_masters`, `integrated_master_frames`, and `flat_library`.
///
/// These tables are managed with raw `CREATE TABLE` statements (see
/// `database.dart` migration v41 — the `_createPostSessionTables()` helper) and
/// accessed through plain DAO classes (`IntegratedMastersDao`, `FlatLibraryDao`)
/// that read/write via `customSelect` / `customStatement`, rather than drift
/// `Table` classes. This follows the dominant v27+ convention
/// (`integration_goals`, `stacked_results`, `projects`): adding them does not
/// require a `melos run generate` codegen pass, so the schema can ship in one
/// `flutter analyze`-clean slice. When generate next runs these can be promoted
/// to drift tables without a data migration, because the row layout is fixed.
///
/// `integrated_masters` — one row per archival integrated master.
///
/// A master is either a one-shot batch integration (status `finalized`,
/// `sidecar_path` NULL) or a multi-night accumulating master (status
/// `accumulating` while subs are still being folded in; `sidecar_path` points
/// at the resumable `.nsmaster` accumulator state). `finalize` writes the
/// shareable FITS and flips status to `finalized` but keeps the sidecar so more
/// nights can be added later.
///
/// Columns:
///   id                        INTEGER PRIMARY KEY AUTOINCREMENT
///   target_id                 INTEGER            (FK targets.id, ON DELETE SET NULL)
///   name                      TEXT NOT NULL
///   master_fits_path          TEXT               (NULL until first finalize)
///   preview_png_path          TEXT
///   sidecar_path              TEXT               (NULL for one-shot integrations)
///   rejection_map_path        TEXT
///   status                    TEXT NOT NULL DEFAULT 'finalized'  ('accumulating'|'finalized')
///   accumulation_mode         TEXT NOT NULL DEFAULT 'batch'      ('batch'|'runningWeightedMean')
///   channels                  INTEGER NOT NULL DEFAULT 1
///   width                     INTEGER NOT NULL DEFAULT 0
///   height                    INTEGER NOT NULL DEFAULT 0
///   frame_count               INTEGER NOT NULL DEFAULT 0
///   total_integration_seconds REAL    NOT NULL DEFAULT 0.0
///   filter                    TEXT
///   settings_json             TEXT NOT NULL DEFAULT '{}'  (IntegrationSettings.toJsonString)
///   stats_json                TEXT NOT NULL DEFAULT '{}'  (per-run aggregate stats)
///   created_at                INTEGER NOT NULL            (unix seconds, UTC)
///   updated_at                INTEGER NOT NULL            (unix seconds, UTC)
///
/// Indexes: target_id, status, created_at.
///
/// `integrated_master_frames` — join table: which captured subs are folded into
/// which master. Enforces dedup so a sub is never double-counted across runs.
///
/// Columns:
///   id                     INTEGER PRIMARY KEY AUTOINCREMENT
///   master_id              INTEGER NOT NULL (FK integrated_masters.id, ON DELETE CASCADE)
///   image_id               INTEGER NOT NULL (FK captured_images.id,    ON DELETE CASCADE)
///   weight                 REAL             (normalized integration weight; null if dropped)
///   alignment_residual_px  REAL             (RMS residual; null if not registered)
///   accepted               INTEGER NOT NULL DEFAULT 1  (0/1)
///   rejection_reason       TEXT
///   folded_at              INTEGER NOT NULL  (unix seconds, UTC)
///   UNIQUE(master_id, image_id)             (the dedup guard)
///
/// Indexes: master_id, image_id.
///
/// `flat_library` — master-flat artifact library, mirroring `dark_library`.
///
/// This is the missing master-flat counterpart to `dark_library`. (Note
/// `flat_history` already exists for the *exposure planner* — a distinct
/// concern: that records flat-exposure measurements, this records master-flat
/// FITS artifacts auto-matched by filter / optics / temperature.)
///
/// Columns:
///   id                  INTEGER PRIMARY KEY AUTOINCREMENT
///   file_path           TEXT NOT NULL   (master flat FITS, unit-mean)
///   filter              TEXT
///   equipment_profile_id INTEGER        (FK equipment_profiles.id, ON DELETE SET NULL)
///   optical_train_id    TEXT            (optional optics identity tag)
///   temperature         REAL            (sensor °C at capture, nullable)
///   gain                INTEGER NOT NULL DEFAULT 0
///   offset              INTEGER NOT NULL DEFAULT 0
///   bin_x               INTEGER NOT NULL DEFAULT 1
///   bin_y               INTEGER NOT NULL DEFAULT 1
///   width               INTEGER
///   height              INTEGER
///   flat_kind           TEXT NOT NULL DEFAULT 'sky'  ('sky'|'panel'|'dome')
///   master_frame_count  INTEGER NOT NULL DEFAULT 0
///   created_at          INTEGER NOT NULL  (unix seconds, UTC)
///
/// Indexes: filter, equipment_profile_id, (filter, gain, bin_x, bin_y).
///
/// v42 (Smart Morning Report / "Night Doctor"): the `night_reports` table plus
/// additive columns on `integrated_masters` and `integrated_master_frames`.
///
/// Same raw-DDL idiom (see `database.dart` migration v42 —
/// `_createNightReportsTable()` + `_ensureIntegratedMastersV42Columns()`);
/// `night_reports` is accessed via the plain `NightReportsDao`.
///
/// `night_reports` — one Night Doctor report per session (and/or target). The
/// `findings_json` array holds the serialized `NightFinding`s; `headline` is the
/// one-line verdict and `score` is the 0..100 overall quality grade.
///
/// Columns:
///   id            INTEGER PRIMARY KEY AUTOINCREMENT
///   session_id    INTEGER            (FK imaging_sessions.id, ON DELETE CASCADE)
///   target_id     INTEGER            (FK targets.id,          ON DELETE SET NULL)
///   score         INTEGER NOT NULL DEFAULT 0      (0..100 overall quality)
///   headline      TEXT    NOT NULL DEFAULT ''     (one-line verdict)
///   findings_json TEXT    NOT NULL DEFAULT '[]'   (JSON array of NightFinding)
///   created_at    INTEGER NOT NULL               (unix seconds, UTC)
///
/// Indexes: session_id, target_id, created_at.
///
/// Additive `integrated_masters` columns (all nullable except
/// `background_extracted`):
///   color_calibrated_path   TEXT                 (SPCC-calibrated FITS/preview)
///   annotated_preview_path  TEXT                 (catalog-annotated preview)
///   background_extracted    INTEGER NOT NULL DEFAULT 0  (0/1)
///   target_snr              REAL                 (achieved-anchor SNR; the SNR
///                                                 reached at target_integration_s)
///   target_integration_s    REAL                 (achieved-anchor integration, s;
///                                                 the cumulative time at target_snr)
///   improvement_curve_json  TEXT                 (serialized IntegrationCurve)
///
/// v57 diagnostic-overlay artifact columns (all nullable):
///   rejection_map_preview_path TEXT              (stretched rejection PNG)
///   coverage_map_path          TEXT              (scientific coverage FITS)
///   coverage_map_preview_path  TEXT              (stretched coverage PNG)
///
/// Additive `integrated_master_frames` columns (per-sub science, all nullable):
///   snr           REAL
///   fwhm          REAL
///   eccentricity  REAL
library;
