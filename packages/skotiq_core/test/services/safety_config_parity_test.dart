import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart'
    show AppSettingsState;
import 'package:skotiq_core/src/services/safety_config_service.dart';

/// Master/slave wire-shape guard for the safety-config consolidation.
///
/// The `/api/safety/settings` payload is assembled from [SafetyConfigStore],
/// which reads the three stores (weatherSettingsDao + appSettings +
/// settingsDao). The slave mirrors that JSON verbatim, so the payload must
/// encode byte-identically to a direct read of the three stores.
///
/// This test builds the payload both ways for a representative config and
/// compares the encoded strings.
void main() {
  // The direct-read helpers and key strings, so the comparison is against the
  // stores themselves rather than the facade under test.
  const kCheckIntervalKey = 'safety_check_interval_seconds';
  const kWarningDelayKey = 'safety_warning_delay_seconds';
  const kRequiredSafeDurationKey = 'safety_required_safe_duration_seconds';
  const kAutoStopKey = 'safety_auto_stop_on_unsafe';
  const kAutoCloseRoofKey = 'safety_auto_close_roof_on_unsafe';

  int parseIntSetting(Map<String, String> s, String key, int fallback) {
    final raw = s[key];
    if (raw == null) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  bool parseBoolSetting(Map<String, String> s, String key, bool fallback) {
    final raw = s[key];
    if (raw == null) return fallback;
    return raw.toLowerCase() == 'true' || raw == '1';
  }

  String failModeToApi(SafetyFailMode mode) => switch (mode) {
    SafetyFailMode.failOpen => 'fail_open',
    SafetyFailMode.failClosed => 'fail_closed',
    SafetyFailMode.warnOnly => 'warn_only',
  };

  /// The pre-consolidation `_buildSettingsPayload` body, reading the three
  /// stores directly. This is the "wire shape of record".
  Future<Map<String, dynamic>> legacyPayload(
    SkotiqDatabase db,
    AppSettingsState appSettings,
  ) async {
    final weatherRow = await db.weatherSettingsDao.getOrCreateSettings();
    final stored = await db.settingsDao.getAllSettings();

    final failMode = appSettings.safetyFailMode;
    final autoParkOnUnsafe =
        appSettings.parkOnUnsafeWeather && weatherRow.autoParkEnabled;

    return {
      'failMode': failModeToApi(failMode),
      'checkIntervalSeconds': parseIntSetting(stored, kCheckIntervalKey, 300),
      'autoStopOnUnsafe': parseBoolSetting(
        stored,
        kAutoStopKey,
        weatherRow.weatherSafetyEnabled,
      ),
      'autoParkOnUnsafe': autoParkOnUnsafe,
      'autoCloseRoofOnUnsafe': parseBoolSetting(
        stored,
        kAutoCloseRoofKey,
        weatherRow.weatherSafetyEnabled,
      ),
      'warningDelaySeconds': parseIntSetting(stored, kWarningDelayKey, 60),
      'requiredSafeDurationSeconds': parseIntSetting(
        stored,
        kRequiredSafeDurationKey,
        300,
      ),
      'enabledMonitors': <String>[],
    };
  }

  /// The consolidated `_buildSettingsPayload`, built from [SafetyConfig].
  Future<Map<String, dynamic>> consolidatedPayload(
    SkotiqDatabase db,
    AppSettingsState appSettings,
  ) async {
    final config = await SafetyConfigStore(db).load(appSettings: appSettings);
    return {
      'failMode': failModeToApi(config.safetyFailMode),
      'checkIntervalSeconds': config.checkIntervalSeconds,
      'autoStopOnUnsafe': config.autoStopOnUnsafe,
      'autoParkOnUnsafe': config.autoParkOnUnsafe,
      'autoCloseRoofOnUnsafe': config.autoCloseRoofOnUnsafe,
      'warningDelaySeconds': config.warningDelaySeconds,
      'requiredSafeDurationSeconds': config.requiredSafeDurationSeconds,
      'enabledMonitors': <String>[],
    };
  }

  group('SafetyConfig wire-shape parity', () {
    late SkotiqDatabase db;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('explicitly-persisted config: identical JSON', () async {
      // Seed the three stores with a representative, fully-populated config.
      await db.weatherSettingsDao.updateSettings(
        weatherSafetyEnabled: true,
        autoParkEnabled: true,
        autoResumeEnabled: true,
        maxHumidityPercent: 85.0,
        maxWindSpeedKph: 25.0,
        maxCloudCoverPercent: 70.0,
      );
      await db.settingsDao.setSettings({
        kCheckIntervalKey: '120',
        kWarningDelayKey: '45',
        kRequiredSafeDurationKey: '600',
        kAutoStopKey: 'true',
        kAutoCloseRoofKey: 'false',
      });

      const appSettings = AppSettingsState(
        safetyFailMode: SafetyFailMode.warnOnly,
        parkOnUnsafeWeather: true,
      );

      final before = jsonEncode(await legacyPayload(db, appSettings));
      final after = jsonEncode(await consolidatedPayload(db, appSettings));

      expect(after, before);
    });

    test('defaults (no settings rows): identical JSON', () async {
      // Nothing persisted in settingsDao; weather row gets defaults.
      const appSettings = AppSettingsState(
        safetyFailMode: SafetyFailMode.failClosed,
        parkOnUnsafeWeather: true,
      );

      final before = jsonEncode(await legacyPayload(db, appSettings));
      final after = jsonEncode(await consolidatedPayload(db, appSettings));

      expect(after, before);
    });

    test(
      'park policy off + weather toggle on: derived autoPark matches',
      () async {
        await db.weatherSettingsDao.updateSettings(autoParkEnabled: true);
        const appSettings = AppSettingsState(
          safetyFailMode: SafetyFailMode.failOpen,
          parkOnUnsafeWeather: false,
        );

        final before = jsonEncode(await legacyPayload(db, appSettings));
        final after = jsonEncode(await consolidatedPayload(db, appSettings));

        expect(after, before);
        // Cross-check the derived field is the AND of the two stores.
        final config = await SafetyConfigStore(
          db,
        ).load(appSettings: appSettings);
        expect(config.autoParkOnUnsafe, isFalse);
      },
    );

    test('write path round-trips through facade to same wire shape', () async {
      final store = SafetyConfigStore(db);
      await store.setAutoStopOnUnsafe(false);
      await store.setAutoCloseRoofOnUnsafe(true);
      await store.setCheckIntervalSeconds(90);
      await store.setWarningDelaySeconds(30);
      await store.setRequiredSafeDurationSeconds(450);
      await store.setAutoParkOnUnsafe(true);

      const appSettings = AppSettingsState(
        safetyFailMode: SafetyFailMode.failClosed,
        parkOnUnsafeWeather: true,
      );

      final before = jsonEncode(await legacyPayload(db, appSettings));
      final after = jsonEncode(await consolidatedPayload(db, appSettings));
      expect(after, before);

      final config = await store.load(appSettings: appSettings);
      expect(config.autoStopOnUnsafe, isFalse);
      expect(config.autoCloseRoofOnUnsafe, isTrue);
      expect(config.checkIntervalSeconds, 90);
      expect(config.warningDelaySeconds, 30);
      expect(config.requiredSafeDurationSeconds, 450);
      expect(config.autoParkOnUnsafe, isTrue);
    });
  });
}
