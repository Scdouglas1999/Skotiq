part of '../database.dart';

extension _SkotiqDatabaseMigrationV2ToV17 on SkotiqDatabase {
  Future<void> _upgradeSchemaV2ToV17(Migrator m, int from) async {
    // Version 2: Add indexes for better query performance
    if (from < 2) {
      // Create indexes for targets
      await m.createIndex(
        Index(
          'idx_targets_name',
          'CREATE INDEX idx_targets_name ON targets (name)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_targets_catalog',
          'CREATE INDEX idx_targets_catalog ON targets (catalog_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_targets_priority',
          'CREATE INDEX idx_targets_priority ON targets (priority)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_targets_favorite',
          'CREATE INDEX idx_targets_favorite ON targets (is_favorite)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_targets_object_type',
          'CREATE INDEX idx_targets_object_type ON targets (object_type)',
        ),
      );

      // Create indexes for captured_images
      await m.createIndex(
        Index(
          'idx_images_session',
          'CREATE INDEX idx_images_session ON captured_images (session_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_images_target',
          'CREATE INDEX idx_images_target ON captured_images (target_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_images_frame_type',
          'CREATE INDEX idx_images_frame_type ON captured_images (frame_type)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_images_captured_at',
          'CREATE INDEX idx_images_captured_at ON captured_images (captured_at)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_images_filter',
          'CREATE INDEX idx_images_filter ON captured_images (filter)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_images_accepted',
          'CREATE INDEX idx_images_accepted ON captured_images (is_accepted)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_images_session_frame',
          'CREATE INDEX idx_images_session_frame ON captured_images (session_id, frame_type)',
        ),
      );

      // Create indexes for imaging_sessions
      await m.createIndex(
        Index(
          'idx_sessions_target',
          'CREATE INDEX idx_sessions_target ON imaging_sessions (target_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_sessions_profile',
          'CREATE INDEX idx_sessions_profile ON imaging_sessions (profile_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_sessions_start',
          'CREATE INDEX idx_sessions_start ON imaging_sessions (start_time)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_sessions_status',
          'CREATE INDEX idx_sessions_status ON imaging_sessions (status)',
        ),
      );

      // Create indexes for sequences
      await m.createIndex(
        Index(
          'idx_sequences_name',
          'CREATE INDEX idx_sequences_name ON sequences (name)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_sequences_template',
          'CREATE INDEX idx_sequences_template ON sequences (is_template)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_sequences_updated',
          'CREATE INDEX idx_sequences_updated ON sequences (updated_at)',
        ),
      );

      // Create indexes for sequence_nodes
      await m.createIndex(
        Index(
          'idx_nodes_sequence',
          'CREATE INDEX idx_nodes_sequence ON sequence_nodes (sequence_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_nodes_parent',
          'CREATE INDEX idx_nodes_parent ON sequence_nodes (parent_node_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_nodes_target',
          'CREATE INDEX idx_nodes_target ON sequence_nodes (target_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_nodes_type',
          'CREATE INDEX idx_nodes_type ON sequence_nodes (node_type)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_nodes_node_id',
          'CREATE INDEX idx_nodes_node_id ON sequence_nodes (node_id)',
        ),
      );

      // Create indexes for image_metadata
      await m.createIndex(
        Index(
          'idx_metadata_image',
          'CREATE INDEX idx_metadata_image ON image_metadata (image_id)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_metadata_key',
          'CREATE INDEX idx_metadata_key ON image_metadata (key)',
        ),
      );

      // Create indexes for equipment_profiles
      await m.createIndex(
        Index(
          'idx_profiles_name',
          'CREATE INDEX idx_profiles_name ON equipment_profiles (name)',
        ),
      );
      await m.createIndex(
        Index(
          'idx_profiles_active',
          'CREATE INDEX idx_profiles_active ON equipment_profiles (is_active)',
        ),
      );
    }

    // Version 3: Add sequence checkpointing table. Drift does not recreate
    // tables to pick up changed FK constraints — SQLite requires explicit
    // recreation — so the FK cascade changes for captured_images,
    // image_metadata and sequence_nodes are applied by version 18 instead.
    if (from < 3) {
      await m.createTable(sequenceCheckpoints);
    }

    // Version 4: Add weather settings table
    if (from < 4) {
      await m.createTable(weatherSettings);
    }

    // Version 5: Add cover_calibrator_id to equipment_profiles
    if (from < 5) {
      final hasCoverCalibratorId = await _columnExists(
        'equipment_profiles',
        'cover_calibrator_id',
      );
      if (!hasCoverCalibratorId) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN cover_calibrator_id TEXT',
        );
      }
    }

    // Version 6: Add meridian_flip_overrides to equipment_profiles
    if (from < 6) {
      final hasMeridianFlipOverrides = await _columnExists(
        'equipment_profiles',
        'meridian_flip_overrides',
      );
      if (!hasMeridianFlipOverrides) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN meridian_flip_overrides TEXT',
        );
      }
    }

    // Version 7: Add flat history table
    if (from < 7) {
      await m.createTable(flatHistory);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_flat_history_profile ON flat_history (equipment_profile_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_flat_history_filter ON flat_history (filter_name)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_flat_history_timestamp ON flat_history (timestamp)',
      );
    }

    // Version 8: Add Quick Start support columns to imaging_sessions
    if (from < 8) {
      final hasSequenceId = await _columnExists(
        'imaging_sessions',
        'sequence_id',
      );
      if (!hasSequenceId) {
        await customStatement(
          'ALTER TABLE imaging_sessions ADD COLUMN sequence_id INTEGER REFERENCES sequences(id)',
        );
      }

      final hasEquipmentSnapshot = await _columnExists(
        'imaging_sessions',
        'equipment_snapshot',
      );
      if (!hasEquipmentSnapshot) {
        await customStatement(
          'ALTER TABLE imaging_sessions ADD COLUMN equipment_snapshot TEXT',
        );
      }
    }

    // Version 9: Add tutorial progress table
    if (from < 9) {
      await m.createTable(tutorialProgress);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tutorial_progress_category ON tutorial_progress (category)',
      );
    }

    // Version 10: Add polar alignment history table
    if (from < 10) {
      await m.createTable(polarAlignmentHistory);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_polar_history_profile ON polar_alignment_history (equipment_profile_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_polar_history_started ON polar_alignment_history (started_at)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_polar_history_completed ON polar_alignment_history (completed_at)',
      );

      final hasQualityScore = await _columnExists(
        'captured_images',
        'quality_score',
      );
      if (!hasQualityScore) {
        await customStatement(
          'ALTER TABLE captured_images ADD COLUMN quality_score REAL',
        );
      }
    }

    // Version 11: Add user-friendly device names, telescope info, and profile customization to equipment_profiles
    if (from < 11) {
      // User-friendly device names
      final hasCameraName = await _columnExists(
        'equipment_profiles',
        'camera_name',
      );
      if (!hasCameraName) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN camera_name TEXT',
        );
      }
      final hasMountName = await _columnExists(
        'equipment_profiles',
        'mount_name',
      );
      if (!hasMountName) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN mount_name TEXT',
        );
      }
      final hasFocuserName = await _columnExists(
        'equipment_profiles',
        'focuser_name',
      );
      if (!hasFocuserName) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN focuser_name TEXT',
        );
      }
      final hasFilterWheelName = await _columnExists(
        'equipment_profiles',
        'filter_wheel_name',
      );
      if (!hasFilterWheelName) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN filter_wheel_name TEXT',
        );
      }
      final hasGuiderName = await _columnExists(
        'equipment_profiles',
        'guider_name',
      );
      if (!hasGuiderName) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN guider_name TEXT',
        );
      }
      final hasRotatorName = await _columnExists(
        'equipment_profiles',
        'rotator_name',
      );
      if (!hasRotatorName) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN rotator_name TEXT',
        );
      }

      // Telescope/OTA information
      final hasTelescopeName = await _columnExists(
        'equipment_profiles',
        'telescope_name',
      );
      if (!hasTelescopeName) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN telescope_name TEXT',
        );
      }
      final hasTelescopeFocalLength = await _columnExists(
        'equipment_profiles',
        'telescope_focal_length',
      );
      if (!hasTelescopeFocalLength) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN telescope_focal_length REAL',
        );
      }
      final hasTelescopeAperture = await _columnExists(
        'equipment_profiles',
        'telescope_aperture',
      );
      if (!hasTelescopeAperture) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN telescope_aperture REAL',
        );
      }

      // Profile customization
      final hasProfileIcon = await _columnExists(
        'equipment_profiles',
        'profile_icon',
      );
      if (!hasProfileIcon) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN profile_icon TEXT',
        );
      }
      final hasProfileColor = await _columnExists(
        'equipment_profiles',
        'profile_color',
      );
      if (!hasProfileColor) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN profile_color INTEGER',
        );
      }
      final hasSortOrder = await _columnExists(
        'equipment_profiles',
        'sort_order',
      );
      if (!hasSortOrder) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN sort_order INTEGER DEFAULT 0',
        );
      }
      final hasIsDefault = await _columnExists(
        'equipment_profiles',
        'is_default',
      );
      if (!hasIsDefault) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN is_default INTEGER DEFAULT 0',
        );
      }
    }

    // Version 12: Add cool_on_connect to equipment_profiles
    if (from < 12) {
      final hasCoolOnConnect = await _columnExists(
        'equipment_profiles',
        'cool_on_connect',
      );
      if (!hasCoolOnConnect) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN cool_on_connect INTEGER NOT NULL DEFAULT 0',
        );
      }
    }

    // Version 13: Add science suite tables
    if (from < 13) {
      await m.createTable(scienceSessionConfig);
      await m.createTable(photometryMeasurements);
      await m.createTable(framePhotometricCalibration);
      await m.createTable(transparencySamples);
      await m.createTable(psfFieldTiles);
      await m.createTable(astrometryResidualVectors);
      await m.createTable(movingObjectCandidates);
      await m.createTable(lineRatioProducts);

      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_photometry_measurements_image ON photometry_measurements (captured_image_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_photometry_measurements_session ON photometry_measurements (session_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_photometry_measurements_timestamp ON photometry_measurements (timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_photometry_measurements_object ON photometry_measurements (object_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_frame_photometric_calibration_image ON frame_photometric_calibration (captured_image_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_frame_photometric_calibration_session ON frame_photometric_calibration (session_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_frame_photometric_calibration_timestamp ON frame_photometric_calibration (timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_frame_photometric_calibration_solver ON frame_photometric_calibration (solver_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_transparency_samples_image ON transparency_samples (captured_image_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_transparency_samples_session ON transparency_samples (session_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_transparency_samples_timestamp ON transparency_samples (timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_psf_field_tiles_image ON psf_field_tiles (captured_image_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_psf_field_tiles_session ON psf_field_tiles (session_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_psf_field_tiles_timestamp ON psf_field_tiles (timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_astrometry_residual_vectors_image ON astrometry_residual_vectors (captured_image_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_astrometry_residual_vectors_session ON astrometry_residual_vectors (session_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_astrometry_residual_vectors_timestamp ON astrometry_residual_vectors (timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_moving_object_candidates_image ON moving_object_candidates (captured_image_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_moving_object_candidates_session ON moving_object_candidates (session_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_moving_object_candidates_timestamp ON moving_object_candidates (timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_moving_object_candidates_object ON moving_object_candidates (candidate_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_line_ratio_products_session ON line_ratio_products (session_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_line_ratio_products_timestamp ON line_ratio_products (created_at)',
      );

      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.advanced_mode.enabled', 'false')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.overlay.enabled', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.photometry', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.photometric_calibration', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.transparency', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.psf_map', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.astrometric_residuals', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.moving_objects', 'false')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.narrowband_ratios', 'false')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.retention.manual_purge_only', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.photometry.differential_active', 'false')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.photometry.target_anchor', '')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.photometry.comparison_anchors', '[]')",
      );
    }

    // Version 14: Add frame quality and tile metrics tables
    if (from < 14) {
      await m.createTable(scienceFrameQualityMetrics);
      await m.createTable(scienceTileMetrics);

      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_science_frame_quality_metrics_image ON science_frame_quality_metrics (captured_image_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_science_frame_quality_metrics_session_layer_timestamp ON science_frame_quality_metrics (session_id, processing_tier, timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_science_tile_metrics_session_layer_timestamp ON science_tile_metrics (session_id, layer_type, timestamp)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_science_tile_metrics_image_layer ON science_tile_metrics (captured_image_id, layer_type)',
      );

      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.frame_quality_maps', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.feature.surface3d', 'true')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.overlay.opacity', '0.35')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.overlay.live_grid_rows', '12')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.overlay.live_grid_cols', '16')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.overlay.analysis_grid_rows', '24')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('science.overlay.analysis_grid_cols', '32')",
      );
    }

    // Version 15: Add default_centering_exposure to equipment_profiles
    if (from < 15) {
      final hasCenteringExposure = await _columnExists(
        'equipment_profiles',
        'default_centering_exposure',
      );
      if (!hasCenteringExposure) {
        await customStatement(
          'ALTER TABLE equipment_profiles ADD COLUMN default_centering_exposure REAL',
        );
      }
    }

    // Version 16: Fix FK constraints and polar_alignment_history column type
    // - imaging_sessions: profileId and targetId now have ON DELETE SET NULL
    // - flat_history: equipmentProfileId is now a proper FK to equipment_profiles
    // - polar_alignment_history: equipmentProfileId changed from TEXT to INTEGER
    if (from < 16) {
      // Recreate imaging_sessions with ON DELETE SET NULL FK constraints
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
          sequence_id INTEGER REFERENCES sequences(id),
          equipment_snapshot TEXT
        )
      ''');
      await customStatement('''
        INSERT INTO imaging_sessions_new
          SELECT * FROM imaging_sessions
      ''');
      await customStatement('DROP TABLE imaging_sessions');
      await customStatement(
        'ALTER TABLE imaging_sessions_new RENAME TO imaging_sessions',
      );
      // Recreate indexes
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

      // Recreate flat_history with proper FK reference
      await customStatement('''
        CREATE TABLE flat_history_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          equipment_profile_id INTEGER REFERENCES equipment_profiles(id) ON DELETE SET NULL,
          filter_name TEXT NOT NULL,
          exposure_time REAL NOT NULL,
          histogram_target REAL NOT NULL,
          actual_adu INTEGER NOT NULL,
          panel_brightness INTEGER,
          sky_adu_rate REAL,
          twilight_phase TEXT,
          gain INTEGER NOT NULL DEFAULT 0,
          binning INTEGER NOT NULL DEFAULT 1,
          timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');
      await customStatement('''
        INSERT INTO flat_history_new
          SELECT * FROM flat_history
      ''');
      await customStatement('DROP TABLE flat_history');
      await customStatement(
        'ALTER TABLE flat_history_new RENAME TO flat_history',
      );
      // Recreate indexes
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_flat_history_profile ON flat_history (equipment_profile_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_flat_history_filter ON flat_history (filter_name)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_flat_history_timestamp ON flat_history (timestamp)',
      );

      // Recreate polar_alignment_history with INTEGER equipment_profile_id
      // and proper FK reference (was TEXT, now INTEGER)
      await customStatement('''
        CREATE TABLE polar_alignment_history_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          equipment_profile_id INTEGER REFERENCES equipment_profiles(id) ON DELETE SET NULL,
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
      // Migrate data, casting TEXT equipment_profile_id to INTEGER
      // Invalid text values will become NULL (CAST returns 0 for non-numeric text, so use CASE)
      await customStatement('''
        INSERT INTO polar_alignment_history_new
          (id, equipment_profile_id, initial_azimuth_error, initial_altitude_error,
           initial_total_error, final_azimuth_error, final_altitude_error,
           final_total_error, started_at, completed_at, auto_completed, is_north, config_json)
        SELECT
          id,
          CASE
            WHEN equipment_profile_id IS NULL THEN NULL
            WHEN TYPEOF(equipment_profile_id) = 'integer' THEN equipment_profile_id
            WHEN equipment_profile_id GLOB '[0-9]*' THEN CAST(equipment_profile_id AS INTEGER)
            ELSE NULL
          END,
          initial_azimuth_error, initial_altitude_error,
          initial_total_error, final_azimuth_error, final_altitude_error,
          final_total_error, started_at, completed_at, auto_completed, is_north, config_json
        FROM polar_alignment_history
      ''');
      await customStatement('DROP TABLE polar_alignment_history');
      await customStatement(
        'ALTER TABLE polar_alignment_history_new RENAME TO polar_alignment_history',
      );
      // Recreate indexes
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

    // Version 17: Add dark frame library table
    if (from < 17) {
      await m.createTable(darkLibrary);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_dark_library_frame_type ON dark_library (frame_type)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_dark_library_exposure ON dark_library (exposure_time)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_dark_library_temperature ON dark_library (temperature)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_dark_library_gain ON dark_library (gain)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_dark_library_match ON dark_library (frame_type, exposure_time, gain, bin_x, bin_y)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_dark_library_created ON dark_library (created_at)',
      );

      // Add dark library default settings
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('dark_library.auto_subtract', 'false')",
      );
      await customStatement(
        "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('dark_library.temp_tolerance', '2.0')",
      );
    }
  }
}
