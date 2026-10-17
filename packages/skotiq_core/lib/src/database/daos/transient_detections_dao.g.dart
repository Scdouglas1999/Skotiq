// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'transient_detections_dao.dart';

// ignore_for_file: type=lint
mixin _$TransientDetectionsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $TargetsTable get targets => attachedDatabase.targets;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $CapturedImagesTable get capturedImages => attachedDatabase.capturedImages;
  $TransientDetectionsTable get transientDetections =>
      attachedDatabase.transientDetections;
  TransientDetectionsDaoManager get managers =>
      TransientDetectionsDaoManager(this);
}

class TransientDetectionsDaoManager {
  final _$TransientDetectionsDaoMixin _db;
  TransientDetectionsDaoManager(this._db);
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
  $$TransientDetectionsTableTableManager get transientDetections =>
      $$TransientDetectionsTableTableManager(
        _db.attachedDatabase,
        _db.transientDetections,
      );
}
