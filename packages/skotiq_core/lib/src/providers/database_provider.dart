import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'host_role.dart';
import '../backend/roles/host_data/host_records.dart';
import '../database/database.dart' as db;
import '../services/wcs/gnomonic_projection.dart' show SolvedWcs;
import '../services/wcs/plate_solve_data_from_result.dart'
    show solvedWcsFromStored;
import '../database/daos/equipment_profiles_dao.dart';
import '../database/daos/targets_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/images_dao.dart';
import '../database/daos/sequences_dao.dart';
import '../database/daos/settings_dao.dart';
import '../database/daos/science_dao.dart';
import '../database/daos/guide_rms_history_dao.dart';
import '../database/daos/narrator_events_dao.dart';
import '../database/daos/calibration_tags_dao.dart';
import '../database/daos/campaigns_dao.dart';
import '../database/daos/coimaging_sessions_dao.dart';
import '../database/daos/constellation_contributions_dao.dart';
import '../database/daos/darkroom_jobs_dao.dart';
import '../database/daos/delivery_journal_dao.dart';
import '../database/daos/delivery_targets_dao.dart';
import '../database/daos/flat_library_dao.dart';
import '../database/daos/integrated_masters_dao.dart';
import '../database/daos/living_sky_retention_dao.dart';
import '../database/daos/mosaic_panels_dao.dart';
import '../database/daos/mosaic_projects_dao.dart';
import '../database/daos/narrowband_composites_dao.dart';
import '../database/daos/night_reports_dao.dart';
import '../database/daos/recipes_dao.dart';
import '../database/daos/sky_atlas_dao.dart';
import '../database/daos/stacked_results_dao.dart';
import '../database/daos/transient_detections_dao.dart';
import '../database/daos/tutorial_progress_dao.dart';
import '../services/local_imaging_records.dart';
import 'host_settings/host_settings_providers.dart';
import 'captured_image_rows.dart';

export 'project_tracking_provider.dart';

final databaseProvider = Provider<db.SkotiqDatabase>((ref) {
  final database = db.SkotiqDatabase();
  ref.onDispose(() => database.close());
  return database;
});

final equipmentProfilesDaoProvider = Provider<EquipmentProfilesDao>((ref) {
  return EquipmentProfilesDao(ref.watch(databaseProvider));
});

final targetsDaoProvider = Provider<TargetsDao>((ref) {
  return TargetsDao(ref.watch(databaseProvider));
});

final sessionsDaoProvider = Provider<SessionsDao>((ref) {
  return SessionsDao(ref.watch(databaseProvider));
});

final imagesDaoProvider = Provider<ImagesDao>((ref) {
  return ImagesDao(ref.watch(databaseProvider));
});

final sequencesDaoProvider = Provider<SequencesDao>((ref) {
  return SequencesDao(ref.watch(databaseProvider));
});

/// Guided-tour progress and dismissed prompts. Always this computer's
/// database: what a user has been shown is theirs, not the imaging host's.
final tutorialProgressDaoProvider = Provider<TutorialProgressDao>((ref) {
  return TutorialProgressDao(ref.watch(databaseProvider));
});

/// Settings DAO provider
///
/// On a linked client this reads and writes the imaging host's rows (see
/// [RemoteSettingsDao]); on the machine that owns the hardware it is this
/// computer's database. Rebuilt when [settingsStoreRevisionProvider] says the
/// rows changed underneath it, so providers that watch it re-read them.
final settingsDaoProvider = Provider<SettingsDao>((ref) {
  final database = ref.watch(databaseProvider);
  ref.watch(settingsStoreRevisionProvider);
  final store = ref.watch(hostSettingsStoreProvider);
  if (store == null) return buildHostSettingsDao(ref, database);
  return buildRemoteSettingsDao(ref, store, database);
});

final scienceDaoProvider = Provider<ScienceDao>((ref) {
  return ScienceDao(ref.watch(databaseProvider));
});

final guideRmsHistoryDaoProvider = Provider<GuideRmsHistoryDao>((ref) {
  return GuideRmsHistoryDao(ref.watch(databaseProvider));
});

final narratorEventsDaoProvider = Provider<NarratorEventsDao>((ref) {
  return NarratorEventsDao(ref.watch(databaseProvider));
});

