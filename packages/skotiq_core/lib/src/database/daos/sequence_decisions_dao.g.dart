// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sequence_decisions_dao.dart';

// ignore_for_file: type=lint
mixin _$SequenceDecisionsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  NotesJournal get notesJournal => attachedDatabase.notesJournal;
  SequenceDecisions get sequenceDecisions => attachedDatabase.sequenceDecisions;
  ConversationalBuilds get conversationalBuilds =>
      attachedDatabase.conversationalBuilds;
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $TargetsTable get targets => attachedDatabase.targets;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $CapturedImagesTable get capturedImages => attachedDatabase.capturedImages;
  FrameForensics get frameForensics => attachedDatabase.frameForensics;
  $ImageMetadataTable get imageMetadata => attachedDatabase.imageMetadata;
  $SequenceNodesTable get sequenceNodes => attachedDatabase.sequenceNodes;
  $SequenceCheckpointsTable get sequenceCheckpoints =>
      attachedDatabase.sequenceCheckpoints;
  SequenceDecisionsDaoManager get managers => SequenceDecisionsDaoManager(this);
}

class SequenceDecisionsDaoManager {
  final _$SequenceDecisionsDaoMixin _db;
  SequenceDecisionsDaoManager(this._db);
  $NotesJournalTableManager get notesJournal =>
      $NotesJournalTableManager(_db.attachedDatabase, _db.notesJournal);
  $SequenceDecisionsTableManager get sequenceDecisions =>
      $SequenceDecisionsTableManager(
        _db.attachedDatabase,
        _db.sequenceDecisions,
      );
  $ConversationalBuildsTableManager get conversationalBuilds =>
      $ConversationalBuildsTableManager(
        _db.attachedDatabase,
        _db.conversationalBuilds,
      );
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
  $$CapturedImagesTableTableManager get capturedImages =>
      $$CapturedImagesTableTableManager(
        _db.attachedDatabase,
        _db.capturedImages,
      );
  $FrameForensicsTableManager get frameForensics =>
      $FrameForensicsTableManager(_db.attachedDatabase, _db.frameForensics);
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
