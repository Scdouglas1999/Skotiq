import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nightshade_ui/nightshade_ui.dart';
import 'package:nightshade_core/nightshade_core.dart';
// FramingPlateScale is the C1 single-source-of-truth astrometric scale shared by
// the framing painters and the gesture hit-tester. It lives in nightshade_core's
// models layer and is not surfaced through the public barrel, matching the
// app->core src-model convention used by the framing painters themselves.
// ignore: implementation_imports
import 'package:nightshade_core/src/models/framing_plate_scale.dart';
// FramingSkyProjection is the shared sky<->screen mapping the gesture handlers
// invert to turn a box-drag pixel position back into the aim's RA/Dec — the
// exact inverse of the transform stack the overlays are drawn through, so the
// dragged point lands on the sky point under the cursor. Same src-model import
// convention as the plate scale above.
// ignore: implementation_imports
import 'package:nightshade_core/src/models/framing_hips_projection.dart';

import '../../../widgets/tutorial_keys/framing_keys.dart';
import '../painters/framing_background_painters.dart';
import '../painters/framing_painters.dart';
import 'framing_overlays.dart';
import 'guide_star_overlay.dart';
import 'hips_tile_layer.dart';

part 'framing_canvas_parts/_canvas_controls.dart';

/// The main framing canvas: handles pan / rotate gestures, stacks the survey
/// image (or starfield fallback), optional grid, equipment FOV overlays, the
/// mosaic grid, and the on-canvas controls (top chips, zoom, scale, target
/// info, error banner).
class FramingCanvas extends ConsumerStatefulWidget {
  final NightshadeColors colors;
  final FramingState framingState;
  final FramingEquipmentResult? equipmentResult;

  /// Reports a pan delta together with the real, sidebar-excluded [canvasSize]
  /// the delta was measured against. The size is required so the framing
  /// provider can convert drawn-canvas-pixel pans to sky degrees through the
  /// shared plate scale (the pan-refetch threshold depends on it).
  final void Function(double dx, double dy, Size canvasSize) onPan;
  final void Function(double angle) onRotate;

  /// Fired as a drag that started INSIDE the FOV rect moves the reticle's aim
  /// point over the (stationary) sky. Reports absolute sky coordinates — RA in
  /// hours, Dec in degrees — projected back through the shared
  /// [FramingSkyProjection]; wired to `FramingNotifier.setAim` by the screen.
  final void Function(double raHours, double decDegrees) onAimChanged;

  /// Fired whenever the measured canvas size changes (the LayoutBuilder reports
  /// a new bounded box, e.g. when the user drags the sidebar splitter or the
  /// window resizes). Drives C9's plate-scale-aware survey re-fetch so the
  /// imagery resolution tracks the canvas.
  final void Function(Size canvasSize) onCanvasResized;

  const FramingCanvas({
    super.key,
    required this.colors,
    required this.framingState,
    required this.equipmentResult,
    required this.onPan,
    required this.onRotate,
    required this.onAimChanged,
    required this.onCanvasResized,
  });

  @override
  ConsumerState<FramingCanvas> createState() => _FramingCanvasState();
}

class _FramingCanvasState extends ConsumerState<FramingCanvas> {
  bool _isDragging = false;
  bool _isRotating = false;

  /// A drag that started inside the FOV rect: moves the reticle's AIM on the
  /// (stationary) sky instead of panning the sky under a fixed reticle.
  bool _isDraggingBox = false;
  Offset _lastPosition = Offset.zero;

  /// Pointer offset from the box center captured at drag start, so the grabbed
  /// spot on the reticle stays under the cursor for the whole box drag.
  Offset _boxGrabOffset = Offset.zero;

  /// The real canvas size, captured from the [LayoutBuilder] in [build].
  ///
  /// Gesture handlers ([GestureDetector] callbacks) need the canvas center and
  /// the plate scale's pixels-per-degree, both of which depend on the *actual*
  /// painted size of the canvas — not [MediaQuery.sizeOf], which returns the
  /// whole window (including the framing sidebar) and so put the rotation ring
  /// and rotation pivot in the wrong place. The size is written from the
  /// LayoutBuilder's constraints on every layout pass and read back in the
  /// gesture math.
  Size _canvasSize = Size.zero;

