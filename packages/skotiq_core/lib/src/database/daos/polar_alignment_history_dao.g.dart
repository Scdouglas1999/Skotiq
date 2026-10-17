// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'polar_alignment_history_dao.dart';

// ignore_for_file: type=lint
mixin _$PolarAlignmentHistoryDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $PolarAlignmentHistoryTable get polarAlignmentHistory =>
      attachedDatabase.polarAlignmentHistory;
  PolarAlignmentHistoryDaoManager get managers =>
      PolarAlignmentHistoryDaoManager(this);
}

class PolarAlignmentHistoryDaoManager {
  final _$PolarAlignmentHistoryDaoMixin _db;
  PolarAlignmentHistoryDaoManager(this._db);
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
  $$PolarAlignmentHistoryTableTableManager get polarAlignmentHistory =>
      $$PolarAlignmentHistoryTableTableManager(
        _db.attachedDatabase,
        _db.polarAlignmentHistory,
      );
}
