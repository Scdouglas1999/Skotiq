// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sequence_checkpoints_dao.dart';

// ignore_for_file: type=lint
mixin _$SequenceCheckpointsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $SequencesTable get sequences => attachedDatabase.sequences;
  $SequenceCheckpointsTable get sequenceCheckpoints =>
      attachedDatabase.sequenceCheckpoints;
  SequenceCheckpointsDaoManager get managers =>
      SequenceCheckpointsDaoManager(this);
}

class SequenceCheckpointsDaoManager {
  final _$SequenceCheckpointsDaoMixin _db;
  SequenceCheckpointsDaoManager(this._db);
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$SequenceCheckpointsTableTableManager get sequenceCheckpoints =>
      $$SequenceCheckpointsTableTableManager(
        _db.attachedDatabase,
        _db.sequenceCheckpoints,
      );
}
