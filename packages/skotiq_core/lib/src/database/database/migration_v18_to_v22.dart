part of '../database.dart';

extension _SkotiqDatabaseMigrationV18ToV22 on SkotiqDatabase {
  Future<void> _upgradeSchemaV18ToV22(Migrator m, int from) async {
    // Version 18: Retroactively apply the FK cascade changes that
    // migration v3 promised but never executed, add composite index
    // on captured_images (session_id, captured_at), and recreate
    // sequence_nodes/image_metadata with proper cascade FKs.
    if (from < 18) {
      await transaction(() async {
        // ── 1. Recreate sequence_nodes with ON DELETE CASCADE on sequenceId ──
        await customStatement('''
        CREATE TABLE sequence_nodes_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          node_id TEXT NOT NULL,
          sequence_id INTEGER NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
          target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,
          node_type TEXT NOT NULL,
          specific_type TEXT NOT NULL,
          name TEXT NOT NULL,
          properties TEXT NOT NULL DEFAULT '{}',
          recovery_config TEXT,
          parent_node_id TEXT,
          order_index INTEGER NOT NULL DEFAULT 0,
          is_enabled INTEGER NOT NULL DEFAULT 1
        )
      ''');
        await customStatement('''
        INSERT INTO sequence_nodes_new
          SELECT * FROM sequence_nodes
      ''');
        await customStatement('DROP TABLE sequence_nodes');
        await customStatement(
          'ALTER TABLE sequence_nodes_new RENAME TO sequence_nodes',
        );
        // Recreate indexes for sequence_nodes
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_nodes_sequence ON sequence_nodes (sequence_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_nodes_parent ON sequence_nodes (parent_node_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_nodes_target ON sequence_nodes (target_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_nodes_type ON sequence_nodes (node_type)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_nodes_node_id ON sequence_nodes (node_id)',
        );

        // ── 2. Recreate captured_images with ON DELETE CASCADE / SET NULL FKs ──
        // First, drop all child tables that reference captured_images so SQLite
        // allows us to drop the parent. We'll recreate them afterward.
        //
        // Save child table data into temp tables before dropping.
        await customStatement(
          'CREATE TEMP TABLE _tmp_image_metadata AS SELECT * FROM image_metadata',
        );
        await customStatement('DROP TABLE image_metadata');

        // Science child tables that reference captured_images:
        await customStatement(
          'CREATE TEMP TABLE _tmp_photometry_measurements AS SELECT * FROM photometry_measurements',
        );
        await customStatement('DROP TABLE photometry_measurements');

        await customStatement(
          'CREATE TEMP TABLE _tmp_frame_photometric_calibration AS SELECT * FROM frame_photometric_calibration',
        );
        await customStatement('DROP TABLE frame_photometric_calibration');

        await customStatement(
          'CREATE TEMP TABLE _tmp_transparency_samples AS SELECT * FROM transparency_samples',
        );
        await customStatement('DROP TABLE transparency_samples');

        await customStatement(
          'CREATE TEMP TABLE _tmp_psf_field_tiles AS SELECT * FROM psf_field_tiles',
        );
        await customStatement('DROP TABLE psf_field_tiles');

        await customStatement(
          'CREATE TEMP TABLE _tmp_science_frame_quality_metrics AS SELECT * FROM science_frame_quality_metrics',
        );
        await customStatement('DROP TABLE science_frame_quality_metrics');

        await customStatement(
          'CREATE TEMP TABLE _tmp_science_tile_metrics AS SELECT * FROM science_tile_metrics',
        );
        await customStatement('DROP TABLE science_tile_metrics');

        await customStatement(
          'CREATE TEMP TABLE _tmp_astrometry_residual_vectors AS SELECT * FROM astrometry_residual_vectors',
        );
        await customStatement('DROP TABLE astrometry_residual_vectors');

        await customStatement(
          'CREATE TEMP TABLE _tmp_moving_object_candidates AS SELECT * FROM moving_object_candidates',
        );
        await customStatement('DROP TABLE moving_object_candidates');

        await customStatement(
          'CREATE TEMP TABLE _tmp_line_ratio_products AS SELECT * FROM line_ratio_products',
        );
        await customStatement('DROP TABLE line_ratio_products');

        final capturedImagesHasQualityScore = await _columnExists(
          'captured_images',
          'quality_score',
        );
        final qualityScoreSelect = capturedImagesHasQualityScore
            ? 'quality_score'
            : 'NULL AS quality_score';

        // Now recreate captured_images with correct FK constraints
        await customStatement('''
        CREATE TABLE captured_images_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          file_path TEXT NOT NULL,
          file_name TEXT NOT NULL,
          file_format TEXT NOT NULL DEFAULT 'fits',
          file_size INTEGER,
          session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE CASCADE,
          target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,
          frame_type TEXT NOT NULL DEFAULT 'light',
          exposure_duration REAL NOT NULL,
          gain INTEGER,
          "offset" INTEGER,
          bin_x INTEGER NOT NULL DEFAULT 1,
          bin_y INTEGER NOT NULL DEFAULT 1,
          filter TEXT,
          sensor_temp REAL,
          cooler_power REAL,
          hfr REAL,
          star_count INTEGER,
          background REAL,
          noise REAL,
          quality_score REAL,
          guiding_rms_ra REAL,
          guiding_rms_dec REAL,
          guiding_rms_total REAL,
          mount_ra REAL,
          mount_dec REAL,
          mount_altitude REAL,
          mount_azimuth REAL,
          pier_side TEXT,
          focuser_position INTEGER,
          focuser_temp REAL,
          rotator_angle REAL,
          is_plate_solved INTEGER NOT NULL DEFAULT 0,
          solved_ra REAL,
          solved_dec REAL,
          solved_rotation REAL,
          solved_pixel_scale REAL,
          captured_at INTEGER NOT NULL,
          created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
          is_accepted INTEGER NOT NULL DEFAULT 1,
          rejection_reason TEXT
        )
      ''');
        await customStatement('''
        INSERT INTO captured_images_new (
          id,
          file_path,
          file_name,
          file_format,
          file_size,
          session_id,
          target_id,
          frame_type,
          exposure_duration,
          gain,
          "offset",
          bin_x,
          bin_y,
          filter,
          sensor_temp,
          cooler_power,
          hfr,
          star_count,
          background,
          noise,
          quality_score,
          guiding_rms_ra,
          guiding_rms_dec,
          guiding_rms_total,
          mount_ra,
          mount_dec,
          mount_altitude,
          mount_azimuth,
          pier_side,
          focuser_position,
          focuser_temp,
          rotator_angle,
          is_plate_solved,
          solved_ra,
          solved_dec,
          solved_rotation,
          solved_pixel_scale,
          captured_at,
          created_at,
          is_accepted,
          rejection_reason
        )
        SELECT
          id,
          file_path,
          file_name,
          file_format,
          file_size,
          session_id,
          target_id,
          frame_type,
          exposure_duration,
          gain,
          "offset",
          bin_x,
          bin_y,
          filter,
          sensor_temp,
          cooler_power,
          hfr,
          star_count,
          background,
          noise,
          $qualityScoreSelect,
          guiding_rms_ra,
          guiding_rms_dec,
          guiding_rms_total,
          mount_ra,
          mount_dec,
          mount_altitude,
          mount_azimuth,
          pier_side,
          focuser_position,
          focuser_temp,
          rotator_angle,
          is_plate_solved,
          solved_ra,
          solved_dec,
          solved_rotation,
          solved_pixel_scale,
          captured_at,
          created_at,
          is_accepted,
          rejection_reason
        FROM captured_images
      ''');
        await customStatement('DROP TABLE captured_images');
        await customStatement(
          'ALTER TABLE captured_images_new RENAME TO captured_images',
        );

        // Recreate indexes for captured_images
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_session ON captured_images (session_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_target ON captured_images (target_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_frame_type ON captured_images (frame_type)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_captured_at ON captured_images (captured_at)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_filter ON captured_images (filter)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_accepted ON captured_images (is_accepted)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_session_frame ON captured_images (session_id, frame_type)',
        );
        // New composite index for session queries ordered by capture time
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_images_session_captured_at ON captured_images (session_id, captured_at)',
        );

        // ── 3. Recreate image_metadata with ON DELETE CASCADE FK ──
        await customStatement('''
        CREATE TABLE image_metadata (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          image_id INTEGER NOT NULL REFERENCES captured_images(id) ON DELETE CASCADE,
          "key" TEXT NOT NULL,
          value TEXT NOT NULL,
          comment TEXT
        )
      ''');
        await customStatement('''
        INSERT INTO image_metadata
          SELECT * FROM _tmp_image_metadata
      ''');
        await customStatement('DROP TABLE _tmp_image_metadata');
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_metadata_image ON image_metadata (image_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_metadata_key ON image_metadata ("key")',
        );

        // ── 4. Recreate science child tables that reference captured_images ──

        // photometry_measurements
        final photometryHasStandardMagnitude = await _columnExists(
          '_tmp_photometry_measurements',
          'standard_magnitude',
        );
        final standardMagnitudeSelect = photometryHasStandardMagnitude
            ? 'standard_magnitude'
            : 'NULL AS standard_magnitude';
        await m.createTable(photometryMeasurements);
        await customStatement('''
        INSERT INTO photometry_measurements (
          id,
          captured_image_id,
          session_id,
          object_id,
          role,
          x,
          y,
          flux,
          differential_magnitude,
          standard_magnitude,
          snr,
          uncertainty,
          is_outlier,
          timestamp
        )
        SELECT
          id,
          captured_image_id,
          session_id,
          object_id,
          role,
          x,
          y,
          flux,
          differential_magnitude,
          $standardMagnitudeSelect,
          snr,
          uncertainty,
          is_outlier,
          timestamp
        FROM _tmp_photometry_measurements
      ''');
        await customStatement('DROP TABLE _tmp_photometry_measurements');
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

        // frame_photometric_calibration
        await m.createTable(framePhotometricCalibration);
        await customStatement('''
        INSERT INTO frame_photometric_calibration
          SELECT * FROM _tmp_frame_photometric_calibration
      ''');
        await customStatement('DROP TABLE _tmp_frame_photometric_calibration');
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

        // transparency_samples
        await m.createTable(transparencySamples);
        await customStatement('''
        INSERT INTO transparency_samples
          SELECT * FROM _tmp_transparency_samples
      ''');
        await customStatement('DROP TABLE _tmp_transparency_samples');
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_transparency_samples_image ON transparency_samples (captured_image_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_transparency_samples_session ON transparency_samples (session_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_transparency_samples_timestamp ON transparency_samples (timestamp)',
        );

        // psf_field_tiles
        await m.createTable(psfFieldTiles);
        await customStatement('''
        INSERT INTO psf_field_tiles
          SELECT * FROM _tmp_psf_field_tiles
      ''');
        await customStatement('DROP TABLE _tmp_psf_field_tiles');
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_psf_field_tiles_image ON psf_field_tiles (captured_image_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_psf_field_tiles_session ON psf_field_tiles (session_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_psf_field_tiles_timestamp ON psf_field_tiles (timestamp)',
        );

        // science_frame_quality_metrics
        await m.createTable(scienceFrameQualityMetrics);
        await customStatement('''
        INSERT INTO science_frame_quality_metrics
          SELECT * FROM _tmp_science_frame_quality_metrics
      ''');
        await customStatement('DROP TABLE _tmp_science_frame_quality_metrics');
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_science_frame_quality_metrics_image ON science_frame_quality_metrics (captured_image_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_science_frame_quality_metrics_session_layer_timestamp ON science_frame_quality_metrics (session_id, processing_tier, timestamp)',
        );

        // science_tile_metrics
        await m.createTable(scienceTileMetrics);
        await customStatement('''
        INSERT INTO science_tile_metrics
          SELECT * FROM _tmp_science_tile_metrics
      ''');
        await customStatement('DROP TABLE _tmp_science_tile_metrics');
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_science_tile_metrics_session_layer_timestamp ON science_tile_metrics (session_id, layer_type, timestamp)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_science_tile_metrics_image_layer ON science_tile_metrics (captured_image_id, layer_type)',
        );

        // astrometry_residual_vectors
        await m.createTable(astrometryResidualVectors);
        await customStatement('''
        INSERT INTO astrometry_residual_vectors
          SELECT * FROM _tmp_astrometry_residual_vectors
      ''');
        await customStatement('DROP TABLE _tmp_astrometry_residual_vectors');
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_astrometry_residual_vectors_image ON astrometry_residual_vectors (captured_image_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_astrometry_residual_vectors_session ON astrometry_residual_vectors (session_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_astrometry_residual_vectors_timestamp ON astrometry_residual_vectors (timestamp)',
        );

        // moving_object_candidates
        await m.createTable(movingObjectCandidates);
        await customStatement('''
        INSERT INTO moving_object_candidates
          SELECT * FROM _tmp_moving_object_candidates
      ''');
        await customStatement('DROP TABLE _tmp_moving_object_candidates');
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

        // line_ratio_products
        await m.createTable(lineRatioProducts);
        await customStatement('''
        INSERT INTO line_ratio_products
          SELECT * FROM _tmp_line_ratio_products
      ''');
        await customStatement('DROP TABLE _tmp_line_ratio_products');
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_line_ratio_products_session ON line_ratio_products (session_id)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_line_ratio_products_timestamp ON line_ratio_products (created_at)',
        );
      });
    }

    if (from < 19) {
      if (!await _columnExists('weather_settings', 'max_humidity_percent')) {
        await customStatement(
          'ALTER TABLE weather_settings ADD COLUMN max_humidity_percent REAL NOT NULL DEFAULT 90.0',
        );
      }
      if (!await _columnExists('weather_settings', 'max_wind_speed_kph')) {
        await customStatement(
          'ALTER TABLE weather_settings ADD COLUMN max_wind_speed_kph REAL NOT NULL DEFAULT 30.0',
        );
      }
      if (!await _columnExists('weather_settings', 'max_cloud_cover_percent')) {
        await customStatement(
          'ALTER TABLE weather_settings ADD COLUMN max_cloud_cover_percent REAL NOT NULL DEFAULT 80.0',
        );
      }
    }

    if (from < 20) {
      if (!await _columnExists('targets', 'goal_integration_secs')) {
        await customStatement(
          'ALTER TABLE targets ADD COLUMN goal_integration_secs REAL NOT NULL DEFAULT 0.0',
        );
      }
    }

    if (from < 21) {
      await _dedupeScienceSessionConfigRows();
      await _normalizeActiveProfiles();
      await _recreateImagingSessionsForSequenceDeleteBehavior();
      await _recreatePolarAlignmentHistoryForCascadeDelete();
    }

    if (from < 22) {
      await _normalizeEquipmentProfileOptics();
    }
  }
}
