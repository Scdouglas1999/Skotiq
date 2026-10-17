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

  factory ProducingNodeThumbnail.fromRow(QueryRow row) {
    // captured_at on disk is stored as INTEGER seconds since epoch (matches
    // `created_at` / SQLite epoch convention). Drift writes DateTime values
    // through `DateTimeColumn` as seconds-since-epoch by default; reading
    // it back here goes through the same path.
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

  Future<List<CapturedImage>> getRecentImagesForSession(
    int sessionId, {
    int limit = 5,
  }) {
    return (select(capturedImages)
          ..where((i) => i.sessionId.equals(sessionId))
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
  // The `thumbnail_path` column lives off-table (raw DDL, see
  // `database.dart::_ensureCapturedImagesThumbnailPathColumn`) so we go
  // through `customStatement` / `customSelect`. Nullable column — null
  // means no sidecar yet; the GET handler falls back to a cold-read and
  // self-heals by writing the sidecar then stamping the column.

  /// Read the sidecar JPEG path for [imageId], or null if no sidecar has
  /// been written. Doesn't probe the filesystem — callers must stat the
  /// file themselves before assuming the path is usable.
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
    final rows = await customSelect(
      'SELECT id, file_path, thumbnail_path FROM captured_images '
      'ORDER BY id ASC',
      readsFrom: {capturedImages},
    ).get();
    return rows
        .map(
          (r) => (
            id: r.read<int>('id'),
            filePath: r.read<String>('file_path'),
            thumbnailPath: r.data['thumbnail_path'] as String?,
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

  /// Update plate solve result. The isotropic scalars go through the typed
  /// companion; the anisotropic WCS (the `solved_cd*` matrix and `solved_sip`
  /// blob) is off-table, so it's written with a follow-up statement only when
  /// the solve carried it. Null CD scalars leave those columns untouched.
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
    await (update(capturedImages)..where((i) => i.id.equals(id))).write(
      CapturedImagesCompanion(
        isPlateSolved: const Value(true),
        solvedRa: Value(solvedRa),
        solvedDec: Value(solvedDec),
        solvedRotation: Value(solvedRotation),
        solvedPixelScale: Value(solvedPixelScale),
      ),
    );
    if (solvedCd1_1 != null &&
        solvedCd1_2 != null &&
        solvedCd2_1 != null &&
        solvedCd2_2 != null) {
      await customStatement(
        'UPDATE captured_images SET solved_cd1_1 = ?, solved_cd1_2 = ?, '
        'solved_cd2_1 = ?, solved_cd2_2 = ?, solved_sip = ? WHERE id = ?',
        [solvedCd1_1, solvedCd1_2, solvedCd2_1, solvedCd2_2, solvedSip, id],
      );
    }
  }

  /// Read the off-table WCS columns for [id] — the `solved_cd*` matrix and the
  /// `solved_sip` blob. Any may be null when the stored solve was isotropic.
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

  // Thumbnail — producing-node provenance
  //
  // The columns producing_node_id / producing_run_id / runtime_grade /
  // eccentricity are stored on captured_images via the v30 raw-DDL migration
  // (see database.dart). They are NOT declared on the [CapturedImages] Drift
  // Table to keep the .g.dart codegen surface unchanged; the helpers below
  // therefore go through `customSelect` / `customStatement`.

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
    if (producingNodeId != null) {
      assignments.add('producing_node_id = ?');
      args.add(producingNodeId);
    }
    if (producingRunId != null) {
      assignments.add('producing_run_id = ?');
      args.add(producingRunId);
    }
    if (runtimeGrade != null) {
      assignments.add('runtime_grade = ?');
      args.add(runtimeGrade);
    }
    if (eccentricity != null) {
      assignments.add('eccentricity = ?');
      args.add(eccentricity);
    }
    if (fwhm != null) {
      assignments.add('fwhm = ?');
      args.add(fwhm);
    }
    if (assignments.isEmpty) {
      return;
    }
    args.add(imageId);
    await customStatement(
      'UPDATE captured_images SET ${assignments.join(", ")} WHERE id = ?',
      args,
    );
  }

  /// Read the persisted median FWHM for [imageId], or null when the
  /// producing path measured none.
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
  /// `fwhm` is a v50 raw-DDL column, so it is NOT a field on the generated
  /// `CapturedImage` data class — anything holding a `List<DbCapturedImage>`
  /// (the exporters, the report builder) cannot see it and has to look it up
  /// here. Batched because the alternative, [getFwhm] per frame, is one query
  /// per sub across a whole night.
  Future<Map<int, double>> getFwhmForSession(int sessionId) async {
    final rows = await customSelect(
      'SELECT id, fwhm FROM captured_images '
      'WHERE session_id = ? AND fwhm IS NOT NULL',
      variables: [Variable<int>(sessionId)],
      readsFrom: {capturedImages},
    ).get();
    return {
      for (final row in rows)
        row.read<int>('id'): (row.data['fwhm'] as num).toDouble(),
    };
  }

  /// Lightweight thumbnail-friendly view of a captured image row: only the
  /// columns the sequence-tree thumbnail strip needs. Pulled out into its
  /// own type so the watch query can stay narrow and so consumers don't
  /// have to depend on the full CapturedImage data class.
  ///
  /// `runtimeGrade` is one of `pass`, `reject`, `pending`, or `null` (no
  /// grading ran). Consumers map this to the strip's border colour.
  /// `eccentricity` mirrors the Rust grader's median star eccentricity.
  Future<List<ProducingNodeThumbnail>> getImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) async {
    final whereParts = <String>['producing_node_id = ?'];
    final variables = <Variable>[Variable<String>(producingNodeId)];
    if (producingRunId != null) {
      whereParts.add('producing_run_id = ?');
      variables.add(Variable<String>(producingRunId));
    }
    variables.add(Variable<int>(limit));
    final rows = await customSelect(
      'SELECT id, file_path, file_name, filter, frame_type, hfr, '
      'eccentricity, fwhm, star_count, exposure_duration, captured_at, '
      'is_accepted, rejection_reason, runtime_grade, producing_node_id, '
      'producing_run_id '
      'FROM captured_images '
      'WHERE ${whereParts.join(' AND ')} '
      'ORDER BY captured_at ASC '
      'LIMIT ?',
      variables: variables,
    ).get();
    return rows.map(ProducingNodeThumbnail.fromRow).toList(growable: false);
  }

  /// Live-update version of [getImagesByProducingNode]. Used by the
  /// sequence-tree thumbnail strip so freshly-captured frames appear
  /// inline without a manual refresh.
  Stream<List<ProducingNodeThumbnail>> watchImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) {
    final whereParts = <String>['producing_node_id = ?'];
    final variables = <Variable>[Variable<String>(producingNodeId)];
    if (producingRunId != null) {
      whereParts.add('producing_run_id = ?');
      variables.add(Variable<String>(producingRunId));
    }
    variables.add(Variable<int>(limit));
    return customSelect(
      'SELECT id, file_path, file_name, filter, frame_type, hfr, '
      'eccentricity, fwhm, star_count, exposure_duration, captured_at, '
      'is_accepted, rejection_reason, runtime_grade, producing_node_id, '
      'producing_run_id '
      'FROM captured_images '
      'WHERE ${whereParts.join(' AND ')} '
      'ORDER BY captured_at ASC '
      'LIMIT ?',
      variables: variables,
      readsFrom: {capturedImages},
    ).watch().map(
      (rows) =>
          rows.map(ProducingNodeThumbnail.fromRow).toList(growable: false),
    );
  }

  /// Count thumbnails for a given producing node — used by the tree
  /// rendering to decide whether to draw the strip at all (an empty
  /// strip is collapsed silently per the spec).
  Future<int> countImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
  }) async {
    final whereParts = <String>['producing_node_id = ?'];
    final variables = <Variable>[Variable<String>(producingNodeId)];
    if (producingRunId != null) {
      whereParts.add('producing_run_id = ?');
      variables.add(Variable<String>(producingRunId));
    }
    final row = await customSelect(
      'SELECT COUNT(*) AS c FROM captured_images '
      'WHERE ${whereParts.join(' AND ')}',
      variables: variables,
    ).getSingleOrNull();
    return (row?.data['c'] as int?) ?? 0;
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
    // Pull rows lacking a size. Drift's typed query API doesn't expose
    // `IS NULL` ergonomically through the generated DAO so we use the
    // raw select for clarity.
    final rows = await customSelect(
      'SELECT id, file_path FROM captured_images WHERE file_size IS NULL',
      readsFrom: {capturedImages},
    ).get();

    int updated = 0;
    int skipped = 0;
    int errors = 0;

    for (final row in rows) {
      final id = row.read<int>('id');
      final filePath = row.read<String>('file_path');
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

  // Replay support — Return all captured-image rows produced
  // by a given sequence run, ordered by capture time ascending. The
  // session-replay scrubber uses this to enumerate every frame on the
  // run's timeline.
  //
  // `producing_run_id` is a raw-DDL TEXT column (v30 migration); the
  // value is `sequence_runs.id.toString()` (see SequenceExecutor).
  // We use `customSelect` because Drift's generated typed select API
  // cannot reference the raw column. We then call `capturedImages.map`
  // on the row data to materialise a fully-typed CapturedImage — that
  // mapper is part of Drift's generated table accessor and accepts a
  // `Map<String, dynamic>` of column-name → value.
  Future<List<CapturedImage>> getImagesByProducingRun({
    required String producingRunId,
    int limit = 1000,
    int offset = 0,
  }) async {
    final rows = await customSelect(
      'SELECT * FROM captured_images '
      'WHERE producing_run_id = ? '
      'ORDER BY captured_at ASC '
      'LIMIT ? OFFSET ?',
      variables: [
        Variable<String>(producingRunId),
        Variable<int>(limit),
        Variable<int>(offset),
      ],
      readsFrom: {capturedImages},
    ).get();
    return [for (final row in rows) capturedImages.map(row.data)];
  }

  Future<int> countImagesByProducingRun({
    required String producingRunId,
  }) async {
    final row = await customSelect(
      'SELECT COUNT(*) AS c FROM captured_images '
      'WHERE producing_run_id = ?',
      variables: [Variable<String>(producingRunId)],
      readsFrom: {capturedImages},
    ).getSingleOrNull();
    return (row?.data['c'] as int?) ?? 0;
  }
}
