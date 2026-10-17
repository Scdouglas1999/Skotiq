import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../coordinate_system.dart';
import '../rendering/sky_renderer.dart';
import 'fov_presets.dart';
// For [SkyFovProjector] — the one projection shared with the sky painter and
// the single-FOV overlay. It is declared in a part of this library because Dart
// part files cannot declare imports of their own; see the class doc.
import 'interactive_sky_view.dart';

/// Interactive, multi-rig FOV framing overlay for the planetarium sky view.
///
/// Draws every *visible* preset from [fovPresetsProvider] as a schematic sensor
/// rectangle, sized from each preset's computed angular field of view and
/// rotated to its position angle. The **active** preset is interactive:
///
///  * dragging its body pins it to a fixed RA/Dec and moves it across the sky;
///  * dragging the small handle above it rotates its position angle;
///  * a host-level "snap to target" sets the active preset's center directly.
///
/// Preset rectangles are placed with [SkyFovProjector] — the *same* projection
/// the sky painter draws the stars with — so a pinned rig lands exactly on its
/// target in every projection, at any view rotation, in either view frame, and
/// across the 0h/24h RA seam. Dragging uses that projector's analytic inverse,
/// so the rectangle tracks the pointer rather than sliding away from it.
///
/// Non-active presets are non-interactive; wrap the whole widget in an
/// [IgnorePointer] at the call site if FOV editing should be globally disabled.
class MultiFovOverlay extends ConsumerStatefulWidget {
  /// Current view center right ascension in hours.
  final double centerRaHours;

  /// Current view center declination in degrees.
  final double centerDecDeg;

  /// Current field of view (short screen axis) in degrees.
  final double fieldOfViewDeg;

  /// View rotation in degrees (the sky's roll).
  final double viewRotationDeg;

  /// Projection the sky view is currently drawn with. Defaults to the sky
  /// view's own default so existing call sites keep their behaviour.
  final SkyProjection projection;

  /// Celestial frame the sky view is centered on. In
  /// [SkyViewMode.horizontal] the alt/az center below is what positions the
  /// rectangles, and [lstHours] is required to place a pinned preset at all.
  final SkyViewMode viewMode;

  /// View center azimuth / altitude in degrees. Read only in
  /// [SkyViewMode.horizontal].
  final double centerAzDeg;
  final double centerAltitudeDeg;

  /// Observer latitude (degrees) and local sidereal time (hours). Needed only
  /// in [SkyViewMode.horizontal]; without [lstHours] a pinned preset is not
  /// drawn there rather than drawn in the wrong place.
  final double latitude;
  final double? lstHours;

  const MultiFovOverlay({
    super.key,
    required this.centerRaHours,
    required this.centerDecDeg,
    required this.fieldOfViewDeg,
    required this.viewRotationDeg,
    this.projection = SkyProjection.stereographic,
    this.viewMode = SkyViewMode.equatorial,
    this.centerAzDeg = 0,
    this.centerAltitudeDeg = 90,
    this.latitude = 0,
    this.lstHours,
  });

  /// The pose these rectangles are projected against.
  SkyViewState get viewState => SkyViewState(
    centerRA: centerRaHours,
    centerDec: centerDecDeg,
    fieldOfView: fieldOfViewDeg,
    rotation: viewRotationDeg,
    projection: projection,
    viewMode: viewMode,
    centerAz: centerAzDeg,
    centerAltitude: centerAltitudeDeg,
  );

  @override
  ConsumerState<MultiFovOverlay> createState() => _MultiFovOverlayState();
}

class _MultiFovOverlayState extends ConsumerState<MultiFovOverlay> {
  /// Hit-test radius (px) around the rotation handle.
  static const double _handleHitRadius = 16;

  bool _rotating = false;

  SkyFovProjector _projector(Size size) => SkyFovProjector.forSize(
    widget.viewState,
    size,
    latitude: widget.latitude,
    lstHours: widget.lstHours,
  );

  double _scale(Size size) =>
      SkyFovProjector.scaleFor(size, widget.fieldOfViewDeg);

