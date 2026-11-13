part of '../backup_service.dart';

extension _BackupTableRegistry on BackupService {
  Future<Map<String, dynamic>> _exportSettings() async {
    final settingsDao = SettingsDao(database);
    final allSettings = await settingsDao.getAllSettings();
    // The backup folder describes THIS machine's disks, not the archive's
    // contents. Carrying it in the bundle would let a restore repoint where a
    // different install writes — and where "Maximum backups" deletes from — at
    // a path chosen on another machine.
    allSettings.remove(BackupService.backupDirectorySettingKey);
    return allSettings;
  }

  Future<List<Map<String, dynamic>>> _exportProfiles() async {
    final profilesDao = EquipmentProfilesDao(database);
    final profiles = await profilesDao.getAllProfiles();

    // Drift's generated JSON codec includes the primary key, default/active
    // flags, timestamps, device display names, and every current profile
    // column, so `id` and `isDefault` survive a restore: without them a
    // replace-restore allocates a new id and loses the startup-profile
    // designation, breaking foreign-key identity.
    return profiles.map((profile) => profile.toJson()).toList();
  }

  /// Restore the single weather-safety configuration row.
  ///
  /// Deliberately not an insert: this table always already holds a row (the
  /// DAO creates a defaults row on first read), so `insertOrIgnore` would keep
  /// the destination's defaults and silently drop the operator's restored
  /// thresholds — the same silent reset this key was added to fix. Configuration
  /// is exactly the case where the backup must win, so the existing row is
  /// updated in place; the auto-increment `id` from the source machine is
  /// ignored on purpose.
  Future<int> _importWeatherSettings(WeatherSettingRow row) async {
    final current = await database.weatherSettingsDao.getOrCreateSettings();
    await (database.update(
      database.weatherSettings,
    )..where((table) => table.id.equals(current.id))).write(
      WeatherSettingsCompanion(
        triggerDistanceKm: Value(row.triggerDistanceKm),
        cloudDensityThreshold: Value(row.cloudDensityThreshold),
        leadTimeMinutes: Value(row.leadTimeMinutes),
        weatherSafetyEnabled: Value(row.weatherSafetyEnabled),
        maxHumidityPercent: Value(row.maxHumidityPercent),
        maxWindSpeedKph: Value(row.maxWindSpeedKph),
        maxCloudCoverPercent: Value(row.maxCloudCoverPercent),
        autoParkEnabled: Value(row.autoParkEnabled),
        autoResumeEnabled: Value(row.autoResumeEnabled),
        preferredProvider: Value(row.preferredProvider),
        refreshIntervalSeconds: Value(row.refreshIntervalSeconds),
        updatedAt: Value(DateTime.now()),
      ),
    );
    return 1;
  }

  /// One row of a 2.x backup's per-table section, decoded through its drift
  /// `fromJson` and inserted with [InsertMode.insertOrIgnore], so existing
  /// primary keys are kept and nothing the user collected after the backup
  /// is overwritten.
  Future<int> _importRows<T extends Insertable<dynamic>>(
    List<dynamic> rows,
    T Function(Map<String, dynamic>) decoder,
    TableInfo table,
  ) async {
    var count = 0;
    for (var index = 0; index < rows.length; index++) {
      final raw = rows[index];
      if (raw is! Map) {
        throw FormatException('Extended table row $index is not an object');
      }
      final row = decoder(raw.cast<String, dynamic>());
      final inserted = await database
          .into(table)
          .insert(row, mode: InsertMode.insertOrIgnore);
      // `insert` returns the row id on success (or the existing one on
      // conflict). Drift returns 0 specifically when an InsertOrIgnore
      // conflicted and nothing was written.
      if (inserted != 0) {
        count++;
      }
    }
    return count;
  }
}
