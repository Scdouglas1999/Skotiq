import '../../../database/daos/images_dao.dart' show ProducingNodeThumbnail;
import '../../../database/database.dart'
    show CapturedImagesCompanion, DbCapturedImage, ImagingSession;

/// The imaging sessions and captured-image rows in the imaging host's
/// database: read, and written as frames arrive.
///
/// A few members are the host's own bookkeeping (closing sessions nothing is
/// driving, the equipment snapshot, publishing a graded frame). A linked
/// client's implementation leaves those to the host, which does them itself.
abstract interface class ImagingRecords {
  Future<List<ImagingSession>> getAllSessions();

  Future<ImagingSession?> getSessionById(int id);

  Future<List<ImagingSession>> getSessionsForTarget(int targetId);

  /// Returns the new session's id.
  Future<int> startSession({
    String? name,
    int? profileId,
    int? targetId,
    int? sequenceId,
  });

  Future<void> endSession(int id, {String status = 'completed'});

  /// Closes every session left `active` with nothing driving it and returns
  /// the ids closed. The host's own bookkeeping.
  Future<List<int>> closeOrphanedSessions({required String cause});

  /// Re-opens an interrupted session so a recovery resumes it. The host's own
  /// bookkeeping.
  Future<void> reopenSession(int id);

  /// Records the equipment this session runs with, so a continued session can
  /// re-apply it. The host's own bookkeeping.
  Future<void> updateEquipmentSnapshot(int id, String snapshotJson);

  /// Closes an abandoned session, dating its end to its last captured frame.
  Future<void> abortSession(int id);

  Future<void> updateSessionStats(
    int id, {
    int? totalExposures,
    int? successfulExposures,
    int? failedExposures,
    double? totalIntegrationSecs,
    double? avgHfr,
    double? avgGuidingRms,
    int? autofocusCount,
  });

  Future<void> updateSessionNotes(int id, String notes);

  Future<DbCapturedImage?> getImageById(int id);

  Future<List<DbCapturedImage>> getImagesForSession(int sessionId);

  Future<List<DbCapturedImage>> getImagesForTarget(int targetId);

  /// The newest [limit] frames of a session, newest first.
  Future<List<DbCapturedImage>> getRecentImagesForSession(
    int sessionId, {
    int limit = 5,
    DateTime? atOrBefore,
  });

  Stream<List<DbCapturedImage>> watchImagesForSession(int sessionId);

  /// Returns the new row's id.
  Future<int> createImage(CapturedImagesCompanion image);

  /// Starts writing the thumbnail of a frame this process just stored. A
  /// linked host writes it when it stores the row.
  void scheduleThumbnail({required int imageId, required String fitsPath});

  Future<void> updateImageFilePath(int id, String filePath);

  Future<void> rejectImage(int id, String reason);

  Future<void> acceptImage(int id);

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
  });

  /// Publishes a solved frame once Science has graded it, so the sky atlas
  /// and transient scan take it. The host's own bookkeeping; it runs in the
  /// background and never delays the next exposure.
  void notifyGradedFrame(int id);

  /// The stored CD matrix and SIP JSON of a solved frame. Null when the row
  /// is absent or the store is a linked host's, which does not serve them.
  Future<
    ({double? cd1_1, double? cd1_2, double? cd2_1, double? cd2_2, String? sip})?
  >
  getStoredWcsDistortion(int id);

  Future<void> stampProducingNode({
    required int imageId,
    String? producingNodeId,
    String? producingRunId,
    String? runtimeGrade,
    double? eccentricity,
    double? fwhm,
  });

  Future<List<ProducingNodeThumbnail>> getImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  });

  Stream<List<ProducingNodeThumbnail>> watchImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  });

  Future<int> countImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
  });
}
