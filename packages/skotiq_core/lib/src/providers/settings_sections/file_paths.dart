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
  Future<void> setImageOutputPath(String value) async {
    // Keep the legacy key synchronized while older post-session consumers and
    // existing databases migrate to image_output_path.
    if (ref.read(backendProvider) is NetworkBackend) {
      // The remote wire model owns only the canonical field; the host's full
      // settings persistence mirrors it into the compatibility key.
      await _saveSetting('image_output_path', value);
    } else {
      await _saveSettings({
        'image_output_path': value,
        'default_image_directory': value,
      });
    }
    _patchState((s) => s.copyWith(imageOutputPath: value));
  }

  Future<void> setSequencesPath(String value) async {
    await _saveSetting('sequences_path', value);
    _patchState((s) => s.copyWith(sequencesPath: value));
  }

  Future<void> setDatabasePath(String value) async {
    await _saveSetting('database_path', value);
    _patchState((s) => s.copyWith(databasePath: value));
  }

  Future<void> setLogsPath(String value) async {
    await _saveSetting('logs_path', value);
    _patchState((s) => s.copyWith(logsPath: value));
  }
}
