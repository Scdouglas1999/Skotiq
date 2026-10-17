import 'package:freezed_annotation/freezed_annotation.dart';

part 'flat_wizard_settings.freezed.dart';
part 'flat_wizard_settings.g.dart';

/// Global settings for flat wizard
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

    /// Default gain for flats
    @Default(0) int gain,

    /// Default binning for flats
    @Default(1) int binning,

    /// Save path for flat frames
    String? savePath,

    /// Create date subfolder
    @Default(true) bool createDateSubfolder,

    /// Create filter subfolders
    @Default(true) bool createFilterSubfolders,

    // Magic-number defaults promoted from
    // hardcoded constants in flat_wizard_service.dart.

    /// Per-frame download timeout (seconds). Was hardcoded
    /// `_imageDownloadTimeout = Duration(seconds: 60)`. Increase for very
    /// large sensors or slow USB hubs.
    @Default(60) int imageDownloadTimeoutSeconds,

    /// Max binary-search iterations for the calibration solver. Was a
    /// `int maxIterations = 8` default parameter in the service. Fewer
    /// iterations exits faster on stubborn filters but risks missing the
    /// target ADU; more iterations is slower but more accurate.
    @Default(8) int maxIterations,
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

    /// Whether this filter is enabled for capture
    @Default(true) bool enabled,

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

    /// Frames captured so far
    @Default(0) int capturedCount,

    /// Current measured ADU
    double? currentAdu,

    /// Calibration status
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
