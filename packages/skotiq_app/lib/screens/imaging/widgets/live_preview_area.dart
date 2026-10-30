import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;
import '../../../widgets/raw_preview_status_badge.dart';
import '../../../utils/preview_transform.dart';
import '../../../widgets/catalog_overlay_widget.dart';
import 'annotation_widgets.dart';
import 'custom_annotation_drawing.dart';
import 'depthlock/depthlock_region_layer.dart';
import 'depthlock/depthlock_selection.dart';

import 'frame_science_chip.dart';
import 'frame_science_selection.dart';
import 'fullscreen_image_viewer.dart';
import 'guiding_active_chip.dart';
import 'image_display.dart';
import 'imaging_hud.dart';
import 'measured_width.dart';
import 'narrator_ticker.dart';
import 'overlay_painters.dart';
import 'overlay_widgets.dart';
import 'preview_display_scale.dart';
import 'preview_histogram_visibility.dart';
import 'science_hud.dart';
import 'sub_quality_badge.dart';

part 'live_preview_area/frame_selection.dart';
part 'live_preview_area/preview_overlays.dart';

class LivePreviewArea extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final double zoomLevel;
  final Offset panOffset;
  final bool showCrosshair;
  final bool showStarOverlay;

  /// A manual capture has been asked to stop and the abort has not settled yet.
  /// The progress overlay drops its countdown while this is true — see
  /// [ExposureProgressOverlay.isAborting].
  final bool isStoppingCapture;

  /// How wide the glass capture bar is on this canvas, or zero when the layout
  /// does not draw one (below the shell breakpoint the controls sheet carries
  /// the shutter instead).
  ///
  /// The canvas needs it to keep its bottom-right histogram off the bar; the
  /// SCREEN is what knows both, so it passes the answer down rather than the
  /// bar leaving a value behind for the canvas to misread.
  final double captureBarWidth;

  /// Scroll-wheel zoom handlers. The discrete zoom/fit/1:1 buttons and overlay
  /// toggles now live in the off-canvas [ImagingPreviewToolbar] above the
  /// preview, so the canvas itself only needs the wheel handlers to keep
  /// scroll-to-zoom working over the image.
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final void Function(Offset delta) onPanUpdate;

  const LivePreviewArea({
    super.key,
    required this.colors,
    required this.zoomLevel,
    required this.panOffset,
    required this.showCrosshair,
    required this.showStarOverlay,
    required this.isStoppingCapture,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onPanUpdate,
    this.captureBarWidth = 0,
  });

  @override
  ConsumerState<LivePreviewArea> createState() => _LivePreviewAreaState();
}

/// Vertical band at the bottom of the preview canvas owned by the capture bar
/// and the histogram. Content centred in the canvas must keep clear of it.
const double _cornerReadoutBandHeight = 120.0;

/// Distance from the canvas edge to a glass HUD panel
/// (`mockups/imaging.html`: 14 px).
const double _hudInset = 14.0;

/// The top of the row under the frame-info pill: the pill's inset, its height,
/// and a small gap.
const double _belowPillTop = _hudInset + _infoPillHeight + SkotiqTokens.spaceSm;

/// The frame-info pill's rendered height with a badge in it: 22 px of chip plus
/// its glass padding.
const double _infoPillHeight = 36;

/// Vertical room the capture bar needs above the canvas edge: its own height
/// plus the gap it sits on plus the gap above it.
const double _captureBarBand = SkotiqTokens.spaceLg + 48 + _hudInset;

/// Where a readout in one of the two bottom corners sits.
///
/// The capture bar is CENTERED, so what a corner readout [cornerWidth] wide
/// competes for is the slack on one side of it. The readout keeps the corner
/// while that slack holds it, and steps up over the bar when it does not. A
/// zero [captureBarWidth] means the bar has not been laid out yet, or is not
/// on screen at all — the corner's case either way.
double _bottomCornerOffset({
  required double canvasWidth,
  required double captureBarWidth,
  required double cornerWidth,
}) {
  if (captureBarWidth <= 0) return _hudInset;
  final slack = (canvasWidth - captureBarWidth) / 2;
  final clears = slack >= cornerWidth + 2 * _hudInset;
  return clears ? _hudInset : _hudInset + _captureBarBand;
}