  FramingEquipment? get _equipment => widget.equipmentResult?.equipment;
  bool get _hasEquipment => widget.equipmentResult?.isReady ?? false;

  /// The astrometric plate scale every overlay painter shares, for the given
  /// real [canvasSize].
  ///
  /// When a survey image is loaded its real [FramingPlateScale] (published by
  /// [FramingNotifier]) is used, so the FOV reticle, equipment overlay and
  /// mosaic grid are co-registered with the imagery to the pixel. When no image
  /// is loaded there is nothing to register against, so a synthetic scale is
  /// derived inline from the current preview FOV and the real canvas geometry:
  /// the field is treated as a cutout whose pixel aspect matches the canvas and
  /// whose *width* spans [FramingState.previewFovDegrees] of sky. With that the
  /// fit-to-canvas math in [FramingPlateScale] makes the preview FOV fill the
  /// canvas width at zoom 1.0 — the long-standing behavior of the no-image
  /// fallback, now expressed through the one shared scale instead of three
  /// divergent ad-hoc constants, so the overlays still render correctly before
  /// any survey imagery is fetched.
  FramingPlateScale _resolvePlateScale(Size canvasSize) {
    final loaded = widget.framingState.plateScale;
    if (loaded != null) return loaded;

    final previewFov = widget.framingState.previewFovDegrees;

    // Match the synthetic cutout's pixel aspect to the canvas so the preview
    // FOV maps onto the full canvas width (mirroring the fit-to-canvas rule the
    // real survey path uses). Before first layout the canvas is empty; fall back
    // to a unit-aspect square, which still yields a valid, finite scale.
    final aspect = canvasSize.isEmpty || canvasSize.height <= 0
        ? 1.0
        : canvasSize.width / canvasSize.height;
    const pixelHeight = 1000;
    final pixelWidth = (pixelHeight * aspect).round().clamp(1, 1 << 20);

    return FramingPlateScale(
      surveyFovWidthDeg: previewFov,
      surveyFovHeightDeg: previewFov / aspect,
      imagePixelWidth: pixelWidth,
      imagePixelHeight: pixelHeight,
    );
  }

  /// Whether to show the equipment FOV overlay (preview FOV > equipment FOV)
  bool get _showEquipmentOverlay {
    if (!_hasEquipment || _equipment == null) return false;
    return widget.framingState.previewFovDegrees > _equipment!.fovWidthDeg &&
        widget.framingState.showEquipmentFovOverlay;
  }

  /// The imaging FOV (width, height) in degrees the guide-star finder searches.
  ///
  /// Uses the equipment FOV when a profile is configured — that is the frame the
  /// user is actually composing — and otherwise the preview FOV (squared off to
  /// the canvas aspect so the finder still works before any equipment is set,
  /// mirroring the no-image plate-scale fallback).
  (double, double) _guideStarFovDegrees(Size canvasSize) {
    if (_hasEquipment && _equipment != null) {
      return (_equipment!.fovWidthDeg, _equipment!.fovHeightDeg);
    }
    final previewFov = widget.framingState.previewFovDegrees;
    final aspect = canvasSize.isEmpty || canvasSize.height <= 0
        ? 1.0
        : canvasSize.width / canvasSize.height;
    return (previewFov, previewFov / aspect);
  }

