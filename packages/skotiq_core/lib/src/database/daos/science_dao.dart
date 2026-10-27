import 'package:drift/drift.dart';

import '../../models/science/science_models.dart' as science;
import '../database.dart';
import '../tables/science.dart';

part 'science_dao.g.dart';

@DriftAccessor(
  tables: [
    ScienceSessionConfig,
    PhotometryMeasurements,
    FramePhotometricCalibration,
    TransparencySamples,
    PsfFieldTiles,
    ScienceFrameQualityMetrics,
    ScienceTileMetrics,
    AstrometryResidualVectors,
    MovingObjectCandidates,
    LineRatioProducts,
    PhotometricTransforms,
  ],
)
class ScienceDao extends DatabaseAccessor<SkotiqDatabase>
    with _$ScienceDaoMixin {
  ScienceDao(super.db);

  Future<void> upsertSessionConfig(science.ScienceSessionConfig config) async {
    if (config.sessionId == null) {
      return;
    }

    await transaction(() async {
      final existing =
          await (select(scienceSessionConfig)
                ..where((tbl) => tbl.sessionId.equals(config.sessionId!)))
              .getSingleOrNull();

      final companion = ScienceSessionConfigCompanion(
        sessionId: Value(config.sessionId),
        photometryEnabled: Value(config.photometryEnabled),
        calibrationEnabled: Value(config.calibrationEnabled),
        transparencyEnabled: Value(config.transparencyEnabled),
        psfMapEnabled: Value(config.psfMapEnabled),
        residualsEnabled: Value(config.residualsEnabled),
        movingObjectsEnabled: Value(config.movingObjectsEnabled),
        narrowbandEnabled: Value(config.narrowbandEnabled),
        psfGridRows: Value(config.psfGridRows),
        psfGridCols: Value(config.psfGridCols),
        transparencyAlertThreshold: Value(config.transparencyAlertThreshold),
        updatedAt: Value(DateTime.now()),
      );

      if (existing == null) {
        await into(scienceSessionConfig).insert(companion);
      } else {
        await (update(
          scienceSessionConfig,
        )..where((tbl) => tbl.id.equals(existing.id))).write(companion);
      }
    });
  }

  Stream<ScienceSessionConfigRow?> watchSessionConfig(int sessionId) {
    return (select(
      scienceSessionConfig,
    )..where((tbl) => tbl.sessionId.equals(sessionId))).watchSingleOrNull();
  }

  Future<void> insertPhotometryMeasurements(
    List<PhotometryMeasurementsCompanion> entries,
  ) async {
    if (entries.isEmpty) {
      return;
    }
    await batch((batch) {
      batch.insertAll(photometryMeasurements, entries);
    });
  }

  Future<void> replacePhotometryMeasurementsForImage(
    int capturedImageId,
    List<PhotometryMeasurementsCompanion> entries,
  ) async {
    await transaction(() async {
      await (delete(
        photometryMeasurements,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      if (entries.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(photometryMeasurements, entries);
      });
    });
  }

  Stream<List<PhotometryMeasurementRow>> watchLightCurve(
    int sessionId,
    String objectId,
  ) {
    return (select(photometryMeasurements)
          ..where(
            (tbl) =>
                tbl.sessionId.equals(sessionId) & tbl.objectId.equals(objectId),
          )
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .watch();
  }

  Stream<List<PhotometryMeasurementRow>> watchPhotometryForSession(
    int sessionId,
  ) {
    return (select(photometryMeasurements)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .watch();
  }

  /// Every session that recorded at least one photometry measurement.
  ///
  /// Used to choose which night the Science tab opens on, so a couple of test
  /// frames taken after a photometry run cannot bury the run they follow.
  Future<Set<int>> getSessionIdsWithPhotometry() async {
    final query = selectOnly(photometryMeasurements, distinct: true)
      ..addColumns([photometryMeasurements.sessionId])
      ..where(photometryMeasurements.sessionId.isNotNull());
    final rows = await query.get();
    return rows
        .map((row) => row.read(photometryMeasurements.sessionId))
        .whereType<int>()
        .toSet();
  }

  /// The check star a session's differential photometry already uses, so
  /// every frame of the session is checked against the same star.
  Future<String?> getSessionCheckStarId(int sessionId) async {
    final row =
        await (select(photometryMeasurements)
              ..where(
                (tbl) =>
                    tbl.sessionId.equals(sessionId) & tbl.role.equals('check'),
              )
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)])
              ..limit(1))
            .getSingleOrNull();
    return row?.objectId;
  }

  Future<List<PhotometryMeasurementRow>> getPhotometryForSession(
    int sessionId,
  ) {
    return (select(photometryMeasurements)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .get();
  }

  /// Every measurement of one object across all sessions that imaged a target.
  ///
  /// Period searches need a baseline longer than the period they are looking
  /// for, and almost no variable star or transit fits inside a single night —
  /// a per-session light curve can only ever report "the period is at least as
  /// long as this run". Joining through `captured_images.target_id` keeps the
  /// campaign together even though photometry rows themselves only know their
  /// session.
  Stream<List<PhotometryMeasurementRow>> watchPhotometryForTarget({
    required int targetId,
    required String objectId,
  }) {
    final query =
        select(photometryMeasurements).join([
            innerJoin(
              capturedImages,
              capturedImages.id.equalsExp(
                photometryMeasurements.capturedImageId,
              ),
            ),
          ])
          ..where(
            capturedImages.targetId.equals(targetId) &
                photometryMeasurements.objectId.equals(objectId),
          )
          ..orderBy([OrderingTerm.asc(photometryMeasurements.timestamp)]);
    return query.watch().map(
      (rows) => rows
          .map((row) => row.readTable(photometryMeasurements))
          .toList(growable: false),
    );
  }

  /// Ids of the session's captured frames that already have any per-frame
  /// science product (frame quality, photometric calibration, PSF tiles or
  /// photometry), keyed by the frame's own session.
  Future<Set<int>> getCapturedImageIdsWithScience(int sessionId) async {
    final rows = await customSelect(
      'SELECT ci.id AS id FROM captured_images ci '
      'WHERE ci.session_id = ? AND ('
      'EXISTS (SELECT 1 FROM science_frame_quality_metrics m '
      'WHERE m.captured_image_id = ci.id) OR '
      'EXISTS (SELECT 1 FROM frame_photometric_calibration c '
      'WHERE c.captured_image_id = ci.id) OR '
      'EXISTS (SELECT 1 FROM psf_field_tiles t '
      'WHERE t.captured_image_id = ci.id) OR '
      'EXISTS (SELECT 1 FROM photometry_measurements p '
      'WHERE p.captured_image_id = ci.id))',
      variables: [Variable.withInt(sessionId)],
      readsFrom: {
        attachedDatabase.capturedImages,
        scienceFrameQualityMetrics,
        framePhotometricCalibration,
        psfFieldTiles,
        photometryMeasurements,
      },
    ).get();
    return rows.map((row) => row.read<int>('id')).toSet();
  }

  Future<void> insertFrameCalibration(
    FramePhotometricCalibrationCompanion calibration,
  ) {
    return into(framePhotometricCalibration).insert(calibration);
  }

  Future<void> replaceFrameCalibrationForImage(
    int capturedImageId,
    FramePhotometricCalibrationCompanion calibration,
  ) async {
    await transaction(() async {
      await (delete(
        framePhotometricCalibration,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      await into(framePhotometricCalibration).insert(calibration);
    });
  }

  Stream<List<FramePhotometricCalibrationRow>> watchCalibrationsForSession(
    int sessionId,
  ) {
    return (select(framePhotometricCalibration)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .watch();
  }

  Future<List<FramePhotometricCalibrationRow>> getCalibrationsForSession(
    int sessionId,
  ) {
    return (select(framePhotometricCalibration)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .get();
  }

  /// The session's newest calibrated frames, newest first. With
  /// [atOrBefore], only frames calibrated at or before that time, so a frame
  /// processed after later ones (a reprocess) sees the history it was
  /// captured with.
  /// The session's calibrated frames, newest first. With [filter], only
  /// frames taken in that filter.
  Future<List<FramePhotometricCalibrationRow>> getRecentCalibrations(
    int sessionId, {
    int limit = 20,
    DateTime? atOrBefore,
    String? filter,
  }) {
    return (select(framePhotometricCalibration)
          ..where((tbl) {
            var where =
                tbl.sessionId.equals(sessionId) & tbl.isCalibrated.equals(true);
            if (atOrBefore != null) {
              where = where & tbl.timestamp.isSmallerOrEqualValue(atOrBefore);
            }
            if (filter != null) {
              where = where & tbl.filter.equals(filter);
            }
            return where;
          })
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(limit))
        .get();
  }

  Future<void> insertTransparencySample(TransparencySamplesCompanion sample) {
    return into(transparencySamples).insert(sample);
  }

  Future<void> replaceTransparencySampleForImage(
    int capturedImageId,
    TransparencySamplesCompanion sample,
  ) async {
    await transaction(() async {
      await (delete(
        transparencySamples,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      await into(transparencySamples).insert(sample);
    });
  }

  /// Remove [capturedImageId]'s transparency sample, so a frame processed
  /// again without one does not keep an old value.
  Future<void> deleteTransparencySampleForImage(int capturedImageId) {
    return (delete(
      transparencySamples,
    )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
  }

  /// Remove [capturedImageId]'s calibration, so a frame processed again
  /// whose fit is refused does not keep an old zero point.
  Future<void> deleteFrameCalibrationForImage(int capturedImageId) {
    return (delete(
      framePhotometricCalibration,
    )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
  }

  Stream<List<TransparencySampleRow>> watchTransparencyForSession(
    int sessionId,
  ) {
    return (select(transparencySamples)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .watch();
  }

  Future<List<TransparencySampleRow>> getTransparencyForSession(int sessionId) {
    return (select(transparencySamples)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .get();
  }

  Future<void> replacePsfTilesForImage(
    int capturedImageId,
    List<PsfFieldTilesCompanion> tiles,
  ) async {
    await transaction(() async {
      await (delete(
        psfFieldTiles,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      if (tiles.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(psfFieldTiles, tiles);
      });
    });
  }

  Stream<List<PsfFieldTileRow>> watchPsfTilesForSession(int sessionId) {
    return (select(psfFieldTiles)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ]))
        .watch();
  }

  /// Replaced spatial maps have new autoincrement row IDs. A count/max-ID
  /// fingerprint per image detects additions, replacements and deletions
  /// without materializing hundreds of thousands of pixel-map rows.
  Future<Map<String, String>> spatialMapVersions(
    int sessionId,
    String product,
  ) async {
    final TableInfo<Table, dynamic> table = switch (product) {
      'psfTiles' => psfFieldTiles,
      'tileMetrics' => scienceTileMetrics,
      'residuals' => astrometryResidualVectors,
      _ => throw ArgumentError.value(product, 'product'),
    };
    final rows = await customSelect(
      'SELECT captured_image_id, COUNT(*) AS n, MAX(id) AS last_id '
      'FROM ${table.actualTableName} WHERE session_id = ? GROUP BY captured_image_id',
      variables: [Variable.withInt(sessionId)],
      readsFrom: {table},
    ).get();
    return {
      for (final row in rows)
        (row.readNullable<int>('captured_image_id')?.toString() ?? 'none'):
            '${row.read<int>('n')}:${row.read<int>('last_id')}',
    };
  }

  Expression<bool> _spatialImages(
    GeneratedColumn<int> column,
    Set<int?> images,
  ) =>
      column.isIn(images.whereType<int>()) |
      (images.contains(null) ? column.isNull() : const Constant(false));

  Future<List<PsfFieldTileRow>> getPsfTilesForSession(
    int sessionId, {
    Set<int?>? imageIds,
  }) {
    return (select(psfFieldTiles)
          ..where(
            (tbl) =>
                tbl.sessionId.equals(sessionId) &
                (imageIds == null
                    ? const Constant(true)
                    : _spatialImages(tbl.capturedImageId, imageIds)),
          )
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ]))
        .get();
  }

  /// The PSF field tiles for a single captured sub — the per-sub field map the
  /// Morning Report workbench renders.
  Future<List<PsfFieldTileRow>> getPsfTilesForImage(int capturedImageId) {
    return (select(psfFieldTiles)
          ..where((tbl) => tbl.capturedImageId.equals(capturedImageId))
          ..orderBy([
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ]))
        .get();
  }

  Future<void> insertFrameQualityMetrics(
    ScienceFrameQualityMetricsCompanion metrics,
  ) {
    return into(scienceFrameQualityMetrics).insert(metrics);
  }

  Future<void> replaceFrameQualityMetricsForImage(
    int capturedImageId,
    ScienceFrameQualityMetricsCompanion metrics,
  ) async {
    await transaction(() async {
      await (delete(
        scienceFrameQualityMetrics,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      await into(scienceFrameQualityMetrics).insert(metrics);
    });
  }

  Stream<List<ScienceFrameQualityMetricsRow>>
  watchFrameQualityMetricsForSession(int sessionId) {
    return (select(scienceFrameQualityMetrics)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .watch();
  }

  Future<List<ScienceFrameQualityMetricsRow>> getFrameQualityMetricsForSession(
    int sessionId,
  ) {
    return (select(scienceFrameQualityMetrics)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .get();
  }

  Stream<ScienceFrameQualityMetricsRow?> watchFrameQualityMetricsForImage(
    int capturedImageId,
  ) {
    return (select(scienceFrameQualityMetrics)
          ..where((tbl) => tbl.capturedImageId.equals(capturedImageId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<void> replaceTileMetricsForImage(
    int capturedImageId,
    List<ScienceTileMetricsCompanion> tiles,
  ) async {
    await transaction(() async {
      await (delete(
        scienceTileMetrics,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      if (tiles.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(scienceTileMetrics, tiles);
      });
    });
  }

  Future<void> insertTileMetrics(
    List<ScienceTileMetricsCompanion> tiles,
  ) async {
    if (tiles.isEmpty) {
      return;
    }
    await batch((batch) {
      batch.insertAll(scienceTileMetrics, tiles);
    });
  }

  Future<void> replaceTileMetricsForImageLayer(
    int capturedImageId,
    String layerType,
    List<ScienceTileMetricsCompanion> tiles,
  ) async {
    await transaction(() async {
      await (delete(scienceTileMetrics)..where(
            (tbl) =>
                tbl.capturedImageId.equals(capturedImageId) &
                tbl.layerType.equals(layerType),
          ))
          .go();
      if (tiles.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(scienceTileMetrics, tiles);
      });
    });
  }

  Stream<List<ScienceTileMetricRow>> watchTileMetricsForSession(int sessionId) {
    return (select(scienceTileMetrics)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ]))
        .watch();
  }

  Future<List<ScienceTileMetricRow>> getTileMetricsForSession(
    int sessionId, {
    Set<int?>? imageIds,
  }) {
    return (select(scienceTileMetrics)
          ..where(
            (tbl) =>
                tbl.sessionId.equals(sessionId) &
                (imageIds == null
                    ? const Constant(true)
                    : _spatialImages(tbl.capturedImageId, imageIds)),
          )
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ]))
        .get();
  }

  Stream<List<ScienceTileMetricRow>> watchTileMetricsForSessionLayer(
    int sessionId,
    String layerType,
  ) {
    return (select(scienceTileMetrics)
          ..where(
            (tbl) =>
                tbl.sessionId.equals(sessionId) &
                tbl.layerType.equals(layerType),
          )
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ]))
        .watch();
  }

  Future<void> replaceResidualVectorsForImage(
    int capturedImageId,
    List<AstrometryResidualVectorsCompanion> vectors,
  ) async {
    await transaction(() async {
      await (delete(
        astrometryResidualVectors,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      if (vectors.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(astrometryResidualVectors, vectors);
      });
    });
  }

  Stream<List<AstrometryResidualVectorRow>> watchResidualsForSession(
    int sessionId,
  ) {
    return (select(astrometryResidualVectors)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .watch();
  }

  Future<List<AstrometryResidualVectorRow>> getResidualsForSession(
    int sessionId, {
    Set<int?>? imageIds,
  }) {
    return (select(astrometryResidualVectors)
          ..where(
            (tbl) =>
                tbl.sessionId.equals(sessionId) &
                (imageIds == null
                    ? const Constant(true)
                    : _spatialImages(tbl.capturedImageId, imageIds)),
          )
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .get();
  }

  Future<void> insertMovingObjectCandidates(
    List<MovingObjectCandidatesCompanion> candidates,
  ) async {
    if (candidates.isEmpty) {
      return;
    }
    await batch((batch) {
      batch.insertAll(movingObjectCandidates, candidates);
    });
  }

  Future<void> replaceMovingObjectCandidatesForImage(
    int capturedImageId,
    List<MovingObjectCandidatesCompanion> candidates,
  ) async {
    await transaction(() async {
      await (delete(
        movingObjectCandidates,
      )..where((tbl) => tbl.capturedImageId.equals(capturedImageId))).go();
      if (candidates.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(movingObjectCandidates, candidates);
      });
    });
  }

  Stream<List<MovingObjectCandidateRow>> watchMovingObjectsForSession(
    int sessionId,
  ) {
    return (select(movingObjectCandidates)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.confidence)]))
        .watch();
  }

  Future<List<MovingObjectCandidateRow>> getMovingObjectsForSession(
    int sessionId,
  ) {
    return (select(movingObjectCandidates)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.confidence)]))
        .get();
  }

  /// Get all moving object candidates matching a candidateId across all
  /// sessions. Used for multi-night linking -- finding the same object
  /// across different imaging nights for MPC reporting.
  Future<List<MovingObjectCandidateRow>> getMovingObjectsByCandidateId(
    String candidateId,
  ) async {
    return (select(movingObjectCandidates)
          ..where((tbl) => tbl.candidateId.equals(candidateId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)]))
        .get();
  }

  /// Get all moving object candidates across all sessions, ordered by
  /// timestamp. Used for MPC export multi-night linking.
  Future<List<MovingObjectCandidateRow>> getAllMovingObjectCandidates() async {
    return (select(
      movingObjectCandidates,
    )..orderBy([(tbl) => OrderingTerm.asc(tbl.timestamp)])).get();
  }

  Future<void> insertLineRatioProduct(LineRatioProductsCompanion product) {
    return into(lineRatioProducts).insert(product);
  }

  Stream<List<LineRatioProductRow>> watchLineRatiosForSession(int sessionId) {
    return (select(lineRatioProducts)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .watch();
  }

  Future<List<LineRatioProductRow>> getLineRatiosForSession(int sessionId) {
    return (select(lineRatioProducts)
          ..where((tbl) => tbl.sessionId.equals(sessionId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .get();
  }

  // Standalone (sessionless) queries — for snapshots taken outside sequences

  Stream<List<FramePhotometricCalibrationRow>>
  watchSessionlessCalibrationsRecent({int limit = 50}) {
    return (select(framePhotometricCalibration)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(limit))
        .watch();
  }

  Stream<List<TransparencySampleRow>> watchSessionlessTransparencyRecent({
    int limit = 50,
  }) {
    return (select(transparencySamples)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(limit))
        .watch();
  }

  Stream<List<PsfFieldTileRow>> watchSessionlessPsfTilesRecent({
    int limit = 500,
  }) {
    return (select(psfFieldTiles)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ])
          ..limit(limit))
        .watch();
  }

  Stream<List<ScienceFrameQualityMetricsRow>>
  watchSessionlessFrameQualityMetricsRecent({int limit = 50}) {
    return (select(scienceFrameQualityMetrics)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(limit))
        .watch();
  }

  Stream<List<ScienceTileMetricRow>> watchSessionlessTileMetricsRecent({
    int limit = 500,
  }) {
    return (select(scienceTileMetrics)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ])
          ..limit(limit))
        .watch();
  }

  Stream<List<AstrometryResidualVectorRow>> watchSessionlessResidualsRecent({
    int limit = 200,
  }) {
    return (select(astrometryResidualVectors)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(limit))
        .watch();
  }

  Stream<List<MovingObjectCandidateRow>> watchSessionlessMovingObjectsRecent({
    int limit = 50,
  }) {
    return (select(movingObjectCandidates)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.confidence)])
          ..limit(limit))
        .watch();
  }

  Stream<List<PhotometryMeasurementRow>> watchSessionlessPhotometryRecent({
    int limit = 200,
  }) {
    return (select(photometryMeasurements)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(limit))
        .watch();
  }

  Stream<List<LineRatioProductRow>> watchSessionlessLineRatiosRecent({
    int limit = 10,
  }) {
    return (select(lineRatioProducts)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)])
          ..limit(limit))
        .watch();
  }

  // Standalone (sessionless) EXPORT queries — complete, un-capped datasets
  //
  // The `watchSessionless*Recent({limit})` streams above are UI *preview* feeds:
  // they cap at a recent-data window so a list/chart stays cheap. Reusing them
  // for CSV export silently dropped 27–62% of the user's science data (measured:
  // 275 photometry rows in the DB, 200 in the file; 1320 PSF tiles, 500 in the
  // file) while the confirmation truthfully reported only the truncated count.
  // Exports read these instead: same filter and ordering, no limit.

  /// Every session-less photometry measurement, newest first.
  Future<List<PhotometryMeasurementRow>> getAllSessionlessPhotometry() {
    return (select(photometryMeasurements)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)]))
        .get();
  }

  /// Every session-less frame-quality metric row, newest first.
  Future<List<ScienceFrameQualityMetricsRow>>
  getAllSessionlessFrameQualityMetrics() {
    return (select(scienceFrameQualityMetrics)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)]))
        .get();
  }

  /// Every session-less transparency sample, newest first.
  Future<List<TransparencySampleRow>> getAllSessionlessTransparency() {
    return (select(transparencySamples)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)]))
        .get();
  }

  /// Every session-less PSF field tile, newest frame first then tile order.
  Future<List<PsfFieldTileRow>> getAllSessionlessPsfTiles() {
    return (select(psfFieldTiles)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([
            (tbl) => OrderingTerm.desc(tbl.timestamp),
            (tbl) => OrderingTerm.asc(tbl.tileRow),
            (tbl) => OrderingTerm.asc(tbl.tileCol),
          ]))
        .get();
  }

  /// Every session-less astrometric residual vector, newest first.
  Future<List<AstrometryResidualVectorRow>> getAllSessionlessResiduals() {
    return (select(astrometryResidualVectors)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)]))
        .get();
  }

  /// Every session-less photometric-calibration row, newest first.
  Future<List<FramePhotometricCalibrationRow>> getAllSessionlessCalibrations() {
    return (select(framePhotometricCalibration)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)]))
        .get();
  }

  /// Every session-less moving-object candidate, most confident first.
  Future<List<MovingObjectCandidateRow>> getAllSessionlessMovingObjects() {
    return (select(movingObjectCandidates)
          ..where((tbl) => tbl.sessionId.isNull())
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.confidence)]))
        .get();
  }

  /// Returns true if any sessionless science data exists (for showing the
  /// standalone tab even when no sequence session is available).
  Future<bool> hasSessionlessScienceData() async {
    final countExp = scienceFrameQualityMetrics.id.count();
    final query = selectOnly(scienceFrameQualityMetrics)
      ..addColumns([countExp])
      ..where(scienceFrameQualityMetrics.sessionId.isNull());
    final result = await query.getSingle();
    return (result.read(countExp) ?? 0) > 0;
  }

  // Photometric transform coefficients

  Future<int> insertPhotometricTransform(
    PhotometricTransformsCompanion transform,
  ) {
    return into(photometricTransforms).insert(transform);
  }

  Future<void> deletePhotometricTransform(int id) {
    return (delete(
      photometricTransforms,
    )..where((tbl) => tbl.id.equals(id))).go();
  }

  Stream<List<PhotometricTransformRow>> watchAllTransforms() {
    return (select(
      photometricTransforms,
    )..orderBy([(tbl) => OrderingTerm.desc(tbl.dateComputed)])).watch();
  }

  Future<List<PhotometricTransformRow>> getAllTransforms() {
    return (select(
      photometricTransforms,
    )..orderBy([(tbl) => OrderingTerm.desc(tbl.dateComputed)])).get();
  }

  Future<PhotometricTransformRow?> getTransformForFilter(
    String filterName, {
    int? equipmentProfileId,
  }) {
    final query = select(photometricTransforms)
      ..where((tbl) => tbl.filterName.equals(filterName))
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.dateComputed)])
      ..limit(1);
    if (equipmentProfileId != null) {
      query.where(
        (tbl) =>
            tbl.equipmentProfileId.equals(equipmentProfileId) |
            tbl.equipmentProfileId.isNull(),
      );
    }
    return query.getSingleOrNull();
  }

  Stream<List<PhotometricTransformRow>> watchTransformsForProfile(
    int? equipmentProfileId,
  ) {
    if (equipmentProfileId == null) {
      return (select(photometricTransforms)
            ..where((tbl) => tbl.equipmentProfileId.isNull())
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.dateComputed)]))
          .watch();
    }
    return (select(photometricTransforms)
          ..where(
            (tbl) =>
                tbl.equipmentProfileId.equals(equipmentProfileId) |
                tbl.equipmentProfileId.isNull(),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.dateComputed)]))
        .watch();
  }

  // Paginated per-table reads for the remote read API.
  //
  // Why these are a separate group: existing per-session methods load the
  // entire table for a session (no pagination, no `total`). The remote
  // surface needs newest-first slices with offsets so a phone can stream
  // history without dragging the full dataset over the network.
  // Each method accepts an optional `sessionId` filter and pagination
  // bounds. Callers MUST clamp `limit`/`offset` before delegating.

  Future<List<PhotometryMeasurementRow>> listPhotometryPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(photometryMeasurements)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countPhotometry({int? sessionId}) async {
    final expr = photometryMeasurements.id.count();
    final q = selectOnly(photometryMeasurements)..addColumns([expr]);
    if (sessionId != null) {
      q.where(photometryMeasurements.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<FramePhotometricCalibrationRow>> listCalibrationsPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(framePhotometricCalibration)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countCalibrations({int? sessionId}) async {
    final expr = framePhotometricCalibration.id.count();
    final q = selectOnly(framePhotometricCalibration)..addColumns([expr]);
    if (sessionId != null) {
      q.where(framePhotometricCalibration.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<TransparencySampleRow>> listTransparencyPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(transparencySamples)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countTransparency({int? sessionId}) async {
    final expr = transparencySamples.id.count();
    final q = selectOnly(transparencySamples)..addColumns([expr]);
    if (sessionId != null) {
      q.where(transparencySamples.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<PsfFieldTileRow>> listPsfTilesPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(psfFieldTiles)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countPsfTiles({int? sessionId}) async {
    final expr = psfFieldTiles.id.count();
    final q = selectOnly(psfFieldTiles)..addColumns([expr]);
    if (sessionId != null) {
      q.where(psfFieldTiles.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<ScienceFrameQualityMetricsRow>> listFrameQualityPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(scienceFrameQualityMetrics)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countFrameQuality({int? sessionId}) async {
    final expr = scienceFrameQualityMetrics.id.count();
    final q = selectOnly(scienceFrameQualityMetrics)..addColumns([expr]);
    if (sessionId != null) {
      q.where(scienceFrameQualityMetrics.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<ScienceTileMetricRow>> listTileMetricsPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(scienceTileMetrics)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countTileMetrics({int? sessionId}) async {
    final expr = scienceTileMetrics.id.count();
    final q = selectOnly(scienceTileMetrics)..addColumns([expr]);
    if (sessionId != null) {
      q.where(scienceTileMetrics.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<AstrometryResidualVectorRow>> listResidualsPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(astrometryResidualVectors)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countResiduals({int? sessionId}) async {
    final expr = astrometryResidualVectors.id.count();
    final q = selectOnly(astrometryResidualVectors)..addColumns([expr]);
    if (sessionId != null) {
      q.where(astrometryResidualVectors.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<MovingObjectCandidateRow>> listMovingObjectsPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(movingObjectCandidates)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countMovingObjects({int? sessionId}) async {
    final expr = movingObjectCandidates.id.count();
    final q = selectOnly(movingObjectCandidates)..addColumns([expr]);
    if (sessionId != null) {
      q.where(movingObjectCandidates.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }

  Future<List<LineRatioProductRow>> listLineRatiosPaginated({
    int? sessionId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(lineRatioProducts)
      ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)])
      ..limit(limit, offset: offset);
    if (sessionId != null) {
      query.where((tbl) => tbl.sessionId.equals(sessionId));
    }
    return query.get();
  }

  Future<int> countLineRatios({int? sessionId}) async {
    final expr = lineRatioProducts.id.count();
    final q = selectOnly(lineRatioProducts)..addColumns([expr]);
    if (sessionId != null) {
      q.where(lineRatioProducts.sessionId.equals(sessionId));
    }
    final row = await q.getSingle();
    return row.read(expr) ?? 0;
  }
}
