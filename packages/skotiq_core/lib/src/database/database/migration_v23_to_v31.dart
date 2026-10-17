part of '../database.dart';

extension _SkotiqDatabaseMigrationV23ToV31 on SkotiqDatabase {
  Future<void> _upgradeSchemaV23ToV31(Migrator m, int from) async {
    // Version 23: Add observation logs table
    // NOTE: This migration block must remain even though we're now at v24+.
    // Users upgrading from <23 still need to create observation_logs.
    if (from < 23) {
      await m.createTable(observationLogs);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_obs_logs_timestamp ON observation_logs (timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_obs_logs_object_name ON observation_logs (object_name)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_obs_logs_catalog_id ON observation_logs (catalog_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_obs_logs_rating ON observation_logs (rating)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_obs_logs_profile ON observation_logs (equipment_profile_id)',
      );
    }

    // Version 24: Add observing lists tables
    if (from < 24) {
      await m.createTable(observingLists);
      await m.createTable(observingListItems);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_observing_lists_name ON observing_lists (name)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_observing_lists_sort_order ON observing_lists (sort_order)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_observing_list_items_list ON observing_list_items (list_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_observing_list_items_catalog ON observing_list_items (catalog_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_observing_list_items_sort ON observing_list_items (list_id, sort_order)',
      );
    }

    // Version 25: Add sequence execution history table
    if (from < 25) {
      await m.createTable(sequenceRuns);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sequence_runs_sequence ON sequence_runs (sequence_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sequence_runs_started ON sequence_runs (started_at)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sequence_runs_status ON sequence_runs (status)',
      );
    }

    // Version 26: Add photometric transformation coefficients table
    // and standard_magnitude column to photometry_measurements
    if (from < 26) {
      await m.createTable(photometricTransforms);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_photometric_transforms_filter ON photometric_transforms (filter_name)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_photometric_transforms_date ON photometric_transforms (date_computed)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_photometric_transforms_profile ON photometric_transforms (equipment_profile_id)',
      );

      if (!await _columnExists(
        'photometry_measurements',
        'standard_magnitude',
      )) {
        await customStatement(
          'ALTER TABLE photometry_measurements ADD COLUMN standard_magnitude REAL',
        );
      }
    }

    // Version 27: Dynamic scheduler tables. The tables are
    // intentionally managed with raw CREATE TABLE statements rather
    // than @DriftDatabase entries so they can land without an FRB/
    // drift codegen pass. The corresponding services do raw SQL
    // through customSelect/customStatement.
    if (from < 27) {
      await customStatement(
        'CREATE TABLE IF NOT EXISTS integration_goals ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,'
        'filter TEXT NOT NULL,'
        'exposure_seconds REAL NOT NULL,'
        'frame_count INTEGER NOT NULL,'
        'priority INTEGER NOT NULL DEFAULT 5,'
        'created_at INTEGER NOT NULL,'
        'UNIQUE(target_id, filter, exposure_seconds))',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_integration_goals_target '
        'ON integration_goals (target_id)',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS target_constraints ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,'
        'kind TEXT NOT NULL,'
        'payload_json TEXT NOT NULL,'
        'enabled INTEGER NOT NULL DEFAULT 1)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_target_constraints_target '
        'ON target_constraints (target_id)',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS horizon_profiles ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'name TEXT NOT NULL,'
        'samples_json TEXT NOT NULL)',
      );
    }

    // Version 28: Defect map table for bad-pixel cosmetic correction. The
    // DefectMaps drift Table class is declared in
    // `tables/defect_map_table.dart` and registered in @DriftDatabase above,
    // but `database.g.dart` carries no `defectMaps` getter, so raw DDL keeps
    // the migration working ahead of the codegen pass.
    if (from < 28) {
      await customStatement(
        'CREATE TABLE IF NOT EXISTS defect_maps ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'camera_id TEXT NOT NULL,'
        'width INTEGER NOT NULL,'
        'height INTEGER NOT NULL,'
        'temperature_bucket_decicelsius INTEGER NOT NULL,'
        'bitmap BLOB NOT NULL,'
        'defective_pixel_count INTEGER NOT NULL,'
        'file_path TEXT,'
        'last_rebuilt_at INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', \'now\') AS INTEGER)))',
      );
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_defect_maps_lookup '
        'ON defect_maps (camera_id, width, height, temperature_bucket_decicelsius)',
      );
    }

    // Version 29: Per-target / per-run notes/journal entries.
    // Managed with raw DDL — same convention as the v27
    // scheduler tables and the v28 defect_maps table — so the
    // migration lands without forcing a drift codegen pass. The
    // accompanying [NotesService] performs all reads/writes via
    // `customSelect`/`customStatement`.
    //
    // Schema design:
    //   * `id` is a UUID string (TEXT PRIMARY KEY) for future
    //     cross-machine sync; never reused on updates.
    //   * `target_id` is a logical TEXT identifier (catalog id like
    //     "M31", or display name) rather than an FK to `targets.id`
    //     so that renaming or recreating a target row does not
    //     silently NULL-out its notes.
    //   * `sequence_run_id` is a soft INT pointer to the
    //     `sequence_runs` row when the note is run-scoped; no FK so
    //     deleting an old run record does not cascade-delete the
    //     journal entry.
    //   * `tags_json` / `attachments_json` store JSON arrays of
    //     strings — search-by-tag uses plain LIKE which is enough
    //     for the small per-user dataset (typically <10k notes).
    //   * `sentiment` is the literal emoji string from the
    //     auto-prompt sentiment dropdown, or NULL when not set.
    if (from < 29) {
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
    }

    // Version 30: Inline frame thumbnails (Thumbnails).
    //
    // Add provenance + grading columns to `captured_images` so each
    // captured frame can be tied back to the ExposureNode that
    // produced it and the sequence_runs row that was active at the
    // time. This is what powers the inline thumbnail strip under
    // each ExposureNode in the sequence tree.
    //
    // All three columns are nullable: legacy rows + ad-hoc captures
    // outside a sequence simply leave them unset. We index
    // producing_node_id (alone and paired with captured_at) because
    // the new `watchImagesByProducingNode` DAO method is the hottest
    // path — it queries by node id and orders by captured_at.
    if (from < 30) {
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

      // guide_rms_history.exposure_seconds is nullable post-v30. SQLite has
      // no ALTER COLUMN, so the column is rebuilt by rename-create-copy-drop
      // and the helper index recreated. The rebuild runs only when the column
      // still carries a NOT NULL constraint, so a fresh v30+ install (created
      // via the v30 raw DDL above) does not pay the cost on every startup.
      // The whole block is guarded on guide_rms_history already existing: the
      // table is first created at the v34 step below
      // (_createGuideRmsHistoryTable), so a database upgrading from < 30 does
      // NOT have it here and an unguarded CREATE INDEX throws "no such table:
      // guide_rms_history" and aborts the entire migration, leaving the app
      // unable to open. Older DBs skip this block and get the nullable table
      // + index from v34.
      // WHY the aside table is checked too, and why the steps below are
      // written to be resumed rather than merely repeated.
      //
      // Rename-create-copy-drop is four statements and a kill can land between
      // any two of them. The guard used to be `guide_rms_history` alone, which
      // is the ONE name that stops existing the moment the first statement
      // runs — so a process killed after the RENAME left the rows in
      // `guide_rms_history_v29`, and every later run took the guard's `false`
      // branch and skipped the whole block. The v34 step then created
      // `guide_rms_history` empty (`IF NOT EXISTS`), the upgrade reported
      // success, and the guiding history sat in an aside table nothing would
      // ever look at again — no error, no warning, just a history that starts
      // at the upgrade.
      //
      // Either name present means there is work to finish. A database
      // upgrading from before 30 has neither and still skips, which is what
      // the original guard was for: the table is first created at v34, and an
      // unguarded `CREATE INDEX` here would abort the whole migration.
      final legacyAside = await _tableExists('guide_rms_history_v29');
      if (await _tableExists('guide_rms_history') || legacyAside) {
        final exposureNotNullInfo = await customSelect(
          "SELECT \"notnull\" FROM pragma_table_info('guide_rms_history') "
          "WHERE name = 'exposure_seconds'",
        ).get();
        final liveTableIsLegacyShape =
            exposureNotNullInfo.isNotEmpty &&
            exposureNotNullInfo.first.data['notnull'] == 1;

        // Step 1 — move the old shape aside. Skipped when a previous run was
        // killed after doing it: the aside table already holds the rows, and
        // renaming onto an existing name throws.
        if (liveTableIsLegacyShape && !legacyAside) {
          await customStatement(
            'ALTER TABLE guide_rms_history RENAME TO guide_rms_history_v29',
          );
        }

        // Steps 2 and 3 — the nullable table, then the rows. Both are written
        // as "make it so" rather than "do it once": `IF NOT EXISTS` covers a
        // kill between the rename and the create, and `OR IGNORE` covers one
        // between the create and the drop, where some or all of the rows have
        // already been copied under the ids they keep.
        if (await _tableExists('guide_rms_history_v29')) {
          await customStatement(
            'CREATE TABLE IF NOT EXISTS guide_rms_history ('
            'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
            'session_id TEXT NOT NULL, '
            'mount_id TEXT NOT NULL, '
            'target_id INTEGER NULL, '
            'total_rms_arcsec REAL NOT NULL, '
            'sample_count INTEGER NOT NULL, '
            'exposure_seconds REAL, '
            'recorded_at INTEGER NOT NULL'
            ')',
          );
          await customStatement(
            'INSERT OR IGNORE INTO guide_rms_history '
            '(id, session_id, mount_id, target_id, total_rms_arcsec, '
            'sample_count, exposure_seconds, recorded_at) '
            'SELECT id, session_id, mount_id, target_id, total_rms_arcsec, '
            'sample_count, exposure_seconds, recorded_at '
            'FROM guide_rms_history_v29',
          );
          // Step 4 — only now, with the rows provably copied.
          await customStatement('DROP TABLE guide_rms_history_v29');
        }

        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_guide_rms_mount_recent '
          'ON guide_rms_history (mount_id, recorded_at DESC)',
        );
      }
    }

    // Version 31: Persisted predictive autofocus models (per-filter).
    //
    // Adds the `focus_models` table that stores the learned linear
    // regression between focuser temperature and best-focus position,
    // keyed by (equipment_profile_id, filter_name). Powers the
    // predictive autofocus feature — confidence-gated prediction,
    // cross-session persistence, and drift-detection notifications.
    //
    // Backwards compat: the legacy JSON-file
    // [FocusModelService] continues to work unchanged. The DB rows
    // here are written by [PredictiveAfService] and are additive.
    if (from < 31) {
      await _createFocusModelsTable();
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('predictive_af.enabled', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('predictive_af.min_samples_for_trust', '8')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('predictive_af.high_confidence_threshold', '0.8')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('predictive_af.low_confidence_threshold', '0.5')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('predictive_af.drift_threshold_steps', '200')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('predictive_af.drift_runs_before_warn', '5')",
      );
    }
  }
}
