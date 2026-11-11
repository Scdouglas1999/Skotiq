part of '../annotation_overlay.dart';

class EnhancedAnnotationPainter extends CustomPainter {
  final ImageAnnotation annotation;
  final AnnotationSettings settings;
  final AnnotationMarkerStyle markerStyle;
  final double zoomLevel;
  final Offset imageOffset;

  EnhancedAnnotationPainter({
    required this.annotation,
    required this.settings,
    required this.markerStyle,
    this.zoomLevel = 1.0,
    this.imageOffset = Offset.zero,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!annotation.visible) return;

    final visibleObjects = annotation.objects.where((obj) {
      if (!obj.visible) return false;
      if (obj.magnitude != null) {
        if (obj.magnitude! > settings.magnitudeCutoff) return false;
        if (obj.magnitude! < settings.minMagnitude) return false;
      }
      return _isTypeVisible(obj.type, settings.visibleTypes);
    }).toList();

    if (visibleObjects.length > settings.maxObjectsToDisplay) {
      visibleObjects
          .sort((a, b) => (a.magnitude ?? 20).compareTo(b.magnitude ?? 20));
      visibleObjects.removeRange(
          settings.maxObjectsToDisplay, visibleObjects.length);
    }

    for (final object in visibleObjects) {
      final screenPosition = imageToViewport(
        imagePoint: Offset(object.x, object.y),
        imageOffset: imageOffset,
        zoomLevel: zoomLevel,
      );

      _drawObjectMarker(canvas, object, screenPosition.dx, screenPosition.dy);

      if (settings.showLabels) {
        _drawObjectLabel(canvas, object, screenPosition.dx, screenPosition.dy);
      }
    }
  }

  bool _isTypeVisible(ObjectType type, Set<AnnotationObjectFilter> filters) {
    switch (type) {
      case ObjectType.galaxy:
        return filters.contains(AnnotationObjectFilter.galaxies);
      case ObjectType.nebula:
        return filters.contains(AnnotationObjectFilter.nebulae);
      case ObjectType.planetaryNebula:
        return filters.contains(AnnotationObjectFilter.planetaryNebulae);
      case ObjectType.starCluster:
        return filters.contains(AnnotationObjectFilter.starClusters);
      case ObjectType.star:
      case ObjectType.doubleStar:
        return filters.contains(AnnotationObjectFilter.stars);
      default:
        return filters.contains(AnnotationObjectFilter.other);
    }
  }

  Color _getColorForType(ObjectType type) {
    switch (type) {
      case ObjectType.galaxy:
        return Color(markerStyle.galaxyColor);
      case ObjectType.nebula:
        return Color(markerStyle.nebulaColor);
      case ObjectType.planetaryNebula:
        return Color(markerStyle.planetaryNebulaColor);
      case ObjectType.starCluster:
        return Color(markerStyle.clusterColor);
      case ObjectType.star:
      case ObjectType.doubleStar:
        return Color(markerStyle.starColor);
      default:
        return Color(markerStyle.otherColor);
    }
  }

  double _getMarkerSize(CelestialObjectAnnotation object) {
    if (!markerStyle.scaleBySize || object.size == null) {
      return markerStyle.minMarkerSize;
    }

    // Scale based on object size (in arcminutes typically)
    final scaled = (object.size! * 2.0).clamp(
      markerStyle.minMarkerSize,
      markerStyle.maxMarkerSize,
    );
    return scaled * zoomLevel;
  }

  void _drawObjectMarker(
      Canvas canvas, CelestialObjectAnnotation object, double x, double y) {
    final color = _getColorForType(object.type);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = markerStyle.strokeWidth
      ..color = color.withValues(alpha: 0.85);

    final markerSize = _getMarkerSize(object);

    switch (object.type) {
      case ObjectType.galaxy:
        _drawGalaxyMarker(canvas, x, y, markerSize, paint);
        break;

      case ObjectType.nebula:
        _drawNebulaMarker(canvas, x, y, markerSize, paint);
        break;

      case ObjectType.planetaryNebula:
        _drawPlanetaryNebulaMarker(canvas, x, y, markerSize, paint);
        break;

      case ObjectType.starCluster:
        _drawClusterMarker(canvas, x, y, markerSize, paint);
        break;

      case ObjectType.star:
      case ObjectType.doubleStar:
        _drawStarMarker(canvas, x, y, markerSize, paint);
        break;

      default:
        canvas.drawCircle(Offset(x, y), markerSize / 2, paint);
    }
  }

