// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterMarkers on SkyCanvasPainter {
  void _drawCardinalDirections(Canvas canvas, Size size) {
    final positions = cardinalScreenPositions(size);
    if (positions.isEmpty) return;

    final cardinalStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.7),
      fontSize: 14,
      fontWeight: FontWeight.bold,
    );
    final intercardinalStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 10,
      fontWeight: FontWeight.w500,
    );

    // Labels sit at the compass point but are nudged inward so one never hangs
    // half off the canvas; an intercardinal is dropped rather than overlapping
    // an already-placed label.
    const margin = 4.0;
    final placed = <Rect>[];

    for (final entry in positions.entries) {
      final isCardinal = entry.key.length == 1;
      final textPainter = _TextCache.get(
        entry.key,
        isCardinal ? cardinalStyle : intercardinalStyle,
      );
      final topLeft =
          entry.value - Offset(textPainter.width / 2, textPainter.height / 2);
      final position = Offset(
        topLeft.dx.clamp(
          margin,
          math.max(margin, size.width - textPainter.width - margin),
        ),
        topLeft.dy.clamp(
          margin,
          math.max(margin, size.height - textPainter.height - margin),
        ),
      );
      final bounds = Rect.fromLTWH(
        position.dx,
        position.dy,
        textPainter.width,
        textPainter.height,
      );

      if (!isCardinal && placed.any(bounds.inflate(2).overlaps)) continue;

      placed.add(bounds);
      textPainter.paint(canvas, position);
    }
  }

  void _drawSelectionMarker(
    Canvas canvas,
    Offset center,
    double scale,
    CelestialCoordinate coord,
  ) {
    final offset = _celestialToScreen(coord, center, scale);
    if (offset == null) return;

    // Apply animation if enabled
    double pulseScale = 1.0;
    double glowOpacity = 0.3;
    if (qualityConfig.enableSelectionAnimation &&
        selectionAnimationPhase != null) {
      // Sinusoidal pulse between 1.0 and 1.1
      pulseScale = 1.0 + 0.1 * math.sin(selectionAnimationPhase! * 2 * math.pi);
      // Pulsing glow opacity
      glowOpacity =
          0.2 + 0.2 * math.sin(selectionAnimationPhase! * 2 * math.pi);
    }

    const baseColor = Color(0xFF00E676);

    // Draw animated glow behind the marker - use cached blur
    if (qualityConfig.enableSelectionAnimation && glowOpacity > 0) {
      if (qualityConfig.useBlurEffects) {
        final glowPaint = _PaintCache.getBlurPaint(
          12,
          baseColor,
          alpha: glowOpacity,
        );
        canvas.drawCircle(offset, 20 * pulseScale, glowPaint);
      } else {
        final glowPaint = Paint()
          ..color = baseColor.withValues(alpha: glowOpacity);
        canvas.drawCircle(offset, 20 * pulseScale, glowPaint);
      }
    }

    final paint = Paint()
      ..color = baseColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Draw crosshairs with pulse
    final circleRadius = 15 * pulseScale;
    final innerOffset = 20 * pulseScale;
    final outerOffset = 25 * pulseScale;

    canvas.drawCircle(offset, circleRadius, paint);
    canvas.drawLine(
      offset - Offset(outerOffset, 0),
      offset - Offset(innerOffset, 0),
      paint,
    );
    canvas.drawLine(
      offset + Offset(innerOffset, 0),
      offset + Offset(outerOffset, 0),
      paint,
    );
    canvas.drawLine(
      offset - Offset(0, outerOffset),
      offset - Offset(0, innerOffset),
      paint,
    );
    canvas.drawLine(
      offset + Offset(0, innerOffset),
      offset + Offset(0, outerOffset),
      paint,
    );
  }

  void _drawMountPositionMarker(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
    CelestialCoordinate coord,
    MountRenderStatus status,
  ) {
    final offset = _celestialToScreen(coord, center, scale);
    if (offset == null) return;

    // Color based on tracking status
    Color markerColor;
    switch (status) {
      case MountRenderStatus.tracking:
        markerColor = const Color(0xFF4CAF50); // Green for tracking
        break;
      case MountRenderStatus.slewing:
        markerColor = const Color(0xFFFF9800); // Orange for slewing
        break;
      case MountRenderStatus.parked:
        markerColor = const Color(0xFF9E9E9E); // Gray for parked
        break;
      case MountRenderStatus.stopped:
        markerColor = const Color(0xFFE53935); // Red for stopped
        break;
      case MountRenderStatus.disconnected:
        return; // Don't draw if disconnected
    }

    // Outer glow - use cached blur
    if (qualityConfig.useBlurEffects) {
      final glowPaint = _PaintCache.getBlurPaint(8, markerColor, alpha: 0.3);
      canvas.drawCircle(offset, 20, glowPaint);
    } else {
      final glowPaint = Paint()..color = markerColor.withValues(alpha: 0.3);
      canvas.drawCircle(offset, 20, glowPaint);
    }

    // Main crosshair with thicker lines
    final paint = Paint()
      ..color = markerColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    // Draw a distinctive mount marker (different from selection marker)
    // Outer circle
    canvas.drawCircle(offset, 18, paint);

    // Inner crosshair lines - extending to edge of circle
    paint.strokeWidth = 2;
    canvas.drawLine(
      offset - const Offset(30, 0),
      offset - const Offset(18, 0),
      paint,
    );
    canvas.drawLine(
      offset + const Offset(18, 0),
      offset + const Offset(30, 0),
      paint,
    );
    canvas.drawLine(
      offset - const Offset(0, 30),
      offset - const Offset(0, 18),
      paint,
    );
    canvas.drawLine(
      offset + const Offset(0, 18),
      offset + const Offset(0, 30),
      paint,
    );

    // Inner dot
    final dotPaint = Paint()
      ..color = markerColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(offset, 3, dotPaint);

    // Draw status label below the marker
    final statusText = switch (status) {
      MountRenderStatus.tracking => 'TRACKING',
      MountRenderStatus.slewing => 'SLEWING',
      MountRenderStatus.parked => 'PARKED',
      MountRenderStatus.stopped => 'STOPPED',
      MountRenderStatus.disconnected => '',
    };

    if (statusText.isNotEmpty) {
      final textStyle = TextStyle(
        color: markerColor,
        fontSize: 9,
        fontWeight: FontWeight.bold,
      );
      final textPainter = TextPainter(
        text: TextSpan(text: statusText, style: textStyle),
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout();

      // Background for better readability
      final bgRect = Rect.fromCenter(
        center: offset + const Offset(0, 35),
        width: textPainter.width + 8,
        height: textPainter.height + 4,
      );
      final bgPaint = Paint()..color = const Color(0xCC000000);
      canvas.drawRRect(
        RRect.fromRectAndRadius(bgRect, const Radius.circular(3)),
        bgPaint,
      );

      textPainter.paint(
        canvas,
        offset + Offset(-textPainter.width / 2, 35 - textPainter.height / 2),
      );
    }
  }
}
