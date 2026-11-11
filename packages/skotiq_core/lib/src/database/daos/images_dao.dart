import 'dart:io';

import 'package:drift/drift.dart';

import '../../services/logging_service.dart';
import '../../services/thumbnail_sidecar_service.dart';
import '../database.dart';
import '../tables/captured_images.dart';
import '../tables/imaging_sessions.dart';
import '../tables/targets.dart';

part 'images_dao.g.dart';

/// Thumbnail — slim image record returned by
/// [ImagesDao.watchImagesByProducingNode] and friends. Carries only the
/// columns the sequence-tree thumbnail strip needs so the watch query
/// stays narrow and so consumers don't have to depend on the full
/// `CapturedImage` data class.
///
/// `runtimeGrade` is one of `'pass'`, `'reject'`, `'pending'`, or `null`
/// when grading didn't run. Border colour mapping happens at the widget
/// level (sequence_tree.dart) — this struct is colour-agnostic.
class ProducingNodeThumbnail {
  final int id;
  final String filePath;
  final String fileName;
  final String? filter;
  final String frameType;
  final double? hfr;
  final double? eccentricity;
  final double? fwhm;
  final int? starCount;
  final double exposureDuration;
  final DateTime capturedAt;
  final bool isAccepted;
  final String? rejectionReason;
  final String? runtimeGrade;
  final String producingNodeId;
  final String? producingRunId;

  const ProducingNodeThumbnail({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.filter,
    required this.frameType,
    required this.hfr,
    required this.eccentricity,
    this.fwhm,
    required this.starCount,
    required this.exposureDuration,
    required this.capturedAt,
    required this.isAccepted,
    required this.rejectionReason,
    required this.runtimeGrade,
    required this.producingNodeId,
    required this.producingRunId,
  });

  /// Convenience: convert the runtime grade text into the strip's color
  /// "kind". Returns `'pass' | 'reject' | 'pending' | 'unknown'`.
  String get gradeKind {
    if (!isAccepted) return 'reject';
    final g = runtimeGrade;
    if (g == null || g.isEmpty) return 'unknown';
    switch (g.toLowerCase()) {
      case 'pass':
      case 'accepted':
        return 'pass';
      case 'reject':
      case 'rejected':
        return 'reject';
      case 'pending':
      case 'borderline':
      case 'review':
        return 'pending';
      default:
        return 'unknown';
    }
  }
}

@DriftAccessor(
  tables: [CapturedImages, ImageMetadata, ImagingSessions, Targets],
)
class ImagesDao extends DatabaseAccessor<SkotiqDatabase> with _$ImagesDaoMixin {
  ImagesDao(super.db);

