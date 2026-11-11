import 'package:skotiq_core/skotiq_core.dart';

/// Settings a linked imaging host serves through their own endpoints.
abstract interface class HostRigSettings {
  /// Load the imaging host's global meridian-flip defaults.
  ///
  /// These settings drive unattended hardware behavior and therefore belong
  /// to the host, not the phone rendering the settings screen.
  Future<MeridianFlipSettings> getMeridianFlipSettings();

  /// Replace the imaging host's global meridian-flip defaults.
  Future<void> updateMeridianFlipSettings(MeridianFlipSettings settings);

  /// Load the headless/desktop host's Home Assistant discovery and broker
  /// configuration. The returned broker never contains its password.
  Future<HomeAssistantHostSettings> getHomeAssistantHostSettings();

  /// POST only the [patch] keys of the typed settings document. The host
  /// merges them onto its current settings, so fields this client did not
  /// change keep whatever value the host holds now.
  Future<void> updateSettingsPatchWithCommandId(
    Map<String, dynamic> patch, {
    required String? commandId,
  });

  /// The host's `app_settings` key/value rows that are not part of the
  /// [models.AppSettings] wire model, or null when the host predates
  /// `GET /api/settings/store` and answers 404.
  Future<Map<String, String>?> getSettingsStore();

  /// Write [settings] into the host's key/value store and delete [remove].
  Future<void> updateSettingsStore(
    Map<String, String> settings, {
    List<String> remove = const [],
  });

  /// Merge [fields] into the JSON-object rows of the host's key/value store.
  ///
  /// [fallback] carries, for every key in [fields], the whole value this
  /// client would write: a host that predates merging ignores `merge` and
  /// stores it, while a current host ignores it and lays only [fields] over
  /// its own row (or over [base] when it has none). Returns the values the
  /// host stored, or [fallback] when the host did not say.
  Future<Map<String, String>> mergeSettingsStore(
    Map<String, Map<String, Object?>> fields, {
    required Map<String, String> fallback,
    Map<String, Map<String, Object?>> base = const {},
  });

  Future<Map<String, String>> getScienceSettings();

  Future<void> updateScienceSettings(Map<String, String> settings);

  Future<Map<String, String>> getSmartNightSettings();

  Future<void> updateSmartNightSettings(Map<String, String> settings);
}
