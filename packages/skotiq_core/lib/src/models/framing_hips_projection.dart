// Shared sky <-> screen projection for the framing render path.
//
// This file adds the *inverse* (screen -> RA/Dec) and *forward* (RA/Dec ->
// screen) projection that the Flutter-side HiPS framing tile layer needs, built
// strictly on top of [FramingPlateScale] (`framing_plate_scale.dart`) WITHOUT
// modifying it — other framing components read that file and it must stay a
// minimal value object describing only the fit-to-canvas pixel geometry.
//
// Why a separate helper rather than fields on FramingPlateScale:
//
//  * FramingPlateScale knows the survey image's *angular extent and pixel size*
//    but deliberately does not know the *sky center* (which RA/Dec the canvas
//    center looks at) nor the live pan/zoom/rotation. Those live in the framing
//    provider state. Projection needs both halves, so it is composed here.
//  * The tile layer and the existing canvas must derive byte-identical geometry,
//    so this file also re-exposes the canvas's plate-scale resolution rule
//    ([FramingPlateScale.resolveForCanvas]) as a pure mirror of
//    `FramingCanvas._resolvePlateScale`. The canvas and the tile layer call the
//    same code, guaranteeing the FOV/mosaic overlay stays registered to the
//    HiPS tiles at every zoom.
//
// Conventions (must match the framing render path exactly):
//
//  * The canvas center `(size.width/2, size.height/2)` looks at the target
//    `(centerRaHours, centerDecDegrees)`; pan displaces that center by
//    `(panX, panY)` logical pixels (see `FramingPlateScale.drawRectFor`).
//  * Screen scale is `FramingPlateScale.pixelsPerDegree(size, zoom)` — the one
//    authoritative px/deg every overlay and the survey background use.
//  * Sign convention (from `FramingProvider._recenterFromPan`,
//    `framing_provider.dart:798-818`): dragging the background to the right
//    (+pan x) reveals sky to the *west* so the look-direction (canvas-center)
//    RA *decreases*; dragging down (+pan y) reveals sky to the *north* so the
//    look-direction Dec *increases*. Because +pan x shifts the canvas center to
//    a *lower* RA, screen +x points toward *increasing* RA, and screen +y
//    points toward *decreasing* Dec (north is up). RA offsets scale by
//    `1/cos(dec)` near the poles, mirroring `_recenterFromPan` and
//    `_recalculateMosaicPanels`.
//  * Rotation is applied as `rotate about canvas center` exactly as
//    `FramingSurveyImagePainter.paint` does
//    (`framing_background_painters.dart:67-73`): the unrotated screen point is
//    rotated by `rotation` degrees about the canvas center to get the final
//    on-screen point, and inverted by rotating by `-rotation` for the inverse.
//
// Pure Dart: depends only on `dart:math` and `dart:ui` geometry primitives plus
// the existing [FramingPlateScale]. No Flutter widgets, no Riverpod, no
// provider import — so it is fully unit-testable and shared across the provider,
// the framing painters and the HiPS tile layer without circular dependencies.

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'framing_plate_scale.dart';

/// Minimal, pure-Dart view of the framing provider state that the projection
/// and plate-scale resolution need.
///
/// The framing provider's `FramingState` lives in
/// `packages/skotiq_core/lib/src/providers/framing_provider.dart`, which
/// pulls in Drift, Riverpod and `http`. Depending on it from this geometry
/// model would (a) make the model non-pure and un-unit-testable in isolation and
/// (b) create a circular import (the provider imports this model). Instead the
/// provider/canvas constructs one of these from its state in a single line:
///
/// ```dart
/// FramingProjectionView(
///   plateScale: framingState.plateScale,
///   previewFovDegrees: framingState.previewFovDegrees,
///   centerRaHours: framingState.target?.raHours ?? 0,
///   centerDecDegrees: framingState.target?.decDegrees ?? 0,
///   zoom: framingState.zoom,
///   panX: framingState.panX,
///   panY: framingState.panY,
///   rotationDegrees: framingState.rotation,
/// );
/// ```
class FramingProjectionView {
  /// The plate scale of the *loaded* survey image, or `null` when no survey
  /// image has been fetched yet (mirrors `FramingState.plateScale`).
  final FramingPlateScale? plateScale;

  /// Preview field-of-view width in degrees used to synthesize a plate scale
  /// when no image is loaded (mirrors `FramingState.previewFovDegrees`).
  final double previewFovDegrees;

  /// RA, in hours, that the canvas center looks at (the framing target's RA).
  final double centerRaHours;

  /// Dec, in degrees, that the canvas center looks at (the framing target's Dec).
  final double centerDecDegrees;

  /// Current zoom factor (mirrors `FramingState.zoom`).
  final double zoom;

