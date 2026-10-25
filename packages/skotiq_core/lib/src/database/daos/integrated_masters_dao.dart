import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/integrated_master.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

/// Data-access object for the v41 `integrated_masters` + `integrated_master_frames`
/// tables — the persisted provenance for every archival integrated master the
/// post-session pipeline produces.
///
/// The tables are managed with raw DDL (see
/// [SkotiqDatabase._createPostSessionTables]) rather than drift `Table`
/// classes, so this DAO is a plain class that reads/writes through the
/// database's `customSelect`/`customStatement`/`customInsert` APIs — mirroring
/// [StackedResultsDao]. It is deliberately NOT a `@DriftAccessor`.
///
/// SQLite errors propagate, the `(master_id, image_id)` UNIQUE constraint
/// guards against double-folding a sub, and reads map nullable columns to the
/// model's nullable fields rather than guessing.
class IntegratedMastersDao {
  IntegratedMastersDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, target_id, name, master_fits_path, '
      'preview_png_path, sidecar_path, rejection_map_path, '
      'rejection_map_preview_path, coverage_map_path, '
      'coverage_map_preview_path, status, '
      'accumulation_mode, channels, width, height, frame_count, '
      'total_integration_seconds, filter, settings_json, stats_json, '
      'created_at, updated_at, '
      // v44 (Phase C): per-master plate-solved WCS (CD-matrix) + finishing paths.
      'wcs_crval1, wcs_crval2, wcs_crpix1, wcs_crpix2, '
      'wcs_cd1_1, wcs_cd1_2, wcs_cd2_1, wcs_cd2_2, '
      'background_extracted_path, deconvolved_path, star_reduced_path, '
      'color_calibrated_path';

