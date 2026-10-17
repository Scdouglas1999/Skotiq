part of '../overlay_painters.dart';

class StarFieldPainter extends CustomPainter {
  final SkotiqColors colors;

  StarFieldPainter({required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42);
    final paint = Paint();

    for (var i = 0; i < 80; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final brightness = random.nextDouble() * 0.25 + 0.05;
      final radius = random.nextDouble() * 1.2 + 0.3;

      // absolute: simulated star field drawn on the preview canvas. White is
      // already neutral (R == G == B), but under red night a white star still
      // emits the green and blue a dark-adapted eye is protected from, so the
      // ink comes off the red-night ladder there.
      paint.color = (colors.isRedNight ? colors.textPrimary : Colors.white)
          .withValues(alpha: brightness);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class CrosshairOverlayPainter extends CustomPainter {
  final Color color;

  /// Radius of the centre ring (`mockups/imaging.html`: 64px across).
  static const double ringRadius = 32;

  /// The ring sits at the top of the 35-50% band the axes sit at the bottom of.
  static const double ringAlpha = SkotiqTokens.opacitySelectedRing;

  CrosshairOverlayPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    final centerX = size.width / 2;
    final centerY = size.height / 2;

    // Horizontal line
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      paint,
    );

    // Vertical line
    canvas.drawLine(
      Offset(centerX, 0),
      Offset(centerX, size.height),
      paint,
    );

    // One centre ring, brighter than the axes (06 §Imaging: "Crosshair and
    // centre ring in primary 35-50%"). Two concentric rings read as a target
    // reticle the app does not own.
    paint
      ..style = PaintingStyle.stroke
      ..color = color.withValues(alpha: ringAlpha);
    canvas.drawCircle(Offset(centerX, centerY), ringRadius, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GridOverlayPainter extends CustomPainter {
  final Color color;

  GridOverlayPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5;

    const gridSize = 50.0;

    // Vertical lines
    for (double x = gridSize; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Horizontal lines
    for (double y = gridSize; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class StarOverlayPainter extends CustomPainter {
  final List<DetectedStar> stars;
  final Color color;
  final double zoomLevel;
  final Offset imageOffset;

  StarOverlayPainter({
    required this.stars,
    required this.color,
    required this.zoomLevel,
    required this.imageOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;

    for (final star in stars) {
      final x = star.x * zoomLevel + imageOffset.dx;
      final y = star.y * zoomLevel + imageOffset.dy;

      // Skip stars outside the visible area
      if (x < -50 || x > size.width + 50 || y < -50 || y > size.height + 50) {
        continue;
      }

      final position = Offset(x, y);

      // Draw circle around star (radius based on HFR)
      final radius = (star.hfr * zoomLevel).clamp(3.0, 30.0);
      canvas.drawCircle(position, radius, fillPaint);
      canvas.drawCircle(position, radius, paint);

      // Draw crosshair
      const crosshairSize = 3.0;
      canvas.drawLine(
        Offset(x - crosshairSize, y),
        Offset(x + crosshairSize, y),
        paint,
      );
      canvas.drawLine(
        Offset(x, y - crosshairSize),
        Offset(x, y + crosshairSize),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StarOverlayPainter oldDelegate) {
    return stars != oldDelegate.stars ||
        color != oldDelegate.color ||
        zoomLevel != oldDelegate.zoomLevel ||
        imageOffset != oldDelegate.imageOffset;
  }
}