  /// Accumulated horizontal pan, in logical pixels (mirrors `FramingState.panX`).
  final double panX;

  /// Accumulated vertical pan, in logical pixels (mirrors `FramingState.panY`).
  final double panY;

  /// Field rotation, in degrees, applied about the canvas center (mirrors
  /// `FramingState.rotation`).
  final double rotationDegrees;

  const FramingProjectionView({
    required this.plateScale,
    required this.previewFovDegrees,
    required this.centerRaHours,
    required this.centerDecDegrees,
    required this.zoom,
    required this.panX,
    required this.panY,
    required this.rotationDegrees,
  });

  /// The accumulated pan as an [Offset], matching `drawRectFor`'s `pan` argument.
  Offset get pan => Offset(panX, panY);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FramingProjectionView &&
        other.plateScale == plateScale &&
        other.previewFovDegrees == previewFovDegrees &&
        other.centerRaHours == centerRaHours &&
        other.centerDecDegrees == centerDecDegrees &&
        other.zoom == zoom &&
        other.panX == panX &&
        other.panY == panY &&
        other.rotationDegrees == rotationDegrees;
  }

  @override
  int get hashCode => Object.hash(
    plateScale,
    previewFovDegrees,
    centerRaHours,
    centerDecDegrees,
    zoom,
    panX,
    panY,
    rotationDegrees,
  );

  @override
  String toString() =>
      'FramingProjectionView('
      'plateScale: $plateScale, '
      'previewFovDegrees: $previewFovDegrees, '
      'centerRaHours: $centerRaHours, '
      'centerDecDegrees: $centerDecDegrees, '
      'zoom: $zoom, panX: $panX, panY: $panY, '
      'rotationDegrees: $rotationDegrees)';
}

/// Plate-scale resolution shared by the framing canvas and the HiPS tile layer.
///
/// [resolveForCanvas] is a *pure mirror* of `FramingCanvas._resolvePlateScale`
/// (`packages/skotiq_app/lib/screens/framing/widgets/framing_canvas.dart`,
/// lines 89-111). Extracting it here lets the canvas background AND the tile
/// layer call one function so they derive byte-identical geometry — without this
/// the two could drift and HiPS tiles would no longer register with the survey
/// background / FOV overlay.
///
/// When a survey image is loaded its real [FramingPlateScale] is returned
/// verbatim. Otherwise a synthetic cutout is built whose pixel aspect matches
/// the canvas and whose *width* spans [FramingProjectionView.previewFovDegrees]
/// of sky, so the fit-to-canvas math makes the preview FOV fill the canvas width
/// at zoom 1.0 — exactly the no-image fallback the canvas uses today.
extension FramingPlateScaleResolution on FramingPlateScale {
  /// Resolve the plate scale for [canvasSize] given the framing [view].
  ///
  /// This is a static-style mirror; it does not read `this` (the extension form
  /// keeps the call site `FramingPlateScale.resolveForCanvas(...)` requested by
  /// the design). It returns the loaded scale when present, otherwise the
  /// synthetic preview cutout.
  static FramingPlateScale resolveForCanvas(
    Size canvasSize,
    FramingProjectionView view,
  ) {
    final loaded = view.plateScale;
    if (loaded != null) return loaded;

    final previewFov = view.previewFovDegrees;

    // Match the synthetic cutout's pixel aspect to the canvas so the preview FOV
    // maps onto the full canvas width. Before first layout the canvas is empty;
    // fall back to a unit-aspect square, which still yields a valid finite scale.
    // This is byte-identical to FramingCanvas._resolvePlateScale.
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
}

/// Forward + inverse sky <-> screen projection for one frame of the framing
/// canvas.
///
/// Construct one per paint via [FramingSkyProjection.fromView] (which resolves
/// the plate scale through [FramingPlateScaleResolution.resolveForCanvas] so it
/// is registered identically to the survey background and overlays). It then
/// answers the two questions the HiPS tile layer needs:
///
///  * [raDecToScreen] — where on the canvas a given sky point lands, so a tile's
///    sky footprint can be turned into a destination rectangle.
///  * [screenToRaDec] — which sky point a canvas pixel looks at, so the visible
///    sky region (and therefore the set of HiPS tiles to fetch) can be derived
///    from the current viewport corners.
///
/// [arcsecPerPixel] is the angular resolution at the current zoom; the HiPS
/// `Norder` level-of-detail selection is driven from it.
class FramingSkyProjection {
  /// The resolved plate scale (loaded survey scale, or synthetic preview).
  final FramingPlateScale plateScale;

  /// The on-screen canvas size, in logical pixels.
  final Size canvasSize;

  /// RA in hours the canvas center looks at.
  final double centerRaHours;

  /// Dec in degrees the canvas center looks at.
  final double centerDecDegrees;

  /// Current zoom factor.
  final double zoom;