  /// Screen position of a preset's center. Pinned presets project from their
  /// fixed RA/Dec; unpinned presets sit at the view center. Null when a pinned
  /// preset cannot be placed (behind the viewer, or the horizontal frame
  /// without a sidereal time) — the caller must then draw nothing.
  Offset? _centerOffset(FovPreset preset, Size size) {
    final center = preset.center;
    final projector = _projector(size);
    if (center == null) return projector.screenCenter;
    return projector.project(center);
  }

  /// Inverse of [_centerOffset]: convert a screen point to a sky coordinate.
  CelestialCoordinate? _coordAt(Offset point, Size size) =>
      _projector(size).unproject(point);

  /// Screen angle (radians, clockwise from screen "up") the preset's rectangle
  /// is drawn at: its position angle measured from local celestial north.
  double _screenAngle(FovPreset preset, Size size) {
    final north = preset.center == null
        ? null
        : _projector(size).northAngleAt(preset.center!);
    return preset.positionAngleDeg * math.pi / 180 +
        (north ?? widget.viewRotationDeg * math.pi / 180);
  }

  /// Screen position of the active preset's rotation handle.
  Offset? _handleOffset(FovPreset active, Size size) {
    final fov = active.fovDegrees;
    if (fov == null) return null;
    final center = _centerOffset(active, size);
    if (center == null) return null;
    final scale = _scale(size);
    final halfHeightPx = fov.$2 * scale / 2;
    final angle = _screenAngle(active, size);
    // Handle sits "up" along the rotated rectangle's short axis.
    final up = Offset(math.sin(angle), -math.cos(angle));
    return center + up * (halfHeightPx + 18);
  }

