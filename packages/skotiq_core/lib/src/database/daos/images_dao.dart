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

/// Reads and writes for captured_images and image_metadata.
///
/// The queries marked "per frame" run for every frame of a run, or on every
/// redraw of a run's views, and stay SQL text on purpose: drift's typed
/// results map rows 2-5x slower (10 000 frames on this machine: thumbnail
/// strip 0.47 -> 2.45 ms, one row 108 -> 132 us), and a typed update wakes
/// every captured_images watcher, the largest of which re-reads the whole
/// night (about 100 ms per 5 000 frames).
@DriftAccessor(
  tables: [CapturedImages, ImageMetadata, ImagingSessions, Targets],
)
class ImagesDao extends DatabaseAccessor<SkotiqDatabase> with _$ImagesDaoMixin {
  ImagesDao(super.db);

  Future<List<DbCapturedImage>> getAllImages() {
    return (select(
      capturedImages,
    )..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])).get();
  }

  /// Get all images with pagination
  ///
  /// More efficient for displaying large image libraries.
  /// Use this instead of getAllImages() when dealing with hundreds or thousands of images.
  Future<List<DbCapturedImage>> getAllImagesPaginated({
    required int limit,
    required int offset,
  }) {
    return (select(capturedImages)
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  Future<int> getImageCount() async {
    final countExp = capturedImages.id.count();
    final query = selectOnly(capturedImages)..addColumns([countExp]);
    final result = await query.getSingle();
    return result.read(countExp) ?? 0;
  }

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

  Stream<List<DbCapturedImage>> watchAllImages() {
    return (select(
      capturedImages,
    )..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])).watch();
  }

  /// Whether any frame is stored: one EXISTS read on each write to the
  /// table, where watching every row reads and maps the whole library.
  Stream<bool> watchHasAnyImage() {
    final any = existsQuery(select(capturedImages));
    return selectExpressions([any]).watchSingle().map((row) => row.read(any)!);
  }

  Future<List<DbCapturedImage>> getImagesForSession(int sessionId) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.equals(sessionId))
          ..orderBy([(i) => OrderingTerm.asc(i.capturedAt)]))
        .get();
  }

  /// Get images for a session with pagination
  ///
  /// This is more efficient for large image sets as it only loads
  /// the requested page instead of all images.
  Future<List<DbCapturedImage>> getImagesForSessionPaginated({
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

  Stream<List<DbCapturedImage>> watchImagesForSession(int sessionId) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.equals(sessionId))
          ..orderBy([(i) => OrderingTerm.asc(i.capturedAt)]))
        .watch();
  }

  /// Watch the images captured in `[start, end)`, oldest first: one
  /// observing night, whatever runs and sessions it held.
  Stream<List<DbCapturedImage>> watchImagesCapturedBetween(
    DateTime start,
    DateTime end,
  ) {
    return _capturedBetween(start, end).watch();
  }

  /// The images captured in `[start, end)`, oldest first.
  Future<List<DbCapturedImage>> getImagesCapturedBetween(
    DateTime start,
    DateTime end,
  ) {
    return _capturedBetween(start, end).get();
  }

  SimpleSelectStatement<$CapturedImagesTable, DbCapturedImage> _capturedBetween(
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

  Future<List<DbCapturedImage>> getImagesForTarget(int targetId) {
    return (select(capturedImages)
          ..where((i) => i.targetId.equals(targetId))
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)]))
        .get();
  }

  Future<DbCapturedImage?> getImageById(int id) {
    return (select(
      capturedImages,
    )..where((i) => i.id.equals(id))).getSingleOrNull();
  }

  Future<DbCapturedImage?> getImageByFilePath(String filePath) {
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
  Future<List<DbCapturedImage>> getRecentImagesForSession(
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

  Future<int> createImage(CapturedImagesCompanion image) {
    return into(capturedImages).insert(image);
  }

  Future<bool> updateImage(DbCapturedImage image) {
    return update(capturedImages).replace(image);
  }

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
  /// file themselves before assuming the path is usable. Per frame: every
  /// thumbnail request reads it.
  Future<String?> getThumbnailPath(int imageId) async {
    final row = await customSelect(
      'SELECT thumbnail_path FROM captured_images WHERE id = ?',
      variables: [Variable<int>(imageId)],
      readsFrom: {capturedImages},
    ).getSingleOrNull();
    if (row == null) return null;
    return row.data['thumbnail_path'] as String?;
  }

  /// Stamp the sidecar path on a row. Passing an empty string or `null`
  /// clears it (used by regenerate-after-failure scenarios). Doesn't
  /// validate the path exists on disk.
  ///
  /// SQL text because a typed update wakes every captured_images watcher,
  /// and the thumbnail backfill stamps the library one row at a time.
  /// Nothing reads this column through a watcher.
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

  Future<int> deleteImage(int id) {
    return (delete(capturedImages)..where((i) => i.id.equals(id))).go();
  }

  Future<void> rejectImage(int id, String reason) {
    return (update(capturedImages)..where((i) => i.id.equals(id))).write(
      CapturedImagesCompanion(
        isAccepted: const Value(false),
        rejectionReason: Value(reason),
      ),
    );
  }

  Future<void> acceptImage(int id) {
    return (update(capturedImages)..where((i) => i.id.equals(id))).write(
      const CapturedImagesCompanion(
        isAccepted: Value(true),
        rejectionReason: Value(null),
      ),
    );
  }

  Future<List<DbCapturedImage>> getImagesByFrameType(String frameType) {
    return (select(capturedImages)
          ..where((i) => i.frameType.equals(frameType))
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)]))
        .get();
  }

  /// Watch recent standalone (sessionless) images — captures taken outside
  /// any sequence session.  Limited to the most recent [limit] images.
  Stream<List<DbCapturedImage>> watchStandaloneImages({int limit = 100}) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.isNull())
          ..orderBy([(i) => OrderingTerm.desc(i.capturedAt)])
          ..limit(limit))
        .watch();
  }

  Future<List<DbCapturedImage>> getImagesByFilter(String filter) {
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
  /// not solved since). Per frame: it re-runs on every write to the table.
  Stream<Set<int>> watchPlateSolveFailedIds() => customSelect(
    'SELECT id FROM captured_images '
    'WHERE plate_solve_failed_at IS NOT NULL AND is_plate_solved = 0',
    readsFrom: {capturedImages},
  ).watch().map((rows) => {for (final r in rows) r.read<int>('id')});

  /// The newest row recorded for [filePath], or null. A path can be recorded
  /// more than once (a frame re-registered after a restart), and the newest
  /// row is the one a run's later facts belong to.
  Future<DbCapturedImage?> getLatestImageByFilePath(String filePath) {
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
  /// isotropic. Per frame: every solved frame's hooks read it.
  Future<
    ({double? cd1_1, double? cd1_2, double? cd2_1, double? cd2_2, String? sip})?
  >
  getStoredWcsDistortion(int id) async {
    final row = await customSelect(
      'SELECT solved_cd1_1, solved_cd1_2, solved_cd2_1, solved_cd2_2, '
      'solved_sip FROM captured_images WHERE id = ?',
      variables: [Variable<int>(id)],
      readsFrom: {capturedImages},
    ).getSingleOrNull();
    if (row == null) return null;
    return (
      cd1_1: row.data['solved_cd1_1'] as double?,
      cd1_2: row.data['solved_cd1_2'] as double?,
      cd2_1: row.data['solved_cd2_1'] as double?,
      cd2_2: row.data['solved_cd2_2'] as double?,
      sip: row.data['solved_sip'] as String?,
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

  // Producing-node provenance and the thumbnail strip (per frame).

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
    final assignments = <String>[];
    final args = <Object?>[];
    void put(String column, Object? value) {
      if (value == null) return;
      assignments.add('$column = ?');
      args.add(value);
    }

    put('producing_node_id', producingNodeId);
    put('producing_run_id', producingRunId);
    put('runtime_grade', runtimeGrade);
    put('eccentricity', eccentricity);
    put('fwhm', fwhm);
    if (assignments.isEmpty) return;
    await customStatement(
      'UPDATE captured_images SET ${assignments.join(", ")} WHERE id = ?',
      [...args, imageId],
    );
  }

  /// Read the persisted median FWHM for [imageId], or null when the
  /// producing path measured none. Per frame: the auto-grader reads it.
  Future<double?> getFwhm(int imageId) async {
    final row = await customSelect(
      'SELECT fwhm FROM captured_images WHERE id = ?',
      variables: [Variable<int>(imageId)],
      readsFrom: {capturedImages},
    ).getSingleOrNull();
    if (row == null) return null;
    return row.data['fwhm'] as double?;
  }

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
    return rows.map(_thumbnailFromRow).toList(growable: false);
  }

  /// Live-update version of [getImagesByProducingNode]. Used by the
  /// sequence-tree thumbnail strip so freshly-captured frames appear
  /// inline without a manual refresh. Per frame: it re-runs on every write
  /// to the table.
  Stream<List<ProducingNodeThumbnail>> watchImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) {
    return _producedBy(producingNodeId, producingRunId, limit).watch().map(
      (rows) => rows.map(_thumbnailFromRow).toList(growable: false),
    );
  }

  /// Count thumbnails for a given producing node — used by the tree
  /// rendering to decide whether to draw the strip at all (an empty
  /// strip is collapsed silently per the spec). Per frame: every tree
  /// redraw asks it for each exposure node.
  Future<int> countImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
  }) async {
    final row = await customSelect(
      'SELECT COUNT(*) AS c FROM captured_images '
      'WHERE producing_node_id = ?'
      '${producingRunId == null ? '' : ' AND producing_run_id = ?'}',
      variables: [
        Variable<String>(producingNodeId),
        if (producingRunId != null) Variable<String>(producingRunId),
      ],
    ).getSingleOrNull();
    return (row?.data['c'] as int?) ?? 0;
  }

  Selectable<QueryRow> _producedBy(
    String producingNodeId,
    String? producingRunId,
    int limit,
  ) {
    return customSelect(
      'SELECT id, file_path, file_name, filter, frame_type, hfr, '
      'eccentricity, fwhm, star_count, exposure_duration, captured_at, '
      'is_accepted, rejection_reason, runtime_grade, producing_node_id, '
      'producing_run_id '
      'FROM captured_images '
      'WHERE producing_node_id = ?'
      '${producingRunId == null ? '' : ' AND producing_run_id = ?'} '
      'ORDER BY captured_at ASC '
      'LIMIT ?',
      variables: [
        Variable<String>(producingNodeId),
        if (producingRunId != null) Variable<String>(producingRunId),
        Variable<int>(limit),
      ],
      readsFrom: {capturedImages},
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
  ///
  /// Per frame: this is frame registration during a run (typed insert,
  /// median 4.1 -> 5.0 ms on this machine).
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
    final ms = capturedAt.toUtc().millisecondsSinceEpoch ~/ 1000;
    Variable<int> intOrNull(int? v) =>
        v == null ? const Variable<int>(null) : Variable<int>(v);
    Variable<String> strOrNull(String? v) =>
        v == null ? const Variable<String>(null) : Variable<String>(v);
    Variable<double> realOrNull(double? v) =>
        v == null ? const Variable<double>(null) : Variable<double>(v);

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

    final result = await customInsert(
      'INSERT INTO captured_images '
      '(file_path, file_name, file_format, file_size, session_id, target_id, '
      'frame_type, exposure_duration, gain, offset, bin_x, bin_y, filter, '
      'hfr, star_count, quality_score, captured_at, is_accepted, '
      'rejection_reason, producing_node_id, producing_run_id, '
      'runtime_grade, eccentricity, thumbnail_path, is_plate_solved, '
      'created_at, sensor_temp, cooler_power, mount_ra, mount_dec, '
      'mount_altitude, mount_azimuth, pier_side, focuser_position, '
      'focuser_temp, rotator_angle) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<String>(filePath),
        Variable<String>(fileName),
        Variable<String>(fileFormat),
        intOrNull(fileSize),
        intOrNull(sessionId),
        intOrNull(targetId),
        Variable<String>(frameType),
        Variable<double>(exposureDuration),
        intOrNull(gain),
        intOrNull(offset),
        Variable<int>(binX ?? 1),
        Variable<int>(binY ?? 1),
        strOrNull(filter),
        realOrNull(hfr),
        intOrNull(starCount),
        realOrNull(qualityScore),
        Variable<int>(ms),
        Variable<bool>(isAccepted),
        strOrNull(rejectionReason),
        Variable<String>(producingNodeId),
        strOrNull(producingRunId),
        strOrNull(runtimeGrade),
        realOrNull(eccentricity),
        strOrNull(thumbnailPath),
        Variable<int>(ms),
        realOrNull(sensorTemp),
        realOrNull(coolerPower),
        realOrNull(mountRa),
        realOrNull(mountDec),
        realOrNull(mountAltitude),
        realOrNull(mountAzimuth),
        strOrNull(pierSide),
        intOrNull(focuserPosition),
        realOrNull(focuserTemp),
        realOrNull(rotatorAngle),
      ],
      updates: {capturedImages},
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

  Future<List<ImageMetadatum>> getMetadataForImage(int imageId) {
    return (select(
      imageMetadata,
    )..where((m) => m.imageId.equals(imageId))).get();
  }

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
  Future<List<DbCapturedImage>> getImagesByProducingRun({
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

  Future<int> _count(Expression<bool> where) async {
    final count = countAll();
    final row =
        await (selectOnly(capturedImages)
              ..addColumns([count])
              ..where(where))
            .getSingle();
    return row.read(count) ?? 0;
  }
}

ProducingNodeThumbnail _thumbnailFromRow(QueryRow row) {
  // captured_at is INTEGER unix seconds, the way drift stores a DateTime
  // column; the strip is handed UTC.
  final capturedAtRaw = row.data['captured_at'];
  final capturedAt = capturedAtRaw is int
      ? DateTime.fromMillisecondsSinceEpoch(capturedAtRaw * 1000, isUtc: true)
      : DateTime.now();
  return ProducingNodeThumbnail(
    id: row.read<int>('id'),
    filePath: row.read<String>('file_path'),
    fileName: row.read<String>('file_name'),
    filter: row.readNullable<String>('filter'),
    frameType: row.read<String>('frame_type'),
    hfr: row.readNullable<double>('hfr'),
    eccentricity: row.readNullable<double>('eccentricity'),
    fwhm: row.readNullable<double>('fwhm'),
    starCount: row.readNullable<int>('star_count'),
    exposureDuration: row.read<double>('exposure_duration'),
    capturedAt: capturedAt,
    isAccepted: row.read<bool>('is_accepted'),
    rejectionReason: row.readNullable<String>('rejection_reason'),
    runtimeGrade: row.readNullable<String>('runtime_grade'),
    producingNodeId: row.read<String>('producing_node_id'),
    producingRunId: row.readNullable<String>('producing_run_id'),
  );
}
