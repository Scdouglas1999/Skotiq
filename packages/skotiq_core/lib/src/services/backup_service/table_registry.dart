part of '../backup_service.dart';

extension _BackupTableRegistry on BackupService {
  /// The `weatherSettings` section of a 2.x backup, written into the one
  /// configuration row the table holds; the id it had is not kept.
  Future<void> _importWeatherSettings(WeatherSettingRow row) async {
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
  }

  /// A 2.x backup's per-table section, each row decoded through its drift
  /// `fromJson`, written in one batch.
  Future<void> _importRows<T extends Insertable<dynamic>>(
    List<dynamic> rows,
    T Function(Map<String, dynamic>) decoder,
    TableInfo table,
  ) async {
    final decoded = <T>[];
    for (var index = 0; index < rows.length; index++) {
      final raw = rows[index];
      if (raw is! Map) {
        throw FormatException('row $index is not an object');
      }
      decoded.add(decoder(raw.cast<String, dynamic>()));
    }
    await database.batch(
      (batch) =>
          batch.insertAll(table, decoded, mode: InsertMode.insertOrIgnore),
    );
  }
}