/// Whether the on-canvas frame readouts — the frame-info pill and the
/// bottom-left science / guiding chips — are drawn. The histogram has its own
/// opt-in toggle, [previewHistogramVisibleProvider].
///
/// Visibility is explicit and user-owned (Overlays → Readouts), defaulting on:
/// nothing on this canvas disappears because of a timer. A pointer-idle fade
/// would hide these permanently for an unattended run or a remote operator
/// watching over a screen share, who has no local pointer at all.
final previewReadoutsVisibleProvider = StateProvider<bool>((ref) => true);

class _LivePreviewAreaState extends ConsumerState<LivePreviewArea> {
  /// The bottom-left science / guiding stack's laid-out width; zero while
  /// both chips hide themselves.
  double _bottomLeftReadoutsWidth = 0;

  /// Hand the measured display scale to readers outside this subtree (the
  /// preview toolbar's zoom readout), which cannot see the preview viewport.
  ///
  /// Deferred to a post-frame callback because it is computed inside `build`
  /// and mutating a provider during a build is illegal. The value is a pure
  /// function of the viewport, the frame size and the zoom multiplier, so the
  /// equality guard makes this converge in one extra frame rather than looping.
  void _publishDisplayScale(double scale) {
    if (ref.read(previewDisplayScaleProvider) == scale) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(previewDisplayScaleProvider.notifier).state = scale;
    });
  }

  /// Same contract as [_publishDisplayScale], for the zoom-multiplier-free fit
  /// scale the zoom mutators need to express "1:1" and the absolute zoom
  /// ceiling.
  void _publishFitScale(double scale) {
    if (ref.read(previewFitScaleProvider) == scale) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(previewFitScaleProvider.notifier).state = scale;
    });
  }

  /// Gate a measurement readout on [previewReadoutsVisibleProvider].
  ///
  /// Hidden readouts are removed from the tree rather than made transparent so
  /// they cannot swallow pan / annotation pointer events while invisible.
  Widget _readout(Widget child, {required bool visible}) {
    if (!visible) return const SizedBox.shrink();
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final zoomLevel = widget.zoomLevel;
    final panOffset = widget.panOffset;
    final showCrosshair = widget.showCrosshair;
    final showStarOverlay = widget.showStarOverlay;
    final onZoomIn = widget.onZoomIn;
    final onZoomOut = widget.onZoomOut;
    final onPanUpdate = widget.onPanUpdate;
    final currentImage = ref.watch(currentImageProvider);
    final readoutsVisible = ref.watch(previewReadoutsVisibleProvider);
    final histogramVisible = ref.watch(previewHistogramVisibleProvider);
    final exposureProgress = ref.watch(exposureProgressProvider);
    final cameraState = ref.watch(cameraStateProvider);
    // Detected only while the overlay is on: one native detection per frame.
    final starDetectionResult = showStarOverlay
        ? ref.watch(currentFrameStarsProvider).valueOrNull
        : null;
    final frameSolve = ref.watch(currentFrameSolveProvider);
    final scienceSettings = ref.watch(scienceSettingsProvider).valueOrNull;
    final scienceVizPrefs =
        ref.watch(scienceVisualizationPrefsProvider).valueOrNull;
    final scienceOverlaysEnabled =
        scienceSettings?.overlayEnabled == true && scienceVizPrefs != null;
    final scienceMode = ref.watch(scienceModeStateProvider);
    final scienceOverlay = ref.watch(scienceOverlayStateProvider);
    final sessionId = ref.watch(sessionStateProvider).dbSessionId;
    final sessionImages = ref.watch(recentSessionFramesProvider);
    final currentFrameImageId = _resolveCurrentFrameImageId(
      sessionImages: sessionImages,
      currentImage: currentImage,
    );

    final sessionPsfTiles = sessionId != null
        ? ref.watch(sessionPsfTilesProvider(sessionId)).valueOrNull ??
            const <PsfFieldTileRow>[]
        : ref.watch(sessionlessPsfTilesProvider).valueOrNull ??
            const <PsfFieldTileRow>[];
    final psfTiles = _selectCurrentFramePsfTiles(
      sessionTiles: sessionPsfTiles,
      capturedImageId: currentFrameImageId,
    );
    final sessionResidualVectors = sessionId != null
        ? ref.watch(sessionResidualVectorsProvider(sessionId)).valueOrNull ??
            const <AstrometryResidualVectorRow>[]
        : ref.watch(sessionlessResidualVectorsProvider).valueOrNull ??
            const <AstrometryResidualVectorRow>[];
    final residualVectors = _selectCurrentFrameResidualVectors(
      sessionVectors: sessionResidualVectors,
      capturedImageId: currentFrameImageId,
    );
    final sessionTileMetrics = sessionId != null
        ? ref.watch(sessionTileMetricsProvider(sessionId)).valueOrNull ??
            const <ScienceTileMetricRow>[]
        : ref.watch(sessionlessTileMetricsProvider).valueOrNull ??
            const <ScienceTileMetricRow>[];
    final currentFrameTileMetrics = _selectCurrentFrameTileMetrics(
      sessionTiles: sessionTileMetrics,
      capturedImageId: currentFrameImageId,
    );
    final uniformityTiles = currentFrameTileMetrics
        .where(
          (tile) => tile.layerType == ScienceLayerType.uniformity.dbValue,
        )
        .toList(growable: false);
    final clipHighTiles = currentFrameTileMetrics
        .where(
          (tile) => tile.layerType == ScienceLayerType.clipHigh.dbValue,
        )
        .toList(growable: false);
    final clipLowTiles = currentFrameTileMetrics
        .where(
          (tile) => tile.layerType == ScienceLayerType.clipLow.dbValue,
        )
        .toList(growable: false);
    // Representative per-frame eccentricity for the frame verdict, derived
    // purely from the science tile metrics already watched above for
    // `currentFrameImageId`. Each eccentricity-layer tile carries its own
    // representative eccentricity in `value`; the median across tiles is a
    // robust single verdict that ignores a few hot corners. No new query or
    // analyzer is introduced — when no eccentricity tiles exist for the frame
    // this is null and the eccentricity rule is skipped.
    final frameEccentricity = _medianEccentricity(currentFrameTileMetrics);
    final sessionMovingCandidates = sessionId == null
        ? const <MovingObjectCandidateRow>[]
        : ref
                .watch(sessionMovingObjectCandidatesProvider(sessionId))
                .valueOrNull ??
            const <MovingObjectCandidateRow>[];
    final movingCandidates = _selectCurrentFrameMovingCandidates(
      sessionCandidates: sessionMovingCandidates,
      capturedImageId: currentFrameImageId,
    );
    final currentFrameWcs = currentFrameImageId == null
        ? null
        : ref.watch(capturedImageWcsProvider(currentFrameImageId)).valueOrNull;

    final annotationSettingsValue = ref.watch(annotationSettingsProvider);
    final annotationSettingsObj = annotationSettingsValue.valueOrNull;
    final gridType = annotationSettingsObj?.gridType ?? GridType.none;
    final annotationShowResiduals =
        annotationSettingsObj?.showSolveResiduals ?? false;
    final currentAnnotation = ref.watch(currentAnnotationProvider);
    final currentSkySolution = currentImage == null
        ? const _CurrentImageSkySolution()
        : _resolveCurrentImageSkySolution(
            wcs: currentFrameWcs,
            annotation: currentAnnotation,
            frameSolve: frameSolve,
            width: currentImage.width,
            height: currentImage.height,
          );

    final isConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final isExposing =
        exposureProgress.percent > 0 || exposureProgress.isDownloading;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        // Screen pixels per IMAGE pixel. `zoomLevel` is only a multiplier on
        // top of fit-to-window, so it is meaningful to [ImageDisplayWidget]
        // (which re-derives fit itself) and to nothing else. Every overlay
        // below maps image coordinates onto this canvas via
        // `computeImageOffset` / `imageToViewport`, whose
        // `scaledSize = imageSize * zoomLevel` is native-scale arithmetic —
        // handing them the raw multiplier spread every marker over
        // `1 / fitScale` times the frame's real footprint (4.2x on a 4144 px
        // sensor in a 990 px viewport), so overlays only landed on their
        // targets at the exact centre of the frame.
        final fitScale = currentImage == null
            ? 1.0
            : previewFitScale(
                viewportSize: viewportSize,
                imageSize: Size(currentImage.width.toDouble(),
                    currentImage.height.toDouble()),
              );
        final displayScale =
            currentImage == null ? zoomLevel : fitScale * zoomLevel;
        _publishDisplayScale(displayScale);
        _publishFitScale(fitScale);
        final imageOffset = currentImage != null
            ? computeImageOffset(
                viewportSize: viewportSize,
                imageSize: Size(currentImage.width.toDouble(),
                    currentImage.height.toDouble()),
                zoomLevel: displayScale,
                panOffset: panOffset,
              )
            : Offset.zero;
        final projectedMovingTracks = currentImage == null
            ? const <ProjectedMovingTrack>[]
            : _projectMovingTracks(
                candidates: movingCandidates,
                wcs: currentSkySolution.catalogWcs,
                imageWidth: currentImage.width.toDouble(),
                imageHeight: currentImage.height.toDouble(),
              );

        return Listener(
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              if (signal.scrollDelta.dy > 0) {
                onZoomOut();
              } else if (signal.scrollDelta.dy < 0) {
                onZoomIn();
              }
            }
          },
          child: GestureDetector(
            // While the DepthLock region tool owns the canvas a drag DRAWS.
            // Left enabled, this pan recogniser competes with the layer's in
            // the same gesture arena and the rectangle starts wherever the
            // arena resolved rather than where the operator pressed.
            onPanUpdate: ref.watch(depthLockRegionToolActiveProvider)
                ? null
                : (details) => onPanUpdate(details.delta),
            // Tap the frame on a phone to inspect it fullscreen (pinch-zoom +
            // pan), since the in-place preview shares the short cover-screen
            // height with the controls. No-op when empty or on desktop, where
            // the preview already has room and a tap shouldn't hijack.
            onTap: (currentImage != null && Responsive.isPhone(context))
                ? () => FullscreenImageViewer.show(context, currentImage)
                : null,
            child: Container(
              // The canvas is a photo backdrop, so it stays on the dark ladder
              // in every theme EXCEPT red night, where the wavelength rule
              // outranks the image-anchoring one (05 §14, and the same
              // exception SkotiqDecorations.glass makes). The dark
              // background is #0B0D12 — G and B differ, so leaving it here put
              // 515,307 off-axis pixels on a red-night Imaging screen.
              color: colors.isRedNight
                  ? colors.background
                  : SkotiqColors.dark.background,
              child: Stack(
                children: [
                  // Image display or empty state
                  if (currentImage != null)
                    Positioned.fill(
                      child: ImageDisplayWidget(
                        imageData: currentImage,
                        zoomLevel: zoomLevel,
                        panOffset: panOffset,
                      ),
                    )
                  else
                    // Star field background with empty-state message
                    Positioned.fill(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: StarFieldPainter(colors: colors),
                            ),
                          ),
                          // While an exposure is in flight the progress
                          // overlay owns the centre of the canvas, so the
                          // empty state stands down. Drawing both stacked
                          // "32%" on top of "No Image" and told the operator
                          // to "take a snapshot or start a capture loop"
                          // directly above a countdown for the capture already
                          // running.
                          //
                          // Centered when there's room; on very short preview
                          // heights (e.g. a phone held in landscape) the
                          // message scrolls instead of overflowing the canvas.
                          if (!isExposing)
                            SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight,
                                ),
                                child: Center(
                                  // The bottom of this canvas is spoken for by
                                  // the capture bar and the histogram, so the
                                  // prompt centres in the space actually free.
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: _cornerReadoutBandHeight,
                                    ),
                                    // The empty state sits ON the canvas, and
                                    // the canvas is image-anchored dark in
                                    // every theme (05 §14). Left on the app
                                    // palette its ink was light-theme grey on
                                    // near-black — the same grey-on-grey that
                                    // got a white glass over a black frame
                                    // rejected.
                                    child: _OnCanvas(
                                      child: EmptyState(
                                        icon: isConnected
                                            ? SkotiqIcons.imageOff
                                            : SkotiqIcons.cameraOff,
                                        title: isConnected
                                            ? 'No frames yet'
                                            : 'No camera connected',
                                        body: isConnected
                                            ? 'Take a snapshot or start a loop '
                                                'and the frame appears here.'
                                            : 'Connect a camera in Equipment '
                                                'to start imaging.',
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                  // Crosshair overlay
                  if (showCrosshair && currentImage != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: CrosshairOverlayPainter(
                          // 06 puts the reticle in primary 35-50%; the two
                          // tokens that bracket that band are opacityStrong
                          // (axes) and opacitySelectedRing (the ring itself,
                          // set inside the painter).
                          color: colors.primary.withValues(
                            alpha: SkotiqTokens.opacityStrong,
                          ),
                        ),
                      ),
                    ),

                  // Pixel grid overlay
                  if (gridType == GridType.pixel && currentImage != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: GridOverlayPainter(
                          color: colors.primary.withValues(alpha: 0.2),
                        ),
                      ),
                    ),

                  // Celestial RA/Dec grid overlay (requires plate solve)
                  if (gridType == GridType.celestial &&
                      currentImage != null &&
                      currentSkySolution.plateSolve != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: CelestialGridPainter(
                            plateSolve: currentSkySolution.plateSolve!,
                            zoomLevel: displayScale,
                            imageOffset: imageOffset,
                          ),
                        ),
                      ),
                    ),

                  // Star overlay
                  if (showStarOverlay &&
                      currentImage != null &&
                      starDetectionResult != null &&
                      starDetectionResult.stars.isNotEmpty)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: StarOverlayPainter(
                          stars: starDetectionResult.stars,
                          color: colors.accent.withValues(alpha: 0.8),
                          zoomLevel: displayScale,
                          imageOffset: imageOffset,
                        ),
                      ),
                    ),

                  // Annotation overlay with fade effects
                  if (currentImage != null)
                    Positioned.fill(
                      child: AnnotationOverlayWrapper(
                        zoomLevel: displayScale,
                        imageOffset: imageOffset,
                        imageSize: Size(currentImage.width.toDouble(),
                            currentImage.height.toDouble()),
                        colors: colors,
                        previewViewportWidth: viewportSize.width,
                        onPanToObject: (imagePoint) {
                          // Pan delta that centres the image point in the
                          // PREVIEW, not on the screen: imageToViewport works
                          // in preview-local coordinates, so measuring the
                          // centre off MediaQuery threw the object off by
                          // half the surrounding chrome — the wider the
                          // window, the further the miss.
                          final previewCenter = Offset(
                            viewportSize.width / 2,
                            viewportSize.height / 2,
                          );
                          final currentScreenPos = imageToViewport(
                            imagePoint: imagePoint,
                            imageOffset: imageOffset,
                            zoomLevel: displayScale,
                          );
                          final delta = previewCenter - currentScreenPos;
                          onPanUpdate(delta);
                        },
                      ),
                    ),

                  // Catalog overlay (F5-CATALOG-OVERLAY): live projection of
                  // Messier / NGC / IC / bright stars from the planetarium
                  // catalog through the solved WCS. Independent of the
                  // existing annotation pipeline.
                  if (currentImage != null)
                    Positioned.fill(
                      child: CatalogOverlayWidget(
                        wcs: currentSkySolution.catalogWcs,
                        zoomLevel: displayScale,
                        imageOffset: imageOffset,
                        imageSize: Size(currentImage.width.toDouble(),
                            currentImage.height.toDouble()),
                        frameSolve: frameSolve,
                      ),
                    ),

                  // Custom user-drawn annotations (circles, arrows, text)
                  if (currentImage != null)
                    Positioned.fill(
                      child: CustomAnnotationDrawingLayer(
                        zoomLevel: displayScale,
                        imageOffset: imageOffset,
                        imageSize: Size(currentImage.width.toDouble(),
                            currentImage.height.toDouble()),
                      ),
                    ),

                  // DepthLock regions: the two rectangles being drawn right
                  // now, and every saved goal that lands on this frame. Above
                  // the annotation layer because while its tool is active it
                  // owns the drag, and below the HUD because it is part of the
                  // picture rather than chrome over it.
                  if (currentImage != null)
                    Positioned.fill(
                      child: DepthLockRegionLayer(
                        zoomLevel: displayScale,
                        imageOffset: imageOffset,
                        imageSize: Size(currentImage.width.toDouble(),
                            currentImage.height.toDouble()),
                        geometry:
                            ref.watch(depthLockSelectionProvider).geometry,
                      ),
                    ),

                  // Compass and scale bar overlays (require plate solve data)
                  if (currentImage != null)
                    _CompassScaleBarOverlay(
                      zoomLevel: displayScale,
                      plateSolve: currentSkySolution.plateSolve,
                      bottomLeftOccupied: readoutsVisible,
                      bottomRightOccupied: histogramVisible,
                      bottomLeftLift: _bottomCornerOffset(
                            canvasWidth: viewportSize.width,
                            captureBarWidth: widget.captureBarWidth,
                            cornerWidth: _bottomLeftReadoutsWidth,
                          ) -
                          _hudInset,
                      bottomRightLift: _bottomCornerOffset(
                            canvasWidth: viewportSize.width,
                            captureBarWidth: widget.captureBarWidth,
                            cornerWidth: HistogramHud.width,
                          ) -
                          _hudInset,
                    ),

                  if (currentImage != null &&
                      scienceOverlaysEnabled &&
                      scienceOverlay.showPsfHeatmap &&
                      psfTiles.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: SciencePsfOverlayPainter(
                            tiles: psfTiles,
                            imageOffset: imageOffset,
                            zoomLevel: displayScale,
                            imageWidth: currentImage.width.toDouble(),
                            imageHeight: currentImage.height.toDouble(),
                            colors: colors,
                          ),
                        ),
                      ),
                    ),

                  if (currentImage != null &&
                      residualVectors.isNotEmpty &&
                      (annotationShowResiduals ||
                          (scienceOverlaysEnabled &&
                              scienceOverlay.showResidualVectors)))
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: ScienceResidualOverlayPainter(
                            vectors: residualVectors,
                            imageOffset: imageOffset,
                            zoomLevel: displayScale,
                            colors: colors,
                          ),
                        ),
                      ),
                    ),

                  if (currentImage != null &&
                      scienceOverlaysEnabled &&
                      scienceOverlay.showUniformityMap &&
                      uniformityTiles.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: ScienceUniformityOverlayPainter(
                            tiles: uniformityTiles,
                            imageOffset: imageOffset,
                            zoomLevel: displayScale,
                            imageWidth: currentImage.width.toDouble(),
                            imageHeight: currentImage.height.toDouble(),
                            opacity: scienceVizPrefs.overlayOpacity,
                            colors: colors,
                          ),
                        ),
                      ),
                    ),

                  if (currentImage != null &&
                      scienceOverlaysEnabled &&
                      (scienceOverlay.showClipHighMap ||
                          scienceOverlay.showClipLowMap))
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: ScienceClipOverlayPainter(
                            highTiles: scienceOverlay.showClipHighMap
                                ? clipHighTiles
                                : const <ScienceTileMetricRow>[],
                            lowTiles: scienceOverlay.showClipLowMap
                                ? clipLowTiles
                                : const <ScienceTileMetricRow>[],
                            imageOffset: imageOffset,
                            zoomLevel: displayScale,
                            imageWidth: currentImage.width.toDouble(),
                            imageHeight: currentImage.height.toDouble(),
                            opacity: scienceVizPrefs.overlayOpacity,
                            colors: colors,
                          ),
                        ),
                      ),
                    ),

                  if (currentImage != null &&
                      scienceOverlaysEnabled &&
                      scienceOverlay.showMovingObjectTracks &&
                      projectedMovingTracks.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: ScienceMovingTrackOverlayPainter(
                              tracks: projectedMovingTracks,
                              imageOffset: imageOffset,
                              zoomLevel: displayScale,
                              colors: colors,
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Exposure progress overlay
                  if (isExposing)
                    Positioned.fill(
                      child: ExposureProgressOverlay(
                        progress: exposureProgress,
                        colors: colors,
                        isAborting: widget.isStoppingCapture,
                      ),
                    ),

                  // Top-right science chrome column: the Night Narrator
                  // ticker (surface #2) over the Science HUD panel. Both fade
                  // with the rest of the corner readouts on idle. The ticker
                  // self-gates (hidden when its feed has nothing recent to
                  // say — sessionless manual captures read the sessionless
                  // bucket rather than going dark)
                  // and the HUD self-gates on advanced mode, so this column
                  // occupies zero height until there is something to show and
                  // the two stack without overlapping when both are present.
                  if (viewportSize.height > 120)
                    Positioned(
                      top: _hudInset,
                      right: _hudInset,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: Responsive.previewOverlayMaxWidth(
                            viewportSize.width,
                          ),
                          maxHeight: viewportSize.height - 72,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const NarratorTicker(),
                            if (scienceMode.scienceHudVisible) ...[
                              const SizedBox(height: SkotiqTokens.spaceSm),
                              Flexible(
                                child: SingleChildScrollView(
                                  child: ScienceHudPanel(colors: colors),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  // Top-left: the one frame-info pill (Imaging.dc.html) —
                  // what the frame is, when it landed, HFR and stars, and the
                  // badges that qualify the same frame: the raw-load state,
                  // calibration, and the accept / reject verdict. They used to
                  // be four separate glass boxes spread over three corners.
                  if (currentImage != null)
                    Positioned(
                      top: _hudInset,
                      left: _hudInset,
                      child: _readout(
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.max(
                              0,
                              viewportSize.width - 2 * _hudInset,
                            ),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.topLeft,
                            child: FrameInfoPill(
                              eccentricity: frameEccentricity,
                              trailing: <Widget>[
                                if (currentImage.rawLoadStatus !=
                                    RawLoadStatus.idle)
                                  RawPreviewStatusBadge(
                                    status: currentImage.rawLoadStatus,
                                    colors: colors,
                                  ),
                                // Only reports true when the saved file path
                                // ended up at `_cal.fits`, so an uncalibrated
                                // frame never wears the badge.
                                _CalibratedBadge(colors: colors),
                                SubQualityVerdict(
                                  eccentricity: frameEccentricity,
                                ),
                              ],
                            ),
                          ),
                        ),
                        visible: readoutsVisible,
                      ),
                    ),

                  // Bottom-right, opt-in (Overlays → Histogram): the histogram.
                  //
                  // The capture bar is centred on the same edge. On a wide
                  // canvas the two clear each other; on a narrow one the bar
                  // reaches the corner and would be drawn ON the histogram, so
                  // the histogram steps up above it. Glass never overlaps
                  // glass — a readout you cannot read is worse than one that
                  // moved.
                  Positioned(
                    bottom: _bottomCornerOffset(
                      canvasWidth: viewportSize.width,
                      captureBarWidth: widget.captureBarWidth,
                      cornerWidth: HistogramHud.width,
                    ),
                    right: _hudInset,
                    child: _readout(
                      const HistogramHud(),
                      visible: histogramVisible,
                    ),
                  ),

                  // Bottom-left: the science calibration chip over the live
                  // "Guiding" indicator. Both self-gate on their own
                  // providers, so on most frames this corner is empty. The
                  // accept / reject verdict that used to lead this stack now
                  // rides in the frame-info pill, beside the frame it grades.
                  //
                  // Deliberately NOT wrapped in IgnorePointer: the children
                  // expose hover tooltips (GuidingActiveChip's RMS-units note)
                  // and a tap target (FrameScienceChip) that an IgnorePointer
                  // would silently kill. They absorb the pointer only within
                  // their own compact footprint; the rest of the canvas keeps
                  // its pan / zoom gestures.
                  //
                  // The capture bar shares this edge too. On a 1536 px window
                  // the bar's left end reached x=360 and drew over the
                  // Guiding chip ("Guiding RMS 0." with the value under
                  // Snapshot), so the stack steps up over the bar when the
                  // slack beside it cannot hold the chips' measured width.
                  if (currentImage != null)
                    Positioned(
                      bottom: _bottomCornerOffset(
                        canvasWidth: viewportSize.width,
                        captureBarWidth: widget.captureBarWidth,
                        cornerWidth: _bottomLeftReadoutsWidth,
                      ),
                      left: _hudInset,
                      child: _readout(
                        MeasuredWidth(
                          onWidth: (width) {
                            if (!mounted || width == _bottomLeftReadoutsWidth) {
                              return;
                            }
                            setState(() => _bottomLeftReadoutsWidth = width);
                          },
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: Responsive.previewOverlayMaxWidth(
                                viewportSize.width,
                              ),
                            ),
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FrameScienceChip(),
                                SizedBox(height: SkotiqTokens.spaceXs),
                                GuidingActiveChip(),
                              ],
                            ),
                          ),
                        ),
                        visible: readoutsVisible,
                      ),
                    ),

                  // Mini annotation object chips, in the row under the
                  // frame-info pill so the two never overlap.
                  if (currentImage != null)
                    Positioned(
                      top: _belowPillTop,
                      left: 8,
                      right: 8,
                      child: AnnotationMiniChips(colors: colors),
                    ),

                  // The annotation status card and the re-annotate
                  // suggestion used to float over the top-left of the frame.
                  // They live in the Annotations section of the side panel
                  // now: a setup problem gets ONE banner in ONE place (02
                  // rule 5), and the canvas belongs to the photons.

                  // Custom annotation drawing palette — docked bottom-centre
                  // just above the bottom histogram/stats strip, and shown
                  // ONLY while annotate/draw mode is active so it never floats
                  // over an idle frame. Opened via the off-canvas toolbar's
                  // "Annotate" toggle.
                  if (currentImage != null &&
                      ref.watch(customAnnotationDrawModeActiveProvider))
                    Positioned(
                      bottom: 110,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: CustomAnnotationToolbar(colors: colors),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Resolves the DARK palette for anything drawn straight onto the canvas.
///
/// The canvas is a photograph of the night sky, dark in every theme, so text
/// over it takes its colours from the dark ladder exactly as [Glass] does.
/// Red night is the one exception and outranks the rule: the wavelength
/// constraint applies to every pixel on the screen.
class _OnCanvas extends StatelessWidget {
  const _OnCanvas({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final inner = colors.isRedNight ? colors : SkotiqColors.dark;
    return Theme(
      data: Theme.of(
        context,
      ).copyWith(extensions: <ThemeExtension<dynamic>>[inner]),
      child: child,
    );
  }
}
