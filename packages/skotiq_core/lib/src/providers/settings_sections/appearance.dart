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

/// Setters for visual-appearance and shell-chrome settings.
extension AppearanceSettingsSection on AppSettingsNotifier {
  Future<void> setTheme(String value) async {
    await _saveSetting('theme', value);
    _patchState((s) => s.copyWith(theme: value));
  }

  Future<void> setLanguage(String value) async {
    await _saveSetting('language', value);
    _patchState((s) => s.copyWith(language: value));
  }

  Future<void> setAccentColor(String value) async {
    await _saveSetting('accent_color', value);
    _patchState((s) => s.copyWith(accentColor: value));
  }

  Future<void> setFontSize(String value) async {
    await _saveSetting('font_size', value);
    _patchState((s) => s.copyWith(fontSize: value));
  }

  Future<void> setUiScale(String value) async {
    await _saveSetting('ui_scale', value);
    _patchState((s) => s.copyWith(uiScale: value));
  }

  Future<void> setSidebarCollapsed(bool value) async {
    await _saveSetting('sidebar_collapsed', value.toString());
    _patchState((s) => s.copyWith(sidebarCollapsed: value));
  }
}
