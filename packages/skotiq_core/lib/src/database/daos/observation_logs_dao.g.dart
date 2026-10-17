// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'observation_logs_dao.dart';

// ignore_for_file: type=lint
mixin _$ObservationLogsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $ObservationLogsTable get observationLogs => attachedDatabase.observationLogs;
  ObservationLogsDaoManager get managers => ObservationLogsDaoManager(this);
}

class ObservationLogsDaoManager {
  final _$ObservationLogsDaoMixin _db;
  ObservationLogsDaoManager(this._db);
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
  $$ObservationLogsTableTableManager get observationLogs =>
      $$ObservationLogsTableTableManager(
        _db.attachedDatabase,
        _db.observationLogs,
      );
}