  // integrated_masters

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
    return _db.customInsert(
      'INSERT INTO integrated_masters('
      'target_id, name, master_fits_path, preview_png_path, sidecar_path, '
      'rejection_map_path, rejection_map_preview_path, coverage_map_path, '
      'coverage_map_preview_path, status, accumulation_mode, channels, width, height, '
      'frame_count, total_integration_seconds, filter, settings_json, '
      'stats_json, created_at, updated_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(targetId),
        Variable<String>(name),
        Variable<String>(masterFitsPath),
        Variable<String>(previewPngPath),
        Variable<String>(sidecarPath),
        Variable<String>(rejectionMapPath),
        Variable<String>(rejectionMapPreviewPath),
        Variable<String>(coverageMapPath),
        Variable<String>(coverageMapPreviewPath),
        Variable<String>(status.wire),
        Variable<String>(accumulationMode.wire),
        Variable<int>(channels),
        Variable<int>(width),
        Variable<int>(height),
        Variable<int>(frameCount),
        Variable<double>(totalIntegrationSeconds),
        Variable<String>(filter),
        Variable<String>(settingsJson),
        Variable<String>(statsJson),
        Variable<int>(_toEpochSeconds(createdAt ?? now)),
        Variable<int>(_toEpochSeconds(updatedAt ?? now)),
      ],
    );
  }

  /// Fetch a master by id, or null when absent.
  Future<IntegratedMaster?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM integrated_masters WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _mapMaster(rows.first);
  }

  /// All masters, newest first.
  Future<List<IntegratedMaster>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM integrated_masters '
          'ORDER BY created_at DESC, id DESC',
        )
        .get();
    return rows.map(_mapMaster).toList();
  }

  /// Masters for a given target, newest first.
  Future<List<IntegratedMaster>> getForTarget(int targetId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM integrated_masters '
          'WHERE target_id = ? ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(targetId)],
        )
        .get();
    return rows.map(_mapMaster).toList();
  }

  /// The active accumulating master for a (target, filter) pair, or null. Used
  /// by the auto-process hook to decide whether to fold tonight's subs into an
  /// existing master vs. start a one-shot integration.
  Future<IntegratedMaster?> getAccumulatingForTargetFilter({
    required int targetId,
    String? filter,
  }) async {
    final hasFilter = filter != null && filter.trim().isNotEmpty;
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM integrated_masters '
          'WHERE target_id = ? AND status = ? '
          '${hasFilter ? 'AND filter = ?' : 'AND (filter IS NULL OR filter = \'\')'} '
          'ORDER BY created_at DESC, id DESC LIMIT 1',
          variables: [
            Variable<int>(targetId),
            Variable<String>(IntegratedMasterStatus.accumulating.wire),
            if (hasFilter) Variable<String>(filter.trim()),
          ],
        )
        .get();
    if (rows.isEmpty) return null;
    return _mapMaster(rows.first);
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
    final sets = <String>['updated_at = ?'];
    final vars = <Variable<Object>>[
      Variable<int>(_toEpochSeconds(DateTime.now().toUtc())),
    ];
    void put(String col, Variable<Object> v) {
      sets.add('$col = ?');
      vars.add(v);
    }

    if (masterFitsPath != null) {
      put('master_fits_path', Variable<String>(masterFitsPath));
    }
    if (previewPngPath != null) {
      put('preview_png_path', Variable<String>(previewPngPath));
    }
    if (rejectionMapPath != null) {
      put('rejection_map_path', Variable<String>(rejectionMapPath));
    }
    if (rejectionMapPreviewPath != null) {
      put(
        'rejection_map_preview_path',
        Variable<String>(rejectionMapPreviewPath),
      );
    }
    if (coverageMapPath != null) {
      put('coverage_map_path', Variable<String>(coverageMapPath));
    }
    if (coverageMapPreviewPath != null) {
      put(
        'coverage_map_preview_path',
        Variable<String>(coverageMapPreviewPath),
      );
    }
    if (status != null) put('status', Variable<String>(status.wire));
    if (channels != null) put('channels', Variable<int>(channels));
    if (width != null) put('width', Variable<int>(width));
    if (height != null) put('height', Variable<int>(height));
    if (frameCount != null) put('frame_count', Variable<int>(frameCount));
    if (totalIntegrationSeconds != null) {
      put(
        'total_integration_seconds',
        Variable<double>(totalIntegrationSeconds),
      );
    }
    if (statsJson != null) put('stats_json', Variable<String>(statsJson));

    vars.add(Variable<int>(id));
    return _db.customUpdate(
      'UPDATE integrated_masters SET ${sets.join(', ')} WHERE id = ?',
      variables: vars,
      updateKind: UpdateKind.update,
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
    final sets = <String>['updated_at = ?'];
    final vars = <Variable<Object>>[
      Variable<int>(_toEpochSeconds(DateTime.now().toUtc())),
    ];
    void put(String col, Variable<Object> v) {
      sets.add('$col = ?');
      vars.add(v);
    }

    if (colorCalibratedPath != null) {
      put('color_calibrated_path', Variable<String>(colorCalibratedPath));
    }
    if (annotatedPreviewPath != null) {
      put('annotated_preview_path', Variable<String>(annotatedPreviewPath));
    }
    if (backgroundExtracted != null) {
      put('background_extracted', Variable<int>(backgroundExtracted ? 1 : 0));
    }
    if (targetSnr != null) put('target_snr', Variable<double>(targetSnr));
    if (targetIntegrationS != null) {
      put('target_integration_s', Variable<double>(targetIntegrationS));
    }
    if (improvementCurveJson != null) {
      put('improvement_curve_json', Variable<String>(improvementCurveJson));
    }

    vars.add(Variable<int>(id));
    return _db.customUpdate(
      'UPDATE integrated_masters SET ${sets.join(', ')} WHERE id = ?',
      variables: vars,
      updateKind: UpdateKind.update,
    );
  }

  /// Persist the master's plate-solved WCS (the v44 CD-matrix columns). Pass the
  /// eight scalars ASTAP / `WcsInfo::from_plate_solve` emit; `updated_at` is
  /// bumped to now. Mirrors [updateSmartFields] (only supplied fields written).
  ///
  /// The CRVAL/CRPIX/CD scalars are stored verbatim so the `WcsOverlay` reader
  /// can derive cdelt/crota from the CD matrix using the same sign convention as
  /// the native source of truth (`imaging/src/fits.rs`). Once written,
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
    return _db.customUpdate(
      'UPDATE integrated_masters SET '
      'wcs_crval1 = ?, wcs_crval2 = ?, wcs_crpix1 = ?, wcs_crpix2 = ?, '
      'wcs_cd1_1 = ?, wcs_cd1_2 = ?, wcs_cd2_1 = ?, wcs_cd2_2 = ?, '
      'updated_at = ? WHERE id = ?',
      variables: [
        Variable<double>(crval1),
        Variable<double>(crval2),
        Variable<double>(crpix1),
        Variable<double>(crpix2),
        Variable<double>(cd1_1),
        Variable<double>(cd1_2),
        Variable<double>(cd2_1),
        Variable<double>(cd2_2),
        Variable<int>(_toEpochSeconds(DateTime.now().toUtc())),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
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
    final sets = <String>['updated_at = ?'];
    final vars = <Variable<Object>>[
      Variable<int>(_toEpochSeconds(DateTime.now().toUtc())),
    ];
    void put(String col, Variable<Object> v) {
      sets.add('$col = ?');
      vars.add(v);
    }

    if (backgroundExtractedPath != null) {
      put(
        'background_extracted_path',
        Variable<String>(backgroundExtractedPath),
      );
    }
    if (deconvolvedPath != null) {
      put('deconvolved_path', Variable<String>(deconvolvedPath));
    }
    if (starReducedPath != null) {
      put('star_reduced_path', Variable<String>(starReducedPath));
    }

    vars.add(Variable<int>(id));
    return _db.customUpdate(
      'UPDATE integrated_masters SET ${sets.join(', ')} WHERE id = ?',
      variables: vars,
      updateKind: UpdateKind.update,
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
    return _db.transaction(() async {
      await _db.customUpdate(
        'UPDATE recipes SET master_id = ?, base_master_path = ? '
        'WHERE master_id = ? OR base_master_path = ?',
        variables: [
          Variable<int>(newId),
          Variable<String>(newPath),
          Variable<int>(oldId),
          Variable<String>(oldPath ?? newPath),
        ],
        updateKind: UpdateKind.update,
      );
      await deleteMaster(oldId);
    });
  }

  /// Delete a master (cascades to its `integrated_master_frames` rows via the FK).
  Future<int> deleteMaster(int id) {
    return _db.customUpdate(
      'DELETE FROM integrated_masters WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
  }

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
    return _db.customInsert(
      'INSERT OR REPLACE INTO integrated_master_frames('
      'master_id, image_id, weight, alignment_residual_px, accepted, '
      'rejection_reason, folded_at, snr, fwhm, eccentricity'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(masterId),
        Variable<int>(imageId),
        Variable<double>(weight),
        Variable<double>(alignmentResidualPx),
        Variable<int>(accepted ? 1 : 0),
        Variable<String>(rejectionReason),
        Variable<int>(_toEpochSeconds((foldedAt ?? DateTime.now()).toUtc())),
        Variable<double>(snr),
        Variable<double>(fwhm),
        Variable<double>(eccentricity),
      ],
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
      final rows = await _db
          .customSelect(
            'SELECT DISTINCT m.id AS id, m.created_at AS created_at '
            'FROM integrated_masters m '
            'INNER JOIN integrated_master_frames f ON f.master_id = m.id '
            'WHERE f.image_id IN ($placeholders)',
            variables: [for (final id in chunk) Variable<int>(id)],
          )
          .get();
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
    final rows = await _db
        .customSelect(
          'SELECT image_id FROM integrated_master_frames WHERE master_id = ?',
          variables: [Variable<int>(masterId)],
        )
        .get();
    return rows.map((r) => r.read<int>('image_id')).toSet();
  }

  /// All fold records for a master, newest first.
  Future<List<IntegratedMasterFrame>> getFramesForMaster(int masterId) async {
    final rows = await _db
        .customSelect(
          'SELECT id, master_id, image_id, weight, alignment_residual_px, '
          'accepted, rejection_reason, folded_at '
          'FROM integrated_master_frames WHERE master_id = ? '
          'ORDER BY folded_at DESC, id DESC',
          variables: [Variable<int>(masterId)],
        )
        .get();
    return rows.map((r) {
      return IntegratedMasterFrame(
        id: r.read<int>('id'),
        masterId: r.read<int>('master_id'),
        imageId: r.read<int>('image_id'),
        weight: r.readNullable<double>('weight'),
        alignmentResidualPx: r.readNullable<double>('alignment_residual_px'),
        accepted: r.read<int>('accepted') != 0,
        rejectionReason: r.readNullable<String>('rejection_reason'),
        foldedAt: _fromEpochSeconds(r.read<int>('folded_at')),
      );
    }).toList();
  }

  IntegratedMaster _mapMaster(QueryRow row) {
    return IntegratedMaster(
      id: row.read<int>('id'),
      targetId: row.readNullable<int>('target_id'),
      name: row.read<String>('name'),
      masterFitsPath: row.readNullable<String>('master_fits_path'),
      previewPngPath: row.readNullable<String>('preview_png_path'),
      sidecarPath: row.readNullable<String>('sidecar_path'),
      rejectionMapPath: row.readNullable<String>('rejection_map_path'),
      rejectionMapPreviewPath: row.readNullable<String>(
        'rejection_map_preview_path',
      ),
      coverageMapPath: row.readNullable<String>('coverage_map_path'),
      coverageMapPreviewPath: row.readNullable<String>(
        'coverage_map_preview_path',
      ),
      status: IntegratedMasterStatus.fromWire(row.read<String>('status')),
      accumulationMode: AccumulationMode.fromWire(
        row.read<String>('accumulation_mode'),
      ),
      channels: row.read<int>('channels'),
      width: row.read<int>('width'),
      height: row.read<int>('height'),
      frameCount: row.read<int>('frame_count'),
      totalIntegrationSeconds: row.read<double>('total_integration_seconds'),
      filter: row.readNullable<String>('filter'),
      settingsJson: row.read<String>('settings_json'),
      statsJson: row.read<String>('stats_json'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
      updatedAt: _fromEpochSeconds(row.read<int>('updated_at')),
      wcsCrval1: row.readNullable<double>('wcs_crval1'),
      wcsCrval2: row.readNullable<double>('wcs_crval2'),
      wcsCrpix1: row.readNullable<double>('wcs_crpix1'),
      wcsCrpix2: row.readNullable<double>('wcs_crpix2'),
      wcsCd1_1: row.readNullable<double>('wcs_cd1_1'),
      wcsCd1_2: row.readNullable<double>('wcs_cd1_2'),
      wcsCd2_1: row.readNullable<double>('wcs_cd2_1'),
      wcsCd2_2: row.readNullable<double>('wcs_cd2_2'),
      backgroundExtractedPath: row.readNullable<String>(
        'background_extracted_path',
      ),
      deconvolvedPath: row.readNullable<String>('deconvolved_path'),
      starReducedPath: row.readNullable<String>('star_reduced_path'),
      colorCalibratedPath: row.readNullable<String>('color_calibrated_path'),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [IntegratedMastersDao].
final integratedMastersDaoProvider = Provider<IntegratedMastersDao>((ref) {
  return IntegratedMastersDao(ref.watch(databaseProvider));
});
