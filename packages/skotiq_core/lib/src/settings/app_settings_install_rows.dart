import 'app_settings_table.dart';

/// The application-settings rows a fresh install starts with.
Map<String, String> appSettingsInstallRows() => {
  for (final setting in kAppSettingsTable)
    if (setting.hasInstallRow)
      for (final row in setting.toRows(setting.fallback).entries)
        row.key: row.key == setting.key ? setting.seed ?? row.value : row.value,
};
