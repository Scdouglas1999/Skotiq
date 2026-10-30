import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// FramingPlateScale is the C1 single-source-of-truth astrometric scale shared by
// the framing painters and gesture hit-tester. It lives in skotiq_core's
// models layer and is not yet surfaced through the public barrel, so it is
// imported directly here, matching the established app->core src-model
// convention used elsewhere in this package.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Paints the survey image background honoring pan/zoom/rotation, using the
/// shared [FramingPlateScale] geometry so the imagery lines up with the FOV
/// reticle and grid overlays to the pixel.
///
/// The destination rectangle is taken verbatim from
/// [FramingPlateScale.drawRectFor] rather than re-deriving a fit-to-canvas
/// rectangle locally: every framing painter and the gesture hit-tester derive
/// px/deg from one astrometric scale.
///
/// The image is rotated about the canvas center by [rotation] degrees so the
/// survey field rotates together with the FOV overlay (which is drawn under the
/// same rotation). Rotating about the canvas center — not the panned image
/// center — matches the overlay's reticle, which is anchored to the canvas
/// center.
class FramingSurveyImagePainter extends CustomPainter {
  final ui.Image image;
  final double zoom;
  final double panX;
  final double panY;

  /// Field rotation in degrees, applied clockwise about the canvas center.
  final double rotation;

  /// Shared astrometric geometry describing how the survey image maps onto the
  /// canvas. The image is drawn into [FramingPlateScale.drawRectFor] so overlays
  /// and imagery agree on the same plate scale.
  final FramingPlateScale plateScale;

  FramingSurveyImagePainter({
    required this.image,
    required this.zoom,
    required this.panX,
    required this.panY,
    required this.rotation,
    required this.plateScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.high;

    final destRect = plateScale.drawRectFor(size, zoom, Offset(panX, panY));
    final srcRect =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

    if (rotation == 0) {
      canvas.drawImageRect(image, srcRect, destRect, paint);
      return;
    }

    // Rotate the survey field about the canvas center so it tracks the FOV
    // overlay, which is drawn under the identical rotation about the same point.
    final pivot = Offset(size.width / 2, size.height / 2);
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(rotation * math.pi / 180);
    canvas.translate(-pivot.dx, -pivot.dy);
    canvas.drawImageRect(image, srcRect, destRect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FramingSurveyImagePainter oldDelegate) {
    return image != oldDelegate.image ||
        zoom != oldDelegate.zoom ||
        panX != oldDelegate.panX ||
        panY != oldDelegate.panY ||
        rotation != oldDelegate.rotation ||
        plateScale != oldDelegate.plateScale;
  }
}

/// Static deterministic starfield + soft nebula hint, used when no survey image
/// is loaded. The seed is fixed so the backdrop is stable across rebuilds.
class FramingStarBackgroundPainter extends CustomPainter {
  final SkotiqColors colors;

  FramingStarBackgroundPainter({required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final random = _SeededRandom(42);

    // Background gradient: a subtle vignette from the elevated surface tone at
    // the center down to the scaffold background at the edges. Uses semantic
    // tokens so the fallback backdrop adapts to dark / light / red-night themes.
    final bgPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: [
          colors.surface,
          colors.background,
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // Draw stars
    for (var i = 0; i < 300; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final brightness = random.nextDouble() * 0.5 + 0.2;
      final radius = random.nextDouble() * 1.5 + 0.3;

      // absolute: stars painted on the sky-background canvas
      paint.color = ImageOverlayColors.foreground.withValues(alpha: brightness);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }

    // Draw faint nebula hint in center
    final center = Offset(size.width / 2, size.height / 2);
    final gradient = RadialGradient(
      colors: [
        colors.primary.withValues(alpha: 0.1),
        colors.accent.withValues(alpha: 0.05),
        Colors.transparent,
      ],
    );
    final rect = Rect.fromCircle(center: center, radius: 150);
    paint.shader = gradient.createShader(rect);
    canvas.drawCircle(center, 150, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SeededRandom {
  int _seed;

  _SeededRandom(this._seed);

  double nextDouble() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed / 0x7fffffff;
  }
}

/// Grid overlay aligned with canvas pan/zoom; brighter cross-hairs on the
/// current center.
///
/// Grid lines are *real angular gridlines*: their spacing is derived from the
/// shared [FramingPlateScale] so each cell spans exactly [gridSpacingDegrees]
/// of sky regardless of zoom, image aspect, or letterboxing. This replaces the
/// previous hardcoded `60px/deg`-equivalent spacing that did not correspond to
/// any real angular extent and drifted out of agreement with the survey
/// imagery.
class FramingGridPainter extends CustomPainter {
  /// Default angular spacing between grid lines, in degrees of sky.
  ///
  /// A quarter-degree (15 arcminutes) gives a useful reference scale for the
  /// typical sub-degree-to-few-degree framing fields without crowding the
  /// canvas.
  static const double defaultGridSpacingDegrees = 0.25;

  final double zoom;
  final double panX;
  final double panY;
  final Color color;

  /// Shared astrometric geometry; supplies on-screen pixels-per-degree so the
  /// grid spacing is a true angular measure.
  final FramingPlateScale plateScale;

  /// Angular spacing between adjacent grid lines, in degrees of sky.
  final double gridSpacingDegrees;

  FramingGridPainter({
    required this.zoom,
    required this.panX,
    required this.panY,
    required this.color,
    required this.plateScale,
    this.gridSpacingDegrees = defaultGridSpacingDegrees,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5;

    final center = Offset(size.width / 2 + panX, size.height / 2 + panY);
    final spacing = plateScale.pixelsPerDegree(size, zoom) * gridSpacingDegrees;

    // A non-positive spacing would loop forever; surface the degenerate
    // geometry rather than silently hanging the paint pass.
    if (!spacing.isFinite || spacing <= 0) {
      throw StateError(
        'FramingGridPainter computed a non-positive grid spacing '
        '($spacing px) for plateScale=$plateScale, zoom=$zoom, '
        'gridSpacingDegrees=$gridSpacingDegrees',
      );
    }

    // Draw vertical lines
    for (var x = center.dx % spacing; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Draw horizontal lines
    for (var y = center.dy % spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Draw center lines (brighter)
    paint.color = color.withValues(alpha: 0.5);
    paint.strokeWidth = 1;
    canvas.drawLine(
        Offset(center.dx, 0), Offset(center.dx, size.height), paint);
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);
  }

  @override
  bool shouldRepaint(covariant FramingGridPainter oldDelegate) {
    return zoom != oldDelegate.zoom ||
        panX != oldDelegate.panX ||
        panY != oldDelegate.panY ||
        color != oldDelegate.color ||
        plateScale != oldDelegate.plateScale ||
        gridSpacingDegrees != oldDelegate.gridSpacingDegrees;
  }
}

/// Center crosshair (full-width and full-height lines + center circle) drawn
/// on top of the survey image to mark the framing reticle.
class FramingCrosshairPainter extends CustomPainter {
  final SkotiqColors colors;

  FramingCrosshairPainter({required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colors.error.withValues(alpha: 0.8)
      ..strokeWidth = 1;

    final center = Offset(size.width / 2, size.height / 2);

    // Horizontal line
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);

    // Vertical line
    canvas.drawLine(
        Offset(center.dx, 0), Offset(center.dx, size.height), paint);

    // Center circle
    paint.style = PaintingStyle.stroke;
    canvas.drawCircle(center, 6, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
