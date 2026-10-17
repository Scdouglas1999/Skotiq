import 'package:freezed_annotation/freezed_annotation.dart';

part 'annotation_settings.freezed.dart';
part 'annotation_settings.g.dart';

/// Grid overlay type for the imaging view
enum GridType {
  /// No grid overlay
  none,

  /// Fixed pixel-based grid (existing behavior)
  pixel,

  /// RA/Dec celestial coordinate grid (requires plate solve)
  celestial,
}

/// Object types that can be displayed in annotations
enum AnnotationObjectFilter {
  galaxies,
  nebulae,
  starClusters,
  planetaryNebulae,
  stars,
  other,
}

/// Settings for controlling annotation display and behavior
@freezed
abstract class AnnotationSettings with _$AnnotationSettings {
  const factory AnnotationSettings({
    /// Whether annotations are enabled
    @Default(true) bool enabled,

    /// Magnitude cutoff for displayed objects (fainter = higher number)
    @Default(15.0) double magnitudeCutoff,

    /// Minimum magnitude to display (brighter = lower number)
    @Default(-5.0) double minMagnitude,

    /// Object types to display
    @Default({
      AnnotationObjectFilter.galaxies,
      AnnotationObjectFilter.nebulae,
      AnnotationObjectFilter.starClusters,
      AnnotationObjectFilter.planetaryNebulae,
    })
    Set<AnnotationObjectFilter> visibleTypes,

    /// Whether to show object labels
    @Default(true) bool showLabels,

    /// Whether to show magnitude values
    @Default(false) bool showMagnitudes,

    /// Whether to fade annotations when mouse is not over image
    @Default(true) bool fadeWhenNotHovering,

    /// Opacity when mouse is hovering over image (0.0-1.0)
    @Default(0.8) double hoverOpacity,

    /// Opacity when mouse is not hovering (0.0-1.0)
    @Default(0.2) double idleOpacity,

    /// Duration of fade animation in milliseconds
    @Default(400) int fadeAnimationMs,

    /// Whether to enable click-to-identify
    @Default(true) bool clickToIdentify,

    /// Search radius for click-to-identify in arcseconds
    @Default(30.0) double clickSearchRadiusArcsec,

    /// Whether to auto-annotate new captured images
    @Default(true) bool autoAnnotate,

    /// Maximum number of objects to display
    @Default(500) int maxObjectsToDisplay,

    /// Fractional padding around the catalog FOV bounding box. 0.05 = 5%
    /// padding. Increase if large DSOs whose centre is just off-frame are
    /// getting clipped from the overlay; decrease to query faster on slow
    /// disks.
    @Default(0.05) double catalogBboxPaddingFraction,

    /// Whether to show compass overlay (N/E arrows from plate solve rotation)
    @Default(true) bool compassEnabled,

    /// Whether to show scale bar overlay (angular size reference)
    @Default(true) bool scaleBarEnabled,

    /// Grid overlay type (none, pixel, or celestial RA/Dec)
    @Default(GridType.none) GridType gridType,

    /// Whether to show plate solve residual vectors overlay
    @Default(false) bool showSolveResiduals,
  }) = _AnnotationSettings;

  factory AnnotationSettings.fromJson(Map<String, dynamic> json) =>
      _$AnnotationSettingsFromJson(json);
}

/// Display settings for individual annotation markers
@freezed
abstract class AnnotationMarkerStyle with _$AnnotationMarkerStyle {
  const factory AnnotationMarkerStyle({
    /// Color for galaxy markers (gold)
    @Default(0xFFFFD700) int galaxyColor,

    /// Color for nebula markers (magenta)
    @Default(0xFFFF00FF) int nebulaColor,

    /// Color for star cluster markers (cyan)
    @Default(0xFF00FFFF) int clusterColor,

    /// Color for planetary nebula markers (violet)
    @Default(0xFF9400D3) int planetaryNebulaColor,

    /// Color for star markers (white)
    @Default(0xFFFFFFFF) int starColor,

    /// Color for unknown/other markers (green)
    @Default(0xFF00FF00) int otherColor,

    /// Stroke width for marker outlines
    @Default(1.5) double strokeWidth,

    /// Font size for labels
    @Default(12.0) double labelFontSize,

    /// Whether to scale markers based on object size
    @Default(true) bool scaleBySize,

    /// Minimum marker size in pixels
    @Default(10.0) double minMarkerSize,

    /// Maximum marker size in pixels
    @Default(100.0) double maxMarkerSize,
  }) = _AnnotationMarkerStyle;

  factory AnnotationMarkerStyle.fromJson(Map<String, dynamic> json) =>
      _$AnnotationMarkerStyleFromJson(json);
}

/// Named preset for annotation display settings
@freezed
abstract class AnnotationPreset with _$AnnotationPreset {
  const factory AnnotationPreset({
    required String name,
    required Set<AnnotationObjectFilter> visibleTypes,
    required double minMagnitude,
    required double magnitudeCutoff,
    required bool showLabels,
    required bool showMagnitudes,
    @Default(false) bool isBuiltIn,
  }) = _AnnotationPreset;

  factory AnnotationPreset.fromJson(Map<String, dynamic> json) =>
      _$AnnotationPresetFromJson(json);
}

/// Type of user-drawn annotation on the image
enum CustomAnnotationType { circle, arrow, text }

/// A user-drawn annotation on the image (circle, arrow, or text)
@freezed
abstract class CustomAnnotation with _$CustomAnnotation {
  const factory CustomAnnotation({
    required String id,
    required CustomAnnotationType type,

    /// Image pixel X of the anchor point (center for circles, start for arrows, position for text)
    required double x,
    required double y,

    /// For circles: radius in pixels. For arrows: end X.
    double? x2,

    /// For arrows: end Y.
    double? y2,

    /// For circles: radius in pixels.
    double? radius,

    /// Label text
    @Default('') String label,

    /// Color as ARGB int
    @Default(0xFFFF6B6B) int color,
  }) = _CustomAnnotation;

  factory CustomAnnotation.fromJson(Map<String, dynamic> json) =>
      _$CustomAnnotationFromJson(json);
}