  /// The shared sky<->screen projection for the CURRENT view: resolved plate
  /// scale, measured canvas size, live pan/zoom/rotation, and the view-center
  /// target as the look-direction. Used by the gesture handlers both forward
  /// (where the FOV box is drawn) and inverse (which sky point a dragged pixel
  /// looks at).
  ///
  /// Returns `null` when the projection cannot be built or inverted: no framed
  /// target to center on, or a degenerate px/deg scale — `screenToRaDec` throws
  /// [StateError] on `pixelsPerDegree <= 0`, and a skipped drag beat is cheaper
  /// than a crash mid-gesture.
  FramingSkyProjection? _gestureProjection(FramingPlateScale plateScale) {
    final state = widget.framingState;
    final target = state.target;
    if (target == null || _canvasSize.isEmpty) return null;
    final projection = FramingSkyProjection.fromResolved(
      plateScale: plateScale,
      canvasSize: _canvasSize,
      centerRaHours: target.raHours,
      centerDecDegrees: target.decDegrees,
      zoom: state.zoom,
      pan: Offset(state.panX, state.panY),
      rotationDegrees: state.rotation,
    );
    final ppd = projection.pixelsPerDegree;
    if (ppd <= 0 || !ppd.isFinite) return null;
    return projection;
  }

  /// The aim's UNROTATED drawn offset, in logical px, from the panned view
  /// center — the `u` term inside `FramingSkyProjection.raDecToScreen`,
  /// recomputed here so the FOV/mosaic overlays can be translated by
  /// `pan + u` within the same rotate-about-canvas-center stack the survey
  /// uses. The reticle then lands at `canvasCenter + R(rotation)·(pan + u)`,
  /// its aim's sky position, while the survey/grid stay on plain `pan` — the
  /// sky stays sky-locked under the moved box.
  ///
  /// [Offset.zero] whenever no separate aim is set, which makes the overlays
  /// draw exactly where they always did (reticle at the view center).
  Offset _aimOffsetPx(FramingPlateScale plateScale) {
    final state = widget.framingState;
    final target = state.target;
    final aimRa = state.aimRaHours;
    final aimDec = state.aimDecDegrees;
    if (target == null || aimRa == null || aimDec == null) {
      return Offset.zero;
    }
    final ppd = plateScale.pixelsPerDegree(_canvasSize, state.zoom);
    if (ppd <= 0 || !ppd.isFinite) return Offset.zero;

    // Mirrors raDecToScreen's inner step: the RA delta wraps to the shortest
    // 24h path and folds by cos(view-center dec) with the same pole clamp;
    // +x points toward increasing RA, +y toward decreasing Dec (north up).
    final decRad = target.decDegrees * math.pi / 180.0;
    final cosDec = math.cos(decRad);
    final safeCosDec =
        cosDec.abs() > 0.01 ? cosDec : (cosDec.isNegative ? -0.01 : 0.01);
    var dRaHours = (aimRa - target.raHours) % 24.0;
    if (dRaHours > 12.0) dRaHours -= 24.0;
    if (dRaHours < -12.0) dRaHours += 24.0;
    return Offset(
      dRaHours * 15.0 * safeCosDec * ppd,
      -(aimDec - target.decDegrees) * ppd,
    );
  }

  /// On-screen position of the drawn FOV-box center this frame —
  /// `raDecToScreen(effectiveAim)` == `canvasCenter + R(rotation)·(pan + u)`.
  /// This is NOT the canvas center once the user has panned the sky or dragged
  /// the reticle off the view center, and both the rotation-handle hit ring
  /// and the rotate gesture's atan2 pivot anchor to it. Falls back to the
  /// canvas center when the projection cannot run (no target / degenerate
  /// scale), matching the pre-aim geometry.
  Offset _boxCenterScreen(FramingPlateScale plateScale) {
    final projection = _gestureProjection(plateScale);
    final state = widget.framingState;
    final aimRa = state.effectiveAimRaHours;
    final aimDec = state.effectiveAimDecDegrees;
    if (projection == null || aimRa == null || aimDec == null) {
      return Offset(_canvasSize.width / 2, _canvasSize.height / 2);
    }
    return projection.raDecToScreen(aimRa, aimDec);
  }

