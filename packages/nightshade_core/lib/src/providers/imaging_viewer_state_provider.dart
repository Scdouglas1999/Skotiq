import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Immutable view state for the imaging preview viewer.
///
/// Pulled out of `_ImagingScreenState` so navigation, hot-reload, and screen
/// rebuilds do not reset the user's pan / zoom / overlay choices, and so other
/// surfaces (e.g. fullscreen preview, secondary monitor mirror) can read the
/// same state without prop-drilling through widget constructors.
@immutable
class ImagingViewerState {
  /// 1.0 = fit-to-window. Clamped at the call site.
  final double zoomLevel;

  /// Pan offset accumulated while dragging the preview.
  final Offset panOffset;

  /// Crosshair overlay visibility.
  final bool showCrosshair;

  /// Reticle / grid overlay visibility.
  final bool showGrid;

  /// Star detection markers overlay visibility.
  final bool showStarOverlay;

  const ImagingViewerState({
    this.zoomLevel = 1.0,
    this.panOffset = Offset.zero,
    this.showCrosshair = false,
    this.showGrid = false,
    this.showStarOverlay = false,
  });

  ImagingViewerState copyWith({
    double? zoomLevel,
    Offset? panOffset,
    bool? showCrosshair,
    bool? showGrid,
    bool? showStarOverlay,
  }) {
    return ImagingViewerState(
      zoomLevel: zoomLevel ?? this.zoomLevel,
      panOffset: panOffset ?? this.panOffset,
      showCrosshair: showCrosshair ?? this.showCrosshair,
      showGrid: showGrid ?? this.showGrid,
      showStarOverlay: showStarOverlay ?? this.showStarOverlay,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImagingViewerState &&
          runtimeType == other.runtimeType &&
          zoomLevel == other.zoomLevel &&
          panOffset == other.panOffset &&
          showCrosshair == other.showCrosshair &&
          showGrid == other.showGrid &&
          showStarOverlay == other.showStarOverlay;

  @override
  int get hashCode => Object.hash(
    zoomLevel,
    panOffset,
    showCrosshair,
    showGrid,
    showStarOverlay,
  );
}

/// Notifier exposing intent-based mutators so callers don't have to hand-roll
/// clamping or copyWith chains, and so behavior (zoom step / clamp range) lives
/// in one place.
class ImagingViewerStateNotifier extends StateNotifier<ImagingViewerState> {
  ImagingViewerStateNotifier() : super(const ImagingViewerState());

  /// Bounds on the scale the frame is actually DRAWN at (screen pixels per
  /// image pixel), not on the fit-relative multiplier.
  static const double minDisplayScale = 0.05;
  static const double maxDisplayScale = 8.0;
  static const double zoomStep = 1.25;

  /// Multiplier bounds for a preview whose fit scale is [fitScale].
  ///
  /// Both are pinned so that fit (multiplier 1.0) is always inside the range —
  /// a sensor big enough that fit is below [minDisplayScale] must still be
  /// viewable whole.
  static double _minZoom(double fitScale) =>
      fitScale <= 0 ? 1.0 : math.min(1.0, minDisplayScale / fitScale);

  static double _maxZoom(double fitScale) =>
      fitScale <= 0 ? 1.0 : math.max(1.0, maxDisplayScale / fitScale);

  /// [fitScale] is screen pixels per image pixel at multiplier 1.0, as measured
  /// by the preview (`previewFitScaleProvider`). It defaults to 1.0 — the value
  /// for a frame that fits natively — so a caller with no preview laid out gets
  /// fit-relative behaviour rather than an exception.
  void zoomIn({double fitScale = 1.0}) {
    final next = (state.zoomLevel * zoomStep).clamp(
      _minZoom(fitScale),
      _maxZoom(fitScale),
    );
    state = state.copyWith(zoomLevel: next);
  }

  void zoomOut({double fitScale = 1.0}) {
    final next = (state.zoomLevel / zoomStep).clamp(
      _minZoom(fitScale),
      _maxZoom(fitScale),
    );
    state = state.copyWith(zoomLevel: next);
  }

  /// Reset to fit-to-window: zoom 1.0, pan zeroed.
  void fitToWindow() {
    state = state.copyWith(zoomLevel: 1.0, panOffset: Offset.zero);
  }

  /// Show the frame at one image pixel per screen pixel.
  ///
  /// Stored zoom is relative to fit, so 1:1 is `1 / fitScale`.
  void zoom1to1({double fitScale = 1.0}) {
    if (fitScale <= 0) return;
    final next = (1.0 / fitScale).clamp(_minZoom(fitScale), _maxZoom(fitScale));
    state = state.copyWith(zoomLevel: next, panOffset: Offset.zero);
  }

  void pan(Offset delta) {
    state = state.copyWith(panOffset: state.panOffset + delta);
  }

  void toggleCrosshair() {
    state = state.copyWith(showCrosshair: !state.showCrosshair);
  }

  void toggleGrid() {
    state = state.copyWith(showGrid: !state.showGrid);
  }

  void toggleStarOverlay() {
    state = state.copyWith(showStarOverlay: !state.showStarOverlay);
  }
}

/// View state for the imaging preview area (zoom, pan, overlay flags).
final imagingViewerStateProvider =
    StateNotifierProvider<ImagingViewerStateNotifier, ImagingViewerState>(
      (ref) => ImagingViewerStateNotifier(),
    );
