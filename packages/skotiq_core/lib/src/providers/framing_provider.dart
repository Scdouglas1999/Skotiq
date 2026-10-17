import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../backend/network_backend.dart';
import '../database/daos/settings_dao.dart';
import '../models/equipment/equipment_models.dart';
import '../models/framing_plate_scale.dart';
import '../models/planning/target_suggestion.dart';
import '../models/target/target_models.dart';
import '../services/mosaic_project_service.dart';
import '../services/sensor_specs/camera_sensor_specs.dart';
import '../services/target_library_service.dart';
import '../utils/coordinate_format.dart';
import '../utils/coordinate_parser.dart';
import 'backend_provider.dart';
import 'camera_sensor_specs_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart';
import 'framing_image_cache_provider.dart';
import 'profiles_provider.dart';

part 'framing_provider/models.dart';
part 'framing_provider/support.dart';
part 'framing_provider/survey_operations.dart';

// Astronomy HTTP client

/// Shared HTTP client for astronomy server requests.
/// Uses standard certificate verification — no SSL bypass.

// Framing state notifier

class FramingNotifier extends StateNotifier<FramingState> {
  final Ref _ref;
  static const _surveyImageTimeout = Duration(seconds: 30);

  /// Pixel width of the survey cutout to request when the canvas size is not
  /// yet known (first load before any layout pass). Once the canvas has been
  /// measured, the request resolution tracks the canvas width (see
  /// [_requestPixelWidthFor]) so the imagery stays crisp on wide displays.
  static const int _defaultRequestPixelWidth = 800;

  /// Hard cap on the requested cutout pixel width. Bounds the network payload
  /// and decode cost even on ultra-wide canvases.
  static const int _maxRequestPixelWidth = 2048;

  /// Fractional canvas-width change required before a resize triggers a
  /// higher-resolution survey re-fetch. A resize that grows the canvas by less
  /// than this is absorbed by the existing cutout (scaled up by the painter)
  /// rather than hammering the survey servers on every drag of the splitter.
  static const double _resizeRefetchGrowthFraction = 0.25;

  /// The canvas width (logical px) the currently-loaded cutout was sized for.
  /// Drives the resize-reload decision in [onCanvasResized]; reset to `null`
  /// whenever the image is cleared so the next load re-establishes it.
  double? _cutoutCanvasWidthPx;
  Object? _surveyRequestToken;
  int _targetPushRevision = 0;
  Future<void> _targetPushTail = Future<void>.value();

  FramingNotifier(this._ref) : super(const FramingState()) {
    _ref.listen(backendProvider, (previous, next) {
      if (!mounted || identical(previous, next)) return;
      _cancelPendingTargetWork();
      _cutoutCanvasWidthPx = null;
      state = state.copyWith(clearTarget: true, clearImage: true);
    });
  }

  FramingState get _currentState => state;
  set _currentState(FramingState value) => state = value;

  Future<void> loadSurveyImage({double? canvasWidthLogicalPx}) {
    final token = Object();
    _surveyRequestToken = token;
    return _loadSurveyImage(
      token: token,
      canvasWidthLogicalPx: canvasWidthLogicalPx,
    );
  }

  bool _isCurrentSurveyRequest(
    Object token,
    FramingTarget target,
    SurveySource source,
  ) {
    return mounted &&
        identical(token, _surveyRequestToken) &&
        identical(target, state.target) &&
        source == state.surveySource;
  }

  void _cancelPendingTargetWork() {
    _surveyRequestToken = Object();
    _targetPushRevision++;
    _targetPushTail = Future<void>.value();
  }

  /// The cutout pixel width to request for a canvas of [canvasWidthLogicalPx]
  /// logical pixels.
  ///
  /// We request roughly one survey pixel per logical canvas pixel (clamped to
  /// [_maxRequestPixelWidth]) so the fit-to-canvas draw does not visibly
  /// upscale the imagery. With no measured canvas yet we fall back to
  /// [_defaultRequestPixelWidth].
  int _requestPixelWidthFor(double? canvasWidthLogicalPx) {
    if (canvasWidthLogicalPx == null || canvasWidthLogicalPx <= 0) {
      return _defaultRequestPixelWidth;
    }
    return canvasWidthLogicalPx.ceil().clamp(
      _defaultRequestPixelWidth,
      _maxRequestPixelWidth,
    );
  }

