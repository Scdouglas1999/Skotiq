import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../utils/skotiq_data_directory.dart';

import '../models/darkroom/darkroom_job.dart' show kDarkroomJobMaxAttempts;
import '../models/settings/app_settings.dart' show kDefaultAccentColorHex;
import '../services/quality_stop_migration.dart';
import 'integrity_check.dart' as integrity;
import 'integrity_check.dart'
    show DatabaseRecoveryMarker, QuarantinedDatabaseCheck;
import 'integration_stage_marker.dart';
import 'session_orphan_sweep.dart';
import 'solved_rotation_repair.dart';
import 'single_instance_lock.dart';
import 'sqlite_busy.dart';
import 'tables/equipment_profiles.dart';
import 'tables/imaging_sessions.dart';
import 'tables/targets.dart';
import 'tables/sequences.dart';
import 'tables/captured_images.dart';
import 'tables/settings.dart';
import 'tables/weather_settings.dart';
import 'tables/flat_history.dart';
import 'tables/tutorial_progress.dart';
import 'tables/polar_alignment_history.dart';
import 'tables/science.dart';
import 'tables/dark_library.dart';
import 'tables/observation_logs.dart';
import 'tables/observing_lists.dart';
import 'tables/sequence_runs.dart';
import 'tables/sequence_versions.dart';
import 'tables/session_diagnostics.dart';
import 'tables/defect_map_table.dart';
import 'tables/focus_models.dart';
import 'tables/guide_rms_history.dart';
import 'tables/narrator_events.dart';
import 'tables/sky_atlas_tables.dart';
import 'tables/constellation_contributions.dart';
import 'tables/coimaging_sessions.dart';
import 'tables/transient_detections.dart';
import 'tables/living_sky_retention.dart';
import 'daos/images_dao.dart';
import 'daos/equipment_profiles_dao.dart';
import 'daos/sessions_dao.dart';
import 'daos/sequences_dao.dart';
import 'daos/sequence_checkpoints_dao.dart';
import 'daos/targets_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/weather_settings_dao.dart';
import 'daos/flat_history_dao.dart';
import 'daos/tutorial_progress_dao.dart';
import 'daos/polar_alignment_history_dao.dart';
import 'daos/science_dao.dart';
import 'daos/dark_library_dao.dart';
import 'daos/observation_logs_dao.dart';
import 'daos/observing_lists_dao.dart';
import 'daos/sequence_runs_dao.dart';
import 'daos/sequence_versions_dao.dart';
import 'daos/session_diagnostics_dao.dart';
import 'daos/guide_rms_history_dao.dart';
import 'daos/narrator_events_dao.dart';
import 'daos/sky_atlas_dao.dart';
import 'daos/constellation_contributions_dao.dart';
import 'daos/coimaging_sessions_dao.dart';
import 'daos/transient_detections_dao.dart';
import 'daos/living_sky_retention_dao.dart';

part 'database.g.dart';
part 'database/migration_strategy.dart';
part 'database/migration_v2_to_v17.dart';
part 'database/migration_v18_to_v22.dart';
part 'database/migration_v23_to_v31.dart';
part 'database/migration_v32_to_v40.dart';
part 'database/migration_v41.dart';
part 'database/migration_v42.dart';
part 'database/migration_v43.dart';
part 'database/migration_v44.dart';
part 'database/migration_v45.dart';
part 'database/migration_v46.dart';
part 'database/migration_v47.dart';
part 'database/migration_v48.dart';
part 'database/migration_v49.dart';
part 'database/migration_v50.dart';
part 'database/migration_v51.dart';
part 'database/migration_v52.dart';
part 'database/migration_v53.dart';
part 'database/migration_v54.dart';
part 'database/migration_v55.dart';
part 'database/migration_v56.dart';
part 'database/migration_v57.dart';
part 'database/migration_v58.dart';
part 'database/migration_v59.dart';
part 'database/migration_v60.dart';
part 'database/migration_v61.dart';
part 'database/migration_v62.dart';
part 'database/schema_helpers.dart';
part 'database/default_settings.dart';
part 'database/connection.dart';

