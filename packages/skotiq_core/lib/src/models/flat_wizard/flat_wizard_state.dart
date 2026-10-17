import 'package:freezed_annotation/freezed_annotation.dart';
import 'flat_wizard_settings.dart';

part 'flat_wizard_state.freezed.dart';
part 'flat_wizard_state.g.dart';

enum FlatWizardMode { quick, batch, skyFlats }

enum TwilightMode { dawn, dusk }

class RuntimeOnlyValueConverter implements JsonConverter<Object?, Object?> {
  const RuntimeOnlyValueConverter();

  @override
  Object? fromJson(Object? json) => null;

  @override
  Object? toJson(Object? object) => null;
}

/// ADU measurement for tracking convergence
@freezed
abstract class AduMeasurement with _$AduMeasurement {
  const factory AduMeasurement({
    required double exposure,
    required double adu,
    required DateTime timestamp,
  }) = _AduMeasurement;

  factory AduMeasurement.fromJson(Map<String, dynamic> json) =>
      _$AduMeasurementFromJson(json);
}

/// Sky brightness measurement for rate tracking
@freezed
abstract class SkyBrightnessMeasurement with _$SkyBrightnessMeasurement {
  const factory SkyBrightnessMeasurement({
    required double adu,
    required double exposureUsed,
    required DateTime timestamp,
  }) = _SkyBrightnessMeasurement;

  factory SkyBrightnessMeasurement.fromJson(Map<String, dynamic> json) =>
      _$SkyBrightnessMeasurementFromJson(json);
}

/// Complete flat wizard state
@freezed
abstract class FlatWizardState with _$FlatWizardState {
  const factory FlatWizardState({
    /// Current operating mode
    @Default(FlatWizardMode.quick) FlatWizardMode mode,

    /// Global settings
    @Default(FlatWizardGlobalSettings())
    FlatWizardGlobalSettings globalSettings,

    /// Per-filter settings
    @Default([]) List<FlatFilterSettings> filterSettings,

    /// Saved filter presets
    @Default([]) List<FlatFilterPreset> filterPresets,

    /// Current filter index being processed
    @Default(0) int currentFilterIndex,

    /// Current frame index for active filter
    @Default(0) int currentFrameIndex,

    /// Is capture/calibration in progress
    @Default(false) bool isCapturing,

    /// Is currently exposing (for countdown)
    @Default(false) bool isExposing,

    /// Current exposure start time (for countdown)
    DateTime? exposureStartTime,

    /// Current exposure duration (for countdown)
    double? currentExposureDuration,

    /// ADU measurements for convergence graph
    @Default([]) List<AduMeasurement> aduHistory,

    /// Sky brightness measurements for rate tracking
    @Default([]) List<SkyBrightnessMeasurement> skyBrightnessHistory,

    /// Calculated sky brightness change rate (ADU/s)
    double? skyAduRate,

    /// Twilight mode for sky flats
    @Default(TwilightMode.dusk) TwilightMode twilightMode,

    /// Most recent captured image path
    String? lastImagePath,

    /// Most recent captured image data (for preview, runtime only)
    @RuntimeOnlyValueConverter() Object? lastImageData,

    /// Error message if any
    String? errorMessage,

    /// Warning message (non-fatal, informational)
    String? warningMessage,

    /// Status message for progress display
    String? statusMessage,

    /// Visualization toggles
    @Default(true) bool showAduGraph,
    @Default(true) bool showExposureTimeline,
    @Default(true) bool showSkyBrightness,
    @Default(true) bool showFilterCards,
    @Default(false) bool showHistogramOverlay,
  }) = _FlatWizardState;

  factory FlatWizardState.fromJson(Map<String, dynamic> json) =>
      _$FlatWizardStateFromJson(json);
}
