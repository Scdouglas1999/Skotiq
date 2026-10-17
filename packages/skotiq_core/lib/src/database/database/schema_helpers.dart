part of '../database.dart';

/// Filename prefix of the copy an upgrade takes of the database before it
/// rewrites it — `skotiq-premigration-v58-<epoch seconds>.db`.
///
/// Distinct from the `skotiq-corrupt-` and `skotiq-incomplete-`
/// prefixes `integrity_check.dart` globs, so a quarantine sweep never consumes
/// one of these and this never consumes one of those.
const String kPreMigrationBackupPrefix = 'skotiq-premigration-';

/// How many pre-upgrade copies are kept beside the database.
///
/// Two: the one from the upgrade that just ran and the one before it, which is
/// what an operator needs when a problem is only noticed after a second
/// launch. These are full copies of the database, so keeping every one of them
/// would grow without bound on the machine least able to afford it.
const int kPreMigrationBackupsKept = 2;

extension _SkotiqDatabaseSchemaHelpers on SkotiqDatabase {
  /// Create the v31 `focus_models` table + its indexes. Called from both
  /// `onCreate` (fresh installs run `m.createAll()` which already covers
  /// the Drift-declared table) and `onUpgrade` (for in-place migrations).
  ///
  /// We use raw DDL with `IF NOT EXISTS` to make this idempotent — drift's
  /// `createTable` is happy to fail if called twice, and we explicitly want
  /// the migration path to be re-runnable in case the prior run aborted.
  Future<void> _createFocusModelsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS focus_models (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL,
        equipment_profile_id INTEGER REFERENCES equipment_profiles(id) ON DELETE SET NULL,
        filter_name TEXT NOT NULL,
        filter_index INTEGER,
        temperature_compensation_slope REAL NOT NULL,
        focus_offset_relative_to_lum INTEGER NOT NULL DEFAULT 0,
        intercept_at_reference_temp INTEGER NOT NULL,
        reference_temp_celsius REAL NOT NULL DEFAULT 10.0,
        last_trained_at INTEGER NOT NULL,
        training_run_count INTEGER NOT NULL DEFAULT 0,
        confidence_score REAL NOT NULL DEFAULT 0.0,
        last_used_at INTEGER,
        training_samples_json TEXT NOT NULL DEFAULT '[]',
        max_training_samples INTEGER NOT NULL DEFAULT 50,
        consecutive_bad_predictions INTEGER NOT NULL DEFAULT 0,
        accumulated_drift_steps INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_focus_models_profile '
      'ON focus_models (equipment_profile_id)',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_focus_models_profile_filter '
      'ON focus_models (equipment_profile_id, filter_name)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_focus_models_last_used '
      'ON focus_models (last_used_at)',
    );
  }

  /// Thumbnail (v30) — add producing-node provenance columns to
  /// `captured_images` if missing. Lives here (called from both
  /// `onCreate` and `onUpgrade`) because the columns are NOT declared on
  /// the Drift `CapturedImages` table class — same convention as the
  /// raw-DDL `notes_journal` / `defect_maps` tables — so a fresh install
  /// would otherwise skip them entirely after `m.createAll()`.
  /// Create the v34 `guide_rms_history` table + its lookup index.
  ///
  /// Drift creates the table on fresh installs through `m.createAll()`, but
  /// this helper is intentionally idempotent so upgrades and fresh-install
  /// index setup share the same schema path.
  Future<void> _createFrameForensicsTable() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS frame_forensics ('
      'id TEXT PRIMARY KEY NOT NULL,'
      'captured_image_id INTEGER REFERENCES captured_images(id) ON DELETE CASCADE,'
      'session_id TEXT,'
      'sequence_run_id INTEGER,'
      'node_id TEXT,'
      'frame_index INTEGER NOT NULL,'
      'total_frames INTEGER NOT NULL,'
      'reject_path TEXT NOT NULL,'
      'reason TEXT NOT NULL,'
      'likely_cause TEXT NOT NULL DEFAULT \'unknown\','
      'evidence_json TEXT NOT NULL DEFAULT \'[]\','
      'environment_json TEXT NOT NULL DEFAULT \'{}\','
      'hfr REAL,'
      'eccentricity REAL,'
      'star_count INTEGER,'
      'created_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_frame_forensics_session '
      'ON frame_forensics (session_id, created_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_frame_forensics_run '
      'ON frame_forensics (sequence_run_id, created_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_frame_forensics_cause '
      'ON frame_forensics (likely_cause, created_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_frame_forensics_image '
      'ON frame_forensics (captured_image_id)',
    );
  }

  /// Create the v38 `stacked_results` table + its lookup indexes
  /// (Stack-and-Share Loop, C3).
  ///
  /// Raw DDL with `IF NOT EXISTS` keeps this idempotent so it can be safely run
  /// from both `onCreate` (fresh installs) and the v38 `onUpgrade` branch, and
  /// re-run if a prior migration aborted. `StackedResultsDao` is a plain class
  /// that reads/writes this table through `customSelect`/`customStatement`,
  /// matching the convention used for `frame_forensics` and `notes_journal`.
  ///
  /// Column nullability mirrors the [StackAndShareResult] model: `session_id`,
  /// `target_id`, `target_name`, `avg_alignment_residual`, `avg_hfr`, `filter`,
  /// and `exported_image_path` are optional, while the integration dimensions,
  /// frame counts, integration time, and creation timestamp are always present.
  /// The v39 colour-provenance columns (`is_color`, `channels`) are NOT NULL
  /// with mono defaults; see the v39 `onUpgrade` branch for the in-place ALTER
  /// that retrofits them onto pre-v39 databases.
  Future<void> _createStackedResultsTable() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS stacked_results('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'session_id INTEGER,'
      'target_id INTEGER,'
      'target_name TEXT,'
      'width INTEGER NOT NULL,'
      'height INTEGER NOT NULL,'
      'frames_stacked INTEGER NOT NULL,'
      'frames_attempted INTEGER NOT NULL,'
      'integration_secs REAL NOT NULL,'
      'avg_alignment_residual REAL,'
      'avg_hfr REAL,'
      'filter TEXT,'
      // v39 (OSC / Color Stacking): colour provenance. `is_color` is a 0/1
      // boolean and `channels` is 1 (mono) or 3 (interleaved RGB). Both carry
      // NOT NULL DEFAULTs matching the [StackAndShareResult] model so the
      // upgrade ALTER and this fresh-install path stay in lock-step.
      'is_color INTEGER NOT NULL DEFAULT 0,'
      'channels INTEGER NOT NULL DEFAULT 1,'
      'exported_image_path TEXT,'
      'created_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_stacked_results_session '
      'ON stacked_results(session_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_stacked_results_target '
      'ON stacked_results(target_id)',
    );
  }

  /// Create the v40 `projects` + `project_targets` tables (and their indexes)
  /// for the multi-night planner. Called from both `onCreate` (fresh installs)
  /// and the `if (from < 40)` `onUpgrade` branch (in-place migrations).
  ///
  /// These are raw-DDL tables (the dominant v27+ scheduler-stack convention)
  /// rather than Drift-declared tables; see
  /// `tables/project_table.dart` for the canonical schema documentation and
  /// `services/planning/project_service.dart`'s `ProjectService` for the
  /// read/write service.
  ///
  /// Every statement is `CREATE ... IF NOT EXISTS` so the helper is idempotent
  /// and the migration is re-runnable if a prior run aborted mid-flight. The
  /// `ON DELETE CASCADE` foreign keys mirror `integration_goals` /
  /// `target_constraints`; foreign-key enforcement is already enabled in
  /// `beforeOpen` (`PRAGMA foreign_keys = ON`), so deleting a project or a
  /// target tears down the corresponding `project_targets` rows automatically.
  Future<void> _createProjectsTables() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS projects('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'name TEXT NOT NULL,'
      'description TEXT,'
      'color_argb INTEGER,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS project_targets('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'project_id INTEGER NOT NULL '
      'REFERENCES projects(id) ON DELETE CASCADE,'
      'target_id INTEGER NOT NULL '
      'REFERENCES targets(id) ON DELETE CASCADE,'
      'priority_override INTEGER,'
      'added_at INTEGER NOT NULL,'
      'UNIQUE(project_id, target_id))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_project_targets_project '
      'ON project_targets (project_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_project_targets_target '
      'ON project_targets (target_id)',
    );
  }

  /// Create the v41 post-session integration tables — `integrated_masters`,
  /// `integrated_master_frames`, and `flat_library` — plus their indexes.
  ///
  /// Called from both `onCreate` (fresh installs) and the `if (from < 41)`
  /// `onUpgrade` branch. Every statement is `CREATE ... IF NOT EXISTS` so the
  /// helper is idempotent and re-runnable. These are raw-DDL tables (the
  /// dominant v27+ convention) accessed via `IntegratedMastersDao` /
  /// `FlatLibraryDao`; see `tables/post_session_tables.dart` for the canonical
  /// schema documentation. `ON DELETE` foreign keys mirror `stacked_results` /
  /// `projects`; FK enforcement is already enabled in `beforeOpen`.
  Future<void> _createPostSessionTables() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS integrated_masters('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
      'name TEXT NOT NULL,'
      'master_fits_path TEXT,'
      'preview_png_path TEXT,'
      'sidecar_path TEXT,'
      'rejection_map_path TEXT,'
      "status TEXT NOT NULL DEFAULT 'finalized',"
      "accumulation_mode TEXT NOT NULL DEFAULT 'batch',"
      'channels INTEGER NOT NULL DEFAULT 1,'
      'width INTEGER NOT NULL DEFAULT 0,'
      'height INTEGER NOT NULL DEFAULT 0,'
      'frame_count INTEGER NOT NULL DEFAULT 0,'
      'total_integration_seconds REAL NOT NULL DEFAULT 0.0,'
      'filter TEXT,'
      "settings_json TEXT NOT NULL DEFAULT '{}',"
      "stats_json TEXT NOT NULL DEFAULT '{}',"
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_integrated_masters_target '
      'ON integrated_masters (target_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_integrated_masters_status '
      'ON integrated_masters (status)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_integrated_masters_created '
      'ON integrated_masters (created_at)',
    );

    await customStatement(
      'CREATE TABLE IF NOT EXISTS integrated_master_frames('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'master_id INTEGER NOT NULL '
      'REFERENCES integrated_masters(id) ON DELETE CASCADE,'
      'image_id INTEGER NOT NULL '
      'REFERENCES captured_images(id) ON DELETE CASCADE,'
      'weight REAL,'
      'alignment_residual_px REAL,'
      'accepted INTEGER NOT NULL DEFAULT 1,'
      'rejection_reason TEXT,'
      'folded_at INTEGER NOT NULL,'
      'UNIQUE(master_id, image_id))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_integrated_master_frames_master '
      'ON integrated_master_frames (master_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_integrated_master_frames_image '
      'ON integrated_master_frames (image_id)',
    );

    await customStatement(
      'CREATE TABLE IF NOT EXISTS flat_library('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'file_path TEXT NOT NULL,'
      'filter TEXT,'
      'equipment_profile_id INTEGER '
      'REFERENCES equipment_profiles(id) ON DELETE SET NULL,'
      'optical_train_id TEXT,'
      'temperature REAL,'
      'gain INTEGER NOT NULL DEFAULT 0,'
      'offset INTEGER NOT NULL DEFAULT 0,'
      'bin_x INTEGER NOT NULL DEFAULT 1,'
      'bin_y INTEGER NOT NULL DEFAULT 1,'
      'width INTEGER,'
      'height INTEGER,'
      "flat_kind TEXT NOT NULL DEFAULT 'sky',"
      'master_frame_count INTEGER NOT NULL DEFAULT 0,'
      'created_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_flat_library_filter '
      'ON flat_library (filter)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_flat_library_profile '
      'ON flat_library (equipment_profile_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_flat_library_match '
      'ON flat_library (filter, gain, bin_x, bin_y)',
    );
  }

  /// Add durable display-preview paths for post-session diagnostic maps.
  ///
  /// The original v41 schema retained only the scientific rejection-map FITS,
  /// and retained no drizzle coverage artifact at all. The UI nevertheless
  /// handed that FITS path to `Image.file`, so its Rejection toggle could never
  /// decode; Coverage was permanently absent. These nullable v57 columns keep
  /// both scientific coverage FITS and the two real PNG overlays.
  Future<void> _ensureIntegratedMastersOverlayColumns() async {
    if (!await _columnExists(
      'integrated_masters',
      'rejection_map_preview_path',
    )) {
      await customStatement(
        'ALTER TABLE integrated_masters '
        'ADD COLUMN rejection_map_preview_path TEXT',
      );
    }
    if (!await _columnExists('integrated_masters', 'coverage_map_path')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN coverage_map_path TEXT',
      );
    }
    if (!await _columnExists(
      'integrated_masters',
      'coverage_map_preview_path',
    )) {
      await customStatement(
        'ALTER TABLE integrated_masters '
        'ADD COLUMN coverage_map_preview_path TEXT',
      );
    }
  }

  /// Create the v42 `night_reports` table — one Night Doctor report per session
  /// (and/or target) produced by the Smart Morning Report pipeline — plus its
  /// lookup indexes.
  ///
  /// Called from both `onCreate` (fresh installs) and the `if (from < 42)`
  /// `onUpgrade` branch. Every statement is `CREATE ... IF NOT EXISTS` so the
  /// helper is idempotent and re-runnable. This is a raw-DDL table (the dominant
  /// v27+ convention) accessed via `NightReportsDao`; see
  /// `tables/post_session_tables.dart` for the canonical schema documentation.
  /// FK columns mirror `stacked_results`: `session_id` and `target_id` are both
  /// nullable so a report can attach to a session, a target, or both. FK
  /// enforcement is already enabled in `beforeOpen`.
  Future<void> _createNightReportsTable() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS night_reports('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE CASCADE,'
      'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
      'score INTEGER NOT NULL DEFAULT 0,'
      "headline TEXT NOT NULL DEFAULT '',"
      "findings_json TEXT NOT NULL DEFAULT '[]',"
      'created_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_night_reports_session '
      'ON night_reports (session_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_night_reports_target '
      'ON night_reports (target_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_night_reports_created '
      'ON night_reports (created_at)',
    );
  }

  /// Add the v42 additive Smart-Morning-Report columns to the raw-DDL
  /// `integrated_masters` and `integrated_master_frames` tables.
  ///
  /// Because both tables are raw-DDL (not Drift `Table` classes), additive
  /// nullable columns are retrofitted with guarded `ALTER TABLE ... ADD COLUMN`
  /// — the exact pattern of `_ensureCapturedImagesProducingNodeColumns`. Every
  /// ALTER is guarded by `_columnExists` so the helper is idempotent and runs
  /// safely from both `onCreate` (fresh installs — the columns are NOT in
  /// `_createPostSessionTables`, so a fresh install needs this too) and the
  /// `if (from < 42)` `onUpgrade` branch.
  Future<void> _ensureIntegratedMastersV42Columns() async {
    // integrated_masters: finishing artifacts + target SNR/time goals + the
    // marginal-SNR improvement curve.
    if (!await _columnExists('integrated_masters', 'color_calibrated_path')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN color_calibrated_path TEXT',
      );
    }
    if (!await _columnExists('integrated_masters', 'annotated_preview_path')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN annotated_preview_path TEXT',
      );
    }
    if (!await _columnExists('integrated_masters', 'background_extracted')) {
      await customStatement(
        'ALTER TABLE integrated_masters '
        'ADD COLUMN background_extracted INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!await _columnExists('integrated_masters', 'target_snr')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN target_snr REAL',
      );
    }
    if (!await _columnExists('integrated_masters', 'target_integration_s')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN target_integration_s REAL',
      );
    }
    if (!await _columnExists('integrated_masters', 'improvement_curve_json')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN improvement_curve_json TEXT',
      );
    }

    // integrated_master_frames: per-sub science data the Night Doctor reads
    // after a morning integration (snr / fwhm / eccentricity).
    if (!await _columnExists('integrated_master_frames', 'snr')) {
      await customStatement(
        'ALTER TABLE integrated_master_frames ADD COLUMN snr REAL',
      );
    }
    if (!await _columnExists('integrated_master_frames', 'fwhm')) {
      await customStatement(
        'ALTER TABLE integrated_master_frames ADD COLUMN fwhm REAL',
      );
    }
    if (!await _columnExists('integrated_master_frames', 'eccentricity')) {
      await customStatement(
        'ALTER TABLE integrated_master_frames ADD COLUMN eccentricity REAL',
      );
    }
  }

  /// Create the v43 `campaigns` table — the durable NINA-style multi-night
  /// `(target, filter, accepted, desired, last_date)` counter — plus its
  /// lookup index.
  ///
  /// Called from both `onCreate` (fresh installs) and the `if (from < 43)`
  /// `onUpgrade` branch. Every statement is `CREATE ... IF NOT EXISTS` so the
  /// helper is idempotent and re-runnable. This is a raw-DDL table (the dominant
  /// v27+ convention) accessed via `CampaignsDao`. The `ON DELETE CASCADE`
  /// foreign key mirrors `integration_goals`; FK enforcement is already enabled
  /// in `beforeOpen` (`PRAGMA foreign_keys = ON`), so deleting a target tears
  /// down its campaign rows automatically.
  ///
  /// `UNIQUE(target_id, filter)` makes the `(target, filter)` pair the campaign
  /// identity. The table is ADDITIVE and orthogonal to `integration_goals`: it
  /// never feeds the live `SchedulerEngine` goals-complete reject (which stays a
  /// read-only derivation), it is a denormalized bookkeeping counter the
  /// campaign UI can later show.
  Future<void> _createCampaignsTable() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS campaigns('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,'
      'filter TEXT NOT NULL,'
      'accepted_count INTEGER NOT NULL DEFAULT 0,'
      'desired_count INTEGER NOT NULL DEFAULT 0,'
      'last_date INTEGER,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL,'
      'UNIQUE(target_id, filter))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_campaigns_target '
      'ON campaigns (target_id)',
    );
  }

  /// Add the v44 additive Phase C "finishing foundation" columns to the
  /// raw-DDL `integrated_masters` table — the per-master plate-solved WCS (eight
  /// CD-matrix scalars) plus the finishing-artifact output paths.
  ///
  /// Because `integrated_masters` is a raw-DDL table (not a Drift `Table`
  /// class), additive nullable columns are retrofitted with guarded
  /// `ALTER TABLE ... ADD COLUMN` — the exact pattern of
  /// `_ensureIntegratedMastersV42Columns`. Every ALTER is guarded by
  /// `_columnExists` so the helper is idempotent and runs safely from both
  /// `onCreate` (fresh installs — the columns are NOT in
  /// `_createPostSessionTables`, so a fresh install needs this too) and the
  /// `if (from < 44)` `onUpgrade` branch.
  ///
  /// The WCS columns store the eight scalars in the CD-matrix form ASTAP emits
  /// (see `WcsInfo::from_plate_solve`, `imaging/src/fits.rs:1094`): reference
  /// world coordinates, reference pixel, and the 2x2 CD matrix. The finishing
  /// paths persist the gated post-step outputs (`<master>_bgx/_decon/_starred`).
  Future<void> _ensureIntegratedMastersV44Columns() async {
    // Plate-solved WCS — reference world coordinates (CRVAL1/2, degrees).
    if (!await _columnExists('integrated_masters', 'wcs_crval1')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_crval1 REAL',
      );
    }
    if (!await _columnExists('integrated_masters', 'wcs_crval2')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_crval2 REAL',
      );
    }
    // Reference pixel (CRPIX1/2 — usually the image centre).
    if (!await _columnExists('integrated_masters', 'wcs_crpix1')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_crpix1 REAL',
      );
    }
    if (!await _columnExists('integrated_masters', 'wcs_crpix2')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_crpix2 REAL',
      );
    }
    // CD matrix (scale + rotation), four scalars.
    if (!await _columnExists('integrated_masters', 'wcs_cd1_1')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_cd1_1 REAL',
      );
    }
    if (!await _columnExists('integrated_masters', 'wcs_cd1_2')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_cd1_2 REAL',
      );
    }
    if (!await _columnExists('integrated_masters', 'wcs_cd2_1')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_cd2_1 REAL',
      );
    }
    if (!await _columnExists('integrated_masters', 'wcs_cd2_2')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN wcs_cd2_2 REAL',
      );
    }

    // Finishing-artifact output paths.
    if (!await _columnExists(
      'integrated_masters',
      'background_extracted_path',
    )) {
      await customStatement(
        'ALTER TABLE integrated_masters '
        'ADD COLUMN background_extracted_path TEXT',
      );
    }
    if (!await _columnExists('integrated_masters', 'deconvolved_path')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN deconvolved_path TEXT',
      );
    }
    if (!await _columnExists('integrated_masters', 'star_reduced_path')) {
      await customStatement(
        'ALTER TABLE integrated_masters ADD COLUMN star_reduced_path TEXT',
      );
    }
  }

  /// Create the v44 `narrowband_composites` table — one row per applied
  /// SHO/HOO/etc. palette combine — plus its lookup index.
  ///
  /// Called from both `onCreate` (fresh installs) and the `if (from < 44)`
  /// `onUpgrade` branch. The single statement is `CREATE TABLE IF NOT EXISTS`,
  /// so the helper is idempotent and re-runnable. This is a raw-DDL table (the
  /// dominant v27+ convention) accessed via [NarrowbandCompositesDao]. The
  /// `ON DELETE SET NULL` foreign key mirrors `integrated_masters.target_id`;
  /// FK enforcement is already enabled in `beforeOpen`
  /// (`PRAGMA foreign_keys = ON`).
  ///
  /// `component_master_ids` is a JSON array of the `integrated_masters.id`
  /// component channels the composite was built from (e.g. the Ha/OIII/SII
  /// masters), and `palette` is the palette name (`SHO`, `HOO`, ...).
  Future<void> _createNarrowbandCompositesTable() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS narrowband_composites('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
      "palette TEXT NOT NULL DEFAULT '',"
      "component_master_ids TEXT NOT NULL DEFAULT '[]',"
      'output_path TEXT NOT NULL,'
      'width INTEGER NOT NULL DEFAULT 0,'
      'height INTEGER NOT NULL DEFAULT 0,'
      'created_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_narrowband_composites_target '
      'ON narrowband_composites (target_id)',
    );
  }

  /// Create the v45 `mosaic_projects` + `mosaic_panels` tables (Mosaic M2),
  /// making a mosaic a first-class durable entity linking grid config → panel
  /// targets → panel masters → the stitched output.
  ///
  /// Called from both `onCreate` (fresh installs) and the `if (from < 45)`
  /// `onUpgrade` branch. Every statement is `CREATE TABLE/INDEX IF NOT EXISTS`,
  /// so the helper is idempotent and re-runnable. These are raw-DDL tables (the
  /// dominant v27+ convention) accessed via [MosaicProjectsDao] /
  /// [MosaicPanelsDao], mirroring [CampaignsDao] / [NarrowbandCompositesDao].
  ///
  /// `mosaic_projects.target_id` and `output_master_id` use `ON DELETE SET NULL`
  /// (a project survives its source target / stitched master being removed);
  /// `mosaic_panels.project_id` uses `ON DELETE CASCADE` (panels are owned by
  /// their project), while the per-panel `target_id` / `integrated_master_id`
  /// use `ON DELETE SET NULL`. FK enforcement is already on in `beforeOpen`
  /// (`PRAGMA foreign_keys = ON`).
  ///
  /// Each panel's plate-solved WCS rides on its `integrated_masters` row (v44
  /// WCS columns) via `integrated_master_id` — there are no duplicate WCS
  /// columns on `mosaic_panels`. The stitched output is itself an
  /// `integrated_masters` row referenced by `mosaic_projects.output_master_id`,
  /// so it flows into the existing master library + morning report unchanged.
  /// `UNIQUE(project_id, panel_index)` makes `(project, panel)` the panel
  /// identity (panel_index is 0-based, matching the FITS `SK-PIDX` provenance).
  Future<void> _createMosaicTables() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS mosaic_projects('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
      'name TEXT NOT NULL,'
      'rows INTEGER NOT NULL,'
      'cols INTEGER NOT NULL,'
      'overlap_pct REAL NOT NULL DEFAULT 15.0,'
      'position_angle_deg REAL NOT NULL DEFAULT 0.0,'
      "status TEXT NOT NULL DEFAULT 'planning',"
      'output_master_id INTEGER '
      'REFERENCES integrated_masters(id) ON DELETE SET NULL,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL,'
      // v56: when an owner publishes this project to the
      // hub as a collaborative mosaic, `hub_mosaic_id` is the hub mosaic id (the
      // handle claim/upload/assemble act on), `collab_role` is owner|participant,
      // and `collab_status` mirrors the hub lifecycle (published|assembling|
      // complete). All nullable — a local-only project never publishes.
      // Retrofitted onto pre-v56 DBs by the v56 onUpgrade branch.
      'hub_mosaic_id TEXT,'
      'collab_role TEXT,'
      'collab_status TEXT)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_mosaic_projects_target '
      'ON mosaic_projects (target_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_mosaic_projects_status '
      'ON mosaic_projects (status)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_mosaic_projects_hub '
      'ON mosaic_projects (hub_mosaic_id)',
    );

    await customStatement(
      'CREATE TABLE IF NOT EXISTS mosaic_panels('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'project_id INTEGER NOT NULL '
      'REFERENCES mosaic_projects(id) ON DELETE CASCADE,'
      'panel_index INTEGER NOT NULL,'
      'center_ra REAL NOT NULL,'
      'center_dec REAL NOT NULL,'
      'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
      'integrated_master_id INTEGER '
      'REFERENCES integrated_masters(id) ON DELETE SET NULL,'
      'captured_count INTEGER NOT NULL DEFAULT 0,'
      "status TEXT NOT NULL DEFAULT 'pending',"
      // v56: distributed-capture panel claim. When a
      // mosaic is published to the hub, a panel is claimed by a rig/user (the
      // hand-off baton pattern), and its uploaded panel master is tracked here.
      // `assigned_rig_id` / `assigned_user_id` carry the hub identities,
      // `claim_token` the hub-issued claim baton, and `uploaded_master_id` the
      // local `integrated_masters.id` of the panel master uploaded. All
      // nullable — a panel is unclaimed until a rig takes it. Retrofitted onto
      // pre-v56 DBs by the v56 onUpgrade branch.
      'assigned_rig_id TEXT,'
      'assigned_user_id TEXT,'
      'claim_token TEXT,'
      'uploaded_master_id INTEGER,'
      'UNIQUE(project_id, panel_index))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_mosaic_panels_project '
      'ON mosaic_panels (project_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_mosaic_panels_master '
      'ON mosaic_panels (integrated_master_id)',
    );
  }

  /// v46 (Calibration Library Manager): user tags / notes plus the
  /// FITS-enriched camera-id cache, keyed by `(master_type, master_id)`
  /// where `master_id` is the row id in the artifact's source table
  /// (`dark_library` / `flat_library` / `defect_maps`). Raw DDL + plain
  /// [CalibrationTagsDao], mirroring [FlatLibraryDao].
  Future<void> _createCalibrationTagsTable() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS calibration_tags('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'master_type TEXT NOT NULL,'
      'master_id INTEGER NOT NULL,'
      "tags_json TEXT NOT NULL DEFAULT '[]',"
      'notes TEXT,'
      'camera_id TEXT,'
      // v56: sharing / provenance. `shared_by` is the
      // sharer's hub account id, `shared_at` an epoch-seconds timestamp,
      // `license` a `ContributionLicense` wire name, and `provenance_json` a
      // serialized [Provenance]. `published_remote_id` is the hub master id this
      // LOCAL master was published under (the owner-scoped retract handle);
      // null until the master is shared, cleared again on retract. All nullable —
      // a master is local-only until shared. Retrofitted onto pre-v56 DBs by the
      // v56 onUpgrade branch.
      'shared_by TEXT,'
      'shared_at INTEGER,'
      'license TEXT,'
      'provenance_json TEXT,'
      'published_remote_id TEXT,'
      'updated_at INTEGER NOT NULL,'
      'UNIQUE(master_type, master_id))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_calibration_tags_camera '
      'ON calibration_tags (camera_id)',
    );
  }

  Future<void> _createGuideRmsHistoryTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS guide_rms_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        mount_id TEXT NOT NULL,
        target_id INTEGER,
        total_rms_arcsec REAL NOT NULL,
        sample_count INTEGER NOT NULL,
        exposure_seconds REAL,
        recorded_at INTEGER NOT NULL
      )
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_guide_rms_mount_recent '
      'ON guide_rms_history (mount_id, recorded_at DESC)',
    );
  }

  Future<void> _ensureCapturedImagesProducingNodeColumns() async {
    if (!await _columnExists('captured_images', 'producing_node_id')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN producing_node_id TEXT',
      );
    }
    if (!await _columnExists('captured_images', 'producing_run_id')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN producing_run_id TEXT',
      );
    }
    if (!await _columnExists('captured_images', 'runtime_grade')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN runtime_grade TEXT',
      );
    }
    if (!await _columnExists('captured_images', 'eccentricity')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN eccentricity REAL',
      );
    }
    if (!await _columnExists('captured_images', 'fwhm')) {
      await customStatement('ALTER TABLE captured_images ADD COLUMN fwhm REAL');
    }
    // v51: anisotropic WCS — the four CD-matrix scalars plus a `solved_sip`
    // JSON blob. Raw-DDL columns retrofitted by the v51 onUpgrade branch;
    // fresh installs add them here.
    if (!await _columnExists('captured_images', 'solved_cd1_1')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN solved_cd1_1 REAL',
      );
    }
    if (!await _columnExists('captured_images', 'solved_cd1_2')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN solved_cd1_2 REAL',
      );
    }
    if (!await _columnExists('captured_images', 'solved_cd2_1')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN solved_cd2_1 REAL',
      );
    }
    if (!await _columnExists('captured_images', 'solved_cd2_2')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN solved_cd2_2 REAL',
      );
    }
    if (!await _columnExists('captured_images', 'solved_sip')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN solved_sip TEXT',
      );
    }
    // Thumbnail sidecar path. Declared as a raw-DDL column rather than
    // a Drift table column to match the existing producing-node convention —
    // additive nullable text columns don't need Drift codegen churn and the
    // sidecar service reads/writes it via `customStatement`. Called from
    // onCreate (fresh installs) and via the v37 onUpgrade branch.
    await _ensureCapturedImagesThumbnailPathColumn();
  }

  Future<void> _ensureCapturedImagesThumbnailPathColumn() async {
    if (!await _columnExists('captured_images', 'thumbnail_path')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN thumbnail_path TEXT',
      );
    }
  }

  Future<void> _createCustomIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sessions_sequence ON imaging_sessions (sequence_id)',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_science_session_config_session_unique '
      'ON science_session_config (session_id) WHERE session_id IS NOT NULL',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_single_active '
      'ON equipment_profiles (is_active) WHERE is_active = 1',
    );

    // Notes_journal table. Managed with raw DDL (matches
    // the v27 scheduler tables + v28 defect_maps convention). Created
    // here so fresh installs (which run `onCreate` rather than
    // `onUpgrade`) also get the table; the v29 migration block above
    // covers in-place upgrades. The accompanying [NotesService] also
    // re-runs these statements through its own `_ensureSchema()` so
    // newly-installed services are tolerant of a pre-v29 connection.
    await customStatement(
      'CREATE TABLE IF NOT EXISTS notes_journal ('
      'id TEXT PRIMARY KEY NOT NULL,'
      'target_id TEXT NOT NULL,'
      'sequence_run_id INTEGER,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL,'
      'title TEXT,'
      'body TEXT NOT NULL,'
      'tags_json TEXT NOT NULL DEFAULT \'[]\','
      'attachments_json TEXT NOT NULL DEFAULT \'[]\','
      'sentiment TEXT)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_journal_target '
      'ON notes_journal (target_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_journal_run '
      'ON notes_journal (sequence_run_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_journal_created '
      'ON notes_journal (created_at)',
    );
    // Thumbnail (v30) — fresh-install indexes for the producing-
    // node provenance columns added by `_ensureCapturedImagesProducingNodeColumns`.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_images_producing_node '
      'ON captured_images (producing_node_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_images_producing_run '
      'ON captured_images (producing_run_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_images_node_captured_at '
      'ON captured_images (producing_node_id, captured_at)',
    );

    await _createGuideRmsHistoryTable();

    // Replay Debug (v33) — sequence_decisions table.
    // Fresh-install path; the v33 onUpgrade block handles the
    // in-place upgrade. Idempotent so re-running is safe.
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

    // Living Sky — Wave 3 (v55) scale indexes. Created here so fresh installs
    // (onCreate path) get them; the v55 onUpgrade block covers in-place
    // upgrades. Idempotent (IF NOT EXISTS), so re-running is safe.
    await _createLivingSkyWave3Indexes();
  }

  Future<void> _dedupeScienceSessionConfigRows() async {
    await customStatement('''
      DELETE FROM science_session_config
      WHERE session_id IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM science_session_config newer
          WHERE newer.session_id = science_session_config.session_id
            AND (
              newer.updated_at > science_session_config.updated_at
              OR (
                newer.updated_at = science_session_config.updated_at
                AND newer.id > science_session_config.id
              )
            )
        )
    ''');
  }

  Future<void> _normalizeActiveProfiles() async {
    await customStatement('''
      UPDATE equipment_profiles
      SET is_active = CASE
        WHEN id = (
          SELECT id
          FROM equipment_profiles
          WHERE is_active = 1
          ORDER BY updated_at DESC, id DESC
          LIMIT 1
        ) THEN 1
        ELSE 0
      END
      WHERE is_active = 1
    ''');
  }

  Future<void> _recreateImagingSessionsForSequenceDeleteBehavior() async {
    await customStatement('''
      CREATE TABLE imaging_sessions_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        profile_id INTEGER REFERENCES equipment_profiles(id) ON DELETE SET NULL,
        target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,
        start_time INTEGER NOT NULL,
        end_time INTEGER,
        total_exposures INTEGER NOT NULL DEFAULT 0,
        successful_exposures INTEGER NOT NULL DEFAULT 0,
        failed_exposures INTEGER NOT NULL DEFAULT 0,
        total_integration_secs REAL NOT NULL DEFAULT 0.0,
        avg_temperature REAL,
        avg_humidity REAL,
        avg_seeing REAL,
        avg_hfr REAL,
        avg_guiding_rms REAL,
        autofocus_count INTEGER NOT NULL DEFAULT 0,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'completed',
        sequence_id INTEGER REFERENCES sequences(id) ON DELETE SET NULL,
        equipment_snapshot TEXT
      )
    ''');
    await customStatement('''
      INSERT INTO imaging_sessions_new
      SELECT
        id, name, profile_id, target_id, start_time, end_time,
        total_exposures, successful_exposures, failed_exposures,
        total_integration_secs, avg_temperature, avg_humidity, avg_seeing,
        avg_hfr, avg_guiding_rms, autofocus_count, notes, status,
        sequence_id, equipment_snapshot
      FROM imaging_sessions
    ''');
    await customStatement('DROP TABLE imaging_sessions');
    await customStatement(
      'ALTER TABLE imaging_sessions_new RENAME TO imaging_sessions',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sessions_target ON imaging_sessions (target_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sessions_profile ON imaging_sessions (profile_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sessions_start ON imaging_sessions (start_time)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sessions_status ON imaging_sessions (status)',
    );
  }

  Future<void> _recreatePolarAlignmentHistoryForCascadeDelete() async {
    await customStatement('''
      CREATE TABLE polar_alignment_history_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        equipment_profile_id INTEGER REFERENCES equipment_profiles(id) ON DELETE CASCADE,
        initial_azimuth_error REAL NOT NULL,
        initial_altitude_error REAL NOT NULL,
        initial_total_error REAL NOT NULL,
        final_azimuth_error REAL NOT NULL,
        final_altitude_error REAL NOT NULL,
        final_total_error REAL NOT NULL,
        started_at INTEGER NOT NULL,
        completed_at INTEGER NOT NULL,
        auto_completed INTEGER NOT NULL DEFAULT 0,
        is_north INTEGER NOT NULL DEFAULT 1,
        config_json TEXT NOT NULL
      )
    ''');
    await customStatement('''
      INSERT INTO polar_alignment_history_new
      SELECT
        id, equipment_profile_id, initial_azimuth_error, initial_altitude_error,
        initial_total_error, final_azimuth_error, final_altitude_error,
        final_total_error, started_at, completed_at, auto_completed,
        is_north, config_json
      FROM polar_alignment_history
    ''');
    await customStatement('DROP TABLE polar_alignment_history');
    await customStatement(
      'ALTER TABLE polar_alignment_history_new RENAME TO polar_alignment_history',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_polar_history_profile ON polar_alignment_history (equipment_profile_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_polar_history_started ON polar_alignment_history (started_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_polar_history_completed ON polar_alignment_history (completed_at)',
    );
  }

  Future<void> _ensureDefaultSettings() async {
    for (final entry in _defaultSettings.entries) {
      await customStatement(
        'INSERT INTO app_settings (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO NOTHING',
        [entry.key, entry.value],
      );
    }
  }

  /// Drop `app_settings` rows whose key no longer has an owner. Runs on every
  /// open so a profile created by an older build stops serving (and exporting)
  /// a value nothing maintains. See [_retiredSettingKeys].
  Future<void> _pruneRetiredSettings() async {
    for (final key in _retiredSettingKeys) {
      await customStatement('DELETE FROM app_settings WHERE key = ?', [key]);
    }
  }

  Future<void> _normalizeEquipmentProfileOptics() async {
    await customStatement('''
      UPDATE equipment_profiles
      SET
        telescope_focal_length = CASE
          WHEN COALESCE(telescope_focal_length, 0) <= 0 AND focal_length > 0
            THEN focal_length
          ELSE telescope_focal_length
        END,
        telescope_aperture = CASE
          WHEN COALESCE(telescope_aperture, 0) <= 0 AND aperture > 0
            THEN aperture
          ELSE telescope_aperture
        END,
        focal_length = CASE
          WHEN focal_length <= 0 AND COALESCE(telescope_focal_length, 0) > 0
            THEN telescope_focal_length
          ELSE focal_length
        END,
        aperture = CASE
          WHEN aperture <= 0 AND COALESCE(telescope_aperture, 0) > 0
            THEN telescope_aperture
          ELSE aperture
        END
    ''');
  }

  /// Create the v58 Darkroom tables — `recipes`, `darkroom_jobs`,
  /// `delivery_targets`, and `delivery_journal` — plus their indexes.
  ///
  /// Called from both `onCreate` (fresh installs) and the `if (from < 58)`
  /// `onUpgrade` branch. Every statement is `CREATE ... IF NOT EXISTS` so the
  /// helper is idempotent and re-runnable. These are raw-DDL tables (the
  /// dominant v27+ convention) accessed via `RecipesDao` / `DarkroomJobsDao` /
  /// `DeliveryTargetsDao` / `DeliveryJournalDao`; see
  /// `tables/darkroom_tables.dart` for the canonical schema documentation.
  ///
  /// Ordering matters on the fresh-install path: `delivery_journal` references
  /// both `delivery_targets` and `darkroom_jobs`, and `recipes` references
  /// `integrated_masters`, so this runs after `_createPostSessionTables`.
  ///
  /// Every enum-valued column carries a `CHECK` listing its legal wire strings.
  /// The DAOs validate before writing, so a `CHECK` firing means a caller
  /// bypassed them; it is the backstop, not the first line.
  Future<void> _createDarkroomTables() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS recipes('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,'
      'session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE SET NULL,'
      'master_id INTEGER '
      'REFERENCES integrated_masters(id) ON DELETE SET NULL,'
      'base_master_path TEXT NOT NULL,'
      "name TEXT NOT NULL DEFAULT '',"
      "steps_json TEXT NOT NULL DEFAULT '[]',"
      "created_by TEXT NOT NULL DEFAULT 'autopilot',"
      "draft_notes_json TEXT NOT NULL DEFAULT '[]',"
      'parent_recipe_id INTEGER REFERENCES recipes(id) ON DELETE RESTRICT,'
      'divergence_index INTEGER,'
      'schema_version INTEGER NOT NULL DEFAULT 1,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL,'
      "CHECK (created_by IN ('autopilot', 'user')),"
      'CHECK (schema_version >= 1),'
      'CHECK (divergence_index IS NULL OR divergence_index >= 0),'
      'CHECK ((parent_recipe_id IS NULL) = (divergence_index IS NULL)))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_recipes_target ON recipes (target_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_recipes_session ON recipes (session_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_recipes_master ON recipes (master_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_recipes_parent '
      'ON recipes (parent_recipe_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_recipes_base_master '
      'ON recipes (base_master_path)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_recipes_created ON recipes (created_at)',
    );

    await customStatement(
      'CREATE TABLE IF NOT EXISTS darkroom_jobs('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE CASCADE,'
      "kind TEXT NOT NULL DEFAULT 'dawn',"
      "state TEXT NOT NULL DEFAULT 'queued',"
      'progress REAL NOT NULL DEFAULT 0.0,'
      'note TEXT,'
      'error_text TEXT,'
      'attempts INTEGER NOT NULL DEFAULT 0,'
      'created_at INTEGER NOT NULL,'
      'started_at INTEGER,'
      'finished_at INTEGER,'
      "CHECK (kind IN ('dawn', 'manual')),"
      "CHECK (state IN ('queued', 'running', 'cancelled', 'done', 'failed')),"
      'CHECK (progress >= 0.0 AND progress <= 1.0),'
      'CHECK (attempts >= 0))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_darkroom_jobs_state '
      'ON darkroom_jobs (state, created_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_darkroom_jobs_session '
      'ON darkroom_jobs (session_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_darkroom_jobs_created '
      'ON darkroom_jobs (created_at)',
    );

    await customStatement(
      'CREATE TABLE IF NOT EXISTS delivery_targets('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'name TEXT NOT NULL,'
      'kind TEXT NOT NULL,'
      "config_json TEXT NOT NULL DEFAULT '{}',"
      'enabled INTEGER NOT NULL DEFAULT 1,'
      "content_json TEXT NOT NULL DEFAULT '[]',"
      'secret_ref TEXT,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL,'
      "CHECK (kind IN ('watched_folder', 'sftp', 'peer')),"
      'CHECK (enabled IN (0, 1)))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_delivery_targets_enabled '
      'ON delivery_targets (enabled, kind)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_delivery_targets_name '
      'ON delivery_targets (name)',
    );

    await customStatement(
      'CREATE TABLE IF NOT EXISTS delivery_journal('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'target_id INTEGER NOT NULL '
      'REFERENCES delivery_targets(id) ON DELETE CASCADE,'
      'job_id INTEGER NOT NULL '
      'REFERENCES darkroom_jobs(id) ON DELETE CASCADE,'
      'file_path TEXT NOT NULL,'
      'bytes INTEGER NOT NULL DEFAULT 0,'
      'checksum TEXT,'
      "state TEXT NOT NULL DEFAULT 'retrying',"
      'attempts INTEGER NOT NULL DEFAULT 0,'
      'last_error TEXT,'
      'created_at INTEGER NOT NULL,'
      'updated_at INTEGER NOT NULL,'
      'delivered_at INTEGER,'
      "CHECK (state IN ('delivered', 'failed', 'retrying')),"
      'CHECK (attempts >= 0),'
      'CHECK (bytes >= 0),'
      'UNIQUE(target_id, job_id, file_path))',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_delivery_journal_target '
      'ON delivery_journal (target_id, state)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_delivery_journal_job '
      'ON delivery_journal (job_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_delivery_journal_state '
      'ON delivery_journal (state, updated_at)',
    );
  }

  /// Close out imaging sessions a previous process left `active`.
  ///
  /// The sibling of the `sequence_runs` sweep above and of
  /// [_recoverInterruptedDarkroomJobs], by the same rule: an `imaging_sessions`
  /// row is only `active` while THIS process's [SessionService] is driving it,
  /// and that state lives in memory, so nothing can still be running at the
  /// moment the database opens. Any `active` row here belongs to a process that
  /// is gone.
  ///
  /// **What the missing sibling cost.** `SessionsDao.startSession` refuses to
  /// open a second row while an older one is `active`, and every caller treats
  /// that refusal as "no session row" rather than as a failure. So one daemon
  /// stop mid-run — a cloud call at 2am, the updater, a power blip — detached
  /// every LATER night: measured on the release bundle, night two's twelve
  /// frames all registered with `session_id` NULL, the session-end hooks that
  /// key on the session id (post-session integration, the dawn Darkroom pass)
  /// logged "no active sequence id recorded" and never fired, no masters and no
  /// drafts were produced, and `GET /api/sessions/active` kept serving the dead
  /// run's counters while the live run captured.
  ///
  /// Runs on every boot path because `beforeOpen` does: the GUI and the
  /// headless daemon open the same [SkotiqDatabase].
  ///
  /// The close itself — status, back-dated `end_time`, appended note — is
  /// [kCloseOrphanedSessionsSql], shared with the sequence-start close in
  /// [SessionService] so the two cannot drift.
  Future<void> _closeOrphanedImagingSessions() async {
    final orphans = await customSelect(
      kSelectOrphanedSessionsSql,
      readsFrom: {imagingSessions},
    ).get();
    if (orphans.isEmpty) return;

    final found = DateTime.now();
    final note = interruptedSessionNote(
      cause: kInterruptedBySessionShutdownCause,
      found: found,
    );
    await customUpdate(
      kCloseOrphanedSessionsSql,
      variables: [
        Variable<int>(found.toUtc().millisecondsSinceEpoch ~/ 1000),
        Variable<String>(note),
        Variable<String>(note),
      ],
      updates: {imagingSessions},
      updateKind: UpdateKind.update,
    );

    final named = orphans
        .map((row) {
          final id = row.data['id'] as int;
          final name = row.data['name'] as String?;
          return name == null || name.isEmpty ? '#$id' : '#$id "$name"';
        })
        .join(', ');
    // ignore: avoid_print
    print(
      '[skotiq_db] Imaging session${orphans.length == 1 ? '' : 's'} left '
      "open by a previous process, now recorded as "
      "'$kInterruptedSessionStatus': $named.",
    );
  }

  /// Close out Darkroom jobs a previous process left mid-flight.
  ///
  /// A `darkroom_jobs` row is only 'running' while THIS process's executor is
  /// driving it — that executor state lives in memory, so nothing can still be
  /// running at the moment the database opens. Any row still marked 'running'
  /// here is residue from a process that died mid-job: a crash, a force quit,
  /// or safing that ran out its shutdown budget. Left alone, such a row is
  /// permanent: the queue reports work in flight that nothing is driving, and
  /// the night's masters are never produced.
  ///
  /// Recovered rows go back to 'queued' with `started_at` cleared and a note
  /// saying what happened. `progress` is left where the dead process left it,
  /// so the report can state how far that attempt got, and `attempts` is left
  /// alone — it counts starts, and the restart will increment it.
  ///
  /// A job that has already used its [kDarkroomJobMaxAttempts] starts is moved
  /// to 'failed' instead: a job that kills the process must not re-queue itself
  /// forever. Its `note` is replaced along with its state, because the note the
  /// dead attempt left — the step it was on, or the re-queue line a previous
  /// recovery wrote — describes work that is over and would read on a failed
  /// row as though it were still going.
  ///
  /// The retry-limit sentence is built from the ROW: the attempt number comes
  /// out of `attempts`, in SQL, so one statement still covers every residual
  /// row. It used to be a constant reading "on attempt 3 of 3" while its own
  /// `WHERE` selects `attempts >= 3`, so a row that had been started five times
  /// was told it died on its third — a number nothing in the row supports.
  ///
  /// Returns what was found BEFORE either write, because those rows are the
  /// evidence of WHICH STAGE of the night the process died in:
  /// [_reportInterruptedIntegration] runs next over a marker that covers the
  /// integrate AND the Darkroom pass, and a session with a Darkroom job left
  /// running is a session whose integration had already finished.
  Future<List<_InterruptedDarkroomJob>>
  _recoverInterruptedDarkroomJobs() async {
    final residue = await customSelect(
      'SELECT id, session_id, kind, created_at, progress, attempts '
      'FROM darkroom_jobs WHERE state = ?',
      variables: [const Variable<String>('running')],
    ).get();
    final interrupted = [
      for (final row in residue)
        _InterruptedDarkroomJob(
          jobId: row.data['id'] as int,
          sessionId: row.data['session_id'] as int?,
          kind: row.data['kind'] as String?,
          createdAtEpochSeconds: row.data['created_at'] as int?,
          progress: (row.data['progress'] as num).toDouble(),
          attempts: row.data['attempts'] as int,
        ),
    ];

    final failed = await customUpdate(
      "UPDATE darkroom_jobs SET state = 'failed', finished_at = ?, "
      "error_text = 'Interrupted by a process exit on attempt ' || attempts || "
      "'; the limit is ' || ? || ' starts, so it is not retried.', "
      'note = ? WHERE state = ? AND attempts >= ?',
      variables: [
        Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
        const Variable<int>(kDarkroomJobMaxAttempts),
        const Variable<String>(
          'Stopped at the retry limit; this job is not re-queued.',
        ),
        const Variable<String>('running'),
        const Variable<int>(kDarkroomJobMaxAttempts),
      ],
      updateKind: UpdateKind.update,
    );
    final requeued = await customUpdate(
      "UPDATE darkroom_jobs SET state = 'queued', started_at = NULL, "
      'note = ? WHERE state = ?',
      variables: [
        const Variable<String>(
          'Re-queued: the previous process exited while this job was running.',
        ),
        const Variable<String>('running'),
      ],
      updateKind: UpdateKind.update,
    );
    if (failed > 0 || requeued > 0) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Darkroom jobs left running by a previous process: '
        're-queued $requeued, failed $failed at the attempt limit.',
      );
    }
    return interrupted;
  }

  /// The directory holding this connection's database file, or null when the
  /// database has no file (an in-memory test connection).
  ///
  /// Asked of SQLite rather than re-derived from
  /// [resolveDefaultDatabaseFile]: a test opens an explicit temp file and a
  /// headless daemon opens `SKOTIQ_DATABASE_DIR`, and `database_list`
  /// reports whichever one this connection actually holds.
  Future<Directory?> _databaseDirectory() async {
    final rows = await customSelect('PRAGMA database_list').get();
    for (final row in rows) {
      if (row.data['name'] != 'main') continue;
      // `file` is the empty string for an in-memory database and null on the
      // builds that omit the column — neither has a directory to put a marker
      // in, and both are answered by "no directory" rather than by a path
      // derived from nothing.
      final file = row.data['file'];
      if (file is! String || file.isEmpty) return null;
      return Directory(p.dirname(file));
    }
    return null;
  }

  /// Copy the database aside, as it is right now, before an upgrade rewrites
  /// it.
  ///
  /// **Why there has to be one.** Every other copy this codebase makes is
  /// post-hoc — `skotiq-corrupt-*.db` and `skotiq-incomplete-*.db` are
  /// both written once a file is ALREADY unusable. An upgrade is the one
  /// routine operation that rewrites a healthy database in place, and two of
  /// its failure modes leave nothing to appeal to: a rebuild that loses rows,
  /// and the downgrade — an install upgraded to a new schema, then opened once
  /// by an older build, which re-stamps `user_version` back down and lets its
  /// foreign keys cascade over rows it does not know about. Nothing in this
  /// build can stop an older binary doing that. A copy taken here is what
  /// makes it survivable.
  ///
  /// **Why `VACUUM INTO`.** It is SQLite's own consistent snapshot: one
  /// statement, no separate `-wal`/`-shm` to keep in step, and the result is a
  /// plain database file the operator can open or swap in. It cannot run
  /// inside a transaction, which is why this is called before the upgrade's
  /// `BEGIN` rather than within it.
  ///
  /// **Why only on a real upgrade.** This runs from `onUpgrade`, which drift
  /// enters only for an existing database whose stored version is behind the
  /// code's. A fresh install goes through `onCreate` and copies nothing, which
  /// is right: there is nothing yet to preserve.
  ///
  /// **Why a failure here does not stop the upgrade.** These files are large,
  /// and refusing to open when the disk is too full to hold one would turn a
  /// missing safety net into an outage. The warning is loud and names the
  /// reason; the upgrade itself is atomic (see `onUpgrade`), so what is being
  /// given up is the ability to go BACK, not the integrity of going forward.
  Future<void> _writePreMigrationBackup(int from) async {
    try {
      final directory = await _databaseDirectory();
      // An in-memory database has no directory and nothing to preserve.
      if (directory == null) return;

      final stamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final path = p.join(
        directory.path,
        '${kPreMigrationBackupPrefix}v$from-$stamp.db',
      );
      final destination = File(path);
      // `VACUUM INTO` refuses to write over an existing file, and a second
      // upgrade inside the same second would land on this name.
      if (destination.existsSync()) await destination.delete();

      await customStatement('VACUUM INTO ?', [path]);

      // ignore: avoid_print
      print(
        '[skotiq_db] Upgrading the database from schema version $from to '
        '$schemaVersion. A copy of it as it was before the upgrade is at '
        '$path',
      );

      await _pruneOldPreMigrationBackups(directory);
    } catch (error) {
      // ignore: avoid_print
      print(
        '[skotiq_db] WARNING: could not copy the database aside before '
        'upgrading it from schema version $from ($error). The upgrade '
        'continues, but there is no pre-upgrade copy to fall back on.',
      );
    }
  }

  /// Keep the newest [kPreMigrationBackupsKept] pre-migration copies and delete
  /// the rest.
  ///
  /// By modification time rather than by name: the name carries the version it
  /// was taken at BEFORE the timestamp, so sorting the strings would rank a
  /// copy from v58 above a newer one from v6 — which is exactly the pair an
  /// operator upgrading, downgrading and upgrading again ends up with.
  Future<void> _pruneOldPreMigrationBackups(Directory directory) async {
    final copies =
        directory
            .listSync()
            .whereType<File>()
            .where(
              (file) =>
                  p.basename(file.path).startsWith(kPreMigrationBackupPrefix),
            )
            .toList()
          ..sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
    for (final stale in copies.skip(kPreMigrationBackupsKept)) {
      try {
        await stale.delete();
      } catch (error) {
        // ignore: avoid_print
        print(
          '[skotiq_db] Could not delete the superseded pre-upgrade copy '
          '${stale.path} ($error).',
        );
      }
    }
  }

  /// Whether [sessionId] already carries a narrator event under [dedupeKey].
  ///
  /// The session-scoped half of [NarratorEventsDao.hasDedupeKey]'s rule, asked
  /// in SQL because this runs inside `beforeOpen`, where the DAOs are not yet
  /// usable. No time window is needed: every night gets a fresh session id, so
  /// a key can only collide with an earlier event of the SAME night — which is
  /// exactly the duplicate worth suppressing.
  Future<bool> _narratorEventExists(int sessionId, String dedupeKey) async {
    final rows = await customSelect(
      'SELECT 1 FROM narrator_events WHERE session_id = ? AND dedupe_key = ? '
      'LIMIT 1',
      variables: [Variable<int>(sessionId), Variable<String>(dedupeKey)],
      readsFrom: {narratorEvents},
    ).get();
    return rows.isNotEmpty;
  }

  /// Consume the integration marker after the post-mortem report it feeds
  /// failed, naming what it said in the log first.
  ///
  /// The report is a courtesy — it tells the operator a night was interrupted —
  /// and the marker that drives it is re-read at every open. So a report that
  /// throws does not fail once: it fails identically on every launch, out of
  /// `beforeOpen`, which drift treats as a fatal migration error and refuses to
  /// open past. Discarding the marker costs one night's warning; keeping it
  /// costs the whole database. The marker's contents go to the log so the
  /// warning is not lost, only relocated.
  Future<void> _discardIntegrationMarkerAfterFailedReport() async {
    try {
      final directory = await _databaseDirectory();
      if (directory == null) return;
      final interrupted = await readIntegrationMarker(directory);
      if (interrupted != null) {
        // ignore: avoid_print
        print(
          '[skotiq_db] The discarded marker recorded: session '
          '${interrupted.sessionId}, stage ${interrupted.stage.name}, started '
          '${interrupted.startedAtUtc.toIso8601String()} UTC, intended masters '
          '${interrupted.intendedMasterPaths.isEmpty ? '(none recorded)' : interrupted.intendedMasterPaths.join('; ')}.',
        );
      }
      await clearIntegrationMarker(directory);
    } catch (error) {
      // ignore: avoid_print
      print(
        '[skotiq_db] WARNING: the interrupted-pass marker could not be '
        'discarded either ($error). It will be read again at the next open; '
        'delete $kIntegrationMarkerName beside the database by hand if '
        'startup keeps failing.',
      );
    }
  }

  /// Report a post-session pass that a previous process died in the middle of,
  /// then clear its marker.
  ///
  /// The integrate leaves no `darkroom_jobs` row to recover — the Darkroom job
  /// is enqueued only after the masters exist — so the marker file written by
  /// `markIntegrationStarted` is the whole record that the night was
  /// interrupted. It is turned into two durable, operator-visible things:
  ///
  ///  - a line appended to the session's notes, which Session Review and the
  ///    session wire snapshot both carry, and
  ///  - a `warning` Night Narrator event on that session, which is what the
  ///    morning feed reads.
  ///
  /// The intended master files are named in both, EACH WITH WHAT IT ACTUALLY
  /// IS. A FITS truncated by a kill is present and non-empty and looks
  /// finished, so an operator told only "the integration was interrupted"
  /// would open one and trust it — and an operator told every present file is
  /// truncated would delete the ones that are whole. Each file is opened and
  /// measured against its own header before it is described.
  ///
  /// Re-running the integration is deliberately NOT automatic: the subs are
  /// still on disk and still graded, so nothing is lost by waiting, whereas a
  /// pass that re-launches itself at every open is how a crash-on-integrate
  /// takes the app down repeatedly. The report says the night needs a re-run;
  /// the operator asks for it.
  ///
  /// WHICH STAGE the kill landed in has two sources, and they answer two
  /// different questions.
  ///
  /// [interruptedJobs] — the `darkroom_jobs` rows
  /// `_recoverInterruptedDarkroomJobs` found still `running`, captured before
  /// it re-queued them — answers "was a Darkroom pass in flight?". A row still
  /// running for the marker's session is a pass the machine died inside, and
  /// its own recovery already owns it.
  ///
  /// [InterruptedIntegration.stage] answers "had the masters finished?", which
  /// no row can. The marker's window covers the integrate AND the Darkroom pass
  /// that follows it (one `finally` clears it after both), and between them
  /// sits a seam the pass cannot close from one transaction: the masters are
  /// finalized bucket by bucket inside `PostSessionIntegrationService`, and the
  /// `darkroom_jobs` row is inserted afterwards. A kill in that seam left NO
  /// row at all, so every one of them was reported as an interrupted integrate
  /// — a night whose four masters were whole, registered and named as intact in
  /// the same sentence that told the operator to run the integration again, and
  /// which said nothing about the drafts, the night report, the delivery and
  /// the morning message that had never been queued. The marker now records
  /// that seam as it is crossed, so this open reads it instead of guessing.
  ///
  /// A pass that was OWED is not merely reported: a `queued` dawn job is
  /// inserted for it, which is the state the crash-requeue machinery already
  /// knows how to finish — `resumeDarkroomWork` drains the queue at every
  /// startup. That is not the same as re-running an integration, which stays
  /// manual: the integrate is the expensive, crash-prone stretch that must not
  /// re-launch itself at every open, while the owed pass is the cheap half that
  /// was already decided and never got to start.
  ///
  /// The marker is deleted last, so a process that dies between reading it and
  /// writing the report finds it again at the next open. The owed pass is
  /// enqueued BEFORE the report, so a process that dies in between finds the
  /// marker again, sees the job it already inserted, and does not insert a
  /// second one.
  ///
  /// Returns the session it reported on, or null when there was nothing to
  /// report. [_supersedeRetryPromiseForCappedJobs] runs next and needs to know:
  /// a session reported HERE already carries this open's verdict, terminal
  /// branch included, and a second record of the same event would only repeat
  /// it.
  Future<int?> _reportInterruptedIntegration(
    List<_InterruptedDarkroomJob> interruptedJobs,
  ) async {
    final directory = await _databaseDirectory();
    if (directory == null) return null;
    final interrupted = await readIntegrationMarker(directory);
    if (interrupted == null) return null;

    // The marker names its session by id, and that row can be gone by the time
    // this runs: the operator deleted the night from the sessions list after
    // the crash, the integrity quarantine rotated the damaged file aside and
    // left this marker beside a FRESH database that never held the session, or
    // a replace-mode restore swapped in a backup predating it. The report below
    // INSERTs a `narrator_events` row keyed to that id under
    // `PRAGMA foreign_keys = ON`, so a missing session turns a post-mortem note
    // into a foreign-key failure thrown out of `beforeOpen` — which drift
    // remembers, so every later open fails the same way while the marker sits
    // on disk producing it again. The database is undamaged and unopenable.
    //
    // A night that is no longer on record has nothing to carry the report, so
    // the marker is consumed and the finding goes to the log instead.
    final sessionRow = await customSelect(
      'SELECT 1 FROM imaging_sessions WHERE id = ? LIMIT 1',
      variables: [Variable<int>(interrupted.sessionId)],
      readsFrom: {imagingSessions},
    ).get();
    if (sessionRow.isEmpty) {
      // ignore: avoid_print
      print(
        '[skotiq_db] A post-session pass was interrupted for session '
        '${interrupted.sessionId} (started '
        '${interrupted.startedAtUtc.toIso8601String()} UTC), but that session '
        'is no longer in the database, so there is no night to report it on. '
        'Discarding the marker. Master files it intended to write: '
        '${interrupted.intendedMasterPaths.isEmpty ? '(none recorded)' : interrupted.intendedMasterPaths.join('; ')}.',
      );
      await clearIntegrationMarker(directory);
      return null;
    }

    _InterruptedDarkroomJob? darkroomPass;
    for (final job in interruptedJobs) {
      if (job.isPassFor(interrupted.sessionId, interrupted.startedAtUtc)) {
        darkroomPass = job;
        break;
      }
    }

    // Whether the integrate had finished, from the marker's own record of the
    // seam rather than from an absence of rows. `darkroomPass` still wins over
    // it: a row the machine died inside is a pass that HAD started, whatever
    // the marker last managed to write before the kill.
    final integrateFinished =
        darkroomPass == null &&
        interrupted.stage != PostSessionPassStage.integrating;

    // Each intended file is MEASURED before anything is said about it. The
    // pass writes its masters one after another, so an interruption leaves
    // some of them whole; calling every present file "truncated — delete it"
    // told the operator to throw away finished data, and the one that really
    // was half-written was buried in the same sentence as the ones that were
    // not.
    final present = await interrupted.presentMasterFiles();
    final incomplete = present.where((file) => !file.complete).toList();
    final whole = present.where((file) => file.complete).toList();
    // Paths the marker named that are not on disk at all. Before the integrate
    // finished this is the ordinary case — the pass had not reached them yet —
    // and after it finished it is a file that went missing since, which the
    // library still points at.
    final absent = integrateFinished
        ? [
            for (final path in interrupted.intendedMasterPaths)
              if (!present.any((file) => file.path == path)) path,
          ]
        : const <String>[];
    final sentences = <String>[];
    if (present.isEmpty && darkroomPass == null && !integrateFinished) {
      // Only the integrate can leave a master half-written, and only then is
      // "nothing on disk is half-finished" news. A kill during the DRAFT hit a
      // stage that writes no master at all, so saying it there would answer a
      // question the operator did not ask about a file that was never in
      // danger.
      sentences.add(
        'No master file had been written yet, so nothing on disk is '
        'half-finished.',
      );
    }
    if (incomplete.isNotEmpty) {
      sentences.add(
        'These master files are incomplete — delete them before re-running: '
        '${incomplete.map((f) => '${f.path} (${f.detail})').join('; ')}.',
      );
    }
    if (absent.isNotEmpty) {
      sentences.add(
        'These master files finished and are no longer on disk, so whatever '
        'the library still says about them, they are gone: '
        '${absent.join('; ')}.',
      );
    }
    for (final file in whole) {
      final registered = await _masterIsRegistered(file.path);
      sentences.add(
        registered
            ? '${file.path} is a complete FITS (${file.detail}) and the master '
                  'library already holds a row for it, so that one arrived '
                  'intact.'
            : '${file.path} is a complete FITS (${file.detail}) but no master '
                  'row records it, so it is finished on disk and missing from '
                  'the library. Re-running the integration writes it again; '
                  'nothing here says it is damaged.',
      );
    }
    final orphanText = sentences.join(' ');
    final startedAt = interrupted.startedAtUtc.toIso8601String();

    // The pass that was OWED and the pass that had already been queued share
    // one marker stage, because the marker is written before the insert and
    // never again — the ROW is what says which of the two happened.
    final queuedJobId = integrateFinished
        ? await _darkroomJobForPass(
            interrupted.sessionId,
            interrupted.startedAtUtc,
          )
        : null;
    final passIsOwed =
        integrateFinished &&
        interrupted.stage == PostSessionPassStage.darkroomPassOwed &&
        queuedJobId == null;

    // Nothing is outstanding and nothing on disk moved: the masters finished,
    // and either no pass was owed or the pass already has a row that says how
    // it ended. Consuming the marker in silence is the honest answer — a
    // `warning` for a night that lost nothing is how an operator learns to
    // scroll past the ones that did.
    if (integrateFinished &&
        !passIsOwed &&
        incomplete.isEmpty &&
        absent.isEmpty) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Session ${interrupted.sessionId}: the post-session '
        'integration had finished when the previous process exited '
        '${queuedJobId == null ? 'and no Darkroom pass was owed' : '(Darkroom '
                  'job #$queuedJobId carries the pass)'}; nothing is outstanding.',
      );
      await clearIntegrationMarker(directory);
      return null;
    }

    // The pass is enqueued BEFORE the report so the report can state what
    // actually happened to it, and so a death in between is idempotent: the
    // next open finds the marker, finds this row, and takes the branch above.
    final owedJobId = passIsOwed
        ? await _enqueueOwedDarkroomPass(interrupted.sessionId)
        : null;

    final String headline;
    if (darkroomPass != null) {
      headline = 'The Darkroom pass was interrupted before it finished.';
    } else if (integrateFinished) {
      headline = passIsOwed
          ? 'The Darkroom pass for this night never started.'
          : 'The post-session integration finished, but its master files no '
                'longer match the library.';
    } else {
      headline =
          'The post-session integration was interrupted before it '
          'finished.';
    }

    final body = <String>[
      if (darkroomPass != null)
        'Skotiq closed while Darkroom job #${darkroomPass.jobId} was '
            'drafting this session, '
            '${(darkroomPass.progress * 100).round()}% of the way through (the '
            'pass started at $startedAt UTC). The integration itself had '
            'already finished — the Darkroom job is queued only once the '
            'masters exist.'
      else if (integrateFinished)
        'The integration finished: every master it set out to write was on '
            'disk and in the library when Skotiq closed (the pass started '
            'at $startedAt UTC).'
      else
        'Skotiq closed while integrating this session (started '
            '$startedAt UTC).',
      if (passIsOwed)
        'What had not happened yet is the Darkroom pass — the drafts, the '
            'night report, the delivery and the morning message. It had not '
            'been queued when the process exited.',
      if (orphanText.isNotEmpty) orphanText,
      if (darkroomPass != null && darkroomPass.willRetry)
        'The job is re-queued, so the drafts, the night report and the '
            'delivery it owes are still owed; re-running the integration is '
            'not what this night needs.'
      else if (darkroomPass != null)
        'That was start ${darkroomPass.attempts} of at most '
            '$kDarkroomJobMaxAttempts, so the job is marked failed rather than '
            're-queued: the drafts, the night report and the delivery are not '
            'coming without you starting the pass yourself. The masters are '
            'untouched.'
      else if (passIsOwed && owedJobId != null)
        'It is queued now as Darkroom job #$owedJobId and runs at this '
            'startup. Do not run the integration again — it is the one part of '
            'this night that did finish.'
      else if (passIsOwed)
        'It could not be queued here either, so the drafts, the night report '
            'and the delivery are not coming without you pressing Process now '
            'in Session Review. Do not run the integration again — it is the '
            'one part of this night that did finish.'
      else if (integrateFinished)
        'The subs are all still on disk and still graded, so re-run the '
            'integration only for the masters named above; the rest of the '
            'library is untouched.'
      else
        'The subs are all still on disk and still graded, so run the '
            'integration again when you are ready.',
    ].join(' ');

    // One interruption, one record. The key below has always been WRITTEN and
    // never read: the "reported once" promise rested entirely on the marker
    // delete at the end of this method, and that delete is a file operation
    // that can fail — a read-only directory, a full disk — and is deliberately
    // the LAST thing here, so a process killed between the insert and the
    // delete leaves the marker standing over an event that already landed.
    // Either way the next open re-reports, and the operator's feed carries the
    // same warning about the same night twice, three times, once per launch.
    // The key is what makes the record idempotent; consulting it is what makes
    // the promise true.
    final dedupeKey = '$kInterruptedPassEventType:$startedAt';
    if (await _narratorEventExists(interrupted.sessionId, dedupeKey)) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Session ${interrupted.sessionId}: this interruption '
        'is already on record ($dedupeKey); consuming the marker without '
        'repeating the warning.',
      );
      await clearIntegrationMarker(directory);
      return interrupted.sessionId;
    }

    await customUpdate(
      'UPDATE imaging_sessions SET notes = '
      "CASE WHEN notes IS NULL OR notes = '' THEN ? "
      "ELSE notes || char(10) || ? END WHERE id = ?",
      variables: [
        Variable<String>('$headline $body'),
        Variable<String>('$headline $body'),
        Variable<int>(interrupted.sessionId),
      ],
      updates: {imagingSessions},
      updateKind: UpdateKind.update,
    );

    await customInsert(
      'INSERT INTO narrator_events('
      'session_id, timestamp, event_type, category, severity, headline, '
      'body, dedupe_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(interrupted.sessionId),
        Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
        const Variable<String>(kInterruptedPassEventType),
        const Variable<String>('quality'),
        const Variable<String>('warning'),
        Variable<String>(headline),
        Variable<String>(body),
        // Session-scoped and stamped with the start instant, so re-reporting
        // the same interruption cannot duplicate the event while two separate
        // interrupted nights each keep their own. Checked above, not merely
        // recorded.
        Variable<String>(dedupeKey),
      ],
    );

    // ignore: avoid_print
    print('[skotiq_db] Session ${interrupted.sessionId}: $headline $body');

    await clearIntegrationMarker(directory);
    return interrupted.sessionId;
  }

  /// Correct the durable interruption record of every job this open just ended
  /// at the retry limit.
  ///
  /// **What was wrong.** The interruption record is written ONCE, by
  /// [_reportInterruptedIntegration], from the marker the dead process left —
  /// and the marker is consumed by that first report. A job that dies three
  /// times therefore produces exactly one record, written after the FIRST
  /// death, when the job still had starts left and the record could honestly
  /// say "the job is re-queued, so the drafts, the night report and the
  /// delivery it owes are still owed". By the third death the cap has moved the
  /// row to `failed` and nothing is re-queued — but the record, which is what
  /// Session Review's banner and the morning feed both read, still promises the
  /// retry. The night was left waiting for drafts that were never coming.
  ///
  /// **What this writes.** For each job the cap just failed: a second
  /// `warning` event of the same type, which is how a reader that takes the
  /// NEWEST interruption record for a session sees the terminal truth instead
  /// of the promise, plus the same sentence appended to the session's notes.
  /// The earlier record is left standing rather than rewritten — it was true
  /// when it was written, and the feed is a record of what happened in order —
  /// so the correction names it and revokes it out loud.
  ///
  /// **Once per job, by construction.** Only rows found `running` reach here,
  /// and the cap has already moved these to `failed`, so no later open can find
  /// the same job again. A session [_reportInterruptedIntegration] just
  /// reported is skipped: that report took the same terminal branch a moment
  /// ago, and repeating it would put the identical verdict on the feed twice.
  Future<void> _supersedeRetryPromiseForCappedJobs(
    List<_InterruptedDarkroomJob> interruptedJobs, {
    required int? reportedSessionId,
  }) async {
    for (final job in interruptedJobs) {
      // A job with starts left was re-queued, so the promise it is under still
      // stands and there is nothing to revoke.
      if (job.willRetry) continue;
      final sessionId = job.sessionId;
      // A job queued outside a session has no night to carry a record.
      if (sessionId == null) continue;
      if (sessionId == reportedSessionId) continue;

      // Keyed on the JOB: one job reaches the cap once, and this is the record
      // of that. The rule is checked rather than assumed, by the same argument
      // as the report above — "once by construction" is a property of the code
      // paths reaching here, and the key costs one indexed lookup to hold it
      // true whatever else learns to put a row back into `running`.
      final dedupeKey =
          '$kInterruptedPassEventType:job:${job.jobId}:retry-limit';
      if (await _narratorEventExists(sessionId, dedupeKey)) continue;

      final standing = await customSelect(
        'SELECT count(*) AS rows FROM narrator_events '
        'WHERE session_id = ? AND event_type = ?',
        variables: [
          Variable<int>(sessionId),
          const Variable<String>(kInterruptedPassEventType),
        ],
        readsFrom: {narratorEvents},
      ).getSingle();
      final hadPromise = standing.read<int>('rows') > 0;

      const headline =
          'The Darkroom pass for this night stopped at the retry limit.';
      // Each sentence stands on its own, because the middle one is conditional:
      // a body whose last sentence leans on a clause the first shape does not
      // print is the same broken-sentence defect the pass banner carried.
      final body = <String>[
        'Darkroom job #${job.jobId} has now been started ${job.attempts} '
            'times, which is the limit of $kDarkroomJobMaxAttempts, so it is '
            'marked failed and is not re-queued.',
        if (hadPromise)
          'The earlier notice on this night said the job was re-queued; that '
              're-queue is over.',
        'The drafts, the night report and the delivery this pass owes are not '
            'coming without you starting it again yourself from Session '
            'Review. The subs and any masters already integrated are '
            'untouched.',
      ].join(' ');

      await customUpdate(
        'UPDATE imaging_sessions SET notes = '
        "CASE WHEN notes IS NULL OR notes = '' THEN ? "
        "ELSE notes || char(10) || ? END WHERE id = ?",
        variables: [
          Variable<String>('$headline $body'),
          Variable<String>('$headline $body'),
          Variable<int>(sessionId),
        ],
        updates: {imagingSessions},
        updateKind: UpdateKind.update,
      );

      await customInsert(
        'INSERT INTO narrator_events('
        'session_id, timestamp, event_type, category, severity, headline, '
        'body, dedupe_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable<int>(sessionId),
          Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
          const Variable<String>(kInterruptedPassEventType),
          const Variable<String>('quality'),
          const Variable<String>('warning'),
          const Variable<String>(headline),
          Variable<String>(body),
          Variable<String>(dedupeKey),
        ],
      );

      // ignore: avoid_print
      print('[skotiq_db] Session $sessionId: $headline $body');
    }
  }

  /// The newest `darkroom_jobs` row THIS pass created for [sessionId], or null
  /// when it never got one.
  ///
  /// Identity, not order: a session carries jobs from earlier nights' passes
  /// and from every "process now" the operator has pressed on it, and none of
  /// those is the pass this marker is about. The marker's own start instant is
  /// the divider, floored to the second `created_at` is stored in — a job
  /// inserted 200 ms after the marker was written shares that second and is
  /// still this pass's.
  Future<int?> _darkroomJobForPass(int sessionId, DateTime startedAtUtc) async {
    final rows = await customSelect(
      'SELECT id FROM darkroom_jobs WHERE session_id = ? AND created_at >= ? '
      'ORDER BY created_at DESC, id DESC LIMIT 1',
      variables: [
        Variable<int>(sessionId),
        Variable<int>(startedAtUtc.millisecondsSinceEpoch ~/ 1000),
      ],
    ).get();
    return rows.isEmpty ? null : rows.first.data['id'] as int;
  }

  /// Queue the Darkroom pass this night was owed and never got, returning the
  /// new job id, or null when the insert did not land.
  ///
  /// A `queued` row is the one state the rest of the system already knows how
  /// to finish: `resumeDarkroomWork` drains the queue at every startup, so the
  /// pass this open just discovered runs in this same launch without a second
  /// mechanism existing to run it.
  ///
  /// Written as `dawn` because that is the pass that was owed — the kind
  /// decides whether the morning message goes out, and the morning message is
  /// one of the four things this night never got.
  ///
  /// The failure is caught rather than thrown: this runs in `beforeOpen`, and a
  /// database that refuses one INSERT must still open. It is not swallowed —
  /// the caller reads the null and the report tells the operator the pass is
  /// owed and was not queued, which is the sentence that gets them to press
  /// Process now.
  Future<int?> _enqueueOwedDarkroomPass(int sessionId) async {
    try {
      return await customInsert(
        'INSERT INTO darkroom_jobs('
        'session_id, kind, state, progress, note, attempts, created_at'
        ') VALUES (?, ?, ?, 0.0, ?, 0, ?)',
        variables: [
          Variable<int>(sessionId),
          const Variable<String>('dawn'),
          const Variable<String>('queued'),
          const Variable<String>(
            'Queued at startup: the integration finished but the previous '
            'process exited before this pass was queued.',
          ),
          Variable<int>(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
        ],
      );
    } catch (error) {
      // ignore: avoid_print
      print(
        '[skotiq_db] Session $sessionId: the owed Darkroom pass could not '
        'be queued ($error); the night report says so.',
      );
      return null;
    }
  }

  /// Whether the master library already holds a row pointing at [path].
  ///
  /// The difference between "this file is finished" and "this file is finished
  /// AND the app knows about it": the integration writes the FITS and then
  /// records it, so a kill between the two leaves a whole master nothing
  /// references. That is a real thing to tell the operator, and it is not the
  /// same thing as a damaged file.
  Future<bool> _masterIsRegistered(String path) async {
    final rows = await customSelect(
      'SELECT 1 FROM integrated_masters WHERE master_fits_path = ? LIMIT 1',
      variables: [Variable<String>(path)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<bool> _columnExists(String table, String column) async {
    final result = await customSelect("PRAGMA table_info('$table')").get();
    return result.any((row) => row.data['name'] == column);
  }

  Future<bool> _tableExists(String table) async {
    final result = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '$table'",
    ).get();
    return result.isNotEmpty;
  }
}

/// A `darkroom_jobs` row a dead process left `running`, read at open BEFORE the
/// recovery rewrites it.
///
/// It is the evidence of which STAGE of the post-session pass the kill landed
/// in: the integrate enqueues the Darkroom job only after the masters exist, so
/// a row here means the integration for that session had finished and the
/// DRAFT is what stopped.
class _InterruptedDarkroomJob {
  /// `darkroom_jobs.id`, named in the report so the operator can find the row.
  final int jobId;

  /// The session the job was processing, or null for a job queued outside one
  /// — which no session-scoped marker can match.
  final int? sessionId;

  /// `dawn` or `manual`. The pass a post-session marker covers is always
  /// `dawn` — `AutoIntegrationService` runs it through
  /// `DawnAutopilotService.runDawnForSession` — while `manual` is the
  /// operator's separate "Process now", which writes no marker at all.
  final String? kind;

  /// `darkroom_jobs.created_at`, whole seconds since the epoch, or null on a
  /// row that carries none.
  final int? createdAtEpochSeconds;

  /// Fraction complete `0.0 .. 1.0` as the dead attempt last reported it. Left
  /// where it was by the recovery precisely so this can be stated.
  final double progress;

  /// How many times the job had been started, including the attempt that died.
  final int attempts;

  const _InterruptedDarkroomJob({
    required this.jobId,
    required this.sessionId,
    required this.kind,
    required this.createdAtEpochSeconds,
    required this.progress,
    required this.attempts,
  });

  /// Whether the recovery re-queued this job rather than failing it, by the
  /// same rule the recovery's own `WHERE` clause applies.
  bool get willRetry => attempts < kDarkroomJobMaxAttempts;

  /// Whether this row is the Darkroom pass the marker written at
  /// [markerStartedAtUtc] for [markerSessionId] was covering.
  ///
  /// Identity, not "same session". A night carries the operator's "Process
  /// now" presses as well as its own automatic pass, and a `manual` row that
  /// was already running when the integrate started is indistinguishable from
  /// this pass's row by session alone. Reading one as the other asserts the
  /// integrate had finished — because a pass row only exists once the masters
  /// do — and tells the operator not to re-run the integration, on a night
  /// whose marker says the masters were still being written and may be
  /// half-finished on disk.
  ///
  /// Two conditions, both from the row: the marker's pass is always `dawn`
  /// (`runDawnForSession`), and it cannot predate the marker that covers it.
  /// The instant is floored to the second `created_at` is stored in, so a job
  /// inserted milliseconds after the marker still counts as this pass's.
  bool isPassFor(int markerSessionId, DateTime markerStartedAtUtc) {
    if (sessionId != markerSessionId) return false;
    if (kind != 'dawn') return false;
    final createdAt = createdAtEpochSeconds;
    if (createdAt == null) return false;
    return createdAt >= markerStartedAtUtc.millisecondsSinceEpoch ~/ 1000;
  }
}
