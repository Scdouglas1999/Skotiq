// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'delivery_journal_dao.dart';

// ignore_for_file: type=lint
mixin _$DeliveryJournalDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $TargetsTable get targets => attachedDatabase.targets;
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  IntegratedMasters get integratedMasters => attachedDatabase.integratedMasters;
  Recipes get recipes => attachedDatabase.recipes;
  DarkroomJobs get darkroomJobs => attachedDatabase.darkroomJobs;
  DeliveryTargets get deliveryTargets => attachedDatabase.deliveryTargets;
  DeliveryJournal get deliveryJournal => attachedDatabase.deliveryJournal;
  DarkroomState get darkroomState => attachedDatabase.darkroomState;
  StackedResults get stackedResults => attachedDatabase.stackedResults;
  $CapturedImagesTable get capturedImages => attachedDatabase.capturedImages;
  IntegratedMasterFrames get integratedMasterFrames =>
      attachedDatabase.integratedMasterFrames;
  FlatLibrary get flatLibrary => attachedDatabase.flatLibrary;
  NightReports get nightReports => attachedDatabase.nightReports;
  NarrowbandComposites get narrowbandComposites =>
      attachedDatabase.narrowbandComposites;
  CalibrationTags get calibrationTags => attachedDatabase.calibrationTags;
  $ImageMetadataTable get imageMetadata => attachedDatabase.imageMetadata;
  $SequenceNodesTable get sequenceNodes => attachedDatabase.sequenceNodes;
  $SequenceCheckpointsTable get sequenceCheckpoints =>
      attachedDatabase.sequenceCheckpoints;
  DeliveryJournalDaoManager get managers => DeliveryJournalDaoManager(this);
}

class DeliveryJournalDaoManager {
  final _$DeliveryJournalDaoMixin _db;
  DeliveryJournalDaoManager(this._db);
  $$TargetsTableTableManager get targets =>
      $$TargetsTableTableManager(_db.attachedDatabase, _db.targets);
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
  $IntegratedMastersTableManager get integratedMasters =>
      $IntegratedMastersTableManager(
        _db.attachedDatabase,
        _db.integratedMasters,
      );
  $RecipesTableManager get recipes =>
      $RecipesTableManager(_db.attachedDatabase, _db.recipes);
  $DarkroomJobsTableManager get darkroomJobs =>
      $DarkroomJobsTableManager(_db.attachedDatabase, _db.darkroomJobs);
  $DeliveryTargetsTableManager get deliveryTargets =>
      $DeliveryTargetsTableManager(_db.attachedDatabase, _db.deliveryTargets);
  $DeliveryJournalTableManager get deliveryJournal =>
      $DeliveryJournalTableManager(_db.attachedDatabase, _db.deliveryJournal);
  $DarkroomStateTableManager get darkroomState =>
      $DarkroomStateTableManager(_db.attachedDatabase, _db.darkroomState);
  $StackedResultsTableManager get stackedResults =>
      $StackedResultsTableManager(_db.attachedDatabase, _db.stackedResults);
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
  $$ImageMetadataTableTableManager get imageMetadata =>
      $$ImageMetadataTableTableManager(_db.attachedDatabase, _db.imageMetadata);
  $$SequenceNodesTableTableManager get sequenceNodes =>
      $$SequenceNodesTableTableManager(_db.attachedDatabase, _db.sequenceNodes);
  $$SequenceCheckpointsTableTableManager get sequenceCheckpoints =>
      $$SequenceCheckpointsTableTableManager(
        _db.attachedDatabase,
        _db.sequenceCheckpoints,
      );
}
