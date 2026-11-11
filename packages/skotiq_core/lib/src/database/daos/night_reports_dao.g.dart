// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'night_reports_dao.dart';

// ignore_for_file: type=lint
mixin _$NightReportsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  StackedResults get stackedResults => attachedDatabase.stackedResults;
  $TargetsTable get targets => attachedDatabase.targets;
  IntegratedMasters get integratedMasters => attachedDatabase.integratedMasters;
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $CapturedImagesTable get capturedImages => attachedDatabase.capturedImages;
  IntegratedMasterFrames get integratedMasterFrames =>
      attachedDatabase.integratedMasterFrames;
  FlatLibrary get flatLibrary => attachedDatabase.flatLibrary;
  NightReports get nightReports => attachedDatabase.nightReports;
  NarrowbandComposites get narrowbandComposites =>
      attachedDatabase.narrowbandComposites;
  CalibrationTags get calibrationTags => attachedDatabase.calibrationTags;
  $SequenceNodesTable get sequenceNodes => attachedDatabase.sequenceNodes;
  $SequenceCheckpointsTable get sequenceCheckpoints =>
      attachedDatabase.sequenceCheckpoints;
  $ImageMetadataTable get imageMetadata => attachedDatabase.imageMetadata;
  NightReportsDaoManager get managers => NightReportsDaoManager(this);
}

class NightReportsDaoManager {
  final _$NightReportsDaoMixin _db;
  NightReportsDaoManager(this._db);
  $StackedResultsTableManager get stackedResults =>
      $StackedResultsTableManager(_db.attachedDatabase, _db.stackedResults);
  $$TargetsTableTableManager get targets =>
      $$TargetsTableTableManager(_db.attachedDatabase, _db.targets);
  $IntegratedMastersTableManager get integratedMasters =>
      $IntegratedMastersTableManager(
        _db.attachedDatabase,
        _db.integratedMasters,
      );
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$ImagingSessionsTableTableManager get imagingSessions =>
      $$ImagingSessionsTableTableManager(
        _db.attachedDatabase,
        _db.imagingSessions,
      );
  $$CapturedImagesTableTableManager get capturedImages =>
      $$CapturedImagesTableTableManager(
        _db.attachedDatabase,
        _db.capturedImages,
      );
  $IntegratedMasterFramesTableManager get integratedMasterFrames =>
      $IntegratedMasterFramesTableManager(
        _db.attachedDatabase,
        _db.integratedMasterFrames,
      );
  $FlatLibraryTableManager get flatLibrary =>
      $FlatLibraryTableManager(_db.attachedDatabase, _db.flatLibrary);
  $NightReportsTableManager get nightReports =>
      $NightReportsTableManager(_db.attachedDatabase, _db.nightReports);
  $NarrowbandCompositesTableManager get narrowbandComposites =>
      $NarrowbandCompositesTableManager(
        _db.attachedDatabase,
        _db.narrowbandComposites,
      );
  $CalibrationTagsTableManager get calibrationTags =>
      $CalibrationTagsTableManager(_db.attachedDatabase, _db.calibrationTags);
  $$SequenceNodesTableTableManager get sequenceNodes =>
      $$SequenceNodesTableTableManager(_db.attachedDatabase, _db.sequenceNodes);
  $$SequenceCheckpointsTableTableManager get sequenceCheckpoints =>
      $$SequenceCheckpointsTableTableManager(
        _db.attachedDatabase,
        _db.sequenceCheckpoints,
      );
  $$ImageMetadataTableTableManager get imageMetadata =>
      $$ImageMetadataTableTableManager(_db.attachedDatabase, _db.imageMetadata);
}
