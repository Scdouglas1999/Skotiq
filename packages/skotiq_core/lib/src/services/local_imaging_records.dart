import '../models/imaging/frame_type_record.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show apiReadFitsFile;

import '../database/daos/images_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/database.dart' as db;
import '../models/backend/event_types.dart' show EventSeverity;
import '../models/notification/notification_categories.dart';
import '../providers/constellation_provider.dart'
    show coImagingSessionServiceProvider;
import '../providers/database_provider.dart';
import '../providers/narrator_provider.dart' show narratorServiceProvider;
import '../providers/notification_router_provider.dart'
    show notificationRouterProvider;
import '../providers/sky_atlas_provider.dart';
import '../providers/transient_detections_provider.dart';
import '../services/logging_service.dart';
import '../services/sky_atlas/sky_atlas_models.dart';
import '../services/sky_atlas/sky_atlas_service.dart' show SkyAtlasService;
import '../services/transients/transient_candidate.dart';
import 'package:skotiq_astro/format.dart';
import '../services/wcs/gnomonic_projection.dart' show SolvedWcs;
import '../services/wcs/wcs_sip_codec.dart';
import '../backend/network_backend/host_data/remote_imaging_records.dart';
import '../backend/roles/host_data/imaging_records.dart';
import '../providers/host_role.dart';
import '../providers/thumbnail_sidecar_provider.dart';
import 'thumbnail_sidecar_service.dart';
import '../providers/logging_service_provider.dart';
part 'local_imaging_records_solved_frame_hooks.dart';

/// The sessions and captured-image rows in this process's own database.
final class LocalImagingRecords implements ImagingRecords {
  LocalImagingRecords({
    required SessionsDao sessionsDao,
    required ImagesDao imagesDao,
    ThumbnailSidecarService? thumbnails,
    SolvedFrameFoldHook? onSolvedFrameFold,
  }) : _sessionsDao = sessionsDao,
       _imagesDao = imagesDao,
       _thumbnails = thumbnails,
       _onSolvedFrameFold = onSolvedFrameFold;

  final SessionsDao _sessionsDao;
  final ImagesDao _imagesDao;
  final ThumbnailSidecarService? _thumbnails;

  /// The scan and atlas fold a graded frame goes to.
  final SolvedFrameFoldHook? _onSolvedFrameFold;

  /// Frames the solved-frame hook has already run for in this process.
  final Set<int> _solvedHookFired = <int>{};

  @override
  Future<List<db.ImagingSession>> getAllSessions() =>
      _sessionsDao.getAllSessions();

  @override
  Future<db.ImagingSession?> getSessionById(int id) =>
      _sessionsDao.getSessionById(id);

  @override
  Future<List<db.ImagingSession>> getSessionsForTarget(int targetId) =>
      _sessionsDao.getSessionsForTarget(targetId);

  @override
  Future<int> startSession({
    String? name,
    int? profileId,
    int? targetId,
    int? sequenceId,
  }) => _sessionsDao.startSession(
    name: name,
    profileId: profileId,
    targetId: targetId,
    sequenceId: sequenceId,
  );

  @override
  Future<void> endSession(int id, {String status = 'completed'}) =>
      _sessionsDao.endSession(id, status: status);

  /// See [SessionsDao.closeOrphanedSessions] for the rule.
  @override
  Future<List<int>> closeOrphanedSessions({required String cause}) =>
      _sessionsDao.closeOrphanedSessions(cause: cause);

  @override
  Future<void> reopenSession(int id) => _sessionsDao.reopenSession(id);

  @override
  Future<void> updateEquipmentSnapshot(int id, String snapshotJson) =>
      _sessionsDao.updateEquipmentSnapshot(id, snapshotJson);

  /// See [SessionsDao.abortSession] for why the recovery clock is the wrong
  /// time to record.
  @override
  Future<void> abortSession(int id) => _sessionsDao.abortSession(id);

  @override
  Future<void> updateSessionStats(
    int id, {
    int? totalExposures,
    int? successfulExposures,
    int? failedExposures,
    double? totalIntegrationSecs,
    double? avgHfr,
    double? avgGuidingRms,
    int? autofocusCount,
  }) => _sessionsDao.updateSessionStats(
    id,
    totalExposures: totalExposures,
    successfulExposures: successfulExposures,
    failedExposures: failedExposures,
    totalIntegrationSecs: totalIntegrationSecs,
    avgHfr: avgHfr,
    avgGuidingRms: avgGuidingRms,
    autofocusCount: autofocusCount,
  );

  @override
  Future<void> updateSessionNotes(int id, String notes) =>
      _sessionsDao.updateNotes(id, notes);

  @override
  Future<db.DbCapturedImage?> getImageById(int id) =>
      _imagesDao.getImageById(id);

