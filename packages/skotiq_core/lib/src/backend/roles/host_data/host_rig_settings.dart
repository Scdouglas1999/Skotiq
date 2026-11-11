import 'package:skotiq_core/skotiq_core.dart';

/// Settings a linked imaging host serves through their own endpoints.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostRigSettings {
  Future<MeridianFlipSettings> getMeridianFlipSettings();

  Future<void> updateMeridianFlipSettings(MeridianFlipSettings settings);

  Future<HomeAssistantHostSettings> getHomeAssistantHostSettings();

  Future<void> updateSettingsPatchWithCommandId(
    Map<String, dynamic> patch, {
    required String? commandId,
  });

  Future<Map<String, String>?> getSettingsStore();

  Future<void> updateSettingsStore(
    Map<String, String> settings, {
    List<String> remove = const [],
  });

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
