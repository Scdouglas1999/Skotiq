import 'dart:async';
import 'dart:developer' as developer;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show apiReadFitsFile;

import '../backend/network_backend.dart';
import '../database/daos/images_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/database.dart' as db;
import '../models/backend/event_types.dart' show EventSeverity;
import '../models/notification/notification_categories.dart';
import '../providers/backend_provider.dart';
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
import '../utils/coordinate_format.dart';
import '../utils/utc_timestamp.dart';
import '../utils/resilient_poll_stream.dart';
import '../services/wcs/gnomonic_projection.dart' show SolvedWcs;
import '../services/wcs/wcs_sip_codec.dart';
part 'imaging_records_repository/solved_frame_hooks.dart';
part 'imaging_records_repository/wire_json.dart';
part 'imaging_records_repository/remote_polling.dart';

/// Host-authoritative access to imaging sessions and captured-image rows.
///
/// Local [FfiBackend] / desktop UI uses Drift DAOs. Remote companions
/// ([NetworkBackend]) read and write through the headless REST API so
/// mobile never mutates an empty local SQLite catalog.
class ImagingRecordsRepository {
  final SessionsDao? _sessionsDao;
  final ImagesDao? _imagesDao;
  final NetworkBackend? _remote;
  final Duration _remotePollInterval;

  /// Optional sky-atlas fold hook, fired after a local plate-solve persist.
  final SolvedFrameFoldHook? _onSolvedFrameFold;

  /// Frames the solved-frame hook has already run for in this process.
  final Set<int> _solvedHookFired = <int>{};

  ImagingRecordsRepository._({
    SessionsDao? sessionsDao,
    ImagesDao? imagesDao,
    NetworkBackend? remote,
    Duration remotePollInterval = const Duration(seconds: 10),
    SolvedFrameFoldHook? onSolvedFrameFold,
  }) : _sessionsDao = sessionsDao,
       _imagesDao = imagesDao,
       _remote = remote,
       _remotePollInterval = remotePollInterval,
       _onSolvedFrameFold = onSolvedFrameFold {
    assert(
      (sessionsDao != null && imagesDao != null && remote == null) ||
          (sessionsDao == null && imagesDao == null && remote != null),
      'ImagingRecordsRepository must be local (DAOs) or remote (NetworkBackend)',
    );
  }

  factory ImagingRecordsRepository.local({
    required SessionsDao sessionsDao,
    required ImagesDao imagesDao,
    SolvedFrameFoldHook? onSolvedFrameFold,
  }) => ImagingRecordsRepository._(
    sessionsDao: sessionsDao,
    imagesDao: imagesDao,
    onSolvedFrameFold: onSolvedFrameFold,
  );

  factory ImagingRecordsRepository.remote(
    NetworkBackend remote, {
    Duration pollInterval = const Duration(seconds: 10),
  }) => ImagingRecordsRepository._(
    remote: remote,
    remotePollInterval: pollInterval,
  );

  bool get isRemote => _remote != null;

  // Sessions

  Future<List<db.ImagingSession>> getAllSessions() async {
    if (_remote != null) {
      final rows = await _remote.getAllSessions();
      return rows.map(imagingSessionFromWireJson).toList();
    }
    return _sessionsDao!.getAllSessions();
  }

  Future<db.ImagingSession?> getSessionById(int id) async {
    if (_remote != null) {
      final row = await _remote.getSessionById(id);
      return row == null ? null : imagingSessionFromWireJson(row);
    }
    return _sessionsDao!.getSessionById(id);
  }

  Future<List<db.ImagingSession>> getSessionsForTarget(int targetId) async {
    if (_remote != null) {
      final rows = await _remote.getSessionsForTarget(targetId);
      return rows.map(imagingSessionFromWireJson).toList();
    }
    return _sessionsDao!.getSessionsForTarget(targetId);
  }

  /// Remote-only: pull the host's `sequence_runs` rows via
  /// `GET /api/sequence-runs` and map them onto the local Drift `SequenceRun`
  /// shape. Used by [SessionReportService] so the report's mount/operations and
  /// errors/warnings sections reflect the master's real run history instead of
  /// the slave's empty local table. Throws when called on a local repository —
  /// callers branch on [isRemote] first and read the local DAO directly there.
  Future<List<db.SequenceRun>> getAllSequenceRunsRemote() async {
    final remote = _remote;
    if (remote == null) {
      throw StateError(
        'getAllSequenceRunsRemote requires a remote (NetworkBackend) repository',
      );
    }
    final runs = await fetchAllRemoteSequenceRuns(remote);
    return runs.map(_sequenceRunFromRemote).toList();
  }

