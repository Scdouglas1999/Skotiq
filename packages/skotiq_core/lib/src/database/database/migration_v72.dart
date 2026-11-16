part of '../database.dart';

extension _SkotiqDatabaseMigrationV72 on SkotiqDatabase {
  /// Version 72 — weather safety is off unless the operator turned it on.
  ///
  /// `weather_settings.weather_safety_enabled` was created `DEFAULT 1`, and
  /// the settings row is inserted with the column's default. The table is
  /// rebuilt so that default is off on every database; every row keeps its
  /// values, a stored "on" included.
  Future<void> _upgradeSchemaV72(Migrator m, int from) async {
    if (from >= 72 || !await _tableExists(weatherSettings.actualTableName)) {
      return;
    }
    await m.alterTable(TableMigration(weatherSettings));
  }
}
