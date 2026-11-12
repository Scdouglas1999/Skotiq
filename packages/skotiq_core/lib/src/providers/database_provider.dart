import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend/host_data/remote_host_records.dart';
import '../backend/remote_host.dart';
import '../backend/roles/host_data/host_records.dart';
import '../database/database.dart' as db;
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
import '../services/imaging_records_repository.dart';
import 'backend_provider.dart';
import 'host_settings/host_settings_providers.dart';

export '../backend/network_backend/host_data/remote_host_records.dart'
    show fetchAllRemoteSequenceRuns;
export 'project_tracking_provider.dart';
export '../database/daos/settings_dao.dart' show StoredSettings;

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
final targetLibraryProvider = Provider<TargetLibrary>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.records ??
      ref.watch(targetsDaoProvider),
);

/// The saved sequences of whichever machine is the imaging host.
final sequenceLibraryProvider = Provider<SequenceLibrary>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.records ??
      ref.watch(sequencesDaoProvider),
);

/// The equipment profiles of whichever machine is the imaging host.
final equipmentProfileLibraryProvider = Provider<EquipmentProfileLibrary>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.records ??
      ref.watch(equipmentProfilesDaoProvider),
);

/// The recorded sessions of whichever machine is the imaging host.
final sessionHistoryProvider = Provider<SessionHistory>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.records ??
      ref.watch(sessionsDaoProvider),
);

// Convenience providers for watching data
// Note: These use the database entity types (prefixed with db.)

final allProfilesProvider = StreamProvider<List<db.EquipmentProfile>>((ref) {
  return ref.watch(equipmentProfileLibraryProvider).watchAllProfiles();
});

final activeProfileProvider = StreamProvider<db.EquipmentProfile?>((ref) {
  return ref.watch(equipmentProfileLibraryProvider).watchActiveProfile();
});

final allDbTargetsProvider = StreamProvider<List<db.Target>>((ref) {
  return ref.watch(targetLibraryProvider).watchAllTargets();
});

final favoriteDbTargetsProvider = StreamProvider<List<db.Target>>((ref) {
  return ref.watch(targetLibraryProvider).watchFavoriteTargets();
});

final allDbSequencesProvider = StreamProvider<List<db.Sequence>>((ref) {
  return ref.watch(sequenceLibraryProvider).watchAllSequences();
});

final allSessionsProvider = StreamProvider<List<db.ImagingSession>>((ref) {
  return ref.watch(sessionHistoryProvider).watchAllSessions();
});

final allDbImagesProvider = StreamProvider<List<db.CapturedImage>>((ref) {
  final rows = ref.watch(remoteImageRowsProvider);
  if (rows != null) return rows.watch();
  return ref.watch(imagesDaoProvider).watchAllImages();
});

/// Whether the imaging host has stored any frame.
final hasCapturedImagesProvider = Provider<AsyncValue<bool>>((ref) {
  if (ref.watch(remoteImageRowsProvider) != null) {
    // A linked client already holds the host's rows.
    return ref.watch(allDbImagesProvider).whenData((rows) => rows.isNotEmpty);
  }
  return ref.watch(_localHasCapturedImagesProvider);
});

final _localHasCapturedImagesProvider = StreamProvider<bool>(
  (ref) => ref.watch(imagesDaoProvider).watchHasAnyImage(),
);

/// A linked client's copy of the imaging host's `captured_images` rows; null
/// on a process with its own database.
final remoteImageRowsProvider = Provider<RemoteImageRows?>((ref) {
  final host = ref.watch(backendProvider).remoteHost?.imagingRecords;
  if (host == null) return null;
  final rows = RemoteImageRows(
    poll: () => pollHostImageRows(host),
    fetchRow: host.getCapturedImageById,
    fetchSessionRows: host.getSessionImageRows,
  );
  ref.onDispose(rows.dispose);
  return rows;
});

/// The host's captured-image rows on a linked client.
///
/// The whole table is polled every 30 s, which put a new frame's row (its
/// frame number, verdict and HFR) on a client's frame strip and session list
/// a mean 15 s after the host's, in jumps of several frames. A frame the host
/// announces is fetched at once instead: [addRows] for the ids of the host's
/// session list, [refreshSessionOf] for a saved frame with no row here yet.
/// The poll still runs, so a row the host changes later (a verdict, a solve)
/// arrives within one cycle.
class RemoteImageRows {
  RemoteImageRows({
    required Stream<List<db.CapturedImage>> Function() poll,
    required Future<Map<String, dynamic>?> Function(int id) fetchRow,
    required Future<List<Map<String, dynamic>>> Function(int sessionId)
    fetchSessionRows,
  }) : _poll = poll,
       _fetchRow = fetchRow,
       _fetchSessionRows = fetchSessionRows;

  final Stream<List<db.CapturedImage>> Function() _poll;
  final Future<Map<String, dynamic>?> Function(int id) _fetchRow;
  final Future<List<Map<String, dynamic>>> Function(int sessionId)
  _fetchSessionRows;

  /// The newest full list from the poll.
  List<db.CapturedImage>? _polled;

  /// Rows fetched one at a time or by session since that list, by id.
  final Map<int, db.CapturedImage> _fetched = {};
  final Set<int> _inFlight = {};
  final Set<StreamController<List<db.CapturedImage>>> _listeners = {};
  StreamSubscription<List<db.CapturedImage>>? _pollSubscription;
  bool _sessionRefreshRunning = false;
  bool _sessionRefreshAgain = false;
  bool _disposed = false;

