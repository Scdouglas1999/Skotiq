// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'focus_history_dao.dart';

// ignore_for_file: type=lint
mixin _$FocusHistoryDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $FocusHistoryPointsTable get focusHistoryPoints =>
      attachedDatabase.focusHistoryPoints;
  $FocusProfileModelsTable get focusProfileModels =>
      attachedDatabase.focusProfileModels;
  $FocusFilterOffsetsTable get focusFilterOffsets =>
      attachedDatabase.focusFilterOffsets;
  FocusHistoryDaoManager get managers => FocusHistoryDaoManager(this);
}

class FocusHistoryDaoManager {
  final _$FocusHistoryDaoMixin _db;
  FocusHistoryDaoManager(this._db);
  $$FocusHistoryPointsTableTableManager get focusHistoryPoints =>
      $$FocusHistoryPointsTableTableManager(
        _db.attachedDatabase,
        _db.focusHistoryPoints,
      );
  $$FocusProfileModelsTableTableManager get focusProfileModels =>
      $$FocusProfileModelsTableTableManager(
        _db.attachedDatabase,
        _db.focusProfileModels,
      );
  $$FocusFilterOffsetsTableTableManager get focusFilterOffsets =>
      $$FocusFilterOffsetsTableTableManager(
        _db.attachedDatabase,
        _db.focusFilterOffsets,
      );
}
