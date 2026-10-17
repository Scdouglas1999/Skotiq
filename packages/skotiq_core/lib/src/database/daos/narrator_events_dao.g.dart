// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'narrator_events_dao.dart';

// ignore_for_file: type=lint
mixin _$NarratorEventsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $TargetsTable get targets => attachedDatabase.targets;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $CapturedImagesTable get capturedImages => attachedDatabase.capturedImages;
  $NarratorEventsTable get narratorEvents => attachedDatabase.narratorEvents;
  NarratorEventsDaoManager get managers => NarratorEventsDaoManager(this);
}

class NarratorEventsDaoManager {
  final _$NarratorEventsDaoMixin _db;
  NarratorEventsDaoManager(this._db);
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
  $$NarratorEventsTableTableManager get narratorEvents =>
      $$NarratorEventsTableTableManager(
        _db.attachedDatabase,
        _db.narratorEvents,
      );
}