final calibrationTagsDaoProvider = Provider<CalibrationTagsDao>((ref) {
  return CalibrationTagsDao(ref.watch(databaseProvider));
});

final campaignsDaoProvider = Provider<CampaignsDao>((ref) {
  return CampaignsDao(ref.watch(databaseProvider));
});

final coImagingSessionsDaoProvider = Provider<CoImagingSessionsDao>((ref) {
  return CoImagingSessionsDao(ref.watch(databaseProvider));
});

final constellationContributionsDaoProvider =
    Provider<ConstellationContributionsDao>((ref) {
      return ConstellationContributionsDao(ref.watch(databaseProvider));
    });

final darkroomJobsDaoProvider = Provider<DarkroomJobsDao>((ref) {
  return DarkroomJobsDao(ref.watch(databaseProvider));
});

final deliveryJournalDaoProvider = Provider<DeliveryJournalDao>((ref) {
  return DeliveryJournalDao(ref.watch(databaseProvider));
});

final deliveryTargetsDaoProvider = Provider<DeliveryTargetsDao>((ref) {
  return DeliveryTargetsDao(ref.watch(databaseProvider));
});

final flatLibraryDaoProvider = Provider<FlatLibraryDao>((ref) {
  return FlatLibraryDao(ref.watch(databaseProvider));
});

final integratedMastersDaoProvider = Provider<IntegratedMastersDao>((ref) {
  return IntegratedMastersDao(ref.watch(databaseProvider));
});

final livingSkyRetentionDaoProvider = Provider<LivingSkyRetentionDao>((ref) {
  return LivingSkyRetentionDao(ref.watch(databaseProvider));
});

final mosaicPanelsDaoProvider = Provider<MosaicPanelsDao>((ref) {
  return MosaicPanelsDao(ref.watch(databaseProvider));
});

final mosaicProjectsDaoProvider = Provider<MosaicProjectsDao>((ref) {
  return MosaicProjectsDao(ref.watch(databaseProvider));
});

final narrowbandCompositesDaoProvider = Provider<NarrowbandCompositesDao>((
  ref,
) {
  return NarrowbandCompositesDao(ref.watch(databaseProvider));
});

final nightReportsDaoProvider = Provider<NightReportsDao>((ref) {
  return NightReportsDao(ref.watch(databaseProvider));
});

final recipesDaoProvider = Provider<RecipesDao>((ref) {
  return RecipesDao(ref.watch(databaseProvider));
});

final skyAtlasDaoProvider = Provider<SkyAtlasDao>((ref) {
  return SkyAtlasDao(ref.watch(databaseProvider));
});

final stackedResultsDaoProvider = Provider<StackedResultsDao>((ref) {
  return StackedResultsDao(ref.watch(databaseProvider));
});

final transientDetectionsDaoProvider = Provider<TransientDetectionsDao>((ref) {
  return TransientDetectionsDao(ref.watch(databaseProvider));
});

/// The saved targets of whichever machine is the imaging host.
final targetLibraryProvider = hostRoleProvider<TargetLibrary>(
  here: (ref) => ref.watch(targetsDaoProvider),
  linked: (ref, host) => host.records,
);

/// The saved sequences of whichever machine is the imaging host.
final sequenceLibraryProvider = hostRoleProvider<SequenceLibrary>(
  here: (ref) => ref.watch(sequencesDaoProvider),
  linked: (ref, host) => host.records,
);

/// The equipment profiles of whichever machine is the imaging host.
final equipmentProfileLibraryProvider =
    hostRoleProvider<EquipmentProfileLibrary>(
      here: (ref) => ref.watch(equipmentProfilesDaoProvider),
      linked: (ref, host) => host.records,
    );

/// The recorded sessions of whichever machine is the imaging host.
final sessionHistoryProvider = hostRoleProvider<SessionHistory>(
  here: (ref) => ref.watch(sessionsDaoProvider),
  linked: (ref, host) => host.records,
);

// Convenience providers for watching data
// Note: These use the database entity types (prefixed with db.)

final allProfilesProvider = StreamProvider<List<db.DbEquipmentProfile>>((ref) {
  return ref.watch(equipmentProfileLibraryProvider).watchAllProfiles();
});