  /// Remote-only: target id -> name map from the host's `/api/targets` list, so
  /// the session report resolves real target names instead of falling back to
  /// "Target N" against the slave's empty local `targets` table. Throws when
  /// called on a local repository (callers branch on [isRemote] first).
  Future<Map<int, String>> getTargetNamesRemote() async {
    final remote = _remote;
    if (remote == null) {
      throw StateError(
        'getTargetNamesRemote requires a remote (NetworkBackend) repository',
      );
    }
    final rows = await remote.getAllTargets();
    final out = <int, String>{};
    for (final row in rows) {
      final id = (row['id'] as num?)?.toInt();
      if (id == null) continue;
      final name = row['name'] as String?;
      if (name != null && name.isNotEmpty) out[id] = name;
    }
    return out;
  }

  Future<int> startSession({
    String? name,
    int? profileId,
    int? targetId,
    int? sequenceId,
  }) async {
    if (_remote != null) {
      return _remote.createSession({
        if (name != null) 'name': name,
        if (profileId != null) 'profileId': profileId,
        if (targetId != null) 'targetId': targetId,
        if (sequenceId != null) 'sequenceId': sequenceId,
      });
    }
    return _sessionsDao!.startSession(
      name: name,
      profileId: profileId,
      targetId: targetId,
      sequenceId: sequenceId,
    );
  }

  Future<void> endSession(int id, {String status = 'completed'}) async {
    if (_remote != null) {
      await _remote.endSession(id, status: status);
      return;
    }
    await _sessionsDao!.endSession(id, status: status);
  }

  /// Close every session row left `active` with nothing driving it, returning
  /// the ids closed. See [SessionsDao.closeOrphanedSessions] for the rule.
  ///
  /// Host-only, like [updateEquipmentSnapshot] and for the same reason: on a
  /// paired companion the session rows live on the appliance, which runs this
  /// sweep at its own open and at its own sequence start. A phone reaching
  /// across to close the host's rows would be a second, blind writer of a
  /// liveness claim only the host can make.
  Future<List<int>> closeOrphanedSessions({required String cause}) async {
    if (_remote != null) return const <int>[];
    return _sessionsDao!.closeOrphanedSessions(cause: cause);
  }

  /// Re-open an interrupted session so a recovery resumes it. Host-only for
  /// the same reason as [closeOrphanedSessions]: the appliance owns the row and
  /// the recovery that reopens it.
  Future<void> reopenSession(int id) async {
    if (_remote != null) return;
    await _sessionsDao!.reopenSession(id);
  }

  /// Record the equipment this session is running with, so the Continue
  /// Session handoff can re-apply it on the next launch.
  ///
  /// Host-only on purpose: on a paired companion the session row lives on the
  /// appliance, and the equipment state worth restoring is the appliance's —
  /// which its own executor stamps. Writing the phone's device state onto a
  /// local row nothing reads would be a second, wrong source.
  Future<void> updateEquipmentSnapshot(int id, String snapshotJson) async {
    if (_remote != null) return;
    await _sessionsDao!.updateEquipmentSnapshot(id, snapshotJson);
  }

  /// Close a session that was abandoned, back-dating `end_time` to its last
  /// captured frame. See [SessionsDao.abortSession] for why the recovery
  /// clock is the wrong timestamp to record.
  ///
  /// The remote branch is the companion asking the HOST to close one of the
  /// host's sessions; the host runs its own recovery against its own DAO, so
  /// the back-dating happens there.
  Future<void> abortSession(int id) async {
    if (_remote != null) {
      await _remote.endSession(id, status: 'aborted');
      return;
    }
    await _sessionsDao!.abortSession(id);
  }

  Future<void> updateSessionStats(
    int id, {
    int? totalExposures,
    int? successfulExposures,
    int? failedExposures,
    double? totalIntegrationSecs,
    double? avgHfr,
    double? avgGuidingRms,
    int? autofocusCount,
  }) async {
    if (_remote != null) {
      await _remote.updateSession(id, {
        if (totalExposures != null) 'totalExposures': totalExposures,
        if (successfulExposures != null)
          'successfulExposures': successfulExposures,
        if (failedExposures != null) 'failedExposures': failedExposures,
        if (totalIntegrationSecs != null)
          'totalIntegrationSecs': totalIntegrationSecs,
        if (avgHfr != null) 'avgHfr': avgHfr,
        if (avgGuidingRms != null) 'avgGuidingRms': avgGuidingRms,
        if (autofocusCount != null) 'autofocusCount': autofocusCount,
      });
      return;
    }
    await _sessionsDao!.updateSessionStats(
      id,
      totalExposures: totalExposures,
      successfulExposures: successfulExposures,
      failedExposures: failedExposures,
      totalIntegrationSecs: totalIntegrationSecs,
      avgHfr: avgHfr,
      avgGuidingRms: avgGuidingRms,
      autofocusCount: autofocusCount,
    );
  }

