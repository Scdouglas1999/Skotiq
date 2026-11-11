// Visual appearance / shell-chrome knobs surfaced in
// Settings → Appearance. Owns the values driving the Material theme,
// localisation, and shell layout.
//
// Owns:
//   * theme, language, accentColor, fontSize, uiScale, sidebarCollapsed
//
// Does NOT own:
//   * critical-alert sound / push toggle → see `environment.dart`.
//   * Image-format / save-path knobs → see `imaging.dart` and
//     `file_paths.dart`.
part of '../settings_provider.dart';

extension AppearanceSettingsSection on AppSettingsNotifier {
  Future<void> setTheme(String value) => _set(AppSettingDefs.theme, value);

  Future<void> setLanguage(String value) => _set(AppSettingDefs.language, value);

  Future<void> setAccentColor(String value) =>
      _set(AppSettingDefs.accentColor, value);

  Future<void> setFontSize(String value) => _set(AppSettingDefs.fontSize, value);

  Future<void> setUiScale(String value) => _set(AppSettingDefs.uiScale, value);

  Future<void> setSidebarCollapsed(bool value) =>
      _set(AppSettingDefs.sidebarCollapsed, value);
}
