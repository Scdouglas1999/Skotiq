/// The stored-row and host/client wire forms of [AppSettingsState], derived
/// from the settings table.
library;

import '../models/settings/app_settings.dart' as models;
import 'app_settings_state.g.dart';
import 'app_settings_table.dart';
import 'setting.dart';

abstract final class AppSettingsCodec {
  static final Map<String, Setting<Object?>> _byKey = {
    for (final setting in kAppSettingsTable)
      for (final key in setting.keys) key: setting,
  };

  static final Map<String, Setting<Object?>> _byWire = {
    for (final setting in kAppSettingsTable)
      if (setting.sync == SettingSync.host) setting.wire: setting,
  };

  /// Every `app_settings` row the settings are stored under.
  static final Set<String> storedKeys = Set.unmodifiable(_byKey.keys);

  /// Rows a linked client can change on the host through the typed settings.
  static final Set<String> hostKeys = Set.unmodifiable({
    for (final setting in kAppSettingsTable)
      if (setting.sync == SettingSync.host) setting.key,
  });

  /// Rows a linked client reads and writes through the host's key/value
  /// store.
  static final Set<String> hostStoreKeys = Set.unmodifiable({
    for (final setting in kAppSettingsTable)
      if (setting.sync == SettingSync.hostStore) setting.key,
  });

  /// Display rows a linked client keeps in its own database.
  static final Set<String> clientOwnKeys = Set.unmodifiable({
    for (final setting in kAppSettingsTable)
      if (setting.clientKeepsOwn) setting.key,
  });

  /// Rows that never leave the computer whose database holds them.
  static final Set<String> thisComputerKeys = Set.unmodifiable({
    for (final setting in kAppSettingsTable)
      if (setting.sync == SettingSync.thisComputer || setting.clientKeepsOwn)
        setting.key,
  });

  /// The setting stored under [key], if any.
  static Setting<Object?>? settingForKey(String key) => _byKey[key];

  /// The settings held in a full set of stored [rows]. A missing or
  /// unreadable row reads as the setting's default.
  static AppSettingsState fromRows(Map<String, String> rows) =>
      AppSettingsState.fromValues(
        (setting) => setting.fromRows(rows, setting.fallback),
      );

  /// Every stored row for [state].
  static Map<String, String> toRows(AppSettingsState state) => {
    for (final setting in kAppSettingsTable)
      ...setting.toRows(state.valueOf(setting)),
  };

  /// [current] with the settings named in [rows] replaced. An unreadable row
  /// keeps the current value.
  static AppSettingsState applyRows(
    AppSettingsState current,
    Map<String, String> rows,
  ) {
    var next = current;
    final seen = <Setting<Object?>>{};
    for (final key in rows.keys) {
      final setting = _byKey[key];
      if (setting == null || !seen.add(setting)) continue;
      next = next.withValue(
        setting,
        setting.fromRows(rows, current.valueOf(setting)),
      );
    }
    return next;
  }

  /// The wire snapshot of [state]. Wire fields no setting stands behind keep
  /// the values of [previous], the last snapshot received from the host.
  static models.AppSettings toWire(
    AppSettingsState state, {
    models.AppSettings? previous,
  }) {
    const blank = models.AppSettings();
    final json = blank
        .copyWith(
          observer: previous?.observer ?? blank.observer,
          telescope: previous?.telescope ?? blank.telescope,
          instrument: previous?.instrument ?? blank.instrument,
          updateCheckEnabled:
              previous?.updateCheckEnabled ?? blank.updateCheckEnabled,
          updateServerUrl: previous?.updateServerUrl ?? blank.updateServerUrl,
          updateChannel: previous?.updateChannel ?? blank.updateChannel,
          updateCheckIntervalHours:
              previous?.updateCheckIntervalHours ??
              blank.updateCheckIntervalHours,
          skippedUpdateVersion:
              previous?.skippedUpdateVersion ?? blank.skippedUpdateVersion,
        )
        .toJson();
    for (final setting in _byWire.values) {
      json[setting.wire] = setting.toJson(state.valueOf(setting));
    }
    json['location'] = <String, dynamic>{
      'latitude': state.latitude,
      'longitude': state.longitude,
      'elevation': state.elevation,
    };
    return models.AppSettings.fromJson(json);
  }

  /// The settings a host snapshot stands for. Settings the wire does not
  /// carry are at their defaults.
  static AppSettingsState fromWire(models.AppSettings remote) {
    final json = remote.toJson();
    var state = const AppSettingsState();
    for (final setting in _byWire.values) {
      final value = setting.fromJson(json[setting.wire]);
      if (!identical(value, invalidWireValue)) {
        state = state.withValue(setting, value);
      }
    }
    final location = remote.location;
    if (location != null) {
      state = state.copyWith(
        latitude: location.latitude,
        longitude: location.longitude,
        elevation: location.elevation,
      );
    }
    return state;
  }

  /// [current] with the one wire field [wireKey] set to [value], or null
  /// when the field is not a setting or the value has the wrong shape.
  static AppSettingsState? applyWireChange(
    AppSettingsState current,
    String wireKey,
    Object? value,
  ) {
    final setting = _byWire[wireKey];
    if (setting == null) return null;
    final decoded = setting.fromJson(value);
    if (identical(decoded, invalidWireValue)) return null;
    return current.withValue(setting, decoded);
  }
}