  /// The merged rows, newest capture first like `ImagesDao.watchAllImages`.
  List<db.CapturedImage>? get current {
    final polled = _polled;
    if (polled == null) return null;
    if (_fetched.isEmpty) return polled;
    final byId = {for (final row in polled) row.id: row, ..._fetched};
    return byId.values.toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  }

  Stream<List<db.CapturedImage>> watch() {
    late final StreamController<List<db.CapturedImage>> controller;
    controller = StreamController<List<db.CapturedImage>>(
      onListen: () {
        _listeners.add(controller);
        // A new listener is a rebuild of the provider, for instance after the
        // host announced a change to its images: it waits for the table read
        // again now, not for the rows from before the change.
        unawaited(_pollSubscription?.cancel());
        _pollSubscription = _poll().listen(
          _onPolled,
          onError: (Object error, StackTrace stackTrace) {
            for (final listener in _listeners) {
              if (_polled == null) listener.addError(error, stackTrace);
            }
          },
        );
      },
      onCancel: () {
        _listeners.remove(controller);
        if (_listeners.isEmpty) {
          unawaited(_pollSubscription?.cancel());
          _pollSubscription = null;
        }
      },
    );
    return controller.stream;
  }

  void _onPolled(List<db.CapturedImage> rows) {
    _polled = rows;
    // The poll is the truth for every row it carries; a row fetched after the
    // poll's request went out stays until the next one carries it too.
    final newest = rows.isEmpty
        ? 0
        : rows.map((row) => row.id).reduce((a, b) => a > b ? a : b);
    _fetched.removeWhere((id, _) => id <= newest);
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    final rows = current;
    if (rows == null) return;
    for (final listener in _listeners) {
      listener.add(rows);
    }
  }

  bool _known(int id) =>
      _fetched.containsKey(id) ||
      (_polled?.any((row) => row.id == id) ?? false);

  /// Fetch the rows of [ids] this client does not have yet.
  Future<void> addRows(Iterable<int> ids) async {
    if (_polled == null) return; // The first poll brings them all.
    final missing = [
      for (final id in ids)
        if (!_known(id) && !_inFlight.contains(id)) id,
    ];
    if (missing.isEmpty) return;
    _inFlight.addAll(missing);
    try {
      final rows = await Future.wait([
        for (final id in missing)
          _fetchRow(id).then<Map<String, dynamic>?>(
            (row) => row,
            onError: (Object _) => null,
          ),
      ]);
      if (_disposed) return;
      var added = false;
      for (final json in rows) {
        if (json == null) continue;
        final row = db.CapturedImage.fromJson(json);
        _fetched[row.id] = row;
        added = true;
      }
      if (added) _emit();
    } finally {
      _inFlight.removeAll(missing);
    }
  }

  /// Fetch the rows of the session the newest known frame belongs to when a
  /// frame saved at [filePath] has no row here yet. A rejected frame is not in
  /// the host's session list, so its id never reaches [addRows].
  Future<void> refreshSessionOf(String filePath) async {
    final rows = current;
    if (rows == null || rows.any((row) => row.filePath == filePath)) return;
    final sessionId = rows
        .map((row) => row.sessionId)
        .firstWhere((id) => id != null, orElse: () => null);
    if (sessionId == null) return;
    if (_sessionRefreshRunning) {
      _sessionRefreshAgain = true;
      return;
    }
    _sessionRefreshRunning = true;
    try {
      do {
        _sessionRefreshAgain = false;
        final List<Map<String, dynamic>> json;
        try {
          json = await _fetchSessionRows(sessionId);
        } on Object {
          return; // The poll brings the row instead.
        }
        if (_disposed) return;
        for (final row in json.map(db.CapturedImage.fromJson)) {
          _fetched[row.id] = row;
        }
        _emit();
      } while (_sessionRefreshAgain && !_disposed);
    } finally {
      _sessionRefreshRunning = false;
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_pollSubscription?.cancel());
    _pollSubscription = null;
    for (final listener in _listeners.toList()) {
      unawaited(listener.close());
    }
    _listeners.clear();
  }
}

final capturedImageByIdProvider = FutureProvider.family<db.CapturedImage?, int>(
  (ref, imageId) {
    if (ref.watch(backendProvider).remoteHost != null) {
      return ref.watch(imagingRecordsRepositoryProvider).getImageById(imageId);
    }
    return ref.watch(imagesDaoProvider).getImageById(imageId);
  },
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
}

final capturedImageWcsProvider =
    FutureProvider.family<CapturedImageWcsData?, int>((ref, imageId) async {
      final linked = ref.watch(backendProvider).remoteHost != null;
      db.CapturedImage? row;
      ({
        double? cd1_1,
        double? cd1_2,
        double? cd2_1,
        double? cd2_2,
        String? sip,
      })?
      distortion;
      if (linked) {
        row = await ref.watch(capturedImageByIdProvider(imageId).future);
      } else {
        final dao = ref.watch(imagesDaoProvider);
        row = await dao.getImageById(imageId);
        if (row != null && row.isPlateSolved) {
          distortion = await dao.getStoredWcsDistortion(imageId);
        }
      }
      if (row == null) {
        return null;
      }
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