  /// Whether [pointer] is inside the drawn FOV rectangle.
  ///
  /// The rect is centered on the aim's screen position with half-extents
  /// `fov * ppd / 2`, rotated by [FramingState.rotation] about the CANVAS
  /// center. The pointer is therefore un-rotated back into the painter's draw
  /// space (the same un-rotate `screenToRaDec` performs), shifted by the box's
  /// unrotated `pan + u` offset, and compared against the axis-aligned rect.
  bool _isInsideFovRect(Offset pointer, FramingPlateScale plateScale) {
    final state = widget.framingState;
    final equipment = _equipment;
    if (equipment == null) return false;
    final ppd = plateScale.pixelsPerDegree(_canvasSize, state.zoom);
    if (ppd <= 0 || !ppd.isFinite) return false;

    final rotRad = state.rotation * math.pi / 180.0;
    final cosR = math.cos(rotRad);
    final sinR = math.sin(rotRad);
    final center = Offset(_canvasSize.width / 2, _canvasSize.height / 2);
    final fromCenter = pointer - center;
    final unrotatedX = fromCenter.dx * cosR + fromCenter.dy * sinR;
    final unrotatedY = -fromCenter.dx * sinR + fromCenter.dy * cosR;
    final u = _aimOffsetPx(plateScale);
    final localX = unrotatedX - state.panX - u.dx;
    final localY = unrotatedY - state.panY - u.dy;

    return localX.abs() <= equipment.fovWidthDeg * ppd / 2 &&
        localY.abs() <= equipment.fovHeightDeg * ppd / 2;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Capture the real canvas size so both the shared plate scale and the
        // gesture handlers below use the canvas geometry rather than the
        // whole-window MediaQuery size (which includes the framing sidebar).
        final newSize = constraints.biggest;
        if (newSize != _canvasSize) {
          _canvasSize = newSize;
          // Notify after the frame: the LayoutBuilder runs during build, and the
          // resize handler may trigger a provider state change (survey re-fetch)
          // which must not mutate state mid-build.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onCanvasResized(newSize);
          });
        }
        final plateScale = _resolvePlateScale(_canvasSize);
        // Mouse-wheel zoom: extend the on-screen +/- zoom buttons to the
        // scroll wheel — scroll up zooms in, down zooms out, reusing the same
        // stepped zoomIn/zoomOut (clamped 0.25–4.0) the buttons use. A Consumer
        // supplies `ref` (this State is a plain State, not a ConsumerState).
        return Consumer(
          builder: (context, ref, _) => Listener(
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent) {
                final notifier = ref.read(framingProvider.notifier);
                if (signal.scrollDelta.dy < 0) {
                  notifier.zoomIn();
                } else if (signal.scrollDelta.dy > 0) {
                  notifier.zoomOut();
                }
              }
            },
            child: _buildCanvas(context, plateScale),
          ),
        );
      },
    );
  }

  /// Whether the floating target card is shown (target resolved + labels on).
  bool get _showTargetInfoOverlay =>
      widget.framingState.target != null && widget.framingState.showLabels;

  /// Whether the "configure equipment for accurate framing" hint is shown.
  bool get _showEquipmentHint =>
      !_hasEquipment && widget.framingState.target != null;

  /// Horizontal space kept clear at the canvas's top-left for the
  /// optical-config affordance, which [FramingScreen] paints in its OWN Stack
  /// at (16, 16): a 48px touch-target button when collapsed, or the panel
  /// (capped at 260px) when open. Reserving it here keeps the two Stacks from
  /// placing their children at the same origin, where the opaque button body
  /// covers the survey dropdown and the open panel hides the Grid chip.
  ///
  /// The gutter is skipped when the canvas is too narrow to give it away: on a
  /// phone the controls already Wrap onto a second line and squeezing them
  /// further would cost more than the overlap.
  double _opticalConfigGutter() {
    const gap = NightshadeTokens.spaceMd;
    final reserved = widget.framingState.showOpticalConfigPanel
        ? 260.0 + gap
        : NightshadeTokens.minTouchTarget + gap;
    final width = _canvasSize.width;
    // Pre-layout (first frame) assume there is room; the next frame corrects it.
    if (width <= 0) return reserved;
    return (width - reserved) >= 240 ? reserved : 0;
  }

  Widget _buildCanvas(BuildContext context, FramingPlateScale plateScale) {
    // The aim's unrotated drawn offset from the view center. The FOV/mosaic
    // overlays are translated by `pan + aimOffset` (still inside the
    // rotate-about-center stack) so the reticle sits at the AIM's sky position
    // while the survey background, grid and HiPS tiles — all left on plain
    // `pan` — stay sky-locked underneath it. Offset.zero until the user drags
    // the box off-center, so the default render is identical to before.
    final aimOffset = _aimOffsetPx(plateScale);
    final overlayOffset = Offset(
      widget.framingState.panX + aimOffset.dx,
      widget.framingState.panY + aimOffset.dy,
    );

    return GestureDetector(
      onPanStart: (details) {
        _lastPosition = details.localPosition;
        final canvasSize = _canvasSize;
        final pointer = details.localPosition;
        // The drawn box center — canvasCenter + R(rotation)·(pan + u) — is NOT
        // the canvas center once the sky is panned or the reticle dragged
        // off-center; both the rotation ring and the rect hit-test anchor to
        // the box, not the canvas.
        final boxCenter = _boxCenterScreen(plateScale);
        final distance = (pointer - boxCenter).distance;

        // If clicking near the rotation handle, rotate instead of pan. The
        // handle is painted [FramingFOVPainter.rotationHandleGap] above the FOV
        // rectangle's top edge with radius
        // [FramingFOVPainter.rotationHandleRadius]; the hit ring spans that
        // handle center +/- [FramingFOVPainter.rotationHitTolerance] so the
        // touch target matches exactly where the handle is drawn. The FOV
        // rectangle's half-height is derived from the *same* shared plate scale
        // the painter uses, so the ring tracks the rendered reticle under any
        // zoom or survey registration.
        if (_hasEquipment && _equipment != null) {
          final pixelsPerDegree =
              plateScale.pixelsPerDegree(canvasSize, widget.framingState.zoom);
          final fovHalfHeight = _equipment!.fovHeightDeg * pixelsPerDegree / 2;
          final handleCenterDistance =
              fovHalfHeight + FramingFOVPainter.rotationHandleGap;
          final innerRadius = handleCenterDistance -
              FramingFOVPainter.rotationHandleRadius -
              FramingFOVPainter.rotationHitTolerance;
          final outerRadius = handleCenterDistance +
              FramingFOVPainter.rotationHandleRadius +
              FramingFOVPainter.rotationHitTolerance;
          if (distance > innerRadius && distance < outerRadius) {
            _isRotating = true;
            return;
          }
          // Inside the drawn FOV rect: drag the reticle's AIM over the
          // stationary sky rather than panning the sky under a fixed reticle.
          // Requires a framed target — the inverse projection needs the
          // view-center look-direction to project against. The grab offset
          // keeps the grabbed spot under the cursor instead of snapping the
          // box center to it.
          if (widget.framingState.target != null &&
              _isInsideFovRect(pointer, plateScale)) {
            _isDraggingBox = true;
            _boxGrabOffset = pointer - boxCenter;
            return;
          }
          _isDragging = true;
        } else {
          _isDragging = true;
        }
      },
      onPanUpdate: (details) {
        if (_isRotating) {
          // The handle rotates about the BOX center (it is painted into the
          // box's transform, so it orbits the aim), not the canvas center.
          final boxCenter = _boxCenterScreen(plateScale);
          final angle = math.atan2(
            details.localPosition.dx - boxCenter.dx,
            -(details.localPosition.dy - boxCenter.dy),
          );
          widget.onRotate(angle * 180 / math.pi);
        } else if (_isDraggingBox) {
          // Move the AIM to the sky point under the dragged spot; the sky
          // itself does not move. screenToRaDec is the exact inverse of the
          // rotate∘translate(pan+u) draw stack, so the box tracks the cursor
          // under any pan/rotation/zoom.
          final projection = _gestureProjection(plateScale);
          if (projection != null) {
            final aim = projection
                .screenToRaDec(details.localPosition - _boxGrabOffset);
            widget.onAimChanged(aim.raHours, aim.decDegrees);
          }
        } else if (_isDragging) {
          final delta = details.localPosition - _lastPosition;
          widget.onPan(delta.dx, delta.dy, _canvasSize);
          _lastPosition = details.localPosition;
        }
      },
      onPanEnd: (_) {
        _isDragging = false;
        _isRotating = false;
        _isDraggingBox = false;
      },
      // A cancelled gesture (lost arena) never reaches onPanEnd — without this
      // a stale _isDraggingBox would hijack the NEXT drag's classification.
      onPanCancel: () {
        _isDragging = false;
        _isRotating = false;
        _isDraggingBox = false;
      },
      // Hard-clip the entire canvas to its bounded box. Several layers paint
      // beyond their own RenderBox via raw canvas ops: in particular
      // [FramingSurveyImagePainter] draws the survey cutout into
      // [FramingPlateScale.drawRectFor], which at zoom > 1 is LARGER than the
      // canvas, and `drawImageRect` does not clip to the CustomPaint's size — so
      // without this the survey background spilled past the canvas edges and
      // painted behind the framing sidebar. The HiPS tile painter already
      // self-clips, which is why only the background bled; this ClipRect makes
      // the guarantee uniform (background, grid, FOV/mosaic overlays and tiles
      // all stay inside the canvas) at one place instead of per-painter.
      child: ClipRect(
        child: Container(
          color: widget.colors.background,
          child: Stack(
            children: [
              // Survey image background
              if (widget.framingState.surveyImage != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: FramingSurveyImagePainter(
                      image: widget.framingState.surveyImage!,
                      zoom: widget.framingState.zoom,
                      panX: widget.framingState.panX,
                      panY: widget.framingState.panY,
                      rotation: widget.framingState.rotation,
                      plateScale: plateScale,
                    ),
                  ),
                )
              else if (widget.framingState.isLoadingImage)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: widget.colors.primary),
                      const SizedBox(height: NightshadeTokens.spaceLg),
                      Text(
                        'Loading sky survey...',
                        style: NightshadeTypography.body
                            .copyWith(color: widget.colors.textMuted),
                      ),
                    ],
                  ),
                )
              else
                // Static star field backdrop
                CustomPaint(
                  painter: FramingStarBackgroundPainter(colors: widget.colors),
                  size: Size.infinite,
                ),

              // GPU HiPS deep-survey tile mosaic. It belongs in the canvas Stack
              // directly ABOVE the single-cutout survey snapshot / starfield (the
              // never-blank fallback underneath) and UNDER the grid / FOV /
              // equipment / mosaic overlays below, so the streamed imagery never
              // hides the FOV reticle. The layer gates itself on
              // hipsFramingActiveProvider and paints nothing (a transparent box)
              // when the feature is off or the survey has no verified HiPS
              // pyramid, so with it inactive the canvas is exactly as before. It
              // resolves the SAME FramingPlateScale this canvas uses, so the
              // mosaic co-registers with the overlays to the pixel. The
              // attribution badge is composed separately at screen level (top
              // chrome) by FramingHipsLayerWiring.
              const Positioned.fill(child: HipsTileLayer()),

              // Grid overlay
              if (widget.framingState.showGrid)
                CustomPaint(
                  painter: FramingGridPainter(
                    zoom: widget.framingState.zoom,
                    panX: widget.framingState.panX,
                    panY: widget.framingState.panY,
                    color: widget.colors.primary
                        .withValues(alpha: NightshadeTokens.opacityMedium),
                    plateScale: plateScale,
                  ),
                  size: Size.infinite,
                ),

              // Equipment FOV overlay - Show when preview FOV > equipment FOV
              //
              // Transform order MUST match FramingSurveyImagePainter: the survey
              // background is drawn into a pan-displaced rect and THEN rotated
              // about the canvas center (rotate ∘ translate), so the image center
              // lands at canvasCenter + rotate(pan). To keep the reticle pixel-co-
              // registered with the imagery under simultaneous pan AND rotation,
              // the overlay must compose the same way: rotate about the canvas
              // center OUTERMOST, translate by pan INNERMOST. (Reversing these —
              // translate outer, rotate inner — drifts the reticle off the
              // imagery by rotate(pan) - pan whenever rotation != 0 and pan != 0.)
              //
              // The translate is by `pan + u` — pan (the view, shared with the
              // sky) PLUS the aim's unrotated sky offset — so the box sits at
              // the AIM's position while the background stays on plain `pan`.
              if (_showEquipmentOverlay && _equipment != null)
                Center(
                  child: Transform.rotate(
                    angle: widget.framingState.rotation * math.pi / 180,
                    child: Transform.translate(
                      offset: overlayOffset,
                      child: CustomPaint(
                        painter: FramingEquipmentFOVOverlayPainter(
                          fovWidth: _equipment!.fovWidthDeg,
                          fovHeight: _equipment!.fovHeightDeg,
                          zoom: widget.framingState.zoom,
                          plateScale: plateScale,
                          colors: widget.colors,
                          opacity:
                              widget.framingState.equipmentFovOverlayOpacity,
                          showDirections:
                              widget.framingState.showCardinalDirections,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),

              // FOV overlay - Show when equipment is configured and preview FOV <= equipment FOV
              // Same rotate-outer / translate-inner order as the background and
              // the larger-than-equipment overlay above, so the reticle stays
              // co-registered with the survey imagery under pan + rotation —
              // and the same `pan + u` translate so the box rides at the aim.
              if (_hasEquipment && _equipment != null && !_showEquipmentOverlay)
                Center(
                  child: Transform.rotate(
                    angle: widget.framingState.rotation * math.pi / 180,
                    child: Transform.translate(
                      offset: overlayOffset,
                      child: CustomPaint(
                        key: FramingTutorialKeys.fovRect,
                        painter: FramingFOVPainter(
                          fovWidth: _equipment!.fovWidthDeg,
                          fovHeight: _equipment!.fovHeightDeg,
                          zoom: widget.framingState.zoom,
                          plateScale: plateScale,
                          colors: widget.colors,
                          showDirections:
                              widget.framingState.showCardinalDirections,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),

              // Mosaic grid overlay
              // Same rotate-outer / translate-inner order as the background and
              // FOV overlays so the mosaic panels stay co-registered with the
              // survey imagery under pan + rotation. The painter draws a rigid
              // grid centered on its origin (it does NOT project the panels'
              // centerRa/Dec), so it needs the same `pan + u` translate: the
              // grid's painted center is the aim — matching the panels
              // _recalculateMosaicPanels computes around the effective aim.
              if (widget.framingState.mosaicEnabled &&
                  _hasEquipment &&
                  _equipment != null)
                Center(
                  child: Transform.rotate(
                    angle: widget.framingState.rotation * math.pi / 180,
                    child: Transform.translate(
                      offset: overlayOffset,
                      child: CustomPaint(
                        painter: FramingMosaicGridPainter(
                          config: widget.framingState.mosaicConfig,
                          panels: widget.framingState.mosaicPanels,
                          fovWidth: _equipment!.fovWidthDeg,
                          fovHeight: _equipment!.fovHeightDeg,
                          zoom: widget.framingState.zoom,
                          plateScale: plateScale,
                          colors: widget.colors,
                          showPanelNumbers:
                              widget.framingState.showPanelNumbers,
                          showSequencePath:
                              widget.framingState.showSequencePath,
                          selectedPanelIndex:
                              widget.framingState.selectedPanelIndex,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),

              // Guide-star finder overlay. Highlights bright (V < 10) catalog
              // stars inside the imaging FOV as candidate autoguider guide
              // stars. It is self-contained (reads framing state, loads nearby
              // catalog stars, projects through the SAME FramingSkyProjection
              // the reticle uses) and gated internally on
              // framingState.showGuideStars + a framed target, so it paints
              // nothing when the toggle is off. Positioned.fill so its markers
              // are placed in absolute canvas coordinates (the projection
              // already bakes in pan / zoom / rotation), NOT inside the
              // Center+Transform stack the reticle uses.
              () {
                final (gsW, gsH) = _guideStarFovDegrees(_canvasSize);
                return Positioned.fill(
                  child: GuideStarOverlay(
                    fovWidthDeg: gsW,
                    fovHeightDeg: gsH,
                  ),
                );
              }(),

              // Crosshairs
              if (ref.watch(imagingViewerStateProvider).showCrosshair)
                Center(
                  child: CustomPaint(
                    painter: FramingCrosshairPainter(colors: widget.colors),
                    size: const Size(100, 100),
                  ),
                ),

              // Top chrome — ONE flow, not three hard-coded offsets.
              //
              // The toolbar was `top: 16` with a [Wrap] that flows onto a second
              // line at narrow widths, while the target card and the
              // equipment-status card were each pinned at a literal `top: 60`.
              // Below roughly 1100 px the wrapped second row landed exactly
              // under those cards, which — being LATER Stack children — painted
              // over it and swallowed its hits: the "HiPS Tiles" chip was
              // visible ghosting through the card and could not be clicked at
              // all. Laying the three out in one Column means the cards always
              // sit below the toolbar however many lines it takes, at any width.
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      // The optical-config gutter reserves room for the gear
                      // that floats at the canvas's left edge.
                      padding: EdgeInsets.only(left: _opticalConfigGutter()),
                      child: _CanvasControls(
                        colors: widget.colors,
                        framingState: widget.framingState,
                      ),
                    ),
                    if (_showTargetInfoOverlay || _showEquipmentHint) ...[
                      const SizedBox(height: NightshadeTokens.spaceMd),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_showTargetInfoOverlay)
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                // The card reports where the telescope will
                                // point — the effective aim (the picked
                                // object's name/catalog id, the dragged
                                // reticle's coordinates) — not the view center.
                                child: FramingTargetInfoOverlay(
                                  colors: widget.colors,
                                  target:
                                      widget.framingState.effectiveAimTarget!,
                                ),
                              ),
                            ),
                          const Spacer(),
                          if (_showEquipmentHint)
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: _EquipmentHintCard(
                                  colors: widget.colors,
                                  previewFovDegrees:
                                      widget.framingState.previewFovDegrees,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Zoom controls
              Positioned(
                bottom: 16,
                right: 16,
                child: Consumer(
                  builder: (context, ref, child) => _ZoomControls(
                    colors: widget.colors,
                    zoom: widget.framingState.zoom,
                    onZoomIn: () => ref.read(framingProvider.notifier).zoomIn(),
                    onZoomOut: () =>
                        ref.read(framingProvider.notifier).zoomOut(),
                    onReset: () =>
                        ref.read(framingProvider.notifier).resetView(),
                  ),
                ),
              ),

              // Scale indicator
              Positioned(
                bottom: 16,
                left: 16,
                child: _ScaleIndicator(
                  colors: widget.colors,
                  zoom: widget.framingState.zoom,
                  plateScale: plateScale,
                  canvasSize: _canvasSize,
                ),
              ),

              // Error overlay
              if (widget.framingState.imageError != null)
                Center(
                  child: Container(
                    padding: NightshadeTokens.paddingLg,
                    margin: const EdgeInsets.all(NightshadeTokens.space3xl),
                    decoration: BoxDecoration(
                      color: widget.colors.error
                          .withValues(alpha: NightshadeTokens.opacitySubtle),
                      borderRadius: NightshadeTokens.borderRadiusMd,
                      border: Border.all(color: widget.colors.error),
                    ),
                    child: Text(
                      widget.framingState.imageError!,
                      style: NightshadeTypography.body
                          .copyWith(color: widget.colors.error),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
