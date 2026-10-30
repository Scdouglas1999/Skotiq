import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';

class AnnotationPainter extends CustomPainter {
  final ImageAnnotation annotation;
  final double zoomLevel;
  final bool showLabels;

  AnnotationPainter({
    required this.annotation,
    this.zoomLevel = 1.0,
    this.showLabels = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!annotation.visible) return;

    for (final object in annotation.objects) {
      if (!object.visible) continue;

      _drawObjectMarker(canvas, object);

      if (showLabels) {
        _drawObjectLabel(canvas, object);
      }
    }
  }

  void _drawObjectMarker(Canvas canvas, CelestialObjectAnnotation object) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / zoomLevel; // Keep stroke width constant on screen

    switch (object.type) {
      case ObjectType.galaxy:
        paint.color =
            AnnotationTypeColors.galaxy.withValues(alpha: 0.8); // Gold
        // Draw ellipse
        final radius = (object.size ?? 50) * 2.0; // Scale size for visibility
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(object.x, object.y),
            width: radius,
            height: radius * 0.6,
          ),
          paint,
        );
        break;

      case ObjectType.nebula:
      case ObjectType.planetaryNebula:
        paint.color =
            AnnotationTypeColors.nebula.withValues(alpha: 0.8); // Magenta
        // Draw cloud shape (simplified as rect with rounded corners)
        final radius = (object.size ?? 50) * 2.0;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(object.x, object.y),
              width: radius,
              height: radius,
            ),
            Radius.circular(radius * 0.3),
          ),
          paint,
        );
        break;

      case ObjectType.starCluster:
        paint.color =
            AnnotationTypeColors.starCluster.withValues(alpha: 0.8); // Cyan
        // Draw dashed circle
        final radius = (object.size ?? 40) * 1.5;
        canvas.drawCircle(Offset(object.x, object.y), radius, paint);
        break;

      case ObjectType.star:
      case ObjectType.doubleStar:
        paint.color = ImageOverlayColors.foreground.withValues(alpha: 0.6);
        // Draw crosshair
        final size = 20.0 / zoomLevel;
        canvas.drawLine(
          Offset(object.x - size, object.y),
          Offset(object.x + size, object.y),
          paint,
        );
        canvas.drawLine(
          Offset(object.x, object.y - size),
          Offset(object.x, object.y + size),
          paint,
        );
        break;

      default:
        paint.color = AnnotationTypeColors.asterism.withValues(alpha: 0.6);
        canvas.drawCircle(Offset(object.x, object.y), 20.0 / zoomLevel, paint);
    }
  }

  void _drawObjectLabel(Canvas canvas, CelestialObjectAnnotation object) {
    final textSpan = TextSpan(
      text: object.name,
      style: TextStyle(
        color: ImageOverlayColors.foreground.withValues(alpha: 0.9),
        fontSize: SkotiqTypography.fontSize12 /
            zoomLevel, // Scale text to remain readable
        fontWeight: FontWeight.w500,
        shadows: [
          Shadow(
            blurRadius: 2,
            color: ImageOverlayColors.shadow.withValues(alpha: 0.8),
            offset: const Offset(1, 1),
          ),
        ],
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();

    // Position label below marker
    final offset = Offset(
      object.x - textPainter.width / 2,
      object.y + (25.0 / zoomLevel),
    );

    textPainter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant AnnotationPainter oldDelegate) {
    return oldDelegate.annotation != annotation ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.showLabels != showLabels;
  }
}