  /// Accumulated pan, in logical pixels.
  final Offset pan;

  /// Field rotation, in degrees, about the canvas center.
  final double rotationDegrees;

  /// On-screen logical pixels per degree of sky at the current zoom — the one
  /// authoritative scale the survey background and every overlay use.
  final double pixelsPerDegree;

  /// Canvas center, in logical pixels.
  final Offset _canvasCenter;

  /// `cos(rotation)` / `sin(rotation)` cached for the rotation transform.
  final double _cosRot;
  final double _sinRot;

  /// `cos(dec)` of the look-direction center, clamped away from zero near the
  /// poles exactly as `_recenterFromPan` / `_recalculateMosaicPanels` do.
  final double _safeCosDec;

  FramingSkyProjection._({
    required this.plateScale,
    required this.canvasSize,
    required this.centerRaHours,
    required this.centerDecDegrees,
    required this.zoom,
    required this.pan,
    required this.rotationDegrees,
    required this.pixelsPerDegree,
    required Offset canvasCenter,
    required double cosRot,
    required double sinRot,
    required double safeCosDec,
  }) : _canvasCenter = canvasCenter,
       _cosRot = cosRot,
       _sinRot = sinRot,
       _safeCosDec = safeCosDec;

  /// Build a projection for [canvasSize] from a framing [view].
  ///
  /// The plate scale is resolved with the shared canvas rule so this projection
  /// is registered identically to the survey background and the FOV/mosaic
  /// overlays.
  factory FramingSkyProjection.fromView(
    Size canvasSize,
    FramingProjectionView view,
  ) {
    final scale = FramingPlateScaleResolution.resolveForCanvas(
      canvasSize,
      view,
    );
    return FramingSkyProjection.fromResolved(
      plateScale: scale,
      canvasSize: canvasSize,
      centerRaHours: view.centerRaHours,
      centerDecDegrees: view.centerDecDegrees,
      zoom: view.zoom,
      pan: view.pan,
      rotationDegrees: view.rotationDegrees,
    );
  }

  /// Build a projection from an already-resolved [plateScale] (e.g. the one the
  /// canvas resolved this frame), avoiding a second resolution.
  factory FramingSkyProjection.fromResolved({
    required FramingPlateScale plateScale,
    required Size canvasSize,
    required double centerRaHours,
    required double centerDecDegrees,
    required double zoom,
    required Offset pan,
    required double rotationDegrees,
  }) {
    final pxPerDeg = plateScale.pixelsPerDegree(canvasSize, zoom);
    final canvasCenter = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final rotRad = rotationDegrees * math.pi / 180.0;

    final decRad = centerDecDegrees * math.pi / 180.0;
    final cosDec = math.cos(decRad);
    // Identical clamp to FramingProvider._recenterFromPan: keep |cos(dec)| >=
    // 0.01 with the sign preserved so RA scaling stays finite near the poles.
    final safeCosDec = cosDec.abs() > 0.01
        ? cosDec
        : (cosDec.isNegative ? -0.01 : 0.01);

    return FramingSkyProjection._(
      plateScale: plateScale,
      canvasSize: canvasSize,
      centerRaHours: centerRaHours,
      centerDecDegrees: centerDecDegrees,
      zoom: zoom,
      pan: pan,
      rotationDegrees: rotationDegrees,
      pixelsPerDegree: pxPerDeg,
      canvasCenter: canvasCenter,
      cosRot: math.cos(rotRad),
      sinRot: math.sin(rotRad),
      safeCosDec: safeCosDec,
    );
  }

  /// Angular resolution of the current view, in arcseconds per on-screen pixel.
  ///
  /// `arcsec/px = 3600 / pixelsPerDegree`. This feeds the HiPS `Norder`
  /// level-of-detail selection: a coarser (lower-Norder) tile set is enough when
  /// arcsec/px is large (zoomed out), a finer (higher-Norder) set is needed when
  /// it is small (zoomed in). Returns [double.infinity] if the scale is
  /// degenerate (zero px/deg): an infinite arcsec/px picks the coarsest tile
  /// set, where a silently substituted finite value would pick a plausible
  /// wrong one.
  double get arcsecPerPixel {
    if (pixelsPerDegree <= 0 || !pixelsPerDegree.isFinite) {
      return double.infinity;
    }
    return 3600.0 / pixelsPerDegree;
  }

  /// The signed angular separation in RA *hours* from the center to [raHours],
  /// normalized to the shortest path across the 0h/24h wrap, so points just east
  /// or west of the seam project correctly instead of jumping a full circle.
  double _deltaRaHours(double raHours) {
    var d = (raHours - centerRaHours) % 24.0;
    if (d > 12.0) d -= 24.0;
    if (d < -12.0) d += 24.0;
    return d;
  }