/// The main database class for Skotiq
@DriftDatabase(
  tables: [
    EquipmentProfiles,
    ImagingSessions,
    Targets,
    Sequences,
    SequenceNodes,
    SequenceCheckpoints,
    CapturedImages,
    ImageMetadata,
    AppSettings,
    WeatherSettings,
    FlatHistory,
    TutorialProgress,
    PolarAlignmentHistory,
    ScienceSessionConfig,
    PhotometryMeasurements,
    FramePhotometricCalibration,
    TransparencySamples,
    PsfFieldTiles,
    ScienceFrameQualityMetrics,
    ScienceTileMetrics,
    AstrometryResidualVectors,
    MovingObjectCandidates,
    LineRatioProducts,
    PhotometricTransforms,
    DarkLibrary,
    ObservationLogs,
    ObservingLists,
    ObservingListItems,
    SequenceRuns,
    SequenceVersions,
    SessionDiagnostics,
    DefectMaps,
    FocusModels,
    GuideRmsHistory,
    NarratorEvents,
    SkyTiles,
    SkyAtlasRegions,
    SkyAtlasFolds,
    ConstellationContributions,
    CoImagingSessions,
    TransientDetections,
    LivingSkyRetention,
  ],
  daos: [
    ImagesDao,
    EquipmentProfilesDao,
    SessionsDao,
    SequencesDao,
    SequenceCheckpointsDao,
    TargetsDao,
    SettingsDao,
    WeatherSettingsDao,
    FlatHistoryDao,
    TutorialProgressDao,
    PolarAlignmentHistoryDao,
    ScienceDao,
    DarkLibraryDao,
    ObservationLogsDao,
    ObservingListsDao,
    SequenceRunsDao,
    SequenceVersionsDao,
    SessionDiagnosticsDao,
    GuideRmsHistoryDao,
    NarratorEventsDao,
    SkyAtlasDao,
    ConstellationContributionsDao,
    CoImagingSessionsDao,
    TransientDetectionsDao,
    LivingSkyRetentionDao,
  ],
)
class SkotiqDatabase extends _$SkotiqDatabase {
  SkotiqDatabase() : super(_openConnection());

  /// For testing with a custom QueryExecutor
  SkotiqDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 62;

  @override
  MigrationStrategy get migration => _buildMigrationStrategy();

  /// One-shot UI hook: returns a [DatabaseRecoveryMarker] iff the previous
  /// app launch rotated a corrupt database into a forensic backup, then
  /// clears every recovery marker in the database directory so the same
  /// dialog is not shown again.
  ///
  /// Why a static helper rather than an instance method: the UI layer needs
  /// to call this at startup, BEFORE constructing the database (otherwise
  /// the freshly-recreated DB has already been "consumed" by the migrator
  /// and the marker has lost its UX meaning of "this is the first launch
  /// AFTER recovery"). Static avoids a chicken-and-egg dependency on a
  /// live [SkotiqDatabase].
  static Future<DatabaseRecoveryMarker?> consumeRecoveryMarker() async {
    final dbFile = await resolveDefaultDatabaseFile();
    return integrity.consumeRecoveryMarker(dbFile.parent);
  }

  /// Reads, but does not clear, the recovery notification. GUI callers should
  /// acknowledge it only after the user has dismissed the warning.
  static Future<DatabaseRecoveryMarker?> readRecoveryMarker() async {
    final dbFile = await resolveDefaultDatabaseFile();
    return integrity.readRecoveryMarker(dbFile.parent);
  }

  static Future<void> acknowledgeRecoveryMarker(
    DatabaseRecoveryMarker marker,
  ) async {
    final dbFile = await resolveDefaultDatabaseFile();
    await integrity.acknowledgeRecoveryMarker(dbFile.parent, marker);
  }

  /// Re-checks a quarantined database so the UI can describe it truthfully.
  /// Builds before the result-code fix quarantined healthy databases on
  /// `SQLITE_BUSY`, so "we called it corrupt" is not evidence that it is.
  static Future<QuarantinedDatabaseCheck> inspectQuarantinedDatabase(
    String backupPath,
  ) => integrity.inspectQuarantinedDatabase(backupPath);

  /// Stages a quarantined database to be swapped back in on the next launch.
  /// Applied by the pre-flight in `_openConnection` before drift opens
  /// anything; the caller is responsible for telling the user to restart.
  static Future<String> stageDatabaseRestore(String backupPath) async {
    final dbFile = await resolveDefaultDatabaseFile();
    return integrity.stageDatabaseRestore(
      dbFile: dbFile,
      backupPath: backupPath,
    );
  }
}
