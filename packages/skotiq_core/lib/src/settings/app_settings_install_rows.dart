import 'app_settings_table.dart';
import 'setting.dart';
import 'store_settings.dart';

/// The application-settings rows a fresh install starts with.
Map<String, String> appSettingsInstallRows() => _installRows(kAppSettingsTable);

/// The rows a fresh install starts with for the settings features keep in
/// the settings store.
Map<String, String> storeSettingsInstallRows() =>
    _installRows(StoreSettings.all);

Map<String, String> _installRows(List<Setting<Object?>> settings) => {
  for (final setting in settings)
    if (setting.hasInstallRow)
      for (final row in setting.toRows(setting.fallback).entries)
        row.key: row.key == setting.key ? setting.seed ?? row.value : row.value,
};