  /// React to the framing canvas being resized.
  ///
  /// C9's plate-scale-aware reload: when the canvas grows enough that the
  /// loaded cutout would be upscaled past [_resizeRefetchGrowthFraction], we
  /// re-fetch a higher-resolution cutout sized to the new canvas so the survey
  /// imagery stays sharp. Shrinking the canvas, or a not-yet-loaded image, is a
  /// no-op (the existing cutout already over-covers a smaller canvas).
  void onCanvasResized(ui.Size canvasSize) {
    final width = canvasSize.width;
    if (width <= 0 || state.target == null || state.surveyImage == null) {
      return;
    }
    final last = _cutoutCanvasWidthPx;
    if (last == null) {
      _cutoutCanvasWidthPx = width;
      return;
    }
    if (width <= last * (1.0 + _resizeRefetchGrowthFraction)) {
      // Growth within tolerance (or a shrink): keep the existing cutout.
      return;
    }
    // Avoid re-fetching past the resolution cap — once we are already at the
    // max cutout width, a larger canvas cannot get any sharper.
    if (_requestPixelWidthFor(last) >= _maxRequestPixelWidth &&
        _requestPixelWidthFor(width) >= _maxRequestPixelWidth) {
      _cutoutCanvasWidthPx = width;
      return;
    }
    _cutoutCanvasWidthPx = width;
    loadSurveyImage(canvasWidthLogicalPx: width);
  }