final activeProfileProvider = StreamProvider<db.DbEquipmentProfile?>((ref) {
  return ref.watch(equipmentProfileLibraryProvider).watchActiveProfile();
});

final allDbTargetsProvider = StreamProvider<List<db.DbTarget>>((ref) {
  return ref.watch(targetLibraryProvider).watchAllTargets();
});

final favoriteDbTargetsProvider = StreamProvider<List<db.DbTarget>>((ref) {
  return ref.watch(targetLibraryProvider).watchFavoriteTargets();
});

final allDbSequencesProvider = StreamProvider<List<db.DbSequence>>((ref) {
  return ref.watch(sequenceLibraryProvider).watchAllSequences();
});

final allSessionsProvider = StreamProvider<List<db.ImagingSession>>((ref) {
  return ref.watch(sessionHistoryProvider).watchAllSessions();
});

final allDbImagesProvider = StreamProvider<List<db.DbCapturedImage>>(
  (ref) => ref.watch(capturedImageRowsProvider).watchAll(),
);

/// Whether the imaging host has stored any frame.
final hasCapturedImagesProvider = Provider<AsyncValue<bool>>(
  (ref) => ref.watch(capturedImageRowsProvider).hasAny(ref),
);

final capturedImageByIdProvider =
    FutureProvider.family<db.DbCapturedImage?, int>(
      (ref, imageId) => ref.watch(imagingRecordsProvider).getImageById(imageId),
    );

class CapturedImageWcsData {
  final int id;
  final bool isPlateSolved;
  final double? solvedRaHours;
  final double? solvedDecDegrees;
  final double? solvedRotationDegrees;
  final double? solvedPixelScaleArcsecPerPixel;

  /// The stored CD matrix (deg/pixel) and SIP block (`solved_sip`
  /// encoding), when the solve recorded them.
  final double? cd1_1;
  final double? cd1_2;
  final double? cd2_1;
  final double? cd2_2;
  final String? sip;

  const CapturedImageWcsData({
    required this.id,
    required this.isPlateSolved,
    required this.solvedRaHours,
    required this.solvedDecDegrees,
    required this.solvedRotationDegrees,
    required this.solvedPixelScaleArcsecPerPixel,
    this.cd1_1,
    this.cd1_2,
    this.cd2_1,
    this.cd2_2,
    this.sip,
  });

  /// The stored solve over a [width] x [height] frame; null when the frame is
  /// not solved or the solve is not usable.
  SolvedWcs? solvedWcs({required int width, required int height}) =>
      isPlateSolved
      ? solvedWcsFromStored(
          raHours: solvedRaHours,
          decDegrees: solvedDecDegrees,
          rotationDeg: solvedRotationDegrees,
          pixelScaleArcsec: solvedPixelScaleArcsecPerPixel,
          imageWidth: width,
          imageHeight: height,
          cd1_1: cd1_1,
          cd1_2: cd1_2,
          cd2_1: cd2_1,
          cd2_2: cd2_2,
          sip: sip,
        )
      : null;
}

final capturedImageWcsProvider =
    FutureProvider.family<CapturedImageWcsData?, int>((ref, imageId) async {
      final row = await ref.watch(capturedImageByIdProvider(imageId).future);
      if (row == null) {
        return null;
      }
      final distortion = row.isPlateSolved
          ? await ref
                .watch(imagingRecordsProvider)
                .getStoredWcsDistortion(imageId)
          : null;
      return CapturedImageWcsData(
        id: row.id,
        isPlateSolved: row.isPlateSolved,
        solvedRaHours: row.solvedRa,
        solvedDecDegrees: row.solvedDec,
        solvedRotationDegrees: row.solvedRotation,
        solvedPixelScaleArcsecPerPixel: row.solvedPixelScale,
        cd1_1: distortion?.cd1_1,
        cd1_2: distortion?.cd1_2,
        cd2_1: distortion?.cd2_1,
        cd2_2: distortion?.cd2_2,
        sip: distortion?.sip,
      );
    });

final allSettingsProvider = StreamProvider<Map<String, String>>((ref) {
  return ref.watch(settingsDaoProvider).watchAllSettings();
});