  /// Get all images
  Future<List<CapturedImage>> getAllImages() {
    return (select(
      capturedImages,
    )..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])).get();
  }

  /// Get all images with pagination
  ///
  /// More efficient for displaying large image libraries.
  /// Use this instead of getAllImages() when dealing with hundreds or thousands of images.
  Future<List<CapturedImage>> getAllImagesPaginated({
    required int limit,
    required int offset,
  }) {
    return (select(capturedImages)
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  /// Get total image count
  Future<int> getImageCount() async {
    final countExp = capturedImages.id.count();
    final query = selectOnly(capturedImages)..addColumns([countExp]);
    final result = await query.getSingle();
    return result.read(countExp) ?? 0;
  }

  /// Get image count for a session
  Future<int> getImageCountForSession(int sessionId) async {
    final countExp = capturedImages.id.count();
    final query = selectOnly(capturedImages)
      ..addColumns([countExp])
      ..where(capturedImages.sessionId.equals(sessionId));
    final result = await query.getSingle();
    return result.read(countExp) ?? 0;
  }

  /// The most recent session that actually contains light frames.
  ///
  /// Analysis surfaces need a session with science content, not simply the
  /// newest row in `imaging_sessions` — a calibration run (darks/flats only) or
  /// a session that aborted before its first light would leave those surfaces
  /// truthfully but uselessly reporting "no light frames yet" while nights of
  /// data sit one row further down.
  Future<int?> getLatestSessionIdWithLightFrames() async {
    final capturedAtMax = capturedImages.capturedAt.max();
    final query = selectOnly(capturedImages)
      ..addColumns([capturedImages.sessionId, capturedAtMax])
      ..where(
        capturedImages.sessionId.isNotNull() &
            capturedImages.frameType.lower().equals('light'),
      )
      ..groupBy([capturedImages.sessionId])
      ..orderBy([OrderingTerm.desc(capturedAtMax)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.read(capturedImages.sessionId);
  }

  /// Every session that holds at least one plate-solved frame.
  ///
  /// Used to choose which night the Science tab opens on: a plate solve is the
  /// precondition for astrometry, photometric calibration and the solve-rate
  /// card, so a session with none has nothing for that tab to show.
  Future<Set<int>> getSessionIdsWithSolvedFrames() async {
    final query = selectOnly(capturedImages, distinct: true)
      ..addColumns([capturedImages.sessionId])
      ..where(
        capturedImages.sessionId.isNotNull() &
            capturedImages.isPlateSolved.equals(true),
      );
    final rows = await query.get();
    return rows
        .map((row) => row.read(capturedImages.sessionId))
        .whereType<int>()
        .toSet();
  }

  /// Watch all images
  Stream<List<CapturedImage>> watchAllImages() {
    return (select(
      capturedImages,
    )..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])).watch();
  }

  /// Get images for a session
  Future<List<CapturedImage>> getImagesForSession(int sessionId) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.equals(sessionId))
          ..orderBy([(i) => OrderingTerm.asc(i.capturedAt)]))
        .get();
  }

  /// Get images for a session with pagination
  ///
  /// This is more efficient for large image sets as it only loads
  /// the requested page instead of all images.
  Future<List<CapturedImage>> getImagesForSessionPaginated({
    required int sessionId,
    required int limit,
    required int offset,
  }) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.equals(sessionId))
          ..orderBy([(i) => OrderingTerm.asc(i.capturedAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  /// Watch images for a session
  Stream<List<CapturedImage>> watchImagesForSession(int sessionId) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.equals(sessionId))
          ..orderBy([(i) => OrderingTerm.asc(i.capturedAt)]))
        .watch();
  }

  /// Watch the images captured in `[start, end)`, oldest first: one
  /// observing night, whatever runs and sessions it held.
  Stream<List<CapturedImage>> watchImagesCapturedBetween(
    DateTime start,
    DateTime end,
  ) {
    return _capturedBetween(start, end).watch();
  }

  /// The images captured in `[start, end)`, oldest first.
  Future<List<CapturedImage>> getImagesCapturedBetween(
    DateTime start,
    DateTime end,
  ) {
    return _capturedBetween(start, end).get();
  }

  SimpleSelectStatement<$CapturedImagesTable, CapturedImage> _capturedBetween(
    DateTime start,
    DateTime end,
  ) {
    return select(capturedImages)
      ..where(
        (i) =>
            i.capturedAt.isBiggerOrEqualValue(start) &
            i.capturedAt.isSmallerThanValue(end),
      )
      ..orderBy([(i) => OrderingTerm.asc(i.capturedAt)]);
  }

  /// Get images for a target
  Future<List<CapturedImage>> getImagesForTarget(int targetId) {
    return (select(capturedImages)
          ..where((i) => i.targetId.equals(targetId))
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)]))
        .get();
  }

  /// Get image by ID
  Future<CapturedImage?> getImageById(int id) {
    return (select(
      capturedImages,
    )..where((i) => i.id.equals(id))).getSingleOrNull();
  }

  Future<CapturedImage?> getImageByFilePath(String filePath) {
    return (select(
      capturedImages,
    )..where((i) => i.filePath.equals(filePath))).getSingleOrNull();
  }

  /// Stamp [id] as folded into the personal sky atlas (Pillar A).
  ///
  /// The solved-frame fold hook calls this after a successful fold; it then
  /// skips re-folding any image whose `atlasFoldedAt` is already set, so a
  /// duplicate inbound `updateCapturedImage{isPlateSolved:true}` cannot
  /// double-count photons. Returns the number of rows updated.
  Future<int> stampAtlasFolded(int id, {DateTime? at}) {
    return (update(capturedImages)..where((i) => i.id.equals(id))).write(
      CapturedImagesCompanion(atlasFoldedAt: Value(at ?? DateTime.now())),
    );
  }

  /// The session's newest frames, newest first. With [atOrBefore], only
  /// frames captured at or before that time.
  Future<List<CapturedImage>> getRecentImagesForSession(
    int sessionId, {
    int limit = 5,
    DateTime? atOrBefore,
  }) {
    return (select(capturedImages)
          ..where(
            (i) => atOrBefore == null
                ? i.sessionId.equals(sessionId)
                : i.sessionId.equals(sessionId) &
                      i.capturedAt.isSmallerOrEqualValue(atOrBefore),
          )
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])
          ..limit(limit))
        .get();
  }

  /// Create a new image record
  Future<int> createImage(CapturedImagesCompanion image) {
    return into(capturedImages).insert(image);
  }

  /// Update an image
  Future<bool> updateImage(CapturedImage image) {
    return update(capturedImages).replace(image);
  }

  /// Update only the stored file path for an image.
  Future<void> updateImageFilePath(int id, String filePath) {
    return (update(capturedImages)..where((i) => i.id.equals(id))).write(
      CapturedImagesCompanion(filePath: Value(filePath)),
    );
  }

  // Thumbnail sidecar bookkeeping.
  //
  // `thumbnail_path` is nullable — null means no sidecar yet; the GET handler
  // falls back to a cold-read and self-heals by writing the sidecar then
  // stamping the column.

  /// Read the sidecar JPEG path for [imageId], or null if no sidecar has
  /// been written. Doesn't probe the filesystem — callers must stat the
  /// file themselves before assuming the path is usable.
  Future<String?> getThumbnailPath(int imageId) =>
      _columnOf(imageId, capturedImages.thumbnailPath);

  /// Stamp the sidecar path on a row. Passing an empty string or `null`
  /// clears it (used by regenerate-after-failure scenarios). Doesn't
  /// validate the path exists on disk.
  ///
  /// SQL text on purpose: a typed update wakes every watcher of
  /// captured_images, and the thumbnail backfill stamps the library one row
  /// at a time. Nothing reads this column through a watcher.
  Future<void> setThumbnailPath(int imageId, String? thumbnailPath) async {
    if (thumbnailPath == null || thumbnailPath.isEmpty) {
      await customStatement(
        'UPDATE captured_images SET thumbnail_path = NULL WHERE id = ?',
        [imageId],
      );
    } else {
      await customStatement(
        'UPDATE captured_images SET thumbnail_path = ? WHERE id = ?',
        [thumbnailPath, imageId],
      );
    }
  }

  /// List images whose sidecar is missing or unset. Used by the backfill
  /// job to decide which rows need a thumbnail generated. Returns the row
  /// id, source FITS path, and the recorded sidecar path (which may be
  /// null or stale — the caller filters by file existence).
  ///
  /// We deliberately don't filter by `IS NULL` here only: the on-disk
  /// file at a previously-stamped path may have been deleted by the
  /// operator (e.g. SD card cleanup); the backfill should pick those up
  /// too. The caller iterates and stats each `thumbnail_path`.
  Future<List<({int id, String filePath, String? thumbnailPath})>>
  listImagesForThumbnailBackfill() async {
    final i = capturedImages;
    final rows =
        await (selectOnly(i)
              ..addColumns([i.id, i.filePath, i.thumbnailPath])
              ..orderBy([OrderingTerm.asc(i.id)]))
            .get();
    return rows
        .map(
          (r) => (
            id: r.read(i.id)!,
            filePath: r.read(i.filePath)!,
            thumbnailPath: r.read(i.thumbnailPath),
          ),
        )
        .toList(growable: false);
  }

  /// Delete an image record
  Future<int> deleteImage(int id) {
    return (delete(capturedImages)..where((i) => i.id.equals(id))).go();
  }

  /// Mark image as rejected
  Future<void> rejectImage(int id, String reason) {
    return (update(capturedImages)..where((i) => i.id.equals(id))).write(
      CapturedImagesCompanion(
        isAccepted: const Value(false),
        rejectionReason: Value(reason),
      ),
    );
  }

  /// Accept a previously rejected image
  Future<void> acceptImage(int id) {
    return (update(capturedImages)..where((i) => i.id.equals(id))).write(
      const CapturedImagesCompanion(
        isAccepted: Value(true),
        rejectionReason: Value(null),
      ),
    );
  }

  /// Get images by frame type
  Future<List<CapturedImage>> getImagesByFrameType(String frameType) {
    return (select(capturedImages)
          ..where((i) => i.frameType.equals(frameType))
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)]))
        .get();
  }

  /// Watch recent standalone (sessionless) images — captures taken outside
  /// any sequence session.  Limited to the most recent [limit] images.
  Stream<List<CapturedImage>> watchStandaloneImages({int limit = 100}) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.isNull())
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])
          ..limit(limit))
        .watch();
  }

  /// Get images by filter
  Future<List<CapturedImage>> getImagesByFilter(String filter) {
    return (select(capturedImages)
          ..where((i) => i.filter.equals(filter))
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)]))
        .get();
  }

  /// Update plate solve result. The anisotropic WCS (the `solved_cd*` matrix
  /// and the `solved_sip` blob) is written only when the solve carried all
  /// four CD scalars; otherwise those columns are left as they are.
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
    await _writeImage(
      id,
      CapturedImagesCompanion(
        isPlateSolved: const Value(true),
        solvedRa: Value(solvedRa),
        solvedDec: Value(solvedDec),
        solvedRotation: Value(solvedRotation),
        solvedPixelScale: Value(solvedPixelScale),
        solvedCd1_1: hasCd ? Value(solvedCd1_1) : const Value.absent(),
        solvedCd1_2: hasCd ? Value(solvedCd1_2) : const Value.absent(),
        solvedCd2_1: hasCd ? Value(solvedCd2_1) : const Value.absent(),
        solvedCd2_2: hasCd ? Value(solvedCd2_2) : const Value.absent(),
        solvedSip: hasCd ? Value(solvedSip) : const Value.absent(),
      ),
    );
  }

  /// Record that a plate solver ran on the frame at [filePath] and found no
  /// solution. A frame that already solved keeps its solve. Returns whether a
  /// row was marked.
  Future<bool> markPlateSolveFailed(String filePath, {DateTime? at}) async {
    final row = await getLatestImageByFilePath(filePath);
    if (row == null || row.isPlateSolved) return false;
    final stamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final changed =
        await (update(capturedImages)..where(
              (i) => i.id.equals(row.id) & i.isPlateSolved.equals(false),
            ))
            .write(CapturedImagesCompanion(plateSolveFailedAt: Value(stamp)));
    return changed > 0;
  }

  /// Ids of frames a plate solver ran on and could not solve (and that have
  /// not solved since).
  Stream<Set<int>> watchPlateSolveFailedIds() {
    final i = capturedImages;
    return (selectOnly(i)
          ..addColumns([i.id])
          ..where(
            i.plateSolveFailedAt.isNotNull() & i.isPlateSolved.equals(false),
          ))
        .watch()
        .map((rows) => {for (final r in rows) r.read(i.id)!});
  }

  /// The newest row recorded for [filePath], or null. A path can be recorded
  /// more than once (a frame re-registered after a restart), and the newest
  /// row is the one a run's later facts belong to.
  Future<CapturedImage?> getLatestImageByFilePath(String filePath) {
    return (select(capturedImages)
          ..where((i) => i.filePath.equals(filePath))
          ..orderBy([(i) => OrderingTerm.desc(i.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Record what the run's frame watch measured on a saved frame. Null values
  /// leave their columns as they are. A non-null [exclusionReason] takes the
  /// frame out of the accepted set and is appended to any reason already on
  /// the row, so the grader's own reason is kept.
  Future<void> applyFrameAssessment(
    int id, {
    double? background,
    double? guidingRmsTotal,
    String? pierSide,
    String? exclusionReason,
  }) {
    return transaction(() async {
      final row = await getImageById(id);
      if (row == null) return;
      String? reason;
      if (exclusionReason != null && exclusionReason.isNotEmpty) {
        final existing = row.rejectionReason;
        reason = existing == null || existing.isEmpty
            ? exclusionReason
            : existing.contains(exclusionReason)
            ? existing
            : '$existing; $exclusionReason';
      }
      await (update(capturedImages)..where((i) => i.id.equals(id))).write(
        CapturedImagesCompanion(
          background: background == null
              ? const Value.absent()
              : Value(background),
          guidingRmsTotal: guidingRmsTotal == null
              ? const Value.absent()
              : Value(guidingRmsTotal),
          pierSide: pierSide == null || row.pierSide != null
              ? const Value.absent()
              : Value(pierSide),
          isAccepted: reason == null
              ? const Value.absent()
              : const Value(false),
          rejectionReason: reason == null
              ? const Value.absent()
              : Value(reason),
        ),
      );
    });
  }

  /// Read the anisotropic WCS columns for [id] — the `solved_cd*` matrix and
  /// the `solved_sip` blob. Any may be null when the stored solve was
  /// isotropic.
  Future<
    ({double? cd1_1, double? cd1_2, double? cd2_1, double? cd2_2, String? sip})?
  >
  getStoredWcsDistortion(int id) async {
    final i = capturedImages;
    final row =
        await (selectOnly(i)
              ..addColumns([
                i.solvedCd1_1,
                i.solvedCd1_2,
                i.solvedCd2_1,
                i.solvedCd2_2,
                i.solvedSip,
              ])
              ..where(i.id.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    return (
      cd1_1: row.read(i.solvedCd1_1),
      cd1_2: row.read(i.solvedCd1_2),
      cd2_1: row.read(i.solvedCd2_1),
      cd2_2: row.read(i.solvedCd2_2),
      sip: row.read(i.solvedSip),
    );
  }

  /// Get image count by filter for a target using SQL GROUP BY.
  Future<Map<String, int>> getFilterCountsForTarget(int targetId) async {
    final countExp = capturedImages.id.count();
    final query = selectOnly(capturedImages)
      ..addColumns([capturedImages.filter, countExp])
      ..where(
        capturedImages.targetId.equals(targetId) &
            capturedImages.isAccepted.equals(true) &
            capturedImages.filter.isNotNull(),
      )
      ..groupBy([capturedImages.filter]);

    final rows = await query.get();
    final counts = <String, int>{};
    for (final row in rows) {
      final filter = row.read(capturedImages.filter);
      final count = row.read(countExp);
      if (filter != null && count != null) {
        counts[filter] = count;
      }
    }
    return counts;
  }

  // Producing-node provenance

  /// Stamp the producing-node provenance on an already-persisted image row.
  ///
  /// Called from the imaging service after `createImage` returns the new
  /// row id, and from the sequence executor when a FrameAccepted /
  /// FrameRejected event ships a runtime grade for a row this Dart side
  /// just inserted.
  ///
  /// Pass `null` for fields you don't want to touch — the corresponding
  /// column is simply omitted from the UPDATE so existing values survive.
  Future<void> stampProducingNode({
    required int imageId,
    String? producingNodeId,
    String? producingRunId,
    String? runtimeGrade,
    double? eccentricity,
    double? fwhm,
  }) async {
    final stamp = CapturedImagesCompanion(
      producingNodeId: Value.absentIfNull(producingNodeId),
      producingRunId: Value.absentIfNull(producingRunId),
      runtimeGrade: Value.absentIfNull(runtimeGrade),
      eccentricity: Value.absentIfNull(eccentricity),
      fwhm: Value.absentIfNull(fwhm),
    );
    if (stamp.toColumns(false).isEmpty) return;
    await _writeImage(imageId, stamp);
  }

  /// Read the persisted median FWHM for [imageId], or null when the
  /// producing path measured none.
  Future<double?> getFwhm(int imageId) =>
      _columnOf(imageId, capturedImages.fwhm);

  /// Measured median FWHM for every frame of [sessionId] that has one, keyed
  /// by image id. Frames the producing path never measured are absent.
  ///
  /// Batched because the alternative, [getFwhm] per frame, is one query per
  /// sub across a whole night.
  Future<Map<int, double>> getFwhmForSession(int sessionId) async {
    final i = capturedImages;
    final rows =
        await (selectOnly(i)
              ..addColumns([i.id, i.fwhm])
              ..where(i.sessionId.equals(sessionId) & i.fwhm.isNotNull()))
            .get();
    return {for (final row in rows) row.read(i.id)!: row.read(i.fwhm)!};
  }

  /// The thumbnail strip's view of the frames one instruction produced
  /// (optionally in one run), oldest first: only the columns the strip shows.
  ///
  /// `runtimeGrade` is one of `pass`, `reject`, `pending`, or `null` (no
  /// grading ran). Consumers map this to the strip's border colour.
  /// `eccentricity` mirrors the Rust grader's median star eccentricity.
  Future<List<ProducingNodeThumbnail>> getImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) async {
    final rows = await _producedBy(
      producingNodeId,
      producingRunId,
      limit,
    ).get();
    return rows.map(_thumbnail).toList(growable: false);
  }

  /// Live-update version of [getImagesByProducingNode]. Used by the
  /// sequence-tree thumbnail strip so freshly-captured frames appear
  /// inline without a manual refresh.
  Stream<List<ProducingNodeThumbnail>> watchImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) {
    return _producedBy(
      producingNodeId,
      producingRunId,
      limit,
    ).watch().map((rows) => rows.map(_thumbnail).toList(growable: false));
  }

  /// Count thumbnails for a given producing node — used by the tree
  /// rendering to decide whether to draw the strip at all (an empty
  /// strip is collapsed silently per the spec).
  Future<int> countImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
  }) async {
    final i = capturedImages;
    return _count(
      producingRunId == null
          ? i.producingNodeId.equals(producingNodeId)
          : i.producingNodeId.equals(producingNodeId) &
                i.producingRunId.equals(producingRunId),
    );
  }

  /// Insert a captured-image row from a sequence-driven event. This is
  /// the only path that captures the producing-node breadcrumbs on
  /// insertion (vs. the [createImage]/[stampProducingNode] dance used by
  /// ad-hoc captures). Returns the new row id.
  ///
  /// `fileSize` is populated from `File(filePath).length()` here so the
  /// REST `/api/images` listing exposes a real byte count to mobile
  /// clients (otherwise they can't pre-size a download). The Rust FITS
  /// writer is synchronous, so by the time the `FrameAccepted` /
  /// `FrameRejected` event reaches Dart the file is already on disk —
  /// if the length lookup throws, that's noteworthy enough to log a
  /// warning, but the row MUST still be written (the size is purely
  /// auxiliary; losing the breadcrumb row is far worse than losing the
  /// size). Pass [logger] from a caller that has the `LoggingService`
  /// already wired so the warning routes through the structured logger;
  /// callers without one (tests, raw-DB tools) can pass `null` and the
  /// warning will be swallowed silently — those callers are not the
  /// production capture path.
  Future<int> insertSequenceFrame({
    required String filePath,
    required String fileName,
    required String fileFormat,
    required double exposureDuration,
    required DateTime capturedAt,
    required bool isAccepted,
    required String producingNodeId,
    String? producingRunId,
    String? runtimeGrade,
    String? rejectionReason,
    int? sessionId,
    int? targetId,
    String? filter,
    String frameType = 'light',
    double? hfr,
    int? starCount,
    double? eccentricity,
    int? gain,
    int? offset,
    int? binX,
    int? binY,
    double? qualityScore,
    // Live equipment state at capture time, taken from the frame event's
    // capture payload — which is the same `FrameContext` the FITS writer
    // stamped the header from. Every one of these columns already existed and
    // no sequencer frame had ever written one, so a row and its own file
    // disagreed about the exposure that produced them both.
    double? sensorTemp,
    double? coolerPower,

    /// Mount right ascension in HOURS (the `captured_images.mount_ra`
    /// convention), not degrees.
    double? mountRa,
    double? mountDec,
    double? mountAltitude,
    double? mountAzimuth,
    String? pierSide,
    int? focuserPosition,
    double? focuserTemp,
    double? rotatorAngle,
    LoggingService? logger,
    ThumbnailSidecarService? sidecarService,
  }) async {
    // Populate file_size so REST clients can pre-size a
    // download. We use the synchronous length() here (the file was just
    // written by Rust and is guaranteed on disk for the
    // FrameAccepted/FrameRejected event path). On a rejected frame that
    // was diverted to the reject folder, the path may still be valid;
    // on a frame with an empty path (legacy emit site that didn't
    // thread save_path through), we skip the stat entirely.
    int? fileSize;
    if (filePath.isNotEmpty) {
      try {
        fileSize = await File(filePath).length();
      } catch (e) {
        logger?.warning(
          'Failed to read file size for $filePath: $e — row will be '
          'inserted with NULL file_size',
          source: 'ImagesDao',
        );
      }
    }

    // Pre-populate `thumbnail_path` with the predicted sidecar
    // location so the GET handler doesn't need to test for the file's
    // existence on every call. The actual JPEG bytes are written
    // asynchronously by `ThumbnailSidecarService` (best-effort,
    // unawaited); a missing file at this path triggers the cold-read
    // self-heal in the GET handler.
    final String? thumbnailPath = filePath.isEmpty
        ? null
        : '$filePath.thumb.jpg';

    final result = await into(capturedImages).insert(
      CapturedImagesCompanion.insert(
        filePath: filePath,
        fileName: fileName,
        fileFormat: Value(fileFormat),
        fileSize: Value(fileSize),
        sessionId: Value(sessionId),
        targetId: Value(targetId),
        frameType: Value(frameType),
        exposureDuration: exposureDuration,
        gain: Value(gain),
        offset: Value(offset),
        binX: Value(binX ?? 1),
        binY: Value(binY ?? 1),
        filter: Value(filter),
        hfr: Value(hfr),
        starCount: Value(starCount),
        qualityScore: Value(qualityScore),
        capturedAt: capturedAt,
        isAccepted: Value(isAccepted),
        rejectionReason: Value(rejectionReason),
        producingNodeId: Value(producingNodeId),
        producingRunId: Value(producingRunId),
        runtimeGrade: Value(runtimeGrade),
        eccentricity: Value(eccentricity),
        thumbnailPath: Value(thumbnailPath),
        isPlateSolved: const Value(false),
        createdAt: Value(capturedAt),
        sensorTemp: Value(sensorTemp),
        coolerPower: Value(coolerPower),
        mountRa: Value(mountRa),
        mountDec: Value(mountDec),
        mountAltitude: Value(mountAltitude),
        mountAzimuth: Value(mountAzimuth),
        pierSide: Value(pierSide),
        focuserPosition: Value(focuserPosition),
        focuserTemp: Value(focuserTemp),
        rotatorAngle: Value(rotatorAngle),
      ),
    );

    // Schedule fire-and-forget sidecar generation. The row is
    // persisted regardless of sidecar outcome — a missing sidecar self-
    // heals on the next GET. Errors land in the structured logger via
    // the service (see ThumbnailSidecarService.writeSidecarForRow).
    if (sidecarService != null && filePath.isNotEmpty && isAccepted) {
      sidecarService.scheduleSidecarWrite(
        imageId: result,
        fitsPath: filePath,
        imagesDao: this,
      );
    }

    return result;
  }

  /// Backfill helper for `file_size IS NULL` rows. Returns a
  /// summary `{updated, skipped, errors}` map. `skipped` covers rows whose
  /// on-disk file no longer exists (e.g. the operator deleted it); each
  /// such row is logged at warning severity via [logger] if provided.
  /// `errors` covers permission denied / I/O errors on `File.length()`.
  ///
  /// Existing databases predating this change will have hundreds or thousands
  /// of rows with NULL file_size; running this once after upgrade brings
  /// them up to par with newly-inserted rows. We deliberately don't
  /// auto-run on schema upgrade — the I/O could be large on a Pi with
  /// an SD card — but the operator (or a debug action) can invoke it.
  Future<Map<String, int>> backfillMissingFileSizes({
    LoggingService? logger,
  }) async {
    final i = capturedImages;
    final rows =
        await (selectOnly(i)
              ..addColumns([i.id, i.filePath])
              ..where(i.fileSize.isNull()))
            .get();

    int updated = 0;
    int skipped = 0;
    int errors = 0;

    for (final row in rows) {
      final id = row.read(i.id)!;
      final filePath = row.read(i.filePath)!;
      if (filePath.isEmpty) {
        skipped++;
        continue;
      }
      final file = File(filePath);
      if (!await file.exists()) {
        skipped++;
        logger?.warning(
          'backfillMissingFileSizes: skipping image $id — file not '
          'found on disk: $filePath',
          source: 'ImagesDao',
        );
        continue;
      }
      try {
        final size = await file.length();
        await (update(capturedImages)..where((i) => i.id.equals(id))).write(
          CapturedImagesCompanion(fileSize: Value(size)),
        );
        updated++;
      } catch (e) {
        errors++;
        logger?.warning(
          'backfillMissingFileSizes: failed to read length for image '
          '$id ($filePath): $e',
          source: 'ImagesDao',
        );
      }
    }

    return {'updated': updated, 'skipped': skipped, 'errors': errors};
  }

  // Image metadata operations

  /// Get metadata for an image
  Future<List<ImageMetadatum>> getMetadataForImage(int imageId) {
    return (select(
      imageMetadata,
    )..where((m) => m.imageId.equals(imageId))).get();
  }

  /// Add metadata to an image
  Future<int> addMetadata(
    int imageId,
    String key,
    String value, {
    String? comment,
  }) {
    return into(imageMetadata).insert(
      ImageMetadataCompanion.insert(
        imageId: imageId,
        key: key,
        value: value,
        comment: Value(comment),
      ),
    );
  }

  /// Add multiple metadata entries
  Future<void> addMetadataBatch(
    int imageId,
    Map<String, String> metadata,
  ) async {
    await batch((batch) {
      for (final entry in metadata.entries) {
        batch.insert(
          imageMetadata,
          ImageMetadataCompanion.insert(
            imageId: imageId,
            key: entry.key,
            value: entry.value,
          ),
        );
      }
    });
  }

  /// Every frame one sequence run produced, oldest first: the session-replay
  /// scrubber's timeline. `producing_run_id` is `sequence_runs.id` as text.
  Future<List<CapturedImage>> getImagesByProducingRun({
    required String producingRunId,
    int limit = 1000,
    int offset = 0,
  }) {
    return (select(capturedImages)
          ..where((i) => i.producingRunId.equals(producingRunId))
          ..orderBy([(i) => OrderingTerm.asc(i.capturedAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  Future<int> countImagesByProducingRun({required String producingRunId}) =>
      _count(capturedImages.producingRunId.equals(producingRunId));

  Future<void> _writeImage(int id, CapturedImagesCompanion changes) =>
      (update(capturedImages)..where((i) => i.id.equals(id))).write(changes);

  /// One nullable column of frame [id], or null when the row is missing.
  Future<T?> _columnOf<T extends Object>(int id, Expression<T> column) async {
    final row =
        await (selectOnly(capturedImages)
              ..addColumns([column])
              ..where(capturedImages.id.equals(id)))
            .getSingleOrNull();
    return row?.read(column);
  }

  Future<int> _count(Expression<bool> where) async {
    final count = countAll();
    final row =
        await (selectOnly(capturedImages)
              ..addColumns([count])
              ..where(where))
            .getSingle();
    return row.read(count) ?? 0;
  }

  List<Expression<Object>> get _thumbnailColumns {
    final i = capturedImages;
    return [
      i.id,
      i.filePath,
      i.fileName,
      i.filter,
      i.frameType,
      i.hfr,
      i.eccentricity,
      i.fwhm,
      i.starCount,
      i.exposureDuration,
      i.capturedAt,
      i.isAccepted,
      i.rejectionReason,
      i.runtimeGrade,
      i.producingNodeId,
      i.producingRunId,
    ];
  }

  JoinedSelectStatement<$CapturedImagesTable, CapturedImage> _producedBy(
    String producingNodeId,
    String? producingRunId,
    int limit,
  ) {
    final i = capturedImages;
    return selectOnly(i)
      ..addColumns(_thumbnailColumns)
      ..where(
        producingRunId == null
            ? i.producingNodeId.equals(producingNodeId)
            : i.producingNodeId.equals(producingNodeId) &
                  i.producingRunId.equals(producingRunId),
      )
      ..orderBy([OrderingTerm.asc(i.capturedAt)])
      ..limit(limit);
  }

  ProducingNodeThumbnail _thumbnail(TypedResult row) {
    final i = capturedImages;
    return ProducingNodeThumbnail(
      id: row.read(i.id)!,
      filePath: row.read(i.filePath)!,
      fileName: row.read(i.fileName)!,
      filter: row.read(i.filter),
      frameType: row.read(i.frameType)!,
      hfr: row.read(i.hfr),
      eccentricity: row.read(i.eccentricity),
      fwhm: row.read(i.fwhm),
      starCount: row.read(i.starCount),
      exposureDuration: row.read(i.exposureDuration)!,
      // Drift decodes a DateTime column as a local instant; the strip has
      // always been handed UTC.
      capturedAt: row.read(i.capturedAt)!.toUtc(),
      isAccepted: row.read(i.isAccepted)!,
      rejectionReason: row.read(i.rejectionReason),
      runtimeGrade: row.read(i.runtimeGrade),
      producingNodeId: row.read(i.producingNodeId)!,
      producingRunId: row.read(i.producingRunId),
    );
  }
}