  /// Set the target by coordinates
  void setTargetCoordinates(
    double raHours,
    double decDegrees, {
    String? name,
    bool fromRemoteSync = false,
  }) {
    final targetName = name ?? 'Custom Location';
    final target = FramingTarget(
      name: targetName,
      raHours: raHours,
      decDegrees: decDegrees,
    );
    state = state.copyWith(
      target: target,
      clearImage: true,
      clearSourceSuggestion: true,
      // A fresh user-picked aim point: the reticle starts centered on the new
      // target, so any aim dragged onto a previous target must not carry over.
      clearAim: true,
    );
    loadSurveyImage();

    if (fromRemoteSync) {
      // Echo of a host-driven change — do not re-persist or push back.
      _targetPushRevision++;
      _targetPushTail = Future<void>.value();
      return;
    }

    _rememberLastFramedTarget(target);

    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      _queueTargetPush(
        backend,
        raHours: raHours,
        decDegrees: decDegrees,
        name: targetName,
      );
    }
  }

  /// Set the target from a planner/suggestion result while keeping the full
  /// source suggestion around for Smart Night sequence generation.
  void setTargetSuggestion(TargetSuggestion suggestion) {
    final target = FramingTarget(
      name: suggestion.targetName,
      catalogId: suggestion.catalogId,
      raHours: suggestion.raHours,
      decDegrees: suggestion.decDegrees,
      type: _targetTypeFromSuggestion(suggestion.objectType),
      objectType: suggestion.objectType,
      magnitude: suggestion.magnitude,
      sizeArcmin: suggestion.sizeArcmin,
      constellation: suggestion.constellation,
    );
    state = state.copyWith(
      target: target,
      sourceSuggestion: suggestion,
      clearImage: true,
      clearAim: true,
    );
    loadSurveyImage();
    _rememberLastFramedTarget(target);

    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      _queueTargetPush(
        backend,
        raHours: target.raHours,
        decDegrees: target.decDegrees,
        name: target.name,
      );
    }
  }

  void _queueTargetPush(
    NetworkBackend backend, {
    required double raHours,
    required double decDegrees,
    required String name,
  }) {
    final revision = ++_targetPushRevision;
    _targetPushTail = _targetPushTail.then((_) async {
      if (!mounted ||
          revision != _targetPushRevision ||
          !identical(backend, _ref.read(backendProvider))) {
        return;
      }
      await _pushTargetToHost(
        backend,
        raHours: raHours,
        decDegrees: decDegrees,
        name: name,
      );
    });
  }

  Future<void> _pushTargetToHost(
    NetworkBackend backend, {
    required double raHours,
    required double decDegrees,
    required String name,
  }) async {
    try {
      await backend.framingSetTarget(ra: raHours, dec: decDegrees, name: name);
    } catch (e, stackTrace) {
      developer.log(
        'Failed to push framing target to host: $e',
        name: 'FramingNotifier',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Set the target from a catalog search result
  void setTarget(FramingTarget target) {
    state = state.copyWith(target: target, clearImage: true, clearAim: true);
    loadSurveyImage();
    _rememberLastFramedTarget(target);

    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      _queueTargetPush(
        backend,
        raHours: target.raHours,
        decDegrees: target.decDegrees,
        name: target.name,
      );
    }
  }

  /// Fire-and-forget persistence of the last framed target to the single
  /// settings key. Failures are logged, never silently swallowed, but must not
  /// block target selection (which is a synchronous UI action).
  void _rememberLastFramedTarget(FramingTarget target) {
    unawaited(
      persistLastFramedTarget(target).catchError((Object e, StackTrace s) {
        developer.log(
          'Failed to persist last framed target: $e',
          name: 'FramingNotifier',
          level: 1000,
          error: e,
          stackTrace: s,
        );
      }),
    );
  }

  /// Clear the current target
  void clearTarget() {
    _cancelPendingTargetWork();
    _cutoutCanvasWidthPx = null;
    state = state.copyWith(clearTarget: true, clearImage: true);
  }

  /// Set the survey source
  void setSurveySource(SurveySource source) {
    state = state.copyWith(surveySource: source, clearImage: true);
    if (state.target != null) {
      loadSurveyImage();
    }
  }

  /// Set frame rotation, normalized to the canonical [-180, 180) domain.
  ///
  /// The on-canvas rotation handle reports angles via `atan2`, which can fall
  /// anywhere in (-180, 180], and a wrapping `% 360` would push values into
  /// (180, 360). The paired rotation `Slider` is declared `min: -180, max: 180`
  /// and asserts `min <= value <= max`, so the rotation domain must agree:
  /// wrap into [-180, 180) here so the gesture and the slider never desync (and
  /// the slider can never be handed an out-of-range value).
  void setRotation(double degrees) {
    var normalized = degrees % 360;
    if (normalized >= 180) {
      normalized -= 360;
    } else if (normalized < -180) {
      normalized += 360;
    }
    state = state.copyWith(rotation: normalized);
    if (state.mosaicEnabled) {
      _recalculateMosaicPanels();
    }
  }

  /// Set zoom level
  void setZoom(double zoom) {
    state = state.copyWith(zoom: zoom.clamp(0.25, 4.0));
  }

  /// Zoom in
  void zoomIn() {
    setZoom(state.zoom * 1.25);
  }

  /// Zoom out
  void zoomOut() {
    setZoom(state.zoom / 1.25);
  }

  /// Reset zoom, pan, and the dragged-out aim (the box re-centers on the
  /// view-center target).
  void resetView() {
    state = state.copyWith(zoom: 1.0, panX: 0, panY: 0, clearAim: true);
  }

  /// Set pan offset
  void setPan(double x, double y) {
    state = state.copyWith(panX: x, panY: y);
  }

  /// Move the FOV reticle's aim point on the sky, in absolute coordinates.
  ///
  /// This is the "drag the FOV box, sky stays" gesture's write path: it shifts
  /// where the telescope will point WITHOUT touching [FramingState.target]
  /// (the view center the survey cutout and the sky<->screen projection are
  /// anchored to) or the pan/zoom view transform — so the sky stays put while
  /// the box moves over it.
  ///
  /// RA is normalized to [0, 24) hours and Dec clamped to [-90, 90], the same
  /// bounds [_recenterFromPan] applies to the view center. When mosaic mode is
  /// on the panel grid is a capture plan around the aim, so it is rebuilt here
  /// exactly as [setRotation] rebuilds it. Non-finite input is dropped — a
  /// NaN/Infinity aim would render the reticle nowhere and feed garbage into
  /// the pointing consumers that read the effective aim.
  void setAim(double raHours, double decDegrees) {
    if (!raHours.isFinite || !decDegrees.isFinite) return;
    var ra = raHours % 24.0;
    if (ra < 0) ra += 24.0;
    state = state.copyWith(
      aimRaHours: ra,
      aimDecDegrees: decDegrees.clamp(-90.0, 90.0),
    );
    if (state.mosaicEnabled) {
      _recalculateMosaicPanels();
    }
  }

  /// Accumulated pan, as a fraction of the survey FOV width, at which the view
  /// has drifted far enough from the fetched cutout's center that we re-fetch a
  /// fresh cutout centered on the new look-direction. Beyond this the existing
  /// survey background no longer covers what the user is looking at.
  static const double _panRefetchFovFraction = 0.35;

  /// Add to the current pan offset (in logical canvas pixels).
  ///
  /// Most pans are a pure display transform. However, once the accumulated pan
  /// has dragged the view center more than [_panRefetchFovFraction] of the
  /// survey FOV away from the fetched cutout's center, the on-screen background
  /// no longer covers the look-direction, so we recompute a new sky center and
  /// re-fetch a cutout there (resetting pan to zero).
  ///
  /// The pan delta is converted to an angular displacement through the loaded
  /// [FramingPlateScale]: `degrees = pan_px / pixelsPerDegree`, exactly as the
  /// painters and gesture math do. [canvasSize] is the logical size of the
  /// framing canvas the pan was measured against — it is required because the
  /// pan deltas are in *drawn* canvas pixels, whose relationship to sky degrees
  /// depends on the canvas geometry and current zoom (a small cached cutout and
  /// a large network cutout fill the canvas at very different native-pixel
  /// densities, so the native image pixel width is *not* a valid substitute).
  void pan(double dx, double dy, {required ui.Size canvasSize}) {
    final newPanX = state.panX + dx;
    final newPanY = state.panY + dy;
    state = state.copyWith(panX: newPanX, panY: newPanY);

    final scale = state.plateScale;
    final target = state.target;
    if (scale == null || target == null) return;

    // Convert the accumulated pan (drawn canvas pixels) to an angular
    // displacement through the plate scale's authoritative on-screen mapping at
    // the current zoom. This is the same px-per-degree the survey painter and
    // FOV reticle use, so the re-fetch threshold tracks what the user actually
    // sees regardless of the cutout's native pixel size.
    final pxPerDeg = scale.pixelsPerDegree(canvasSize, state.zoom);
    if (pxPerDeg <= 0) return;
    final degreesMovedX = newPanX / pxPerDeg;
    final degreesMovedY = newPanY / pxPerDeg;

    final thresholdDeg = scale.surveyFovWidthDeg * _panRefetchFovFraction;
    final movedDeg = math.sqrt(
      degreesMovedX * degreesMovedX + degreesMovedY * degreesMovedY,
    );
    if (movedDeg <= thresholdDeg) return;

    // The view has drifted past the margin: recompute a new sky center using a
    // real spherical offset (RA scaled by 1/cos(dec)), mirroring the mosaic
    // panel math, then re-fetch a cutout there and reset the pan.
    _recenterFromPan(
      target: target,
      raDisplacementDeg: degreesMovedX,
      decDisplacementDeg: degreesMovedY,
    );
  }

  /// Recompute the target center after a pan past the re-fetch margin and load
  /// a fresh survey cutout there.
  ///
  /// Screen convention: dragging the background to the right (+pan x) reveals
  /// sky to the *west*, so the look-direction RA decreases; dragging down
  /// (+pan y) reveals sky to the *north*, so the look-direction Dec increases.
  /// RA offset is divided by cos(dec) so a fixed on-screen pan corresponds to a
  /// smaller absolute RA step near the celestial poles — the same cos(dec)
  /// scaling used by [_recalculateMosaicPanels].
  void _recenterFromPan({
    required FramingTarget target,
    required double raDisplacementDeg,
    required double decDisplacementDeg,
  }) {
    final decRad = target.decDegrees * math.pi / 180;
    final cosDec = math.cos(decRad);
    final safeCosDec = cosDec.abs() > 0.01
        ? cosDec
        : (cosDec.isNegative ? -0.01 : 0.01);

    final raOffsetHours = (-raDisplacementDeg / 15.0) / safeCosDec;
    final decOffsetDeg = decDisplacementDeg;

    var newRaHours = (target.raHours + raOffsetHours) % 24.0;
    if (newRaHours < 0) newRaHours += 24.0;
    final newDecDegrees = (target.decDegrees + decOffsetDeg).clamp(-90.0, 90.0);

    final recentered = FramingTarget(
      name: target.name,
      catalogId: target.catalogId,
      raHours: newRaHours,
      decDegrees: newDecDegrees,
      type: target.type,
      objectType: target.objectType,
      magnitude: target.magnitude,
      sizeArcmin: target.sizeArcmin,
      constellation: target.constellation,
    );

    state = state.copyWith(
      target: recentered,
      panX: 0,
      panY: 0,
      clearImage: true,
    );
    loadSurveyImage();
  }

  /// Toggle grid display
  void toggleGrid() {
    state = state.copyWith(showGrid: !state.showGrid);
  }

  /// Toggle labels display
  void toggleLabels() {
    state = state.copyWith(showLabels: !state.showLabels);
  }

  /// Toggle cardinal directions
  void toggleCardinalDirections() {
    state = state.copyWith(
      showCardinalDirections: !state.showCardinalDirections,
    );
  }

  /// Toggle the candidate guide-star overlay.
  void toggleGuideStars() {
    state = state.copyWith(showGuideStars: !state.showGuideStars);
  }

  /// Toggle optical config panel visibility
  void toggleOpticalConfigPanel() {
    state = state.copyWith(
      showOpticalConfigPanel: !state.showOpticalConfigPanel,
    );
  }

  /// Set optical config panel visibility
  void setOpticalConfigPanelVisible(bool visible) {
    state = state.copyWith(showOpticalConfigPanel: visible);
  }

  /// Set custom equipment
  void setCustomEquipment(FramingEquipment equipment) {
    state = state.copyWith(
      customEquipment: equipment,
      useCustomEquipment: true,
    );
  }

  /// Use equipment from active profile
  void useProfileEquipment() {
    state = state.copyWith(useCustomEquipment: false);
  }

  /// Set preview FOV for browsing without equipment
  void setPreviewFov(double degrees) {
    state = state.copyWith(
      previewFovDegrees: degrees.clamp(0.1, 20.0),
      clearImage: true,
    );
    if (state.target != null) {
      loadSurveyImage();
    }
  }

  /// Set equipment FOV overlay opacity
  void setEquipmentFovOverlayOpacity(double opacity) {
    state = state.copyWith(equipmentFovOverlayOpacity: opacity.clamp(0.0, 1.0));
  }

  /// Toggle equipment FOV overlay visibility
  void toggleEquipmentFovOverlay() {
    state = state.copyWith(
      showEquipmentFovOverlay: !state.showEquipmentFovOverlay,
    );
  }

  // Mosaic methods

  /// Enable or disable mosaic mode
  void setMosaicEnabled(bool enabled) {
    state = state.copyWith(mosaicEnabled: enabled);
    if (enabled) {
      _recalculateMosaicPanels();
    } else {
      state = state.copyWith(mosaicPanels: [], selectedPanelIndex: -1);
    }
  }

  /// Update mosaic configuration
  void setMosaicConfig(FramingMosaicConfig config) {
    state = state.copyWith(mosaicConfig: config);
    if (state.mosaicEnabled) {
      _recalculateMosaicPanels();
    }
  }

  /// Set number of mosaic columns
  void setMosaicColumns(int columns) {
    setMosaicConfig(state.mosaicConfig.copyWith(columns: columns.clamp(1, 10)));
  }

  /// Set number of mosaic rows
  void setMosaicRows(int rows) {
    setMosaicConfig(state.mosaicConfig.copyWith(rows: rows.clamp(1, 10)));
  }

  /// Set mosaic overlap percentage
  void setMosaicOverlap(double percent) {
    setMosaicConfig(
      state.mosaicConfig.copyWith(overlapPercent: percent.clamp(0, 50)),
    );
  }

  /// Toggle serpentine capture pattern
  void toggleSerpentine() {
    setMosaicConfig(
      state.mosaicConfig.copyWith(serpentine: !state.mosaicConfig.serpentine),
    );
  }

  /// Set mosaic start corner
  void setMosaicStartCorner(MosaicStartCorner corner) {
    setMosaicConfig(state.mosaicConfig.copyWith(startCorner: corner));
  }

  /// Select a panel by index
  void selectPanel(int index) {
    state = state.copyWith(selectedPanelIndex: index);
  }

  /// Toggle panel number visibility
  void togglePanelNumbers() {
    state = state.copyWith(showPanelNumbers: !state.showPanelNumbers);
  }

  /// Toggle sequence path visibility
  void toggleSequencePath() {
    state = state.copyWith(showSequencePath: !state.showSequencePath);
  }

  /// Recalculate mosaic panels based on current target and equipment FOV
  Future<void> _recalculateMosaicPanels() async {
    if (state.target == null) {
      state = state.copyWith(mosaicPanels: []);
      return;
    }

    final fov = await _getCurrentFOV();
    if (fov == null) {
      state = state.copyWith(mosaicPanels: []);
      return;
    }

    final (fovWidth, fovHeight) = fov;
    final config = state.mosaicConfig;

    // Calculate step size accounting for overlap
    final overlapFactor = 1 - (config.overlapPercent / 100);
    final stepWidthDeg = fovWidth * overlapFactor;
    final stepHeightDeg = fovHeight * overlapFactor;

    // Calculate the total extent of the mosaic
    final totalWidthDeg = fovWidth + (config.columns - 1) * stepWidthDeg;
    final totalHeightDeg = fovHeight + (config.rows - 1) * stepHeightDeg;

    // Center coordinates: the mosaic is a capture plan around where the
    // telescope will point, so panels are built around the effective AIM (the
    // dragged reticle position), not the view-center target. They coincide
    // whenever the box has not been dragged off-center.
    final centerRa = state.effectiveAimRaHours!;
    final centerDec = state.effectiveAimDecDegrees!;

    // Frame rotation, applied to each panel's tangent-plane offset with the
    // same convention as mosaicPanelCenters so the listed coords match the
    // rotated on-sky grid and the project MosaicService.generatePanels creates.
    final rotation = state.rotation;
    final rotRad = rotation * math.pi / 180;
    final cosRot = math.cos(rotRad);
    final sinRot = math.sin(rotRad);

    // Calculate starting corner offset from center
    final startRaOffset = -totalWidthDeg / 2 + fovWidth / 2;
    final startDecOffset = totalHeightDeg / 2 - fovHeight / 2;

    // Generate panels in capture order
    final panels = <FramingMosaicPanel>[];
    int panelIndex = 0;

    for (int row = 0; row < config.rows; row++) {
      final actualRow = _getActualRow(row, config);

      for (int col = 0; col < config.columns; col++) {
        final actualCol = _getActualCol(col, row, config);

        // Panel offset from center in the tangent plane (east/north degrees),
        // rotated by the frame rotation before the cos(dec) RA compression.
        final eastOffsetDeg = startRaOffset + actualCol * stepWidthDeg;
        final northOffsetDeg = startDecOffset - actualRow * stepHeightDeg;

        final double rotatedEastDeg;
        final double rotatedNorthDeg;
        if (rotation != 0.0) {
          rotatedEastDeg = eastOffsetDeg * cosRot - northOffsetDeg * sinRot;
          rotatedNorthDeg = eastOffsetDeg * sinRot + northOffsetDeg * cosRot;
        } else {
          rotatedEastDeg = eastOffsetDeg;
          rotatedNorthDeg = northOffsetDeg;
        }

        // Note: RA offset needs to account for declination (cos(dec) factor)
        final decRad = centerDec * math.pi / 180;
        final cosDec = math.cos(decRad);
        final raOffsetHours =
            rotatedEastDeg / 15 / (cosDec.abs() > 0.01 ? cosDec : 0.01);

        final panelRa = (centerRa + raOffsetHours) % 24;
        final panelDec = (centerDec + rotatedNorthDeg).clamp(-90.0, 90.0);

        panels.add(
          FramingMosaicPanel(
            index: panelIndex,
            column: actualCol,
            row: actualRow,
            centerRaHours: panelRa,
            centerDecDegrees: panelDec,
            name: 'Panel ${panelIndex + 1} ($actualCol,$actualRow)',
          ),
        );

        panelIndex++;
      }
    }

    state = state.copyWith(mosaicPanels: panels);
  }

  int _getActualRow(int row, FramingMosaicConfig config) {
    final flipVertical =
        config.startCorner == MosaicStartCorner.bottomLeft ||
        config.startCorner == MosaicStartCorner.bottomRight;
    return flipVertical ? (config.rows - 1 - row) : row;
  }

  int _getActualCol(int col, int row, FramingMosaicConfig config) {
    final flipHorizontal =
        config.startCorner == MosaicStartCorner.topRight ||
        config.startCorner == MosaicStartCorner.bottomRight;
    final baseCol = flipHorizontal ? (config.columns - 1 - col) : col;

    // Apply serpentine pattern (reverse direction on odd rows)
    if (config.serpentine && row % 2 == 1) {
      return config.columns - 1 - baseCol;
    }
    return baseCol;
  }

  /// Recalculate panels when target or equipment changes
  void recalculateMosaicIfNeeded() {
    if (state.mosaicEnabled) {
      _recalculateMosaicPanels();
    }
  }

  /// Get mosaic total coverage info
  (double widthDeg, double heightDeg) getMosaicCoverage() {
    final config = state.mosaicConfig;
    final baseWidthDeg =
        state.customEquipment?.fovWidthDeg ?? state.previewFovDegrees;
    final baseHeightDeg =
        state.customEquipment?.fovHeightDeg ??
        (state.surveyImage != null && state.surveyImage!.width > 0
            ? state.previewFovDegrees *
                  (state.surveyImage!.height / state.surveyImage!.width)
            : state.previewFovDegrees);
    return (
      config.effectiveWidthMultiplier * baseWidthDeg,
      config.effectiveHeightMultiplier * baseHeightDeg,
    );
  }

  /// Persist the currently-framed mosaic as a DURABLE mosaic project (the same
  /// `mosaic_projects` + per-panel `mosaic_panels`/`targets` structure the
  /// mosaic wizard's "Create Project" writes), and return the new
  /// `mosaic_projects.id`.
  ///
  /// The grid geometry (rows/cols/overlap), center, and per-panel FOV
  /// are taken straight from the live framing state, so the persisted project
  /// matches the panels the user sees on the canvas. The scheduler/sequencer
  /// can then drive the project via the `/mosaic/:id` screen.
  ///
  /// Returns the new project id, or null when there is no framed target or the
  /// rig FOV cannot be resolved (in which case no rows are written).
  Future<int?> createDurableMosaicProject({String? name}) async {
    if (_ref.read(backendProvider) is NetworkBackend) {
      throw StateError(
        'Durable mosaic projects must be created on the imaging host.',
      );
    }
    // The project center is where the rig will point — the effective aim,
    // which carries the picked target's name when the box has been dragged.
    final aimTarget = state.effectiveAimTarget;
    if (aimTarget == null) return null;

    final fov = await _getCurrentFOV();
    if (fov == null) return null;
    final (fovWidthDeg, fovHeightDeg) = fov;

    final config = state.mosaicConfig;
    final service = _ref.read(mosaicProjectServiceProvider);
    return service.createProject(
      name: name?.trim().isNotEmpty == true ? name!.trim() : aimTarget.name,
      rows: config.rows,
      cols: config.columns,
      centerRa: aimTarget.raHours,
      centerDec: aimTarget.decDegrees,
      overlapPct: config.overlapPercent,
      positionAngleDeg: state.rotation,
      fovWidthDeg: fovWidthDeg,
      fovHeightDeg: fovHeightDeg,
    );
  }

  /// Persists the currently-framed target as the "last framed target" so it can
  /// be restored across app restarts. Writes a SINGLE settings key (overwritten
  /// each call) — this deliberately does NOT create a row in the `targets`
  /// library table, which would pollute Analytics → Projects with phantom
  /// targets the user never deliberately added.
  Future<void> persistLastFramedTarget(FramingTarget target) async {
    final dao = _ref.read(settingsDaoProvider);
    await dao.setSetting(_lastFramedTargetKey, jsonEncode(target.toJson()));
  }

  /// Saves the current target into the persistent targets library.
  ///
  /// Routed through [TargetLibraryService.ensureCatalogTarget], which dedups
  /// against existing rows (by catalog id / name / coordinates) and handles both
  /// the local SQLite (FFI) and remote host (NetworkBackend) backends, so
  /// repeated "Save target" presses do not stack duplicate rows.
  Future<void> saveTarget() async {
    final target = state.target;
    if (target == null) return;

    final library = _ref.read(targetLibraryServiceProvider);
    await library.ensureCatalogTarget(
      targetName: target.name,
      raHours: target.raHours,
      decDegrees: target.decDegrees,
      catalogId: target.catalogId,
      objectType: target.type?.name,
      magnitude: target.magnitude,
      sizeArcmin: target.sizeArcmin,
      constellation: target.constellation,
    );
  }

  /// Restores the last framed target from the single settings key written by
  /// [persistLastFramedTarget]. Does nothing when the key is absent — there is
  /// deliberately NO fallback to scanning the `targets` table, so the framing
  /// restore never resurrects phantom library rows.
  Future<void> loadMostRecentTarget() async {
    if (_ref.read(backendProvider) is NetworkBackend) return;
    final dao = _ref.read(settingsDaoProvider);
    final raw = await dao.getSetting(_lastFramedTargetKey);
    if (raw == null || raw.isEmpty) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e, stackTrace) {
      developer.log(
        'Discarding corrupt framing.lastTarget setting: $e',
        name: 'FramingNotifier',
        level: 900,
        error: e,
        stackTrace: stackTrace,
      );
      await dao.deleteSetting(_lastFramedTargetKey);
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    final target = FramingTarget.fromJson(decoded);
    if (target == null) return;

    setTarget(target);
  }
}

/// Settings key holding the JSON-encoded last framed target. Single key,
/// overwritten on every selection — never a new `targets` row.
const String _lastFramedTargetKey = 'framing.lastTarget';

/// Factory for the HTTP client the survey-image fetch uses.
///
/// Seam so a test can decide what the network does instead of depending on
/// whether the machine running it happens to be online: the survey fetch allows
/// each endpoint 30s, which is also the whole budget of a default Dart test.
///
/// Production keeps the real client; tests override this with one that fails
/// immediately.
final framingSurveyHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => http.Client.new,
);

final framingProvider = StateNotifierProvider<FramingNotifier, FramingState>((
  ref,
) {
  return FramingNotifier(ref);
});

double _normalizeRaHoursMaybeDegrees(double ra) {
  if (ra.isNaN || ra.isInfinite) return ra;

  // Normal case: already in hours.
  if (ra >= 0.0 && ra < 24.0) return ra;

  // Legacy bug / external sources: treat as degrees and convert to hours.
  var deg = ra % 360.0;
  if (deg < 0.0) deg += 360.0;
  return deg / 15.0;
}