  @override
  Future<List<db.DbCapturedImage>> getImagesForSession(int sessionId) =>
      _imagesDao.getImagesForSession(sessionId);

  @override
  Future<List<db.DbCapturedImage>> getImagesForTarget(int targetId) =>
      _imagesDao.getImagesForTarget(targetId);

  @override
  Future<List<db.DbCapturedImage>> getRecentImagesForSession(
    int sessionId, {
    int limit = 5,
    DateTime? atOrBefore,
  }) => _imagesDao.getRecentImagesForSession(
    sessionId,
    limit: limit,
    atOrBefore: atOrBefore,
  );

  @override
  Stream<List<db.DbCapturedImage>> watchImagesForSession(int sessionId) =>
      _imagesDao.watchImagesForSession(sessionId);

  @override
  Future<int> createImage(db.CapturedImagesCompanion image) =>
      _imagesDao.createImage(image);

  @override
  void scheduleThumbnail({required int imageId, required String fitsPath}) {
    _thumbnails?.scheduleSidecarWrite(
      imageId: imageId,
      fitsPath: fitsPath,
      imagesDao: _imagesDao,
    );
  }

  @override
  Future<void> updateImageFilePath(int id, String filePath) =>
      _imagesDao.updateImageFilePath(id, filePath);

  @override
  Future<void> rejectImage(int id, String reason) =>
      _imagesDao.rejectImage(id, reason);

  @override
  Future<void> acceptImage(int id) => _imagesDao.acceptImage(id);

  @override
  Future<void> updatePlateSolveResult(
    int id, {
    required double solvedRa,
    required double solvedDec,
    required double solvedRotation,
    required double solvedPixelScale,
    double? solvedCd1_1,
    double? solvedCd1_2,
    double? solvedCd2_1,
    double? solvedCd2_2,
    String? solvedSip,
  }) => _imagesDao.updatePlateSolveResult(
    id,
    solvedRa: solvedRa,
    solvedDec: solvedDec,
    solvedRotation: solvedRotation,
    solvedPixelScale: solvedPixelScale,
    solvedCd1_1: solvedCd1_1,
    solvedCd1_2: solvedCd1_2,
    solvedCd2_1: solvedCd2_1,
    solvedCd2_2: solvedCd2_2,
    solvedSip: solvedSip,
  );

  /// Solving alone must not start the scan and fold: the deferred PSF grade
  /// may still reject the frame.
  @override
  void notifyGradedFrame(int id) {
    final hook = _onSolvedFrameFold;
    if (hook == null) return;
    if (!_solvedHookFired.add(id)) return;
    unawaited(
      () async {
        final image = await _imagesDao.getImageById(id);
        if (image == null || !image.isAccepted || !image.isPlateSolved) {
          _solvedHookFired.remove(id);
          return;
        }
        await hook(id);
      }().catchError((Object _) {
        _solvedHookFired.remove(id);
        // The hook logs its own errors; a failed attempt may be retried.
      }),
    );
  }

  @override
  Future<
    ({double? cd1_1, double? cd1_2, double? cd2_1, double? cd2_2, String? sip})?
  >
  getStoredWcsDistortion(int id) => _imagesDao.getStoredWcsDistortion(id);

  @override
  Future<void> stampProducingNode({
    required int imageId,
    String? producingNodeId,
    String? producingRunId,
    String? runtimeGrade,
    double? eccentricity,
    double? fwhm,
  }) => _imagesDao.stampProducingNode(
    imageId: imageId,
    producingNodeId: producingNodeId,
    producingRunId: producingRunId,
    runtimeGrade: runtimeGrade,
    eccentricity: eccentricity,
    fwhm: fwhm,
  );

  @override
  Future<List<ProducingNodeThumbnail>> getImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) => _imagesDao.getImagesByProducingNode(
    producingNodeId: producingNodeId,
    producingRunId: producingRunId,
    limit: limit,
  );

  @override
  Stream<List<ProducingNodeThumbnail>> watchImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) => _imagesDao.watchImagesByProducingNode(
    producingNodeId: producingNodeId,
    producingRunId: producingRunId,
    limit: limit,
  );

  @override
  Future<int> countImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
  }) => _imagesDao.countImagesByProducingNode(
    producingNodeId: producingNodeId,
    producingRunId: producingRunId,
  );
}

