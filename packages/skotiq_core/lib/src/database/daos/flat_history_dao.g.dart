// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flat_history_dao.dart';

// ignore_for_file: type=lint
mixin _$FlatHistoryDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $FlatHistoryTable get flatHistory => attachedDatabase.flatHistory;
  FlatHistoryDaoManager get managers => FlatHistoryDaoManager(this);
}

class FlatHistoryDaoManager {
  final _$FlatHistoryDaoMixin _db;
  FlatHistoryDaoManager(this._db);
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
  $$FlatHistoryTableTableManager get flatHistory =>
      $$FlatHistoryTableTableManager(_db.attachedDatabase, _db.flatHistory);
}
