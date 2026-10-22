import 'dart:async';

import '../../database/daos/settings_dao.dart';
import 'host_settings_store.dart';
import 'settings_key_scope.dart';

/// Reads and writes of the settings rows that the app-settings notifier owns.
///
/// Those rows reach the host through `GET/POST /api/settings`, whose typed wire
/// model the host applies through its own settings notifier; writing the same
/// rows through the key/value store would leave the host's in-memory copy
/// stale and the next save would revert them.
abstract interface class AppSettingsRows {
  /// The keys the notifier owns.
  Set<String> get keys;

  /// The current values of [keys], as the stored rows would hold them.
  Future<Map<String, String>> read();

  /// Save [settings] (a subset of [keys]) through the notifier.
  Future<void> write(Map<String, String> settings);

  /// Fires when the notifier's values change.
  Stream<void> get changes;
}

/// The settings DAO a linked client uses: one store for every reader of
/// `app_settings`, routed by who owns each key.
///
/// * A device-local key ([isDeviceLocalSettingKey]) stays in this computer's
///   database.
/// * A key owned by the app-settings notifier goes through it, and so through
///   the host's typed settings endpoint.
/// * Every other key is the host's row in [HostSettingsStore].
///
/// When the host is too old to serve a key at all, the read falls back to this
/// computer's row and the key is recorded in
/// [HostSettingsStore.unsharedKeys], so the Settings
/// screen can say which values are this computer's own copy rather than present
/// them as the host's.
class RemoteSettingsDao extends SettingsDao {
  RemoteSettingsDao(
    super.db, {
    required HostSettingsStore store,
    required AppSettingsRows appSettings,
  }) : _store = store,
       _appSettings = appSettings;

  final HostSettingsStore _store;
  final AppSettingsRows _appSettings;

  bool _isAppSettingsKey(String key) => _appSettings.keys.contains(key);

  Future<bool> _isHostStoreKey(String key) async {
    if (isDeviceLocalSettingKey(key) || _isAppSettingsKey(key)) return false;
    await _store.ensureLoaded();
    if (_store.covers(key)) return true;
    _store.noteUnsharedKey(key);
    return false;
  }

  @override
  Future<String?> getSetting(String key) async {
    if (isDeviceLocalSettingKey(key)) return super.getSetting(key);
    if (_isAppSettingsKey(key)) return (await _appSettings.read())[key];
    if (await _isHostStoreKey(key)) return _store.values[key];
    return super.getSetting(key);
  }

  @override
  Future<Map<String, String>> getAllSettings() async {
    final local = await super.getAllSettings();
    await _store.ensureLoaded();
    final merged = <String, String>{};
    local.forEach((key, value) {
      if (isDeviceLocalSettingKey(key)) {
        merged[key] = value;
      } else if (!_isAppSettingsKey(key) && !_store.covers(key)) {
        _store.noteUnsharedKey(key);
        merged[key] = value;
      }
    });
    _store.values.forEach((key, value) {
      if (!isDeviceLocalSettingKey(key) && !_isAppSettingsKey(key)) {
        merged[key] = value;
      }
    });
    (await _appSettings.read()).forEach((key, value) {
      if (!isDeviceLocalSettingKey(key)) merged[key] = value;
    });
    return merged;
  }

  @override
  Future<void> setSetting(String key, String value) =>
      setSettings({key: value});

  @override
  Future<void> setSettings(Map<String, String> settings) async {
    final local = <String, String>{};
    final app = <String, String>{};
    final host = <String, String>{};
    for (final entry in settings.entries) {
      if (isDeviceLocalSettingKey(entry.key)) {
        local[entry.key] = entry.value;
      } else if (_isAppSettingsKey(entry.key)) {
        app[entry.key] = entry.value;
      } else if (await _isHostStoreKey(entry.key)) {
        host[entry.key] = entry.value;
      } else {
        local[entry.key] = entry.value;
      }
    }
    if (host.isNotEmpty) await _store.write(host);
    if (app.isNotEmpty) await _appSettings.write(app);
    if (local.isNotEmpty) await super.setSettings(local);
  }

  @override
  Future<int> deleteSetting(String key) async {
    if (isDeviceLocalSettingKey(key) || _isAppSettingsKey(key)) {
      return super.deleteSetting(key);
    }
    if (await _isHostStoreKey(key)) {
      final existed = _store.values.containsKey(key);
      await _store.write(const {}, remove: [key]);
      return existed ? 1 : 0;
    }
    return super.deleteSetting(key);
  }

  @override
  Stream<String?> watchSetting(String key) {
    if (isDeviceLocalSettingKey(key)) return super.watchSetting(key);
    return _watch(() => getSetting(key));
  }

  @override
  Stream<Map<String, String>> watchAllSettings() => _watch(getAllSettings);

  /// Emit [read] now and again whenever the host's rows or the app-settings
  /// notifier change, skipping repeats of the same value.
  Stream<T> _watch<T>(Future<T> Function() read) {
    late StreamController<T> controller;
    StreamSubscription<Object?>? storeSub;
    StreamSubscription<Object?>? appSub;
    var hasLast = false;
    T? last;
    Future<void> emit() async {
      try {
        final value = await read();
        if (controller.isClosed) return;
        if (hasLast && _sameValue(last, value)) return;
        hasLast = true;
        last = value;
        controller.add(value);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<T>(
      onListen: () {
        storeSub = _store.changes.listen((_) => emit());
        appSub = _appSettings.changes.listen((_) => emit());
        unawaited(emit());
      },
      onCancel: () async {
        await storeSub?.cancel();
        await appSub?.cancel();
      },
    );
    return controller.stream;
  }

  static bool _sameValue(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        if (b[entry.key] != entry.value) return false;
      }
      return true;
    }
    return a == b;
  }
}