  void _onPanStart(DragStartDetails details, Size size) {
    final active = ref.read(fovPresetsProvider).active;
    if (active == null || !active.visible) return;
    final handle = _handleOffset(active, size);
    if (handle != null &&
        (details.localPosition - handle).distance <= _handleHitRadius) {
      _rotating = true;
    } else {
      _rotating = false;
      // Begin a drag: pin the preset to where it currently sits so subsequent
      // deltas move a concrete coordinate rather than the floating view center.
      if (active.center == null) {
        final here = _centerOffset(active, size);
        final coord = here == null ? null : _coordAt(here, size);
        if (coord != null) {
          ref.read(fovPresetsProvider.notifier).setActiveCenter(coord);
        }
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails details, Size size) {
    final notifier = ref.read(fovPresetsProvider.notifier);
    final active = ref.read(fovPresetsProvider).active;
    if (active == null) return;

    if (_rotating) {
      final center = _centerOffset(active, size);
      if (center == null) return;
      final v = details.localPosition - center;
      if (v.distance < 1e-6) return;
      // Angle of the pointer measured from screen "up", minus the screen angle
      // of celestial north at the preset, so the stored PA stays relative to
      // the sky rather than to the rotated canvas.
      final northRad = active.center == null
          ? widget.viewRotationDeg * math.pi / 180
          : (_projector(size).northAngleAt(active.center!) ??
                widget.viewRotationDeg * math.pi / 180);
      final screenAngle = math.atan2(v.dx, -v.dy);
      notifier.setActivePositionAngle((screenAngle - northRad) * 180 / math.pi);
    } else {
      final coord = _coordAt(details.localPosition, size);
      if (coord == null) return;
      notifier.setActiveCenter(coord);
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _rotating = false;
  }

  /// Axis-aligned screen bounds of the active preset's rotated rectangle,
  /// expanded to enclose its rotation handle and a small touch margin. This is
  /// the only region that captures gestures, so panning empty sky always falls
  /// through to the sky-pan handler beneath.
  Rect? _activeHitRect(FovPreset active, Size size) {
    final fov = active.fovDegrees;
    if (fov == null) return null;
    final center = _centerOffset(active, size);
    if (center == null) return null;
    final scale = _scale(size);
    final halfW = fov.$1 * scale / 2;
    final halfH = fov.$2 * scale / 2;
    final angle = _screenAngle(active, size);
    final cos = math.cos(angle).abs();
    final sin = math.sin(angle).abs();
    // Half-extents of the rotated rectangle's enclosing AABB.
    final aabbHalfW = halfW * cos + halfH * sin;
    final aabbHalfH = halfW * sin + halfH * cos;
    var rect = Rect.fromCenter(
      center: center,
      width: aabbHalfW * 2,
      height: aabbHalfH * 2,
    );
    final handle = _handleOffset(active, size);
    if (handle != null) {
      rect = rect.expandToInclude(
        Rect.fromCircle(center: handle, radius: _handleHitRadius),
      );
    }
    // Touch margin so thin rigs remain grabbable.
    return rect.inflate(8);
  }

  @override
  Widget build(BuildContext context) {
    final presetsState = ref.watch(fovPresetsProvider);
    final visible = presetsState.presets.where((p) => p.visible).toList();
    if (visible.isEmpty) return const SizedBox.expand();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final active = presetsState.active;
        final hitRect = (active != null && active.visible)
            ? _activeHitRect(active, size)
            : null;

        return Stack(
          children: [
            // Non-interactive drawing layer: never intercepts gestures, so
            // sky pan/zoom keeps working over the whole canvas.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  size: size,
                  painter: _MultiFovPainter(
                    presets: visible,
                    activeId: presetsState.activeId,
                    viewState: widget.viewState,
                    latitude: widget.latitude,
                    lstHours: widget.lstHours,
                  ),
                ),
              ),
            ),
            // Interactive hit region scoped to the active preset only. Gestures
            // are reported in the full overlay's coordinate space (the region
            // is a sub-rect of it), so the existing projection math is reused
            // unchanged.
            if (hitRect != null)
              Positioned.fromRect(
                rect: hitRect,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) =>
                      _onPanStart(_shift(d, hitRect.topLeft), size),
                  onPanUpdate: (d) =>
                      _onPanUpdate(_shiftUpdate(d, hitRect.topLeft), size),
                  onPanEnd: _onPanEnd,
                ),
              ),
          ],
        );
      },
    );
  }

  // The hit region is offset from the overlay origin, so translate gesture
  // local positions back into overlay space before projecting.
  DragStartDetails _shift(DragStartDetails d, Offset origin) =>
      DragStartDetails(
        sourceTimeStamp: d.sourceTimeStamp,
        globalPosition: d.globalPosition,
        localPosition: d.localPosition + origin,
        kind: d.kind,
      );

  DragUpdateDetails _shiftUpdate(DragUpdateDetails d, Offset origin) =>
      DragUpdateDetails(
        sourceTimeStamp: d.sourceTimeStamp,
        delta: d.delta,
        primaryDelta: d.primaryDelta,
        globalPosition: d.globalPosition,
        localPosition: d.localPosition + origin,
      );
}

class _MultiFovPainter extends CustomPainter {
  final List<FovPreset> presets;
  final String? activeId;
  final SkyViewState viewState;
  final double latitude;
  final double? lstHours;