/// What the host does with a frame Science has graded: scan it for
/// transients against the sky atlas, fold it into the atlas ("Your Sky") and
/// contribute it to any live co-imaging session that covers it.
SolvedFrameFoldHook solvedFrameFoldHook(
  Ref ref,
  ImagesDao imagesDao,
) => (capturedImageId) async {
  final logger = ref.read(loggingServiceProvider);
  try {
    // With Your Sky off nothing is folded and First Light, whose template
    // is the atlas, has nothing to compare against: write nothing.
    if (!await ref.read(skyAtlasServiceProvider).isEnabled()) return;
    final image = await imagesDao.getImageById(capturedImageId);
    if (image == null ||
        !image.isAccepted ||
        !image.isPlateSolved ||
        !image.isLight) {
      return;
    }
    // A frame already folded had its First Light scan and co-imaging
    // contribution with that fold, in this or an earlier session.
    if (image.atlasFoldedAt != null) return;
    final fits = await apiReadFitsFile(filePath: image.filePath);
    final stored = await imagesDao.getStoredWcsDistortion(capturedImageId);
    final sip = decodeSolvedSip(stored?.sip);
    final distortion = SolvedWcsDistortion(
      cd1_1: stored?.cd1_1,
      cd1_2: stored?.cd1_2,
      cd2_1: stored?.cd2_1,
      cd2_2: stored?.cd2_2,
      aOrder: sip?.aOrder ?? 0,
      bOrder: sip?.bOrder ?? 0,
      aCoeffs: sip?.aCoeffs ?? const [],
      bCoeffs: sip?.bCoeffs ?? const [],
      apOrder: sip?.apOrder ?? 0,
      bpOrder: sip?.bpOrder ?? 0,
      apCoeffs: sip?.apCoeffs ?? const [],
      bpCoeffs: sip?.bpCoeffs ?? const [],
    );

    // Pillar B ("First Light"): the SAME solve-persist event that folds the
    // light into the atlas also differences it against the comparison
    // template and logs any transient. Gated on a light frame with a valid,
    // invertible WCS; the scan itself no-ops (skips thin tiles) until a deep
    // template exists, so an early-night frame over a sparse tile is cheap.
    //
    // ORDER IS LOAD-BEARING (Wave 1 self-subtraction fix): the scan MUST run
    // BEFORE the atlas fold below. The diff template is read from the SAME
    // per-tile `.skt` sidecars the fold writes into, so folding first would
    // average this frame's own flux into the template it is differenced
    // against (weight ~1/(N+1)) — every transient would self-suppress and
    // faint SNR~5-6 sources would drop below the persist gate and vanish.
    // Running the scan first means the template = history (all PRIOR frames
    // only); the fold then deepens the template for the NEXT frame.
    // A future refactor MUST NOT reorder fold above scan.
    await _runFirstLightScan(
      ref: ref,
      logger: logger,
      image: image,
      imageWidth: fits.width,
      imageHeight: fits.height,
      distortion: distortion,
    );

    // Fold dedup: a re-solved frame fires this hook again with the same
    // captured-image id, so [applyAtlasFoldDedup] folds only when the row
    // is not already stamped, and stamps only after a fold that ran.
    final foldSummary = await applyAtlasFoldDedup(
      image: image,
      imagesDao: imagesDao,
      atlas: ref.read(skyAtlasServiceProvider),
      imageWidth: fits.width,
      imageHeight: fits.height,
      distortion: distortion,
    );

    // Live co-imaging auto-contribute: a fold
    // that ACTUALLY ran (non-null summary) means this rig's own-light delta
    // is now in the atlas, so any live co-imaging session whose target this
    // frame covers can fold the SAME sub into the shared-target tile and
    // advance the combined accounting. Ordering is load-bearing: contributing
    // only AFTER the atlas fold lands is what makes the additive-sum export
    // non-empty, so the headline depth tracks real fused depth (no undercount
    // race). A non-fold (re-solve / not foldable) skips — the sub was already
    // contributed on its first fold.
    if (foldSummary != null) {
      await _driveCoImagingAutoContribute(
        ref: ref,
        logger: logger,
        image: image,
      );
    }
  } catch (e, st) {
    logger.warning(
      'Sky-atlas auto-fold for image $capturedImageId failed: $e\n$st',
      source: 'SkyAtlasService',
    );
  }
};

/// The sessions and captured-image rows of whichever machine is the imaging
/// host. On the host a graded frame goes on to [solvedFrameFoldHook].
final imagingRecordsProvider = hostRoleProvider<ImagingRecords>(
  here: (ref) {
    final imagesDao = ref.watch(imagesDaoProvider);
    return LocalImagingRecords(
      sessionsDao: ref.watch(sessionsDaoProvider),
      imagesDao: imagesDao,
      thumbnails: ref.watch(thumbnailSidecarServiceProvider),
      onSolvedFrameFold: solvedFrameFoldHook(ref, imagesDao),
    );
  },
  linked: (ref, host) => RemoteImagingRecords(host.imagingRecords),
);