  Future<void> updateSessionNotes(int id, String notes) async {
    if (_remote != null) {
      await _remote.updateSession(id, {'notes': notes});
      return;
    }
    await _sessionsDao!.updateNotes(id, notes);
  }

  // Captured images

  Future<db.CapturedImage?> getImageById(int id) async {
    if (_remote != null) {
      final row = await _remote.getCapturedImageById(id);
      return row == null ? null : db.CapturedImage.fromJson(row);
    }
    return _imagesDao!.getImageById(id);
  }

  Future<List<db.CapturedImage>> getImagesForSession(int sessionId) async {
    if (_remote != null) {
      final rows = await _remote.getSessionImageRows(sessionId);
      return rows.map(db.CapturedImage.fromJson).toList();
    }
    return _imagesDao!.getImagesForSession(sessionId);
  }

  Future<List<db.CapturedImage>> getImagesForTarget(int targetId) async {
    if (_remote != null) {
      final rows = await _remote.getImagesForTarget(targetId);
      return rows.map(db.CapturedImage.fromJson).toList();
    }
    return _imagesDao!.getImagesForTarget(targetId);
  }

  Future<List<db.CapturedImage>> getRecentImagesForSession(
    int sessionId, {
    int limit = 5,
    DateTime? atOrBefore,
  }) async {
    if (_remote != null) {
      final rows = await _remote.getSessionImageRows(sessionId);
      final images =
          rows
              .map(db.CapturedImage.fromJson)
              .where(
                (image) =>
                    atOrBefore == null || !image.capturedAt.isAfter(atOrBefore),
              )
              .toList()
            ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      if (images.length <= limit) {
        return images;
      }
      return images.sublist(0, limit);
    }
    return _imagesDao!.getRecentImagesForSession(
      sessionId,
      limit: limit,
      atOrBefore: atOrBefore,
    );
  }

  Stream<List<db.CapturedImage>> watchImagesForSession(int sessionId) {
    if (_remote != null) {
      return _pollRemoteSessionImages(
        _remote,
        sessionId,
        interval: _remotePollInterval,
      );
    }
    return _imagesDao!.watchImagesForSession(sessionId);
  }

  Future<int> createImage(db.CapturedImagesCompanion image) async {
    if (_remote != null) {
      return _remote.createCapturedImage(_companionToCreateJson(image));
    }
    return _imagesDao!.createImage(image);
  }

  Future<void> updateImageFilePath(int id, String filePath) async {
    if (_remote != null) {
      await _remote.updateCapturedImage(id, {'filePath': filePath});
      return;
    }
    await _imagesDao!.updateImageFilePath(id, filePath);
  }

  Future<void> rejectImage(int id, String reason) async {
    if (_remote != null) {
      await _remote.updateCapturedImage(id, {
        'isAccepted': false,
        'rejectionReason': reason,
      });
      return;
    }
    await _imagesDao!.rejectImage(id, reason);
  }

