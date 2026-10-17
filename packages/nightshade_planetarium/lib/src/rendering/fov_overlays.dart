import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../coordinate_system.dart';
// [SkyFovProjector] is declared in a part of the interactive sky view library
// because Dart part files cannot declare their own imports, so that is the only
// place all three FOV overlays can share one projection from. Reaching for it
// here is deliberate: a second, parallel projection drifts from the one the
// sky view draws with.
import '../widgets/interactive_sky_view.dart';
import 'sky_renderer.dart';

/// Type of FOV indicator
enum FOVType {
  /// Rectangular sensor FOV (camera)
  sensorRectangle,

  /// Circular eyepiece FOV
  eyepieceCircle,

  /// Standard Telrad circles (0.5, 2, 4 degrees)
  telradCircles,

  /// Finder scope circle
  finderScope,

  /// Custom rectangle
  customRectangle,

  /// Custom circle
  customCircle,
}

/// Configuration for a field of view indicator
class FOVIndicator {
  /// Type of FOV indicator
  final FOVType type;

  /// Width in degrees (for rectangles)
  final double widthDegrees;

  /// Height in degrees (for rectangles) or diameter for circles
  final double heightDegrees;

  /// Rotation angle in degrees
  final double rotation;

  /// Display color
  final Color color;

  /// Label text (e.g., "Camera", "50mm eyepiece")
  final String label;

  /// Whether this indicator is visible
  final bool visible;

  /// Line thickness
  final double strokeWidth;

  /// Whether to show corner brackets instead of full border
  final bool showCornerBrackets;

  /// Whether to show center crosshair
  final bool showCrosshair;

  const FOVIndicator({
    required this.type,
    required this.widthDegrees,
    required this.heightDegrees,
    this.rotation = 0,
    this.color = const Color(0xFF00E676),
    this.label = '',
    this.visible = true,
    this.strokeWidth = 2.0,
    this.showCornerBrackets = true,
    this.showCrosshair = false,
  });

  /// Create a camera sensor FOV indicator
  factory FOVIndicator.camera({
    required double widthDegrees,
    required double heightDegrees,
    double rotation = 0,
    Color color = const Color(0xFF00E676),
    String label = 'Camera',
  }) {
    return FOVIndicator(
      type: FOVType.sensorRectangle,
      widthDegrees: widthDegrees,
      heightDegrees: heightDegrees,
      rotation: rotation,
      color: color,
      label: label,
      showCornerBrackets: true,
      showCrosshair: false,
    );
  }

  /// Create a circular eyepiece FOV indicator
  factory FOVIndicator.eyepiece({
    required double diameterDegrees,
    Color color = const Color(0xFF2196F3),
    String label = 'Eyepiece',
  }) {
    return FOVIndicator(
      type: FOVType.eyepieceCircle,
      widthDegrees: diameterDegrees,
      heightDegrees: diameterDegrees,
      color: color,
      label: label,
      showCornerBrackets: false,
      showCrosshair: false,
    );
  }

  /// Create standard Telrad circles
  factory FOVIndicator.telrad({Color color = const Color(0xFFFF0000)}) {
    return FOVIndicator(
      type: FOVType.telradCircles,
      widthDegrees: 4.0, // Outer circle
      heightDegrees: 4.0,
      color: color,
      label: 'Telrad',
      showCornerBrackets: false,
      showCrosshair: false, // Telrad has its own pattern
    );
  }

  /// Create finder scope FOV indicator
  factory FOVIndicator.finder({
    required double diameterDegrees,
    Color color = const Color(0xFFFF9800),
    String label = 'Finder',
  }) {
    return FOVIndicator(
      type: FOVType.finderScope,
      widthDegrees: diameterDegrees,
      heightDegrees: diameterDegrees,
      color: color,
      label: label,
      showCornerBrackets: false,
      showCrosshair: false,
    );
  }

