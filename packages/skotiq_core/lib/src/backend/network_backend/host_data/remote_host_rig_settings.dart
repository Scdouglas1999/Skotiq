import 'package:skotiq_core/skotiq_core.dart';

/// [HostRigSettings] on a linked host.
final class RemoteHostRigSettings implements HostRigSettings {
  RemoteHostRigSettings(this._host);

  final NetworkBackend _host;

  @override
  Future<MeridianFlipSettings> getMeridianFlipSettings() =>
      _host.getMeridianFlipSettings();

  @override
  Future<void> updateMeridianFlipSettings(MeridianFlipSettings settings) =>
      _host.updateMeridianFlipSettings(settings);

  @override
  Future<HomeAssistantHostSettings> getHomeAssistantHostSettings() =>
      _host.getHomeAssistantHostSettings();

  @override
  Future<void> updateSettingsPatchWithCommandId(
    Map<String, dynamic> patch, {
    required String? commandId,
  }) => _host.updateSettingsPatchWithCommandId(patch, commandId: commandId);

  @override
  Future<Map<String, String>?> getSettingsStore() => _host.getSettingsStore();

  @override
  Future<void> updateSettingsStore(
    Map<String, String> settings, {
    List<String> remove = const [],
  }) => _host.updateSettingsStore(settings, remove: remove);

  @override
  Future<Map<String, String>> mergeSettingsStore(
    Map<String, Map<String, Object?>> fields, {
    required Map<String, String> fallback,
    Map<String, Map<String, Object?>> base = const {},
  }) => _host.mergeSettingsStore(fields, fallback: fallback, base: base);

  @override
  Future<Map<String, String>> getScienceSettings() =>
      _host.getScienceSettings();

  @override
  Future<void> updateScienceSettings(Map<String, String> settings) =>
      _host.updateScienceSettings(settings);

  @override
  Future<Map<String, String>> getSmartNightSettings() =>
      _host.getSmartNightSettings();

  @override
  Future<void> updateSmartNightSettings(Map<String, String> settings) =>
      _host.updateSmartNightSettings(settings);
}
