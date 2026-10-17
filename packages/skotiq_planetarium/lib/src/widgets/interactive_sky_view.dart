import 'dart:math' as math;
import 'dart:ui' show FrameTiming, FramePhase;
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../coordinate_system.dart';
import '../celestial_object.dart';
import '../catalogs/constellation_data.dart';
import '../catalogs/satellite_catalog.dart';
import '../catalogs/variable_star_catalog.dart';
import '../catalogs/minor_planet_catalog.dart';
import '../astronomy/astronomy_calculations.dart';
import '../astronomy/planetary_positions.dart';
import '../astronomy/milky_way_data.dart';
import '../rendering/sky_renderer.dart';
import '../rendering/render_quality.dart';
import '../providers/performance_providers.dart';
import '../providers/planetarium_providers.dart';
import '../providers/deep_star_providers.dart';
import '../providers/satellite_providers.dart';
import '../providers/variable_star_providers.dart';
import '../providers/minor_planet_providers.dart';

part 'interactive_sky_view/fov_overlay_painter.dart';
part 'interactive_sky_view/measurement_overlay_painter.dart';
part 'interactive_sky_view/sky_background_layer.dart';
part 'interactive_sky_view/toolbar.dart';
part 'interactive_sky_view/view_motion.dart';
part 'interactive_sky_view/painter_wiring.dart';
part 'interactive_sky_view/hit_testing.dart';

/// Interactive sky view widget with pan, zoom, and object selection
class InteractiveSkyView extends ConsumerStatefulWidget {
  /// Callback when an object is selected
  final ValueChanged<CelestialObject?>? onObjectSelected;

  /// Callback when coordinates are tapped
  final ValueChanged<CelestialCoordinate>? onCoordinateTapped;

  /// Callback when an object is tapped with position info for popup display.
  ///
  /// `coordinates` is the CATALOG position of `object` whenever the tap hit
  /// one; it falls back to the tapped sky coordinate only for empty sky.
  final void Function(
    CelestialObject? object,
    CelestialCoordinate coordinates,
    Offset screenPosition,
  )?
  onObjectTapped;

  /// Whether to show the FOV indicator
  final bool showFOV;
  final bool showCrosshair;

  /// Custom FOV rectangle (if not using equipment provider)
  final (double width, double height)? customFOV;

  /// FOV center coordinate (if different from view center)
  final CelestialCoordinate? fovCenter;

  /// Set of catalog IDs/names for objects that have been observed.
  /// A small green indicator is drawn on matching DSOs in the sky view.
  final Set<String> observedObjectIds;

  /// Set of catalog IDs/names for objects in user observing lists.
  /// A small amber bookmark is drawn on matching DSOs in the sky view.
  final Set<String> listedObjectIds;

  /// Set of catalog IDs/names that are targets of the currently loaded
  /// sequence. A small cyan target ring is drawn on matching DSOs, so the sky
  /// shows what tonight's plan is actually pointed at.
  final Set<String> sequencedObjectIds;

  /// Bortle dark-sky scale (1-9). Controls light pollution dome intensity.
  final int bortleClass;

  /// Pre-computed horizon altitudes for each degree of azimuth (0-359).
  /// When non-null, the ground plane follows this custom horizon profile.
  final List<double>? horizonAltitudes;

  /// When true, click-drag measures the angular separation and position angle
  /// between two sky points (drawn as an overlay ruler) instead of panning.
  final bool measurementMode;

  /// An optional layer composited beneath the star field — real sky imagery,
  /// typically, for the narrow fields where the star catalogue runs out.
  ///
  /// See [SkyBackgroundLayer]: the host supplies the widget and states whether
  /// it is currently opaque, and the sky view stops painting its own background
  /// gradient while it is. Null (the default) is the plain star chart.
  final SkyBackgroundLayer? backgroundLayer;

