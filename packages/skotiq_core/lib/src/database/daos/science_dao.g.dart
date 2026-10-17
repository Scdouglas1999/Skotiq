// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'science_dao.dart';

// ignore_for_file: type=lint
mixin _$ScienceDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $TargetsTable get targets => attachedDatabase.targets;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $ScienceSessionConfigTable get scienceSessionConfig =>
      attachedDatabase.scienceSessionConfig;
  $CapturedImagesTable get capturedImages => attachedDatabase.capturedImages;
  $PhotometryMeasurementsTable get photometryMeasurements =>
      attachedDatabase.photometryMeasurements;
  $FramePhotometricCalibrationTable get framePhotometricCalibration =>
      attachedDatabase.framePhotometricCalibration;
  $TransparencySamplesTable get transparencySamples =>
      attachedDatabase.transparencySamples;
  $PsfFieldTilesTable get psfFieldTiles => attachedDatabase.psfFieldTiles;
  $ScienceFrameQualityMetricsTable get scienceFrameQualityMetrics =>
      attachedDatabase.scienceFrameQualityMetrics;
  $ScienceTileMetricsTable get scienceTileMetrics =>
      attachedDatabase.scienceTileMetrics;
  $AstrometryResidualVectorsTable get astrometryResidualVectors =>
      attachedDatabase.astrometryResidualVectors;
  $MovingObjectCandidatesTable get movingObjectCandidates =>
      attachedDatabase.movingObjectCandidates;
  $LineRatioProductsTable get lineRatioProducts =>
      attachedDatabase.lineRatioProducts;
  $PhotometricTransformsTable get photometricTransforms =>
      attachedDatabase.photometricTransforms;
  ScienceDaoManager get managers => ScienceDaoManager(this);
}

class ScienceDaoManager {
  final _$ScienceDaoMixin _db;
  ScienceDaoManager(this._db);
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
  $$TargetsTableTableManager get targets =>
      $$TargetsTableTableManager(_db.attachedDatabase, _db.targets);
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$ImagingSessionsTableTableManager get imagingSessions =>
      $$ImagingSessionsTableTableManager(
        _db.attachedDatabase,
        _db.imagingSessions,
      );
  $$ScienceSessionConfigTableTableManager get scienceSessionConfig =>
      $$ScienceSessionConfigTableTableManager(
        _db.attachedDatabase,
        _db.scienceSessionConfig,
      );
  $$CapturedImagesTableTableManager get capturedImages =>
      $$CapturedImagesTableTableManager(
        _db.attachedDatabase,
        _db.capturedImages,
      );
  $$PhotometryMeasurementsTableTableManager get photometryMeasurements =>
      $$PhotometryMeasurementsTableTableManager(
        _db.attachedDatabase,
        _db.photometryMeasurements,
      );
  $$FramePhotometricCalibrationTableTableManager
  get framePhotometricCalibration =>
      $$FramePhotometricCalibrationTableTableManager(
        _db.attachedDatabase,
        _db.framePhotometricCalibration,
      );
  $$TransparencySamplesTableTableManager get transparencySamples =>
      $$TransparencySamplesTableTableManager(
        _db.attachedDatabase,
        _db.transparencySamples,
      );
  $$PsfFieldTilesTableTableManager get psfFieldTiles =>
      $$PsfFieldTilesTableTableManager(_db.attachedDatabase, _db.psfFieldTiles);
  $$ScienceFrameQualityMetricsTableTableManager
  get scienceFrameQualityMetrics =>
      $$ScienceFrameQualityMetricsTableTableManager(
        _db.attachedDatabase,
        _db.scienceFrameQualityMetrics,
      );
  $$ScienceTileMetricsTableTableManager get scienceTileMetrics =>
      $$ScienceTileMetricsTableTableManager(
        _db.attachedDatabase,
        _db.scienceTileMetrics,
      );
  $$AstrometryResidualVectorsTableTableManager get astrometryResidualVectors =>
      $$AstrometryResidualVectorsTableTableManager(
        _db.attachedDatabase,
        _db.astrometryResidualVectors,
      );
  $$MovingObjectCandidatesTableTableManager get movingObjectCandidates =>
      $$MovingObjectCandidatesTableTableManager(
        _db.attachedDatabase,
        _db.movingObjectCandidates,
      );
  $$LineRatioProductsTableTableManager get lineRatioProducts =>
      $$LineRatioProductsTableTableManager(
        _db.attachedDatabase,
        _db.lineRatioProducts,
      );
  $$PhotometricTransformsTableTableManager get photometricTransforms =>
      $$PhotometricTransformsTableTableManager(
        _db.attachedDatabase,
        _db.photometricTransforms,
      );
}
