// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'equipment_profiles_dao.dart';

// ignore_for_file: type=lint
mixin _$EquipmentProfilesDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  EquipmentProfilesDaoManager get managers => EquipmentProfilesDaoManager(this);
}

class EquipmentProfilesDaoManager {
  final _$EquipmentProfilesDaoMixin _db;
  EquipmentProfilesDaoManager(this._db);
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
}