  Future<void> acceptImage(int id) async {
    if (_remote != null) {
      await _remote.updateCapturedImage(id, {
        'isAccepted': true,
        'rejectionReason': null,
      });
      return;
    }
    await _imagesDao!.acceptImage(id);
  }

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
  }) async {
    final hasCd =
        solvedCd1_1 != null &&
        solvedCd1_2 != null &&
        solvedCd2_1 != null &&
        solvedCd2_2 != null;
    if (_remote != null) {
      await _remote.updateCapturedImage(id, {
        'isPlateSolved': true,
        'solvedRa': solvedRa,
        'solvedDec': solvedDec,
        'solvedRotation': solvedRotation,
        'solvedPixelScale': solvedPixelScale,
        if (hasCd) 'solvedCd1_1': solvedCd1_1,
        if (hasCd) 'solvedCd1_2': solvedCd1_2,
        if (hasCd) 'solvedCd2_1': solvedCd2_1,
        if (hasCd) 'solvedCd2_2': solvedCd2_2,
        if (hasCd) 'solvedSip': solvedSip,
      });
      return;
    }
    await _imagesDao!.updatePlateSolveResult(
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

    notifySolvedFrame(id);
  }

  /// Run the solved-frame hook (First Light scan, Your Sky fold, co-imaging)
  /// for the frame [id], whose solve with its CD matrix is on the row. It runs
  /// once per frame however many times the frame is solved or its stored
  /// solve reused, so a frame solved by the frame watch and then processed by
  /// the science pipeline is scanned and folded exactly once. Fire-and-forget:
  /// a hook failure never reaches the solve or the imaging path.
  void notifySolvedFrame(int id) {
    final hook = _onSolvedFrameFold;
    if (_remote != null || hook == null) return;
    if (!_solvedHookFired.add(id)) return;
    unawaited(
      hook(id).catchError((Object _) {
        // Swallowed: the hook logs its own errors.
      }),
    );
  }

  /// Read the off-table v51 WCS distortion (CD matrix + SIP JSON) for [id].
  /// Returns null in remote mode (the appliance owns the authoritative DB)
  /// or when the row is absent; absent CD/SIP fields mean an isotropic solve.
  Future<
    ({double? cd1_1, double? cd1_2, double? cd2_1, double? cd2_2, String? sip})?
  >
  getStoredWcsDistortion(int id) async {
    if (_remote != null) return null;
    return _imagesDao!.getStoredWcsDistortion(id);
  }

  Future<void> stampProducingNode({
    required int imageId,
    String? producingNodeId,
    String? producingRunId,
    String? runtimeGrade,
    double? eccentricity,
    double? fwhm,
  }) async {
    if (_remote != null) {
      await _remote.updateCapturedImage(imageId, {
        if (producingNodeId != null) 'producingNodeId': producingNodeId,
        if (producingRunId != null) 'producingRunId': producingRunId,
        if (runtimeGrade != null) 'runtimeGrade': runtimeGrade,
        if (eccentricity != null) 'eccentricity': eccentricity,
        if (fwhm != null) 'fwhm': fwhm,
      });
      return;
    }
    await _imagesDao!.stampProducingNode(
      imageId: imageId,
      producingNodeId: producingNodeId,
      producingRunId: producingRunId,
      runtimeGrade: runtimeGrade,
      eccentricity: eccentricity,
      fwhm: fwhm,
    );
  }

  Future<List<ProducingNodeThumbnail>> getImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) async {
    if (_remote != null) {
      final rows = await _remote.getImagesByProducingNode(
        producingNodeId,
        producingRunId: producingRunId,
        limit: limit,
      );
      return rows.map(_producingThumbnailFromApiJson).toList();
    }
    return _imagesDao!.getImagesByProducingNode(
      producingNodeId: producingNodeId,
      producingRunId: producingRunId,
      limit: limit,
    );
  }

  Stream<List<ProducingNodeThumbnail>> watchImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) {
    if (_remote != null) {
      return _pollRemoteProducingNodeThumbnails(
        _remote,
        producingNodeId: producingNodeId,
        producingRunId: producingRunId,
        limit: limit,
        interval: _remotePollInterval,
      );
    }
    return _imagesDao!.watchImagesByProducingNode(
      producingNodeId: producingNodeId,
      producingRunId: producingRunId,
      limit: limit,
    );
  }

  Future<int> countImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
  }) async {
    if (_remote != null) {
      final rows = await _remote.getImagesByProducingNode(
        producingNodeId,
        producingRunId: producingRunId,
      );
      return rows.length;
    }
    return _imagesDao!.countImagesByProducingNode(
      producingNodeId: producingNodeId,
      producingRunId: producingRunId,
    );
  }
}

/// In local mode the repository is wired with the Pillar A ("Your Sky") fold
/// hook: every solve persisted through [ImagingRecordsRepository.updatePlateSolveResult]
/// auto-folds that light into the personal sky atlas. The hook reads the stored
/// WCS distortion + the frame's FITS dimensions, then delegates to
/// [SkyAtlasService.autoFoldCapturedImage]; remote companions skip it (the
/// appliance host owns the authoritative atlas).
final imagingRecordsRepositoryProvider = Provider<ImagingRecordsRepository>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return ImagingRecordsRepository.remote(backend);
  }
  final imagesDao = ref.watch(imagesDaoProvider);
  return ImagingRecordsRepository.local(
    sessionsDao: ref.watch(sessionsDaoProvider),
    imagesDao: imagesDao,
    onSolvedFrameFold: (capturedImageId) async {
      final logger = ref.read(loggingServiceProvider);
      try {
        final image = await imagesDao.getImageById(capturedImageId);
        if (image == null) return;
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
    },
  );
});

/// Persisted captured-image rows for one session (Drift watch or remote poll).
final sessionDbImagesProvider = StreamProvider.autoDispose
    .family<List<db.CapturedImage>, int>((ref, sessionId) {
      return ref
          .watch(imagingRecordsRepositoryProvider)
          .watchImagesForSession(sessionId);
    });
