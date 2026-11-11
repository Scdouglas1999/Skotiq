// Pre-flight check defaults. Owns how aggressively the
// pre-flight dialog warns / blocks on questionable conditions.
//
// Owns:
//   * preflightStrictness (the lax/normal/strict enum)
//   * polarAlignmentMaxAgeDays (staleness threshold)
//   * darkLibraryMinCoverage (frames-per-bin quorum)
//   * opticalTrainDriftThreshold (rig-reshuffle detector)
//
// Does NOT own:
//   * Smart Night uses its own polar-alignment staleness window (a user
//     may want pre-flight to fire at 7 days but Smart Night to prepend an
//     alignment only at 14 days) → see `smart_night.dart`.
//   * Dark library generation defaults → those live in
//     `dark_library_provider.dart`, not in app settings.
part of '../settings_provider.dart';

/// Setters for pre-flight strictness and the rule-tuning knobs the
/// pre-flight dialog consults.
extension PreflightSettingsSection on AppSettingsNotifier {
  /// Pre-flight strictness mode. See [PreflightStrictness] for what each
  /// value implies for rule severities.
  Future<void> setPreflightStrictness(PreflightStrictness value) =>
      _set(AppSettingDefs.preflightStrictness, value);

  /// Maximum age in days for the last polar alignment before pre-flight
  /// considers it stale. Zero disables the freshness check; positive values
  /// are clamped to [1, 365].
  Future<void> setPolarAlignmentMaxAgeDays(int value) =>
      _set(AppSettingDefs.polarAlignmentMaxAgeDays, value);

  /// Minimum coverage (number of dark frames) before a (gain, offset,
  /// temp, duration, binning) combination is considered "well covered".
  /// Clamped to [1, 1000].
  Future<void> setDarkLibraryMinCoverage(int value) =>
      _set(AppSettingDefs.darkLibraryMinCoverage, value);

  /// Threshold for the optical-train pre-flight drift comparison. Clamped
  /// to [0.1, 1000.0]. Larger values silence the check; smaller values
  /// surface every minor reshuffle.
  Future<void> setOpticalTrainDriftThreshold(double value) =>
      _set(AppSettingDefs.opticalTrainDriftThreshold, value);
}
