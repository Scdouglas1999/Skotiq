import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Arrow indicator showing cloud movement direction on the weather radar map.
///
/// Displays an arrow pointing in the direction clouds are moving FROM
/// (meteorological convention). For example, if clouds are moving from west
/// to east, the arrow points west (270 degrees).
class MotionIndicator extends StatelessWidget {
  /// Direction in degrees (0-360, where 0 = North, 90 = East, etc.)
  /// This represents the direction clouds are moving FROM
  final double directionDegrees;

  final SkotiqColors colors;

  const MotionIndicator({
    super.key,
    required this.directionDegrees,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MotionIndicatorPainter(
        directionDegrees: directionDegrees,
        colors: colors,
      ),
      size: const Size(60, 60),
    );
  }
}

class _MotionIndicatorPainter extends CustomPainter {
  final double directionDegrees;
  final SkotiqColors colors;

  _MotionIndicatorPainter({
    required this.directionDegrees,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // The disc goes down first: it is there to lift the arrow off the radar
    // colors, and drawn after the arrow it veiled it instead.
    final backgroundPaint = Paint()
      ..color = colors.surface.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, size.width * 0.35, backgroundPaint);

    final ringPaint = Paint()
      ..color = colors.info.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawCircle(center, size.width * 0.35, ringPaint);

    // Subtract 90 to align 0 degrees with North (up) instead of East (right)
    final angleRadians = (directionDegrees - 90) * math.pi / 180;

    canvas.save();

    canvas.translate(center.dx, center.dy);
    canvas.rotate(angleRadians);

    final arrowLength = size.width * 0.5;
    final arrowWidth = size.width * 0.15;
    final arrowHeadLength = size.width * 0.2;
    final arrowHeadWidth = size.width * 0.25;

    // Create arrow path (pointing right before rotation)
    final arrowPath = Path();

    arrowPath.moveTo(-arrowLength / 2, -arrowWidth / 2);
    arrowPath.lineTo(arrowLength / 2 - arrowHeadLength, -arrowWidth / 2);
    arrowPath.lineTo(arrowLength / 2 - arrowHeadLength, -arrowHeadWidth / 2);

    arrowPath.lineTo(arrowLength / 2, 0);
    arrowPath.lineTo(arrowLength / 2 - arrowHeadLength, arrowHeadWidth / 2);

    arrowPath.lineTo(arrowLength / 2 - arrowHeadLength, arrowWidth / 2);
    arrowPath.lineTo(-arrowLength / 2, arrowWidth / 2);
    arrowPath.close();

    final arrowPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          colors.info.withValues(alpha: 0.7),
          colors.info,
        ],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(
        Rect.fromCenter(
          center: Offset.zero,
          width: arrowLength,
          height: arrowHeadWidth,
        ),
      )
      ..style = PaintingStyle.fill;

    canvas.drawPath(arrowPath, arrowPaint);

    final borderPaint = Paint()
      ..color = colors.info.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawPath(arrowPath, borderPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MotionIndicatorPainter oldDelegate) {
    return oldDelegate.directionDegrees != directionDegrees ||
        oldDelegate.colors != colors;
  }
}