  FOVIndicator copyWith({
    FOVType? type,
    double? widthDegrees,
    double? heightDegrees,
    double? rotation,
    Color? color,
    String? label,
    bool? visible,
    double? strokeWidth,
    bool? showCornerBrackets,
    bool? showCrosshair,
  }) {
    return FOVIndicator(
      type: type ?? this.type,
      widthDegrees: widthDegrees ?? this.widthDegrees,
      heightDegrees: heightDegrees ?? this.heightDegrees,
      rotation: rotation ?? this.rotation,
      color: color ?? this.color,
      label: label ?? this.label,
      visible: visible ?? this.visible,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      showCornerBrackets: showCornerBrackets ?? this.showCornerBrackets,
      showCrosshair: showCrosshair ?? this.showCrosshair,
    );
  }
}

/// Painter for FOV overlay indicators
class FOVOverlayPainter extends CustomPainter {
  /// Current view center RA in hours
  final double centerRA;

  /// Current view center Dec in degrees
  final double centerDec;

  /// Current field of view in degrees
  final double viewFOV;

  /// View rotation in degrees
  final double viewRotation;

  /// List of FOV indicators to display
  final List<FOVIndicator> indicators;

  /// Center coordinates for the FOV indicators (if different from view center)
  final CelestialCoordinate? indicatorCenter;

  /// Projection the sky view is drawn with. Defaults to the sky view's own
  /// default so existing call sites are unchanged.
  final SkyProjection projection;

  FOVOverlayPainter({
    required this.centerRA,
    required this.centerDec,
    required this.viewFOV,
    this.viewRotation = 0,
    required this.indicators,
    this.indicatorCenter,
    this.projection = SkyProjection.stereographic,
  });

  /// The pose the indicators are projected against.
  SkyViewState get _viewState => SkyViewState(
    centerRA: centerRA,
    centerDec: centerDec,
    fieldOfView: viewFOV,
    rotation: viewRotation,
    projection: projection,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (viewFOV <= 0 || size.shortestSide <= 0) return;

    // Place the indicators with the exact projection the sky painter uses, so
    // the drawn footprint always agrees with the star field. A flat
    // `(ra - centerRA) * 15 * scale` offset mirrors the sky in RA, drops the
    // cos(dec) foreshortening, and flings the glyphs off-canvas at the 0h/24h
    // seam.
    final projector = SkyFovProjector.forSize(_viewState, size);
    final scale = projector.pixelsPerDegree;

    final target = indicatorCenter;
    Offset indicatorCenterOffset = projector.screenCenter;
    double northRad = viewRotation * math.pi / 180;
    if (target != null) {
      final projected = projector.project(target);
      // Behind the viewer: draw nothing rather than something false.
      if (projected == null) return;
      indicatorCenterOffset = projected;
      northRad = projector.northAngleAt(target) ?? northRad;
    }

    for (final indicator in indicators) {
      if (!indicator.visible) continue;

      switch (indicator.type) {
        case FOVType.sensorRectangle:
        case FOVType.customRectangle:
          _drawRectangleFOV(
            canvas,
            size,
            indicatorCenterOffset,
            scale,
            northRad,
            indicator,
          );
          break;
        case FOVType.eyepieceCircle:
        case FOVType.finderScope:
        case FOVType.customCircle:
          _drawCircleFOV(canvas, indicatorCenterOffset, scale, indicator);
          break;
        case FOVType.telradCircles:
          _drawTelradCircles(canvas, indicatorCenterOffset, scale, indicator);
          break;
      }
    }
  }

