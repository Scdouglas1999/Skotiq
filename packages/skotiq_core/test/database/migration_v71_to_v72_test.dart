// Migration test for the v71 -> v72 step: weather_settings is rebuilt so
// weather safety defaults off. A v71 database is simulated by recreating the
// table with the v71 definition (`DEFAULT 1`) and rewinding `user_version`.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

const _v71WeatherSettings =
    'CREATE TABLE "weather_settings" ("id" INTEGER NOT NULL PRIMARY KEY '
    'AUTOINCREMENT, "trigger_distance_km" REAL NOT NULL DEFAULT 30.0, '
    '"cloud_density_threshold" REAL NOT NULL DEFAULT 60.0, '
    '"lead_time_minutes" INTEGER NOT NULL DEFAULT 15, '
    '"weather_safety_enabled" INTEGER NOT NULL DEFAULT 1 CHECK '
    '("weather_safety_enabled" IN (0, 1)), "max_humidity_percent" REAL NOT '
    'NULL DEFAULT 90.0, "max_wind_speed_kph" REAL NOT NULL DEFAULT 30.0, '
    '"max_cloud_cover_percent" REAL NOT NULL DEFAULT 80.0, '
    '"auto_park_enabled" INTEGER NOT NULL DEFAULT 1 CHECK '
    '("auto_park_enabled" IN (0, 1)), "auto_resume_enabled" INTEGER NOT NULL '
    'DEFAULT 0 CHECK ("auto_resume_enabled" IN (0, 1)), "preferred_provider" '
    "TEXT NOT NULL DEFAULT 'auto', \"refresh_interval_seconds\" INTEGER NOT "
    'NULL DEFAULT 300, "updated_at" INTEGER NOT NULL DEFAULT '
    "(CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)))";

void main() {
  late File file;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('skotiq_v71_v72_');
    addTearDown(() => dir.delete(recursive: true));
    file = File('${dir.path}/skotiq.db');
  });

  /// A v71 database holding one settings row with weather safety on, or none.
  Future<void> writeV71({required bool withRow}) async {
    final setup = SkotiqDatabase.forTesting(NativeDatabase(file));
    await setup.customStatement('DROP TABLE weather_settings');
    await setup.customStatement(_v71WeatherSettings);
    if (withRow) {
      await setup.customStatement(
        'INSERT INTO weather_settings (id, trigger_distance_km, '
        'weather_safety_enabled, max_humidity_percent, auto_park_enabled, '
        "preferred_provider) VALUES (1, 25.0, 1, 85.0, 0, 'openmeteo')",
      );
    }
    await setup.customStatement('PRAGMA user_version = 71');
    await setup.close();
  }

  test(
    'the stored row keeps every value, weather safety on included',
    () async {
      await writeV71(withRow: true);

      final db = SkotiqDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion);

      final rows = await db.select(db.weatherSettings).get();
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.weatherSafetyEnabled, isTrue);
      expect(row.triggerDistanceKm, 25.0);
      expect(row.maxHumidityPercent, 85.0);
      expect(row.autoParkEnabled, isFalse);
      expect(row.preferredProvider, 'openmeteo');
    },
  );

  test('a reset on an upgraded database turns weather safety off', () async {
    await writeV71(withRow: true);

    final db = SkotiqDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.weatherSettingsDao.resetToDefaults();

    final row = await db.weatherSettingsDao.getOrCreateSettings();
    expect(row.weatherSafetyEnabled, isFalse);
  });

  test('an upgraded database with no settings row creates one off', () async {
    await writeV71(withRow: false);

    final db = SkotiqDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final row = await db.weatherSettingsDao.getOrCreateSettings();
    expect(row.weatherSafetyEnabled, isFalse);
  });
}
