import '../../database/daos/settings_dao.dart';
import 'settings_key_scope.dart';

/// The settings DAO on the machine that owns the hardware: this computer's
/// database, announcing every write of a host-owned row so linked clients
/// re-read the host's settings instead of keeping a stale copy until their
/// next periodic refresh.
class PublishingSettingsDao extends SettingsDao {
  PublishingSettingsDao(super.db, {required this.onHostRowsWritten});

  /// Called with the host-owned keys a write touched. Device-local keys are
  /// left out; a write that touched only those does not call it.
  final void Function(List<String> keys) onHostRowsWritten;

  void _announce(Iterable<String> keys) {
    final hostKeys = keys.where((k) => !isDeviceLocalSettingKey(k)).toList();
    if (hostKeys.isNotEmpty) onHostRowsWritten(hostKeys);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    await super.setSetting(key, value);
    _announce([key]);
  }

  @override
  Future<void> setSettings(Map<String, String> settings) async {
    await super.setSettings(settings);
    _announce(settings.keys);
  }

  @override
  Future<int> deleteSetting(String key) async {
    final deleted = await super.deleteSetting(key);
    if (deleted > 0) _announce([key]);
    return deleted;
  }
}
