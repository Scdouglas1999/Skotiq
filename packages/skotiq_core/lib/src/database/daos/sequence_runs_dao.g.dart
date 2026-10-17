// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sequence_runs_dao.dart';

// ignore_for_file: type=lint
mixin _$SequenceRunsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $SequencesTable get sequences => attachedDatabase.sequences;
  $SequenceRunsTable get sequenceRuns => attachedDatabase.sequenceRuns;
  SequenceRunsDaoManager get managers => SequenceRunsDaoManager(this);
}

class SequenceRunsDaoManager {
  final _$SequenceRunsDaoMixin _db;
  SequenceRunsDaoManager(this._db);
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$SequenceRunsTableTableManager get sequenceRuns =>
      $$SequenceRunsTableTableManager(_db.attachedDatabase, _db.sequenceRuns);
}
