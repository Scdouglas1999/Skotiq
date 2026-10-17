// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sequences_dao.dart';

// ignore_for_file: type=lint
mixin _$SequencesDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $SequencesTable get sequences => attachedDatabase.sequences;
  $TargetsTable get targets => attachedDatabase.targets;
  $SequenceNodesTable get sequenceNodes => attachedDatabase.sequenceNodes;
  SequencesDaoManager get managers => SequencesDaoManager(this);
}

class SequencesDaoManager {
  final _$SequencesDaoMixin _db;
  SequencesDaoManager(this._db);
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$TargetsTableTableManager get targets =>
      $$TargetsTableTableManager(_db.attachedDatabase, _db.targets);
  $$SequenceNodesTableTableManager get sequenceNodes =>
      $$SequenceNodesTableTableManager(_db.attachedDatabase, _db.sequenceNodes);
}
