// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sequence_versions_dao.dart';

// ignore_for_file: type=lint
mixin _$SequenceVersionsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $SequencesTable get sequences => attachedDatabase.sequences;
  $SequenceVersionsTable get sequenceVersions =>
      attachedDatabase.sequenceVersions;
  SequenceVersionsDaoManager get managers => SequenceVersionsDaoManager(this);
}

class SequenceVersionsDaoManager {
  final _$SequenceVersionsDaoMixin _db;
  SequenceVersionsDaoManager(this._db);
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$SequenceVersionsTableTableManager get sequenceVersions =>
      $$SequenceVersionsTableTableManager(
        _db.attachedDatabase,
        _db.sequenceVersions,
      );
}
