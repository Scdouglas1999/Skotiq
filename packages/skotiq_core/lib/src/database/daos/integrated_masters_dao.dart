import 'package:drift/drift.dart';

import '../../models/imaging/integrated_master.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'integrated_masters_dao.g.dart';

/// Reads and writes for `integrated_masters` + `integrated_master_frames`: the
/// persisted provenance for every archival integrated master the post-session
/// pipeline produces.
///
/// SQLite errors propagate, the `(master_id, image_id)` UNIQUE constraint
/// guards against double-folding a sub, and reads map nullable columns to the
/// model's nullable fields rather than guessing.
@DriftAccessor(
  include: {'../schema/post_session.drift', '../schema/darkroom.drift'},
)
class IntegratedMastersDao extends DatabaseAccessor<SkotiqDatabase>
    with _$IntegratedMastersDaoMixin {
  IntegratedMastersDao(super.db);

  /// Insert a new master row and return its id. [createdAt]/[updatedAt] default
  /// to "now" (UTC seconds) when omitted.
  Future<int> insertMaster({
    int? targetId,
    required String name,
    String? masterFitsPath,
    String? previewPngPath,
    String? sidecarPath,
    String? rejectionMapPath,
    String? rejectionMapPreviewPath,
    String? coverageMapPath,
    String? coverageMapPreviewPath,
    required IntegratedMasterStatus status,
    required AccumulationMode accumulationMode,
    int channels = 1,
    int width = 0,
    int height = 0,
    int frameCount = 0,
    double totalIntegrationSeconds = 0.0,
    String? filter,
    String settingsJson = '{}',
    String statsJson = '{}',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final now = DateTime.now().toUtc();
    return into(integratedMasters).insert(
      IntegratedMastersCompanion.insert(
        targetId: Value(targetId),
        name: name,
        masterFitsPath: Value(masterFitsPath),
        previewPngPath: Value(previewPngPath),
        sidecarPath: Value(sidecarPath),
        rejectionMapPath: Value(rejectionMapPath),
        rejectionMapPreviewPath: Value(rejectionMapPreviewPath),
        coverageMapPath: Value(coverageMapPath),
        coverageMapPreviewPath: Value(coverageMapPreviewPath),
        status: Value(status.wire),
        accumulationMode: Value(accumulationMode.wire),
        channels: Value(channels),
        width: Value(width),
        height: Value(height),
        frameCount: Value(frameCount),
        totalIntegrationSeconds: Value(totalIntegrationSeconds),
        filter: Value(filter),
        settingsJson: Value(settingsJson),
        statsJson: Value(statsJson),
        createdAt: toEpochSeconds(createdAt ?? now),
        updatedAt: toEpochSeconds(updatedAt ?? now),
      ),
    );
  }

  Future<IntegratedMaster?> getById(int id) async {
    final row = await (select(
      integratedMasters,
    )..where((m) => m.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapMaster(row);
  }

  /// All masters, newest first.
  Future<List<IntegratedMaster>> getAll() async {
    final rows = await _newestFirst().get();
    return rows.map(_mapMaster).toList();
  }

  /// Masters for a given target, newest first.
  Future<List<IntegratedMaster>> getForTarget(int targetId) async {
    final rows = await _newestFirst(
      where: (m) => m.targetId.equals(targetId),
    ).get();
    return rows.map(_mapMaster).toList();
  }

  /// The active accumulating master for a (target, filter) pair, or null. Used
  /// by the auto-process hook to decide whether to fold tonight's subs into an
  /// existing master vs. start a one-shot integration.
  Future<IntegratedMaster?> getAccumulatingForTargetFilter({
    required int targetId,
    String? filter,
  }) async {
    final trimmed = filter?.trim() ?? '';
    final row = await (_newestFirst(
      where: (m) =>
          m.targetId.equals(targetId) &
          m.status.equals(IntegratedMasterStatus.accumulating.wire) &
          (trimmed.isNotEmpty
              ? m.filter.equals(trimmed)
              : (m.filter.isNull() | m.filter.equals(''))),
    )..limit(1)).getSingleOrNull();
    return row == null ? null : _mapMaster(row);
  }

  /// Apply a bookkeeping update after an accumulation `add`/`finalize`. Only the
  /// supplied fields are written; `updated_at` is always bumped to now.
  Future<int> updateBookkeeping(
    int id, {
    String? masterFitsPath,
    String? previewPngPath,
    String? rejectionMapPath,
    String? rejectionMapPreviewPath,
    String? coverageMapPath,
    String? coverageMapPreviewPath,
    IntegratedMasterStatus? status,
    int? channels,
    int? width,
    int? height,
    int? frameCount,
    double? totalIntegrationSeconds,
    String? statsJson,
  }) {
    return _write(
      id,
      IntegratedMastersCompanion(
        masterFitsPath: Value.absentIfNull(masterFitsPath),
        previewPngPath: Value.absentIfNull(previewPngPath),
        rejectionMapPath: Value.absentIfNull(rejectionMapPath),
        rejectionMapPreviewPath: Value.absentIfNull(rejectionMapPreviewPath),
        coverageMapPath: Value.absentIfNull(coverageMapPath),
        coverageMapPreviewPath: Value.absentIfNull(coverageMapPreviewPath),
        status: Value.absentIfNull(status?.wire),
        channels: Value.absentIfNull(channels),
        width: Value.absentIfNull(width),
        height: Value.absentIfNull(height),
        frameCount: Value.absentIfNull(frameCount),
        totalIntegrationSeconds: Value.absentIfNull(totalIntegrationSeconds),
        statsJson: Value.absentIfNull(statsJson),
      ),
    );
  }

  /// Apply the v42 Smart-Morning-Report fields to a master. Only the supplied
  /// fields are written; `updated_at` is always bumped to now. Mirrors
  /// [updateBookkeeping] but targets the additive v42 columns
  /// (`_ensureIntegratedMastersV42Columns`):
  ///
  ///  * [colorCalibratedPath] / [annotatedPreviewPath] — catalog-powered
  ///    finishing artifacts.
  ///  * [backgroundExtracted] — whether background extraction has been applied.
  ///  * [targetSnr] / [targetIntegrationS] — the master's **achieved anchor**:
  ///    the SNR actually reached (`targetSnr`) at the cumulative integration time
  ///    actually accumulated (`targetIntegrationS`), i.e. the last point of the
  ///    night's marginal-SNR curve. The "how much more?" loop reads this as the
  ///    point it scales by `SNR ∝ sqrt(time)` to project a *current* SNR; the
  ///    user's desired SNR goal is supplied separately as the
  ///    `pushDeficitToScheduler(targetSnr)` argument. (Despite the historical
  ///    `target_` column prefix these are an achieved measurement, NOT a goal —
  ///    do not write a desired-SNR goal here.)
  ///  * [improvementCurveJson] — a serialized [IntegrationCurve]
  ///    (`IntegrationCurve.toJson` → `jsonEncode`); pass the encoded string.
  Future<int> updateSmartFields(
    int id, {
    String? colorCalibratedPath,
    String? annotatedPreviewPath,
    bool? backgroundExtracted,
    double? targetSnr,
    double? targetIntegrationS,
    String? improvementCurveJson,
  }) {
    return _write(
      id,
      IntegratedMastersCompanion(
        colorCalibratedPath: Value.absentIfNull(colorCalibratedPath),
        annotatedPreviewPath: Value.absentIfNull(annotatedPreviewPath),
        backgroundExtracted: Value.absentIfNull(
          backgroundExtracted == null ? null : (backgroundExtracted ? 1 : 0),
        ),
        targetSnr: Value.absentIfNull(targetSnr),
        targetIntegrationS: Value.absentIfNull(targetIntegrationS),
        improvementCurveJson: Value.absentIfNull(improvementCurveJson),
      ),
    );
  }

  /// Persist the master's plate-solved WCS (the v44 CD-matrix columns). Pass the
  /// eight scalars ASTAP / `WcsInfo::from_plate_solve` emit; `updated_at` is
  /// bumped to now. Mirrors [updateSmartFields] (only supplied fields written).
  ///
  /// The CRVAL/CRPIX/CD scalars are stored verbatim, so the projection reads
  /// the solver's own matrix. Once written,
  /// `IntegratedMaster.hasWcs` flips true and the annotation overlay + colour
  /// calibration unblock.
  Future<int> updateWcs(
    int id, {
    required double crval1,
    required double crval2,
    required double crpix1,
    required double crpix2,
    required double cd1_1,
    required double cd1_2,
    required double cd2_1,
    required double cd2_2,
  }) {
    return _write(
      id,
      IntegratedMastersCompanion(
        wcsCrval1: Value(crval1),
        wcsCrval2: Value(crval2),
        wcsCrpix1: Value(crpix1),
        wcsCrpix2: Value(crpix2),
        wcsCd11: Value(cd1_1),
        wcsCd12: Value(cd1_2),
        wcsCd21: Value(cd2_1),
        wcsCd22: Value(cd2_2),
      ),
    );
  }

  /// Persist the v44 finishing-artifact output paths. Only the supplied fields
  /// are written; `updated_at` is always bumped to now. Mirrors
  /// [updateSmartFields] but targets the `_bgx`/`_decon`/`_starred` paths the
  /// gated finishing passes write.
  Future<int> updateFinishingPaths(
    int id, {
    String? backgroundExtractedPath,
    String? deconvolvedPath,
    String? starReducedPath,
  }) {
    return _write(
      id,
      IntegratedMastersCompanion(
        backgroundExtractedPath: Value.absentIfNull(backgroundExtractedPath),
        deconvolvedPath: Value.absentIfNull(deconvolvedPath),
        starReducedPath: Value.absentIfNull(starReducedPath),
      ),
    );
  }

  /// Replace master [oldId] with [newId], a newer build of the same target and
  /// filter at [newPath]: the old master's recipes move to the new one, since
  /// their steps apply to the same target, and the old row is deleted.
  Future<void> replaceMaster({
    required int oldId,
    required String? oldPath,
    required int newId,
    required String newPath,
  }) {
    return transaction(() async {
      await (update(recipes)..where(
            (r) =>
                r.masterId.equals(oldId) |
                r.baseMasterPath.equals(oldPath ?? newPath),
          ))
          .write(
            RecipesCompanion(
              masterId: Value(newId),
              baseMasterPath: Value(newPath),
            ),
          );
      await deleteMaster(oldId);
    });
  }

  /// Delete a master (cascades to its `integrated_master_frames` rows via the FK).
  Future<int> deleteMaster(int id) =>
      (delete(integratedMasters)..where((m) => m.id.equals(id))).go();

  // Integrated_master_frames (join / dedup)

  /// Record that [imageId] was folded into [masterId]. Idempotent: the
  /// `(master_id, image_id)` UNIQUE constraint means a re-fold is an
  /// `INSERT OR REPLACE` that refreshes the weight/residual rather than
  /// duplicating the row. Returns the affected row id.
  ///
  /// [snr] / [fwhm] / [eccentricity] are the v42 per-sub science metrics the
  /// Night Doctor reads after a morning integration (`integrated_master_frames`
  /// additive columns). All three are nullable and default to null so existing
  /// callers stay source-compatible.
  Future<int> recordFoldedFrame({
    required int masterId,
    required int imageId,
    double? weight,
    double? alignmentResidualPx,
    bool accepted = true,
    String? rejectionReason,
    DateTime? foldedAt,
    double? snr,
    double? fwhm,
    double? eccentricity,
  }) {
    return into(integratedMasterFrames).insert(
      IntegratedMasterFramesCompanion.insert(
        masterId: masterId,
        imageId: imageId,
        weight: Value(weight),
        alignmentResidualPx: Value(alignmentResidualPx),
        accepted: Value(accepted ? 1 : 0),
        rejectionReason: Value(rejectionReason),
        foldedAt: toEpochSeconds((foldedAt ?? DateTime.now()).toUtc()),
        snr: Value(snr),
        fwhm: Value(fwhm),
        eccentricity: Value(eccentricity),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  /// Ids of the masters that folded at least one of [imageIds], newest first.
  ///
  /// The *scoping* query for a review surface: `target_id` is frequently NULL on
  /// a master row (a session with no catalog target still integrates), so it
  /// cannot answer "which master belongs to the night I am looking at". The
  /// `integrated_master_frames` join can — it records exactly which subs went
  /// into which master. Session Review uses this so a night that produced no
  /// master shows its empty state instead of the newest master in the library
  /// (which would then be what "Calibrate colour" / "Extract gradient" operate
  /// on).
  ///
  /// [imageIds] is chunked to stay well inside SQLite's bound-variable limit, so
  /// a multi-night target review with thousands of subs is safe to pass whole.
  ///
  /// SQL text on purpose: Session Review runs this over every frame of the
  /// night it opens, and drift's typed join result took it from 1.7 to
  /// 2.3 ms for 3 000 frames.
  Future<List<int>> masterIdsForImages(Iterable<int> imageIds) async {
    final ids = imageIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const [];

    const chunkSize = 400;
    // (created_at, id) per matched master, so the merged result across chunks
    // can be ordered exactly like the single-query newest-first ordering.
    final found = <int, int>{};
    for (var offset = 0; offset < ids.length; offset += chunkSize) {
      final chunk = ids.skip(offset).take(chunkSize).toList(growable: false);
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await customSelect(
        'SELECT DISTINCT m.id AS id, m.created_at AS created_at '
        'FROM integrated_masters m '
        'INNER JOIN integrated_master_frames f ON f.master_id = m.id '
        'WHERE f.image_id IN ($placeholders)',
        variables: [for (final id in chunk) Variable<int>(id)],
      ).get();
      for (final row in rows) {
        found[row.read<int>('id')] = row.read<int>('created_at');
      }
    }

    final ordered = found.keys.toList()
      ..sort((a, b) {
        final byCreated = found[b]!.compareTo(found[a]!);
        return byCreated != 0 ? byCreated : b.compareTo(a);
      });
    return List.unmodifiable(ordered);
  }

  /// The set of `captured_images.id` already folded into [masterId]. The dedup
  /// source of truth: [MasterAccumulationService] subtracts this from the
  /// freshly-selected subs before an `add`.
  Future<Set<int>> getFoldedImageIds(int masterId) async {
    final imageId = integratedMasterFrames.imageId;
    final rows =
        await (selectOnly(integratedMasterFrames)
              ..addColumns([imageId])
              ..where(integratedMasterFrames.masterId.equals(masterId)))
            .get();
    return rows.map((r) => r.read(imageId)!).toSet();
  }

  /// All fold records for a master, newest first.
  Future<List<IntegratedMasterFrame>> getFramesForMaster(int masterId) async {
    final rows =
        await (select(integratedMasterFrames)
              ..where((f) => f.masterId.equals(masterId))
              ..orderBy([
                (f) => OrderingTerm.desc(f.foldedAt),
                (f) => OrderingTerm.desc(f.id),
              ]))
            .get();
    return rows.map((r) {
      return IntegratedMasterFrame(
        id: r.id,
        masterId: r.masterId,
        imageId: r.imageId,
        weight: r.weight,
        alignmentResidualPx: r.alignmentResidualPx,
        accepted: r.accepted != 0,
        rejectionReason: r.rejectionReason,
        foldedAt: fromEpochSeconds(r.foldedAt),
      );
    }).toList();
  }

  SimpleSelectStatement<IntegratedMasters, IntegratedMasterRow> _newestFirst({
    Expression<bool> Function(IntegratedMasters m)? where,
  }) {
    final query = select(integratedMasters)
      ..orderBy([
        (m) => OrderingTerm.desc(m.createdAt),
        (m) => OrderingTerm.desc(m.id),
      ]);
    if (where != null) query.where(where);
    return query;
  }

  /// Writes [changes] to master [id] and bumps `updated_at` to now.
  Future<int> _write(int id, IntegratedMastersCompanion changes) {
    return (update(integratedMasters)..where((m) => m.id.equals(id))).write(
      changes.copyWith(
        updatedAt: Value(toEpochSeconds(DateTime.now().toUtc())),
      ),
    );
  }

  IntegratedMaster _mapMaster(IntegratedMasterRow row) {
    return IntegratedMaster(
      id: row.id,
      targetId: row.targetId,
      name: row.name,
      masterFitsPath: row.masterFitsPath,
      previewPngPath: row.previewPngPath,
      sidecarPath: row.sidecarPath,
      rejectionMapPath: row.rejectionMapPath,
      rejectionMapPreviewPath: row.rejectionMapPreviewPath,
      coverageMapPath: row.coverageMapPath,
      coverageMapPreviewPath: row.coverageMapPreviewPath,
      status: IntegratedMasterStatus.fromWire(row.status),
      accumulationMode: AccumulationMode.fromWire(row.accumulationMode),
      channels: row.channels,
      width: row.width,
      height: row.height,
      frameCount: row.frameCount,
      totalIntegrationSeconds: row.totalIntegrationSeconds,
      filter: row.filter,
      settingsJson: row.settingsJson,
      statsJson: row.statsJson,
      createdAt: fromEpochSeconds(row.createdAt),
      updatedAt: fromEpochSeconds(row.updatedAt),
      wcsCrval1: row.wcsCrval1,
      wcsCrval2: row.wcsCrval2,
      wcsCrpix1: row.wcsCrpix1,
      wcsCrpix2: row.wcsCrpix2,
      wcsCd1_1: row.wcsCd11,
      wcsCd1_2: row.wcsCd12,
      wcsCd2_1: row.wcsCd21,
      wcsCd2_2: row.wcsCd22,
      backgroundExtractedPath: row.backgroundExtractedPath,
      deconvolvedPath: row.deconvolvedPath,
      starReducedPath: row.starReducedPath,
      colorCalibratedPath: row.colorCalibratedPath,
    );
  }
}
