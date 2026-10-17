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
  Future<void> setPreflightStrictness(PreflightStrictness value) async {
    await _saveSetting('preflight_strictness', value.persistedName);
    _patchState((s) => s.copyWith(preflightStrictness: value));
  }

  /// Maximum age in days for the last polar alignment before pre-flight
  /// considers it stale. Zero disables the freshness check; positive values
  /// are clamped to [1, 365].
  Future<void> setPolarAlignmentMaxAgeDays(int value) async {
    final clamped = value.clamp(0, 365);
    await _saveSetting('polar_alignment_max_age_days', clamped.toString());
    _patchState((s) => s.copyWith(polarAlignmentMaxAgeDays: clamped));
  }

  /// Minimum coverage (number of dark frames) before a (gain, offset,
  /// temp, duration, binning) combination is considered "well covered".
  /// Clamped to [1, 1000].
  Future<void> setDarkLibraryMinCoverage(int value) async {
    final clamped = value.clamp(1, 1000);
    await _saveSetting('dark_library_min_coverage', clamped.toString());
    _patchState((s) => s.copyWith(darkLibraryMinCoverage: clamped));
  }

  /// Threshold for the optical-train pre-flight drift comparison. Clamped
  /// to [0.1, 1000.0]. Larger values silence the check; smaller values
  /// surface every minor reshuffle.
  Future<void> setOpticalTrainDriftThreshold(double value) async {
    final clamped = value.clamp(0.1, 1000.0);
    await _saveSetting('optical_train_drift_threshold', clamped.toString());
    _patchState((s) => s.copyWith(opticalTrainDriftThreshold: clamped));
  }
}
