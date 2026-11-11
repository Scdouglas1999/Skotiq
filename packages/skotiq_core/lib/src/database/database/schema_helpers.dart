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
  /// Creates each of [entities] that the database does not have yet.
  ///
  /// Every table and index is declared once, in drift (`tables/*.dart` and
  /// `schema/*.drift`), and that declaration is the current shape. An upgrade
  /// step that introduced a table creates it from there, so the columns later
  /// versions added are already present and those versions' guarded
  /// `ADD COLUMN` steps find nothing to do.
  ///
  /// With [keepGoingPastIndexFailures], an index that cannot be built is
  /// reported and skipped. That is for the pass that closes an upgrade: it
  /// may be the first time a database is asked for an index it never had,
  /// and rows that break a UNIQUE index must not stop the database opening.
  Future<void> _createMissing(
    Migrator m,
    Iterable<DatabaseSchemaEntity> entities, {
    bool keepGoingPastIndexFailures = false,
  }) async {
    final rows = await customSelect('SELECT name FROM sqlite_master').get();
    final existing = {for (final row in rows) row.read<String>('name')};
    for (final entity in entities) {
      if (existing.contains(entity.entityName)) continue;
      if (entity is Index && keepGoingPastIndexFailures) {
        try {
          await m.create(entity);
        } catch (error) {
          // ignore: avoid_print
          print(
            '[skotiq_db] WARNING: could not create the index '
            '${entity.entityName} ($error). The database opens without it.',
          );
        }
        continue;
      }
      await m.create(entity);
    }
  }

  /// v31.
  Future<void> _createFocusModelsTable(Migrator m) => _createMissing(m, [
    focusModels,
    idxFocusModelsProfile,
    idxFocusModelsProfileFilter,
    idxFocusModelsLastUsed,
  ]);

  /// v34.
  Future<void> _createGuideRmsHistoryTable(Migrator m) =>
      _createMissing(m, [guideRmsHistory, idxGuideRmsMountRecent]);

  /// v32.
  Future<void> _createFrameForensicsTable(Migrator m) => _createMissing(m, [
    frameForensics,
    idxFrameForensicsSession,
    idxFrameForensicsRun,
    idxFrameForensicsCause,
    idxFrameForensicsImage,
  ]);

  /// v38.
  Future<void> _createStackedResultsTable(Migrator m) => _createMissing(m, [
    stackedResults,
    idxStackedResultsSession,
    idxStackedResultsTarget,
  ]);

  /// v40.
  Future<void> _createProjectsTables(Migrator m) => _createMissing(m, [
    projects,
    projectTargets,
    idxProjectTargetsProject,
    idxProjectTargetsTarget,
  ]);

  /// v41.
  Future<void> _createPostSessionTables(Migrator m) => _createMissing(m, [
    integratedMasters,
    idxIntegratedMastersTarget,
    idxIntegratedMastersStatus,
    idxIntegratedMastersCreated,
    integratedMasterFrames,
    idxIntegratedMasterFramesMaster,
    idxIntegratedMasterFramesImage,
    flatLibrary,
    idxFlatLibraryFilter,
    idxFlatLibraryProfile,
    idxFlatLibraryMatch,
  ]);

  /// v57: preview and coverage paths for the post-session diagnostic maps.
  /// A no-op once the table has been created from its current definition.
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

  /// v42.
  Future<void> _createNightReportsTable(Migrator m) => _createMissing(m, [
    nightReports,
    idxNightReportsSession,
    idxNightReportsTarget,
    idxNightReportsCreated,
  ]);

  /// v42: finishing artifacts, SNR/time goals and per-sub science columns on
  /// `integrated_masters` / `integrated_master_frames`, for a database whose
  /// tables predate them.
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

  /// v43.
  Future<void> _createCampaignsTable(Migrator m) =>
      _createMissing(m, [campaigns, idxCampaignsTarget]);

  /// v44: the plate-solved WCS and finishing-artifact paths on
  /// `integrated_masters`, for a database whose table predates them.
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

  /// v44.
  Future<void> _createNarrowbandCompositesTable(Migrator m) =>
      _createMissing(m, [narrowbandComposites, idxNarrowbandCompositesTarget]);

  /// v45.
  Future<void> _createMosaicTables(Migrator m) => _createMissing(m, [
    mosaicProjects,
    idxMosaicProjectsTarget,
    idxMosaicProjectsStatus,
    idxMosaicProjectsHub,
    mosaicPanels,
    idxMosaicPanelsProject,
    idxMosaicPanelsMaster,
  ]);

  /// v46.
  Future<void> _createCalibrationTagsTable(Migrator m) =>
      _createMissing(m, [calibrationTags, idxCalibrationTagsCamera]);

  /// v58.
  Future<void> _createDarkroomTables(Migrator m) => _createMissing(m, [
    recipes,
    idxRecipesTarget,
    idxRecipesSession,
    idxRecipesMaster,
    idxRecipesParent,
    idxRecipesBaseMaster,
    idxRecipesCreated,
    darkroomJobs,
    idxDarkroomJobsState,
    idxDarkroomJobsSession,
    idxDarkroomJobsCreated,
    deliveryTargets,
    idxDeliveryTargetsEnabled,
    idxDeliveryTargetsName,
    deliveryJournal,
    idxDeliveryJournalTarget,
    idxDeliveryJournalJob,
    idxDeliveryJournalState,
  ]);

  /// v65. Builds before v65 added this column at every open instead of in a
  /// versioned step, so a v64 database may or may not have it.
  Future<void> _ensureCapturedImagesSolveFailureColumn() async {
    if (!await _columnExists('captured_images', 'plate_solve_failed_at')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN plate_solve_failed_at INTEGER',
      );
    }
  }

  Future<void> _ensureCapturedImagesThumbnailPathColumn() async {
    if (!await _columnExists('captured_images', 'thumbnail_path')) {
      await customStatement(
        'ALTER TABLE captured_images ADD COLUMN thumbnail_path TEXT',
      );
    }
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

  /// Your Sky became opt-in. A profile whose atlas switch is on only because
  /// the old default seeded it on is turned off once, and a one-time notice is
  /// queued so the user hears about it and can turn it back on or delete the
  /// data. The seed never recorded whether the user chose the value, so every
  /// profile that predates this rule is treated as never having chosen. Turning
  /// Your Sky on afterwards is a real choice and is never undone: the rule runs
  /// once per profile, marked by [skyAtlasOptInMigratedKey].
  Future<void> _migrateSkyAtlasToOptIn() async {
    final marker = await customSelect(
      'SELECT 1 FROM app_settings WHERE key = ?',
      variables: [Variable.withString(skyAtlasOptInMigratedKey)],
    ).get();
    if (marker.isNotEmpty) return;
    final row = await customSelect(
      'SELECT value FROM app_settings WHERE key = ?',
      variables: [Variable.withString('science.feature.sky_atlas')],
    ).getSingleOrNull();
    final value = row?.read<String>('value').trim().toLowerCase();
    if (value != 'false') {
      await customStatement(
        'INSERT INTO app_settings (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        ['science.feature.sky_atlas', 'false'],
      );
      await customStatement(
        'INSERT INTO app_settings (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [skyAtlasOffNoticeKey, 'pending'],
      );
    }
    await customStatement(
      'INSERT INTO app_settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO NOTHING',
      [skyAtlasOptInMigratedKey, 'true'],
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
      final directory = await databaseDirectory();
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