  void _drawGalaxyMarker(
      Canvas canvas, double x, double y, double size, Paint paint) {
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(0.3); // Slight tilt

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size,
        height: size * 0.5,
      ),
      paint,
    );

    // Draw inner ellipse for spiral arm suggestion
    final innerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = markerStyle.strokeWidth * 0.7
      ..color = paint.color.withValues(alpha: 0.4);

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size * 0.6,
        height: size * 0.3,
      ),
      innerPaint,
    );

    canvas.restore();
  }

  void _drawNebulaMarker(
      Canvas canvas, double x, double y, double size, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y), width: size, height: size * 0.8),
        Radius.circular(size * 0.25),
      ),
      paint,
    );
  }

  void _drawPlanetaryNebulaMarker(
      Canvas canvas, double x, double y, double size, Paint paint) {
    canvas.drawCircle(Offset(x, y), size / 2, paint);

    final innerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = markerStyle.strokeWidth
      ..color = paint.color.withValues(alpha: 0.6);
    canvas.drawCircle(Offset(x, y), size / 4, innerPaint);

    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = paint.color.withValues(alpha: 0.8);
    canvas.drawCircle(Offset(x, y), markerStyle.strokeWidth, dotPaint);
  }

  void _drawClusterMarker(
      Canvas canvas, double x, double y, double size, Paint paint) {
    canvas.drawCircle(Offset(x, y), size / 2, paint);

    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = paint.color.withValues(alpha: 0.5);

    final dotRadius = markerStyle.strokeWidth * 0.8;
    canvas.drawCircle(
        Offset(x - size * 0.15, y - size * 0.1), dotRadius, dotPaint);
    canvas.drawCircle(
        Offset(x + size * 0.1, y - size * 0.15), dotRadius, dotPaint);
    canvas.drawCircle(
        Offset(x + size * 0.12, y + size * 0.1), dotRadius, dotPaint);
    canvas.drawCircle(
        Offset(x - size * 0.08, y + size * 0.12), dotRadius, dotPaint);
    canvas.drawCircle(Offset(x, y), dotRadius, dotPaint);
  }

  void _drawStarMarker(
      Canvas canvas, double x, double y, double size, Paint paint) {
    final halfSize = size / 2;

    canvas.drawLine(
      Offset(x - halfSize, y),
      Offset(x + halfSize, y),
      paint,
    );
    canvas.drawLine(
      Offset(x, y - halfSize),
      Offset(x, y + halfSize),
      paint,
    );
  }

  void _drawObjectLabel(
      Canvas canvas, CelestialObjectAnnotation object, double x, double y) {
    final label = settings.showMagnitudes && object.magnitude != null
        ? '${object.name} (${object.magnitude!.toStringAsFixed(1)})'
        : object.name;

    final textSpan = TextSpan(
      text: label,
      style: TextStyle(
        color: ImageOverlayColors.foreground.withValues(alpha: 0.95),
        fontSize: markerStyle.labelFontSize,
        fontWeight: FontWeight.w500,
        shadows: const [
          Shadow(
            blurRadius: 3,
            color: _annotationOverlayShadowColor,
            offset: Offset(1, 1),
          ),
          Shadow(
            blurRadius: 6,
            color: _annotationOverlayShadowColor,
            offset: Offset(0, 0),
          ),
        ],
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();

    final markerSize = _getMarkerSize(object);
    final offset = Offset(
      x - textPainter.width / 2,
      y + markerSize / 2 + 4,
    );

    textPainter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant EnhancedAnnotationPainter oldDelegate) {
    return oldDelegate.annotation != annotation ||
        oldDelegate.settings != settings ||
        oldDelegate.markerStyle != markerStyle ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.imageOffset != imageOffset;
  }
}
