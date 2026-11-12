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

  /// Null when the host predates `GET /api/settings/store`.
  Future<HostSettingsRows?> getSettingsStore();

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

/// The imaging host's key/value settings rows as this client may see them.
class HostSettingsRows {
  const HostSettingsRows(this.values, {this.adminAccess});

  final Map<String, String> values;

  /// Whether this client's credential has admin access to the host, which
  /// credential settings need. Null when the host does not say.
  final bool? adminAccess;
}
