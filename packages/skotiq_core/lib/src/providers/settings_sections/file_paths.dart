// File-path defaults surfaced in Settings → File Paths. Owns where the
// app writes images, sequence files, the SQLite database, and the log
// directory.
//
// Owns:
//   * imageOutputPath, sequencesPath, databasePath, logsPath
//
// Does NOT own:
//   * Image-grading reject folder override → see `image_grading.dart`
//     (it's a per-rule override, not a global default).
//   * The platform-specific default values these fall back to when empty
//     — those resolve in the relevant service (ImagingService for
//     imageOutputPath, etc.).
part of '../settings_provider.dart';

/// Setters for global file-path defaults.
extension FilePathSettingsSection on AppSettingsNotifier {
  Future<void> setImageOutputPath(String value) =>
      _set(AppSettingDefs.imageOutputPath, value);

  Future<void> setSequencesPath(String value) =>
      _set(AppSettingDefs.sequencesPath, value);

  Future<void> setDatabasePath(String value) =>
      _set(AppSettingDefs.databasePath, value);

  Future<void> setLogsPath(String value) => _set(AppSettingDefs.logsPath, value);
}
