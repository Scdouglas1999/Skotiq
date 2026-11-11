import 'package:freezed_annotation/freezed_annotation.dart';

part 'flat_wizard_settings.freezed.dart';
part 'flat_wizard_settings.g.dart';

@freezed
abstract class FlatWizardGlobalSettings with _$FlatWizardGlobalSettings {
  const factory FlatWizardGlobalSettings({
    /// Target histogram percentage (0-100), default 50%
    @Default(50.0) double histogramTarget,

    /// Tolerance as percentage of target (1-25), default 10%
    @Default(10.0) double tolerancePercent,

    /// Minimum exposure in seconds
    @Default(0.001) double minExposure,

    /// Maximum exposure in seconds
    @Default(30.0) double maxExposure,

    /// Number of frames to capture per filter
    @Default(30) int frameCount,

    @Default(0) int gain,

    @Default(1) int binning,

    String? savePath,

    @Default(true) bool createDateSubfolder,

    @Default(true) bool createFilterSubfolders,

    /// Per-frame download timeout (seconds). Was hardcoded
    /// `_imageDownloadTimeout = Duration(seconds: 60)`. Increase for very
    /// large sensors or slow USB hubs.
    @Default(60) int imageDownloadTimeoutSeconds,
    // The calibration attempt limit lives in app settings
    // (`AppSettingsState.flatCalibrationAttempts`), so the host and every
    // linked client use one value and every flat path reads it.
  }) = _FlatWizardGlobalSettings;

  factory FlatWizardGlobalSettings.fromJson(Map<String, dynamic> json) =>
      _$FlatWizardGlobalSettingsFromJson(json);
}

/// Per-filter settings override
@freezed
abstract class FlatFilterSettings with _$FlatFilterSettings {
  const factory FlatFilterSettings({
    required String filterName,

    /// Filter position in wheel (0-indexed)
    required int filterPosition,

    @Default(true) bool enabled,

    /// Null inherits the resolved camera/profile setting; zero is explicit.
    int? gainOverride,
    int? offsetOverride,

    /// Override histogram target (null = use global)
    double? histogramTargetOverride,

    /// Override tolerance (null = use global)
    double? toleranceOverride,

    /// Override min exposure (null = use global)
    double? minExposureOverride,

    /// Override max exposure (null = use global)
    double? maxExposureOverride,

    /// Override frame count (null = use global)
    int? frameCountOverride,

    /// Suggested exposure from history (informational)
    double? suggestedExposure,

    /// Current calibrated exposure (set after tuning)
    double? calibratedExposure,

    @Default(0) int capturedCount,

    double? currentAdu,

    @Default(FilterCalibrationStatus.pending) FilterCalibrationStatus status,
  }) = _FlatFilterSettings;

  factory FlatFilterSettings.fromJson(Map<String, dynamic> json) =>
      _$FlatFilterSettingsFromJson(json);
}

enum FilterCalibrationStatus {
  pending,
  calibrating,
  calibrated,
  capturing,
  complete,

  /// Calibration succeeded and capture ran, but fewer frames were saved than
  /// requested (some per-frame captures/saves failed, or the run was cancelled
  /// after at least one frame was written). Distinct from [complete] so the
  /// filter card never claims a full set when only part of it landed on disk.
  partial,
  failed,
  skipped,
}

/// Filter preset for quick selection
@freezed
abstract class FlatFilterPreset with _$FlatFilterPreset {
  const factory FlatFilterPreset({
    required String name,
    required List<String> filterNames,
  }) = _FlatFilterPreset;

  factory FlatFilterPreset.fromJson(Map<String, dynamic> json) =>
      _$FlatFilterPresetFromJson(json);
}