  void _drawRectangleFOV(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
    double northRad,
    FOVIndicator indicator,
  ) {
    final width = indicator.widthDegrees * scale;
    final height = indicator.heightDegrees * scale;
    final rotation = indicator.rotation * math.pi / 180 + northRad;

    final paint = Paint()
      ..color = indicator.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = indicator.strokeWidth;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);

    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: width,
      height: height,
    );

    if (indicator.showCornerBrackets) {
      // Draw corner brackets instead of full rectangle
      final cornerLength = math.min(width, height) * 0.15;
      _drawCornerBrackets(canvas, rect, cornerLength, paint);
    } else {
      // Draw full rectangle
      canvas.drawRect(rect, paint);
    }

    // Draw crosshair
    if (indicator.showCrosshair) {
      _drawCrosshair(canvas, Offset.zero, math.min(width, height) * 0.1, paint);
    }

    // Draw label
    if (indicator.label.isNotEmpty) {
      _drawLabel(
        canvas,
        Offset(0, height / 2 + 15),
        indicator.label,
        indicator.color,
      );
    }

    // Draw dimensions
    final dimText =
        '${indicator.widthDegrees.toStringAsFixed(1)}° × ${indicator.heightDegrees.toStringAsFixed(1)}°';
    _drawLabel(
      canvas,
      Offset(0, -height / 2 - 15),
      dimText,
      indicator.color.withValues(alpha: 0.7),
    );

    canvas.restore();
  }

  void _drawCircleFOV(
    Canvas canvas,
    Offset center,
    double scale,
    FOVIndicator indicator,
  ) {
    final radius = indicator.widthDegrees / 2 * scale;

    final paint = Paint()
      ..color = indicator.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = indicator.strokeWidth;

    canvas.drawCircle(center, radius, paint);

    // Draw crosshair
    if (indicator.showCrosshair) {
      _drawCrosshair(canvas, center, radius * 0.15, paint);
    }

    // Draw label
    if (indicator.label.isNotEmpty) {
      _drawLabel(
        canvas,
        center + Offset(0, radius + 15),
        indicator.label,
        indicator.color,
      );
    }

    // Draw diameter
    final dimText = '${indicator.widthDegrees.toStringAsFixed(1)}°';
    _drawLabel(
      canvas,
      center + Offset(0, -radius - 15),
      dimText,
      indicator.color.withValues(alpha: 0.7),
    );
  }

  void _drawTelradCircles(
    Canvas canvas,
    Offset center,
    double scale,
    FOVIndicator indicator,
  ) {
    // Standard Telrad circles: 0.5°, 2°, 4°
    const telradDiameters = [0.5, 2.0, 4.0];

    final paint = Paint()
      ..color = indicator.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = indicator.strokeWidth;

    for (final diameter in telradDiameters) {
      final radius = diameter / 2 * scale;
      canvas.drawCircle(center, radius, paint);
    }

    // Draw center dot
    final dotPaint = Paint()
      ..color = indicator.color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3, dotPaint);

    // Draw label
    if (indicator.label.isNotEmpty) {
      final outerRadius = telradDiameters.last / 2 * scale;
      _drawLabel(
        canvas,
        center + Offset(0, outerRadius + 15),
        indicator.label,
        indicator.color,
      );
    }
  }

  void _drawCornerBrackets(
    Canvas canvas,
    Rect rect,
    double length,
    Paint paint,
  ) {
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ];

    final directions = [
      [const Offset(1, 0), const Offset(0, 1)], // Top-left: right, down
      [const Offset(-1, 0), const Offset(0, 1)], // Top-right: left, down
      [const Offset(-1, 0), const Offset(0, -1)], // Bottom-right: left, up
      [const Offset(1, 0), const Offset(0, -1)], // Bottom-left: right, up
    ];

    for (var i = 0; i < 4; i++) {
      final corner = corners[i];
      final dirs = directions[i];

      canvas.drawLine(corner, corner + dirs[0] * length, paint);
      canvas.drawLine(corner, corner + dirs[1] * length, paint);
    }
  }

  void _drawCrosshair(Canvas canvas, Offset center, double size, Paint paint) {
    // Horizontal line with gap
    canvas.drawLine(
      center + Offset(-size * 2, 0),
      center + Offset(-size * 0.5, 0),
      paint,
    );
    canvas.drawLine(
      center + Offset(size * 0.5, 0),
      center + Offset(size * 2, 0),
      paint,
    );

    // Vertical line with gap
    canvas.drawLine(
      center + Offset(0, -size * 2),
      center + Offset(0, -size * 0.5),
      paint,
    );
    canvas.drawLine(
      center + Offset(0, size * 0.5),
      center + Offset(0, size * 2),
      paint,
    );
  }

  void _drawLabel(Canvas canvas, Offset position, String text, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      position - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant FOVOverlayPainter oldDelegate) {
    return centerRA != oldDelegate.centerRA ||
        centerDec != oldDelegate.centerDec ||
        viewFOV != oldDelegate.viewFOV ||
        viewRotation != oldDelegate.viewRotation ||
        indicators != oldDelegate.indicators ||
        indicatorCenter != oldDelegate.indicatorCenter ||
        projection != oldDelegate.projection;
  }
}