  const InteractiveSkyView({
    super.key,
    this.onObjectSelected,
    this.onCoordinateTapped,
    this.onObjectTapped,
    this.showFOV = false,
    this.showCrosshair = false,
    this.customFOV,
    this.fovCenter,
    this.observedObjectIds = const {},
    this.listedObjectIds = const {},
    this.sequencedObjectIds = const {},
    this.bortleClass = 5,
    this.horizonAltitudes,
    this.measurementMode = false,
    this.backgroundLayer,
  });

  @override
  ConsumerState<InteractiveSkyView> createState() => _InteractiveSkyViewState();
}

class _InteractiveSkyViewState extends ConsumerState<InteractiveSkyView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// How many sky views are mounted.
  ///
  /// The renderer's caches ([SkyCanvasPainter.releaseRenderCaches]) are
  /// process-wide, so they are released only when the last view goes away —
  /// otherwise closing a framing view would drop the sprite atlas the
  /// planetarium behind it is still drawing from.
  static int _liveViews = 0;

  Offset? _lastFocalPoint;
  double? _lastScale;

  // Smooth zoom animation
  late AnimationController _zoomController;
  Animation<double>? _zoomAnimation;
  double _targetFOV = 60.0;
  double _startFOV = 60.0;

  /// Sky point the running zoom must keep under [_zoomAnchorPoint], and the
  /// screen position to keep it at. Both null when the zoom has no anchor (the
  /// double-tap reset, a keyboard zoom), in which case the view centre is what
  /// stays put.
  ///
  /// Wheel zoom anchors on the cursor: the sky point under it stays under it,
  /// instead of sliding off screen as the field narrows.
  CelestialCoordinate? _zoomAnchorSky;
  Offset? _zoomAnchorPoint;

  // Smooth fly-to (animated re-center) for search/GoTo actions.
  late AnimationController _flyToController;
  Animation<double>? _flyToRaAnimation;
  Animation<double>? _flyToDecAnimation;
  int? _lastFlyToToken;

  // Star twinkle animation
  AnimationController? _twinkleController;

  // Selection pulse animation
  late AnimationController _selectionController;
  CelestialCoordinate? _lastSelection;

  // Panning momentum.
  //
  // Momentum is integrated by a per-frame ticker rather than a fixed-duration
  // AnimationController curve: on each tick the live velocity (px/s) is applied
  // for the real elapsed dt and then exponentially decayed, so the glide stays
  // even at low frame rates and settles instead of stopping abruptly.
  late final Ticker _momentumTicker;
  Offset _panVelocity = Offset.zero;
  Duration _lastMomentumElapsed = Duration.zero;
  final List<_PanSample> _panSamples = [];

  // Star pop-in animation (tracks previous magnitude threshold)
  double _previousMagLimit = 6.0;
  late AnimationController _popinController;

  // DSO pop-in animation (tracks previous DSO magnitude threshold)
  double _previousDsoMagLimit = 10.0;
  late AnimationController _dsoPopinController;

  // Parallax effect - tracks current pan delta for dim star offset
  Offset _currentPanDelta = Offset.zero;

  /// Last laid-out canvas size, captured in the [LayoutBuilder] so gesture
  /// handlers that run outside the build (the momentum ticker) can convert
  /// pixels to sky angle with the same scale the painter uses.
  Size? _lastViewSize;

  // Angular-measurement tool. Endpoints are stored as celestial coordinates so
  // the ruler stays pinned to the sky under pan/zoom; the overlay re-projects
  // them every paint. Both null when no measurement is active. Driven by
  // setState because the ruler lives on the overlay layer, which rebuilds at
  // animation cadence anyway — the extra setState only marks it dirty.
  CelestialCoordinate? _measureStart;
  CelestialCoordinate? _measureEnd;

  // Listenable driving ONLY the animated overlay layer (bright-star twinkle +
  // selection pulse). The static base layer is never a descendant of this, so
  // twinkle/selection ticks repaint only the cheap overlay, never the base.
  late Listenable _overlayAnimations;

  @override
  void initState() {
    super.initState();
    _liveViews++;
    WidgetsBinding.instance.addObserver(this);
    _zoomController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onZoomAnimation);

    // Smooth fly-to glide from search/GoTo. 600ms easeInOutCubic feels like a
    // deliberate camera move rather than a teleport.
    _flyToController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addListener(_onFlyToAnimation);

    // Twinkle animation cycles every 3 seconds
    // NOTE: We don't start the animation here - it will be started in build
    // if the quality config enables it. This prevents constant repaints when
    // star twinkle is disabled.
    _twinkleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    // No setState listener - value read directly via ListenableBuilder

    // Selection pulse animation (cycles every 1.5 seconds)
    _selectionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    // No setState listener - value read directly via ListenableBuilder

    // Momentum glide ticker — integrates velocity per real frame (see
    // _onMomentumTick). Started on a fling, stopped when the speed decays
    // below _momentumStopSpeed or a new touch cancels it.
    _momentumTicker = createTicker(_onMomentumTick);

    // Star pop-in animation (600ms with elastic out).
    //
    // Seeded at 1.0 — see the DSO controller below for why the resting value
    // matters.
    _popinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0,
    );
    // No setState listener - value read directly via ListenableBuilder

    // DSO pop-in animation (300ms smooth fade/scale).
    //
    // The resting value MUST be 1.0, not the AnimationController default of
    // `lowerBound` (0.0). The painter reads this controller as "how far
    // through the pop-in are we", and 0.0 means "just started fading in", i.e.
    // every DSO glyph is tinted at alpha 0 and every DSO label is drawn fully
    // transparent. This controller is only ever driven by `forward(from: 0)`
    // when an animated zoom reveals fainter DSOs, so a controller left at its
    // default sat at 0.0 from launch and the entire deep-sky layer — glyphs
    // AND labels — was invisible until (and only until) such a zoom happened.
    _dsoPopinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1.0,
    );
    // No setState listener - value read directly via ListenableBuilder

    // The overlay layer animates the bright-star twinkle (continuous, ~20Hz
    // effective after quantization) and the selection pulse (transient). Both
    // drive ONLY the overlay's ListenableBuilder.
    _overlayAnimations = Listenable.merge([
      _twinkleController,
      _selectionController,
    ]);

    // Record frame timings for FPS/quality diagnostics.
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
  }

  @override
  void didUpdateWidget(InteractiveSkyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Leaving measurement mode discards any drawn ruler so it doesn't linger
    // over the normal interactive view.
    if (oldWidget.measurementMode &&
        !widget.measurementMode &&
        (_measureStart != null || _measureEnd != null)) {
      _measureStart = null;
      _measureEnd = null;
    }
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_handleFrameTimings);
    WidgetsBinding.instance.removeObserver(this);
    _zoomController.dispose();
    _flyToController.dispose();
    _twinkleController?.dispose();
    _selectionController.dispose();
    _momentumTicker.dispose();
    _popinController.dispose();
    _dsoPopinController.dispose();
    if (--_liveViews == 0) SkyCanvasPainter.releaseRenderCaches();
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    SkyCanvasPainter.releaseRenderCaches();
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    final monitor = ref.read(performanceMonitorProvider);
    for (final timing in timings) {
      final buildMs = timing.buildDuration.inMicroseconds / 1000;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000;
      final vsyncStart = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      final rasterFinish = timing.timestampInMicroseconds(
        FramePhase.rasterFinish,
      );
      final totalMs = rasterFinish > vsyncStart
          ? (rasterFinish - vsyncStart) / 1000
          : buildMs + rasterMs;
      monitor.recordFrameTimings(
        buildMs: buildMs,
        rasterMs: rasterMs,
        totalMs: totalMs,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final observer = ref.watch(observerLocationProvider);
    final site = observer.site;
    // Every coordinate on this chart — the horizon, the alt/az grid, what is
    // even above ground — is measured from the observer's site. Without one the
    // view says so instead of drawing somebody else's sky.
    if (site == null) return const _NoObservingSiteSky();

    final viewState = ref.watch(skyViewStateProvider);
    final renderConfig = ref.watch(effectiveSkyRenderConfigProvider);
    // Use minute-precision time for rendering to avoid rebuilds every second
    // The sky doesn't visibly change in one second, but rebuilding 60x/min hurts performance
    final observationMinute = ref.watch(observationMinuteProvider);
    final selectedObject = ref.watch(selectedObjectProvider);
    final stars = ref.watch(combinedStarsProvider);
    final dsos = ref.watch(fovFilteredDsosProvider);
    final constellations = ref.watch(constellationDataProvider);
    final equipmentFOV = ref.watch(equipmentFOVProvider);
    final mountPosition = ref.watch(mountPositionProvider);
    final sunPos = ref.watch(sunPositionProvider);
    final moonPos = ref.watch(moonPositionProvider);
    final moonIllumination = ref.watch(moonInfoProvider);
    final planets = ref.watch(planetPositionsProvider);
    final milkyWayPoints = ref.watch(milkyWayPointsProvider);
    final qualityConfig = ref.watch(fovAdaptiveQualityProvider);
    final satellites = ref.watch(currentSatellitesProvider);
    final variableStars = ref.watch(variableStarDataProvider);
    final minorPlanets = ref.watch(currentMinorPlanetsProvider);

    // React to fly-to (GoTo) requests by smoothly animating the view center.
    // Tokens dedupe so a request only fires its glide once, even across the
    // many rebuilds this widget performs.
    ref.listen<FlyToRequest?>(flyToRequestProvider, (prev, next) {
      if (next == null || next.token == _lastFlyToToken) return;
      _lastFlyToToken = next.token;
      _startFlyTo(next.target);
    });

    // Handle selection animation
    if (qualityConfig.enableSelectionAnimation) {
      if (selectedObject.coordinates != _lastSelection) {
        _lastSelection = selectedObject.coordinates;
        if (selectedObject.coordinates != null) {
          // Start pulsing animation for new selection
          _selectionController.repeat();
        } else {
          // Stop animation when deselected
          _selectionController.stop();
          _selectionController.reset();
        }
      }
    }

    // Handle star twinkle animation - only run when enabled in quality config
    if (qualityConfig.animateStarTwinkle) {
      if (!_twinkleController!.isAnimating) {
        _twinkleController!.repeat();
      }
    } else {
      if (_twinkleController!.isAnimating) {
        _twinkleController!.stop();
        _twinkleController!.reset();
      }
    }

    // The overlay layer exists only to animate cheaply on top of a static
    // base. When nothing on it actually animates, the split is pure cost: a
    // SECOND full-canvas offscreen texture to allocate, rasterize and
    // composite every frame. On a large window that is the dominant GPU cost —
    // measured at 5120x1440, rasterizing the sky is the whole frame budget, so
    // halving the number of full-screen targets is the single biggest lever.
    //
    // Collapse to one `full`-scope painter unless something on the overlay is
    // genuinely moving. `full` draws the bright-star pass too, so nothing is
    // lost visually.
    final overlayAnimates =
        qualityConfig.animateStarTwinkle ||
        selectedObject.coordinates != null ||
        renderConfig.showPlanningOverlays;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Cached so the momentum ticker, which runs outside build, converts
        // pixels to sky angle at the same scale the painter uses.
        _lastViewSize = Size(constraints.maxWidth, constraints.maxHeight);
        // Publish the canvas shape so the catalogue queries fetch a region that
        // actually covers the window. They take a SHORT-AXIS field of view, so
        // without this a wide window's outer columns have no star data at all.
        // Deferred: providers must not be written during a build.
        final aspect = constraints.maxHeight > 0
            ? constraints.maxWidth / constraints.maxHeight
            : 1.0;
        if ((ref.read(skyViewAspectRatioProvider) - aspect).abs() > 0.01) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref.read(skyViewAspectRatioProvider.notifier).state = aspect;
          });
        }
        return Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              // The cursor is the anchor: every map UI (and Stellarium and
              // SkySafari) zooms toward what the pointer is over.
              _zoomByStep(
                zoomOut: event.scrollDelta.dy > 0,
                focalPoint: event.localPosition,
              );
            }
          },
          child: GestureDetector(
            onScaleStart: (details) {
              // A new touch always cancels any in-flight momentum glide, and
              // takes the centre back from any in-flight wheel zoom.
              _stopMomentum();
              _clearZoomAnchor();

              // Measurement mode: begin a ruler at the touch point instead of
              // panning. The endpoint coincides with the start until the drag
              // moves.
              if (widget.measurementMode) {
                final coord = _screenToCelestial(
                  details.localFocalPoint,
                  Size(constraints.maxWidth, constraints.maxHeight),
                  viewState,
                );
                setState(() {
                  _measureStart = coord;
                  _measureEnd = coord;
                });
                return;
              }

              _lastFocalPoint = details.focalPoint;
              _lastScale = 1.0;
              _panSamples.clear();
              _panSamples.add(_PanSample(details.focalPoint, DateTime.now()));
            },
            onScaleUpdate: (details) {
              // Measurement mode: drag drives the ruler end point; the view
              // pose is held still so the two sky anchors stay fixed.
              if (widget.measurementMode) {
                if (_measureStart == null) return;
                final coord = _screenToCelestial(
                  details.localFocalPoint,
                  Size(constraints.maxWidth, constraints.maxHeight),
                  viewState,
                );
                if (coord != null) {
                  setState(() => _measureEnd = coord);
                }
                return;
              }

              final viewNotifier = ref.read(skyViewStateProvider.notifier);

              // Distinguish a pinch-zoom from a one-finger drag.
              //
              // On a touchpad the focal point drifts during a pinch, so
              // treating the focal-point delta as a pan (as v1 did) drags the
              // sky around while zooming. We therefore PAN only for a genuine
              // single-pointer drag, and ZOOM-ONLY for a pinch — identified by
              // either a second pointer being down OR the scale meaningfully
              // departing from 1.0 (covers touchpads that report pointerCount
              // == 1 for a two-finger pinch).
              const double pinchScaleEpsilon = 0.01;
              final isPinch =
                  details.pointerCount >= 2 ||
                  (details.scale - 1.0).abs() > pinchScaleEpsilon;

              // Pan — single-finger drag only.
              if (!isPinch && _lastFocalPoint != null) {
                final delta = details.focalPoint - _lastFocalPoint!;
                _panByPixels(
                  delta,
                  Size(constraints.maxWidth, constraints.maxHeight),
                );

                // Track pan delta for parallax effect (decays over time).
                // No setState needed: the viewState change from pan() above
                // already triggers a rebuild via ref.watch(skyViewStateProvider).
                _currentPanDelta = delta;

                // Track pan samples for momentum (fling) velocity.
                _panSamples.add(_PanSample(details.focalPoint, DateTime.now()));
                if (_panSamples.length > 10) {
                  _panSamples.removeAt(0);
                }
              } else if (isPinch) {
                // During a pinch the focal point is unreliable; do NOT carry it
                // into a pan and do NOT feed it to the momentum sampler. We keep
                // _lastFocalPoint tracking the focal point so that if the user
                // lifts one finger and continues a one-finger drag, the next pan
                // delta is measured from the current focal point (no jump), but
                // we clear the fling samples so a pinch never launches momentum.
                _panSamples.clear();
              }
              // Always advance the focal-point reference so a drag resuming
              // after a pinch measures from the correct anchor.
              _lastFocalPoint = details.focalPoint;

              // Zoom — apply for any real scale change (pinch). Zoom about the
              // focal point is left to the projection's view center; we only
              // change the field of view here so a pinch zooms in place without
              // translating the sky.
              if (_lastScale != null && details.scale != 1.0) {
                final scaleDelta = _lastScale! / details.scale;
                final newFOV = (viewState.fieldOfView * scaleDelta).clamp(
                  1.0,
                  180.0,
                );
                viewNotifier.setFieldOfView(newFOV);
                _lastScale = details.scale;
              }
            },
            onScaleEnd: (_) {
              // Measurement mode never glides — the drag only positioned the
              // ruler; the result stays on screen until cleared or remeasured.
              if (widget.measurementMode) return;

              // Launch a momentum glide only for a real one-finger fling. The
              // pinch path clears _panSamples, so a pinch-release yields zero
              // velocity here and never glides.
              _panVelocity = _calculatePanVelocity();
              if (_panVelocity.distance >
                  _momentumSpeedPx(_momentumMinLaunchFraction)) {
                _lastMomentumElapsed = Duration.zero;
                _momentumTicker.start();
              } else {
                _panVelocity = Offset.zero;
              }

              // Reset parallax delta. No setState needed: momentum animation
              // or next user interaction will trigger rebuilds.
              _currentPanDelta = Offset.zero;

              _lastFocalPoint = null;
              _lastScale = null;
              _panSamples.clear();
            },
            onTapDown: (_) {
              // A tap is a new touch — cancel any in-flight momentum glide so
              // the view holds still under the finger.
              _stopMomentum();
            },
            onDoubleTapDown: (details) {
              // Zoom in 2x centered on the double-tap position
              _stopMomentum();
              _handleDoubleTapZoom(
                details.localPosition,
                Size(constraints.maxWidth, constraints.maxHeight),
              );
            },
            onTapUp: (details) {
              // In measurement mode a single tap clears the current ruler so
              // the user can start a fresh measurement; it never selects an
              // object.
              if (widget.measurementMode) {
                if (_measureStart != null || _measureEnd != null) {
                  setState(() {
                    _measureStart = null;
                    _measureEnd = null;
                  });
                }
                return;
              }
              _handleTap(
                details.localPosition,
                Size(constraints.maxWidth, constraints.maxHeight),
              );
            },
            // Two RepaintBoundary-isolated layers in a Stack:
            //
            // - BASE layer (bottom): the expensive, non-animated content —
            //   background, Milky Way, grids, constellations, DSOs, dim+medium
            //   stars, solar-system bodies, satellites, labels and the static
            //   mount marker, plus the FOV foreground overlay. It is built
            //   directly in this `build()` and is NOT a descendant of the
            //   twinkle/selection ListenableBuilder, so animation ticks never
            //   rebuild or repaint it. Its painter's shouldRepaint returns
            //   false for twinkle/selection/pop-in and true only for real
            //   changes (pose, minute, config, catalog, mount).
            //
            // - OVERLAY layer (top): only the cheap animated bits — the
            //   bright-star (twinkle) pass and the selection pulse ring. It is
            //   wrapped in a ListenableBuilder driven by the twinkle and
            //   selection controllers so ONLY this layer rebuilds at animation
            //   cadence. A static view therefore paints the base once and then
            //   idles, with just a handful of bright stars + the selection ring
            //   repainting at ~20Hz.
            child: Stack(
              fit: StackFit.expand,
              children: [
                // BACKGROUND slot (bottom, optional): a host-supplied imagery
                // layer. It is only visible while it reports itself opaque,
                // because that is also what stops the base layer's painter
                // filling the canvas with the twilight gradient on top of it.
                if (widget.backgroundLayer != null)
                  widget.backgroundLayer!.child,
                RepaintBoundary(
                  // The base layer is driven only by the DSO pop-in controller
                  // (a brief ~300ms transient after a zoom reveals fainter
                  // DSOs, which scale on the base layer). It is NOT driven by
                  // the twinkle/selection controllers, so those animations
                  // never rebuild or repaint the base. When idle the pop-in
                  // controller is stopped (value pinned at 1.0) so it issues no
                  // ticks and the base stays static.
                  child: ListenableBuilder(
                    listenable: _dsoPopinController,
                    builder: (context, child) {
                      return ClipRect(
                        child: CustomPaint(
                          painter: _buildSkyPainter(
                            scope: overlayAnimates
                                ? SkyRenderScope.base
                                : SkyRenderScope.full,
                            viewState: viewState,
                            renderConfig: renderConfig,
                            qualityConfig: qualityConfig,
                            stars: stars.valueOrNull ?? const [],
                            dsos: dsos.valueOrNull ?? const [],
                            constellations: constellations,
                            observationMinute: observationMinute,
                            location: site,
                            selectedObject: selectedObject,
                            mountPosition: mountPosition,
                            sunPos: sunPos,
                            moonPos: moonPos,
                            moonIllumination: moonIllumination,
                            planets: planets,
                            satellites: satellites,
                            variableStars: variableStars,
                            minorPlanets: minorPlanets,
                            milkyWayPoints: milkyWayPoints,
                          ),
                          foregroundPainter: widget.showFOV
                              ? _FOVOverlayPainter(
                                  showCrosshair: widget.showCrosshair,
                                  viewState: viewState,
                                  fovWidth:
                                      widget.customFOV?.$1 ??
                                      equipmentFOV.fov?.$1,
                                  fovHeight:
                                      widget.customFOV?.$2 ??
                                      equipmentFOV.fov?.$2,
                                  fovCenter: widget.fovCenter,
                                  rotation: equipmentFOV.rotation,
                                )
                              : null,
                          size: Size.infinite,
                        ),
                      );
                    },
                  ),
                ),
                if (overlayAnimates)
                  RepaintBoundary(
                    child: ListenableBuilder(
                      listenable: _overlayAnimations,
                      builder: (context, child) {
                        return ClipRect(
                          child: CustomPaint(
                            painter: _buildSkyPainter(
                              scope: SkyRenderScope.overlay,
                              viewState: viewState,
                              renderConfig: renderConfig,
                              qualityConfig: qualityConfig,
                              stars: stars.valueOrNull ?? const [],
                              dsos: dsos.valueOrNull ?? const [],
                              constellations: constellations,
                              observationMinute: observationMinute,
                              location: site,
                              selectedObject: selectedObject,
                              mountPosition: mountPosition,
                              sunPos: sunPos,
                              moonPos: moonPos,
                              moonIllumination: moonIllumination,
                              planets: planets,
                              satellites: satellites,
                              variableStars: variableStars,
                              minorPlanets: minorPlanets,
                              milkyWayPoints: milkyWayPoints,
                            ),
                            // The angular-measurement ruler rides the overlay
                            // layer's foreground so drawing/clearing it never
                            // repaints the static base.
                            foregroundPainter:
                                (_measureStart != null && _measureEnd != null)
                                ? _MeasurementOverlayPainter(
                                    viewState: viewState,
                                    start: _measureStart!,
                                    end: _measureEnd!,
                                    latitude: site.latitude,
                                    lstHours:
                                        viewState.viewMode ==
                                            SkyViewMode.horizontal
                                        ? AstronomyCalculations.localSiderealTime(
                                            observationMinute,
                                            site.longitude,
                                          )
                                        : null,
                                  )
                                : null,
                            size: Size.infinite,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What the sky view shows before an observing site is on record.
class _NoObservingSiteSky extends StatelessWidget {
  const _NoObservingSiteSky();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF05070F),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.place_outlined, size: 32, color: Color(0xFF8A93A6)),
              SizedBox(height: 12),
              Text(
                'No observing site set',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFE6EAF2),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Set your location in Settings to draw the sky over your site.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF8A93A6), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Helper class for tracking pan velocity samples
class _PanSample {
  final Offset position;
  final DateTime time;

  _PanSample(this.position, this.time);
}