  /// Project a sky point to its on-screen pixel position.
  ///
  /// Steps (inverse of [screenToRaDec]):
  ///  1. Compute the tangent-plane angular offset of the point from the center:
  ///     `dRaDeg = ΔRA_hours * 15 * cos(dec_center)` (the standard small-field
  ///     RA-fold-in-by-cos(dec)), `dDecDeg = dec - dec_center`.
  ///  2. Convert degrees to the *unrotated* screen offset using the sign
  ///     convention: +x points toward *increasing* RA (because +pan x lowers
  ///     the center RA), +y toward *decreasing* Dec (north is up). So
  ///     `dx = +dRaDeg * pxPerDeg`, `dy = -dDecDeg * pxPerDeg`.
  ///  3. Translate by canvas center + pan, then rotate about the canvas center
  ///     by `rotation` degrees — matching `FramingSurveyImagePainter.paint`'s
  ///     rotate-about-center, translate-by-pan composition.
  Offset raDecToScreen(double raHours, double decDegrees) {
    final dRaHours = _deltaRaHours(raHours);
    final dRaDeg = dRaHours * 15.0 * _safeCosDec;
    final dDecDeg = decDegrees - centerDecDegrees;

    // Unrotated screen offset from the (panned) canvas center.
    final ux = dRaDeg * pixelsPerDegree;
    final uy = -dDecDeg * pixelsPerDegree;

    // The panned center is the canvas center displaced by pan (drawRectFor's
    // center). Rotation is about the canvas center, so rotate the vector from
    // the canvas center which includes the pan displacement.
    final fromCenterX = ux + pan.dx;
    final fromCenterY = uy + pan.dy;

    final rx = fromCenterX * _cosRot - fromCenterY * _sinRot;
    final ry = fromCenterX * _sinRot + fromCenterY * _cosRot;

    return Offset(_canvasCenter.dx + rx, _canvasCenter.dy + ry);
  }

  /// Project an on-screen pixel position back to the sky point it looks at.
  ///
  /// Exact inverse of [raDecToScreen]:
  ///  1. Subtract the canvas center and un-rotate by `-rotation`.
  ///  2. Subtract pan to get the unrotated offset from the panned center.
  ///  3. Convert pixels to degrees and invert the sign convention to recover
  ///     `ΔRA` (folded out by `cos(dec)`) and `ΔDec`.
  ///  4. Add to the center RA/Dec, normalizing RA to `[0,24)` and clamping Dec
  ///     to `[-90,90]` (same bounds the provider applies on recenter).
  ({double raHours, double decDegrees}) screenToRaDec(Offset screen) {
    final fromCenterX = screen.dx - _canvasCenter.dx;
    final fromCenterY = screen.dy - _canvasCenter.dy;

    // Un-rotate (rotate by -rotation): inverse of the rotation matrix above.
    final ux0 = fromCenterX * _cosRot + fromCenterY * _sinRot;
    final uy0 = -fromCenterX * _sinRot + fromCenterY * _cosRot;

    // Remove pan to get the unrotated offset from the panned center.
    final ux = ux0 - pan.dx;
    final uy = uy0 - pan.dy;

    if (pixelsPerDegree <= 0 || !pixelsPerDegree.isFinite) {
      // Degenerate scale: cannot invert. Surface it rather than returning a
      // bogus sky point that would silently mis-place tiles.
      throw StateError(
        'FramingSkyProjection.screenToRaDec: non-positive pixelsPerDegree '
        '($pixelsPerDegree); plate scale is degenerate for this canvas/zoom.',
      );
    }

    // Invert the sign convention from raDecToScreen.
    final dRaDeg = ux / pixelsPerDegree;
    final dDecDeg = -uy / pixelsPerDegree;

    final dRaHours = (dRaDeg / _safeCosDec) / 15.0;

    var raHours = (centerRaHours + dRaHours) % 24.0;
    if (raHours < 0) raHours += 24.0;
    final decDegrees = (centerDecDegrees + dDecDeg).clamp(-90.0, 90.0);

    return (raHours: raHours, decDegrees: decDegrees);
  }

  /// The four canvas corners projected back to sky, in clockwise order from the
  /// top-left: top-left, top-right, bottom-right, bottom-left.
  ///
  /// The HiPS tile layer uses these to compute the visible sky region (and thus
  /// the set of tiles to request) directly from the live viewport, so requests
  /// track exactly what the user sees under any pan/zoom/rotation.
  List<({double raHours, double decDegrees})> visibleSkyCorners() {
    return <({double raHours, double decDegrees})>[
      screenToRaDec(Offset.zero),
      screenToRaDec(Offset(canvasSize.width, 0)),
      screenToRaDec(Offset(canvasSize.width, canvasSize.height)),
      screenToRaDec(Offset(0, canvasSize.height)),
    ];
  }
}
