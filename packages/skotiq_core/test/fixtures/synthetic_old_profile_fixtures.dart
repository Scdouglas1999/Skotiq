import 'dart:io';

import 'package:drift/native.dart';
import 'package:skotiq_core/src/database/database.dart';

class SyntheticOldProfileFixture {
  final Directory tempDir;
  final File dbFile;

  const SyntheticOldProfileFixture._({
    required this.tempDir,
    required this.dbFile,
  });

  static Future<SyntheticOldProfileFixture>
  schema20WithDuplicateActiveProfiles() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_schema20_profile_',
    );
    final dbFile = File('${tempDir.path}/skotiq.db');
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await db.customStatement(
        'DROP INDEX IF EXISTS idx_profiles_single_active',
      );
      await db.customStatement('DELETE FROM equipment_profiles');
      await db.customStatement('''
INSERT INTO equipment_profiles (
  id, name, description, focal_length, aperture, telescope_focal_length,
  telescope_aperture, created_at, updated_at, is_active
) VALUES
  (1, 'Legacy Widefield', 'older active profile', 250.0, 60.0, NULL, NULL, 1700000000, 1700000000, 1),
  (2, 'Legacy Observatory', 'newer active profile', 0.0, 0.0, 900.0, 120.0, 1700000100, 1700000200, 1)
''');
      await db.customStatement('PRAGMA user_version = 20');
    } finally {
      await db.close();
    }

    return SyntheticOldProfileFixture._(tempDir: tempDir, dbFile: dbFile);
  }

  static Future<SyntheticOldProfileFixture>
  schema17WithCapturedImageMetadata() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_schema17_images_',
    );
    final dbFile = File('${tempDir.path}/skotiq.db');
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await db.customStatement('DELETE FROM image_metadata');
      await db.customStatement('DELETE FROM captured_images');
      await db.customStatement('DELETE FROM imaging_sessions');
      await db.customStatement('''
INSERT INTO imaging_sessions (id, start_time, status)
VALUES (1, 1700000000, 'completed')
''');
      await db.customStatement('''
INSERT INTO captured_images (
  id, file_path, file_name, file_format, session_id, frame_type,
  exposure_duration, captured_at
) VALUES (
  1, '/legacy/light-001.fits', 'light-001.fits', 'fits', 1, 'light',
  120.0, 1700000001
)
''');
      await db.customStatement('''
INSERT INTO image_metadata (id, image_id, "key", value, comment)
VALUES (1, 1, 'FILTER', 'L', 'legacy FITS metadata')
''');
      await db.customStatement('PRAGMA user_version = 17');
    } finally {
      await db.close();
    }

    return SyntheticOldProfileFixture._(tempDir: tempDir, dbFile: dbFile);
  }

  static Future<SyntheticOldProfileFixture>
  schema20WithDuplicateScienceSessionConfigs() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_schema20_science_',
    );
    final dbFile = File('${tempDir.path}/skotiq.db');
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await db.customStatement(
        'DROP INDEX IF EXISTS idx_science_session_config_session_unique',
      );
      await db.customStatement('DELETE FROM science_session_config');
      await db.customStatement('DELETE FROM imaging_sessions');
      await db.customStatement('''
INSERT INTO imaging_sessions (id, start_time, status)
VALUES (1, 1700000000, 'completed')
''');
      await db.customStatement('''
INSERT INTO science_session_config (
  id, session_id, photometry_enabled, calibration_enabled,
  transparency_enabled, psf_map_enabled, residuals_enabled,
  moving_objects_enabled, narrowband_enabled, psf_grid_rows, psf_grid_cols,
  transparency_alert_threshold, created_at, updated_at
) VALUES
  (1, 1, 1, 1, 1, 1, 1, 0, 0, 4, 6, 70.0, 1700000000, 1700000000),
  (2, 1, 0, 0, 0, 0, 0, 1, 1, 8, 10, 55.0, 1700000100, 1700000200)
''');
      await db.customStatement('PRAGMA user_version = 20');
    } finally {
      await db.close();
    }

    return SyntheticOldProfileFixture._(tempDir: tempDir, dbFile: dbFile);
  }

  static Future<SyntheticOldProfileFixture>
  schema20WithDuplicateWeatherSettings() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_schema20_weather_',
    );
    final dbFile = File('${tempDir.path}/skotiq.db');
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await db.customStatement('DELETE FROM weather_settings');
      await db.customStatement('''
INSERT INTO weather_settings (
  id, trigger_distance_km, cloud_density_threshold, lead_time_minutes,
  weather_safety_enabled, max_humidity_percent, max_wind_speed_kph,
  max_cloud_cover_percent, auto_park_enabled, auto_resume_enabled,
  preferred_provider, refresh_interval_seconds, updated_at
) VALUES
  (1, 25.0, 55.0, 10, 1, 85.0, 25.0, 70.0, 1, 0, 'legacy_primary', 240, 1700000000),
  (2, 80.0, 95.0, 45, 0, 99.0, 90.0, 99.0, 0, 1, 'legacy_duplicate', 900, 1700000200)
''');
      await db.customStatement('PRAGMA user_version = 20');
    } finally {
      await db.close();
    }

    return SyntheticOldProfileFixture._(tempDir: tempDir, dbFile: dbFile);
  }

  Future<void> dispose() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}