  _MultiFovPainter({
    required this.presets,
    required this.activeId,
    required this.viewState,
    required this.latitude,
    required this.lstHours,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (viewState.fieldOfView <= 0 || size.shortestSide <= 0) return;
    final projector = SkyFovProjector.forSize(
      viewState,
      size,
      latitude: latitude,
      lstHours: lstHours,
    );
    final scale = projector.pixelsPerDegree;

    for (final preset in presets) {
      final fov = preset.fovDegrees;
      if (fov == null) continue;

      // Project the preset center through the same maths as the stars. A null
      // projection means the target is behind the viewer (or unplaceable in
      // this frame) — skip it rather than draw the rig somewhere false.
      final pc = preset.center;
      final center = pc == null
          ? projector.screenCenter
          : projector.project(pc);
      if (center == null) continue;

      // Position angle is measured from celestial north, which is only screen
      // "up" at the view center; elsewhere the projection tilts it.
      final northRad = pc == null
          ? viewState.rotation * math.pi / 180
          : (projector.northAngleAt(pc) ?? viewState.rotation * math.pi / 180);

      final isActive = preset.id == activeId;
      _drawPreset(canvas, center, scale, northRad, fov, preset, isActive);
    }
  }

  void _drawPreset(
    Canvas canvas,
    Offset center,
    double scale,
    double northRad,
    (double, double) fov,
    FovPreset preset,
    bool isActive,
  ) {
    final widthPx = fov.$1 * scale;
    final heightPx = fov.$2 * scale;
    final angle = preset.positionAngleDeg * math.pi / 180 + northRad;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: widthPx,
      height: heightPx,
    );

    final color = preset.color;

    // Faint fill so overlapping rigs read as distinct framing footprints.
    canvas.drawRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: isActive ? 0.10 : 0.05)
        ..style = PaintingStyle.fill,
    );

    // Schematic border: dimmer for inactive presets so the active one reads.
    final border = Paint()
      ..color = color.withValues(alpha: isActive ? 0.95 : 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isActive ? 1.6 : 1.1;
    canvas.drawRect(rect, border);

    // Corner brackets emphasise the sensor framing.
    _drawCornerBrackets(canvas, rect, border);

    // Center tick.
    final tick = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    canvas.drawLine(const Offset(-6, 0), const Offset(6, 0), tick);
    canvas.drawLine(const Offset(0, -6), const Offset(0, 6), tick);

    // Rotation handle (active only): a stem + dot at the top short edge.
    if (isActive) {
      final handlePaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      final stem = Paint()
        ..color = color.withValues(alpha: 0.8)
        ..strokeWidth = 1.2;
      final handleY = -heightPx / 2 - 18;
      canvas.drawLine(Offset(0, -heightPx / 2), Offset(0, handleY + 5), stem);
      canvas.drawCircle(Offset(0, handleY), 5, handlePaint);
    }

    canvas.restore();

    // Labels are drawn un-rotated, below the (unrotated) center, so they stay
    // legible regardless of position angle.
    final label = preset.name;
    final fovText =
        '${fov.$1.toStringAsFixed(2)}° × ${fov.$2.toStringAsFixed(2)}°';
    final scaleText = preset.imageScaleArcsecPerPx != null
        ? '${preset.imageScaleArcsecPerPx!.toStringAsFixed(2)}"/px'
        : null;

    final maxHalf = math.max(widthPx, heightPx) / 2;
    _drawLabel(
      canvas,
      center + Offset(0, maxHalf + 14),
      label,
      preset.color,
      bold: isActive,
    );
    _drawLabel(
      canvas,
      center + Offset(0, maxHalf + 28),
      scaleText == null ? fovText : '$fovText  ·  $scaleText',
      preset.color.withValues(alpha: 0.75),
      fontSize: 9,
    );
  }

  void _drawCornerBrackets(Canvas canvas, Rect rect, Paint paint) {
    final len = math.min(rect.width, rect.height) * 0.14;
    if (len <= 0) return;
    // Top-left
    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(len, 0), paint);
    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(0, len), paint);
    // Top-right
    canvas.drawLine(rect.topRight, rect.topRight + Offset(-len, 0), paint);
    canvas.drawLine(rect.topRight, rect.topRight + Offset(0, len), paint);
    // Bottom-right
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + Offset(-len, 0),
      paint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + Offset(0, -len),
      paint,
    );
    // Bottom-left
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + Offset(len, 0), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + Offset(0, -len), paint);
  }

  void _drawLabel(
    Canvas canvas,
    Offset position,
    String text,
    Color color, {
    double fontSize = 10,
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    painter.layout();
    painter.paint(
      canvas,
      position - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _MultiFovPainter old) {
    return old.presets != presets ||
        old.activeId != activeId ||
        old.viewState != viewState ||
        old.latitude != latitude ||
        old.lstHours != lstHours;
  }
}
