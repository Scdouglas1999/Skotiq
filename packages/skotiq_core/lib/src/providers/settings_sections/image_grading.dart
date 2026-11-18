// Image Grading defaults. Owns the live-frame Pass/Reject
// thresholds the executor consults to auto-reject obviously-bad frames
// (catastrophic focus drift, trailed stars, clouds rolling in, etc.).
//
// Each threshold is independently nullable: passing `null` disables that
// specific check while keeping other grading active. The master switch
// [setEnableImageGrading] gates the whole subsystem.
//
// Owns:
//   * enableImageGrading (master)
//   * imageGradingHfrThresholdPx, imageGradingHfrBaselinePercent
//   * imageGradingEccentricityThreshold, imageGradingEccentricityBaselinePercent
//   * imageGradingStarCountMin, imageGradingStarCountDropPercent
//   * imageGradingMaxConsecutiveRejects, imageGradingRejectFolderPath
//
// Does NOT own:
//   * Per-node `quality_check` overrides on TakeExposure nodes — those live
//     in the sequence model, not in app settings.
// * Adaptive exposure (which is a separate system) → see
//     `adaptive_exposure.dart`.
part of '../settings_provider.dart';

double? _validateOptionalImageGradingDouble(
  String setting,
  double? value, {
  required double min,
  required double max,
}) {
  if (value == null) return null;
  if (!value.isFinite || value < min || value > max) {
    throw ArgumentError.value(
      value,
      setting,
      'must be a finite value between $min and $max',
    );
  }
  return value;
}

int? _validateOptionalImageGradingInt(
  String setting,
  int? value, {
  required int min,
  required int max,
}) {
  if (value == null) return null;
  if (value < min || value > max) {
    throw ArgumentError.value(value, setting, 'must be between $min and $max');
  }
  return value;
}

extension ImageGradingSettingsSection on AppSettingsNotifier {
  /// Master switch: when false, live frame Pass/Reject grading is disabled
  /// at the executor level. Per-node `quality_check` on TakeExposure
  /// nodes still wins; this only toggles the *default*.
  Future<void> setEnableImageGrading(bool value) =>
      _set(AppSettingDefs.enableImageGrading, value);

  /// Reject if HFR exceeds this absolute pixel value. Pass `null` to
  /// disable the check while keeping other grading enabled.
  Future<void> setImageGradingHfrThreshold(double? value) async {
    final validated = _validateOptionalImageGradingDouble(
      'HFR threshold',
      value,
      min: 0.1,
      max: 50,
    );
    await _set(AppSettingDefs.imageGradingHfrThresholdPx, validated);
  }

  /// Reject if HFR exceeds `baseline * (1 + percent / 100)`. Pass `null`
  /// to disable.
  Future<void> setImageGradingHfrBaselinePercent(double? value) async {
    final validated = _validateOptionalImageGradingDouble(
      'HFR baseline percent',
      value,
      min: 1,
      max: 500,
    );
    await _set(AppSettingDefs.imageGradingHfrBaselinePercent, validated);
  }

  /// Reject if median star eccentricity across the frame exceeds this
  /// value: 0.6 is a 1.25:1 smear, 0.8 a 1.7:1 smear. The star detector
  /// stops treating a source as a star past 0.95
  /// (`skotiq_imaging::DETECTION_MAX_ECCENTRICITY`) — it is a satellite
  /// trail by then — so thresholds above that never fire. Pass `null` to
  /// disable. The range below stays the full 0-1 domain of the quantity;
  /// the settings field is what caps operator input at the useful subrange.
  Future<void> setImageGradingEccentricityThreshold(double? value) async {
    final validated = _validateOptionalImageGradingDouble(
      'eccentricity threshold',
      value,
      min: 0,
      max: 1,
    );
    await _set(AppSettingDefs.imageGradingEccentricityThreshold, validated);
  }

  /// Reject if eccentricity exceeds its filter's baseline by more than this
  /// percent. Pass `null` to disable.
  Future<void> setImageGradingEccentricityBaselinePercent(double? value) async {
    final validated = _validateOptionalImageGradingDouble(
      'eccentricity baseline percent',
      value,
      min: 1,
      max: 500,
    );
    await _set(
      AppSettingDefs.imageGradingEccentricityBaselinePercent,
      validated,
    );
  }

  /// Reject if the star count falls more than this percent below its
  /// filter's baseline (50 => fewer than half the stars). Pass `null` to
  /// disable.
  Future<void> setImageGradingStarCountDropPercent(double? value) async {
    final validated = _validateOptionalImageGradingDouble(
      'star count drop percent',
      value,
      min: 1,
      max: 99,
    );
    await _set(AppSettingDefs.imageGradingStarCountDropPercent, validated);
  }

  /// Reject if star count drops below this absolute floor. Pass `null` to
  /// disable.
  Future<void> setImageGradingStarCountMin(int? value) async {
    final validated = _validateOptionalImageGradingInt(
      'minimum star count',
      value,
      min: 1,
      max: 100000,
    );
    await _set(AppSettingDefs.imageGradingStarCountMin, validated);
  }

  /// Notify the operator once when this many frames in a row are rejected;
  /// the run carries on. Required; the default is 3. Values outside the UI's 1–100 range
  /// are rejected so API callers cannot persist a value the settings page
  /// cannot represent.
  Future<void> setImageGradingMaxConsecutiveRejects(int value) async {
    final validated = _validateOptionalImageGradingInt(
      'maximum consecutive rejects',
      value,
      min: 1,
      max: 100,
    )!;
    await _set(AppSettingDefs.imageGradingMaxConsecutiveRejects, validated);
  }

  /// Override for the reject folder. `null` or empty => use the default
  /// `<save_path>/Reject/`. Relative paths resolve against the run
  /// save_path; absolute paths are honoured verbatim.
  Future<void> setImageGradingRejectFolderPath(String? value) async {
    final normalised = (value == null || value.trim().isEmpty) ? null : value;
    await _set(AppSettingDefs.imageGradingRejectFolderPath, normalised);
  }
}
