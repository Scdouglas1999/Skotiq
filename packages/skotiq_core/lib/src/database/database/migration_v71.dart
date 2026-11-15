part of '../database.dart';

extension _SkotiqDatabaseMigrationV71 on SkotiqDatabase {
  /// The profile's default camera read mode. Existing profiles state none,
  /// so their cameras stay in the mode they are in.
  Future<void> _upgradeSchemaV71(Migrator m, int from) async {
    if (from >= 71 ||
        !await _tableExists(equipmentProfiles.actualTableName) ||
        await _columnExists(
          equipmentProfiles.actualTableName,
          equipmentProfiles.defaultReadoutMode.name,
        )) {
      return;
    }
    await m.addColumn(equipmentProfiles, equipmentProfiles.defaultReadoutMode);
  }
}
