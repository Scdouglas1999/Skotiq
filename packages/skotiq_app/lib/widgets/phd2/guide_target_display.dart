import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

// GuideErrorPoint is owned by skotiq_core (phd2_models.dart) so the entire
// app can share one canonical model rather than duplicating it per layer.

/// Widget that displays a PHD2-style target display showing guide error history
///
/// Shows concentric circles representing error thresholds with:
/// - Current error position (red X)
/// - Historical error positions (fading blue dots)
/// - Center crosshairs
class GuideTargetDisplay extends StatelessWidget {
  /// List of historical error points (newest last)
  final List<GuideErrorPoint> errorHistory;

  /// Maximum number of historical points to display
  final int maxHistoryPoints;

  /// Scale in [unitSuffix] units per ring
  final double scaleArcsec;

  /// Unit suffix for the ring labels. The guider reports residuals in
  /// guide-camera pixels; callers convert to arcseconds only when a pixel
  /// scale is known, so the label must not claim arcseconds unconditionally.
  final String unitSuffix;

  /// Number of rings to display
  final int numRings;

  /// Whether to show the current error marker prominently
  final bool showCurrentError;

  /// Current RA error in arcseconds
  final double currentRaError;

  /// Current Dec error in arcseconds
  final double currentDecError;

  const GuideTargetDisplay({
    super.key,
    this.errorHistory = const [],
    this.maxHistoryPoints = 50,
    this.scaleArcsec = 1.0,
    this.unitSuffix = '"',
    this.numRings = 3,
    this.showCurrentError = true,
    this.currentRaError = 0,
    this.currentDecError = 0,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border.all(color: colors.border),
        borderRadius: SkotiqTokens.borderRadiusLg,
      ),
      child: ClipRRect(
        borderRadius: SkotiqTokens.borderRadiusSm,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = math.min(constraints.maxWidth, constraints.maxHeight);
            return CustomPaint(
              size: Size(size, size),
              painter: _TargetDisplayPainter(
                errorHistory: errorHistory,
                maxHistoryPoints: maxHistoryPoints,
                scaleArcsec: scaleArcsec,
                unitSuffix: unitSuffix,
                numRings: numRings,
                showCurrentError: showCurrentError,
                currentRaError: currentRaError,
                currentDecError: currentDecError,
                colors: colors,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TargetDisplayPainter extends CustomPainter {
  final List<GuideErrorPoint> errorHistory;
  final int maxHistoryPoints;
  final double scaleArcsec;
  final String unitSuffix;
  final int numRings;
  final bool showCurrentError;
  final double currentRaError;
  final double currentDecError;
  final SkotiqColors colors;

  _TargetDisplayPainter({
    required this.errorHistory,
    required this.maxHistoryPoints,
    required this.scaleArcsec,
    required this.unitSuffix,
    required this.numRings,
    required this.showCurrentError,
    required this.currentRaError,
    required this.currentDecError,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;

    // Calculate pixels per arcsecond
    final maxArcsec = scaleArcsec * numRings;
    final pixelsPerArcsec = radius / maxArcsec;

    // Draw background rings
    _drawRings(canvas, center, radius);

    // Draw crosshairs
    _drawCrosshairs(canvas, center, radius);

    // Draw scale labels
    _drawScaleLabels(canvas, center, radius);

    // Draw historical points
    _drawHistory(canvas, center, pixelsPerArcsec);

    // Draw current error
    if (showCurrentError) {
      _drawCurrentError(canvas, center, pixelsPerArcsec);
    }
  }

  void _drawRings(Canvas canvas, Offset center, double radius) {
    final paint = Paint()
      ..color = colors.border.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (int i = 1; i <= numRings; i++) {
      final ringRadius = (radius / numRings) * i;
      canvas.drawCircle(center, ringRadius, paint);
    }

    // Draw outer ring with gradient effect
    final outerPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          colors.primary.withValues(alpha: 0.0),
          colors.primary.withValues(alpha: 0.1),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, outerPaint);
  }

  void _drawCrosshairs(Canvas canvas, Offset center, double radius) {
    final paint = Paint()
      ..color = colors.border.withValues(alpha: 0.3)
      ..strokeWidth = 1;

    // Vertical line
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      paint,
    );

    // Horizontal line
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      paint,
    );

    // Center dot
    final centerPaint = Paint()
      ..color = colors.primary.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 2, centerPaint);
  }

  void _drawScaleLabels(Canvas canvas, Offset center, double radius) {
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (int i = 1; i <= numRings; i++) {
      final label = '${(scaleArcsec * i).toStringAsFixed(1)}$unitSuffix';
      textPainter.text = TextSpan(
        text: label,
        style: TextStyle(
          color: colors.textMuted.withValues(alpha: 0.7),
          fontSize: SkotiqTypography.fontSize9,
          fontWeight: FontWeight.w500,
        ),
      );
      textPainter.layout();

      final ringRadius = (radius / numRings) * i;
      textPainter.paint(
        canvas,
        Offset(
          center.dx + ringRadius - textPainter.width - 4,
          center.dy + 4,
        ),
      );
    }
  }

  void _drawHistory(Canvas canvas, Offset center, double pixelsPerArcsec) {
    if (errorHistory.isEmpty) return;

    final historyCount = math.min(errorHistory.length, maxHistoryPoints);
    final startIndex = errorHistory.length - historyCount;

    for (int i = startIndex; i < errorHistory.length; i++) {
      final point = errorHistory[i];
      final age = errorHistory.length - 1 - i;
      final opacity = 1.0 - (age / maxHistoryPoints).clamp(0.0, 0.9);

      final paint = Paint()
        ..color = colors.info.withValues(alpha: opacity * 0.7)
        ..style = PaintingStyle.fill;

      // RA is horizontal (X), Dec is vertical (Y - inverted)
      final x = center.dx + point.raError * pixelsPerArcsec;
      final y = center.dy - point.decError * pixelsPerArcsec; // Invert Y

      canvas.drawCircle(Offset(x, y), 2.5, paint);
    }
  }

  void _drawCurrentError(Canvas canvas, Offset center, double pixelsPerArcsec) {
    final x = center.dx + currentRaError * pixelsPerArcsec;
    final y = center.dy - currentDecError * pixelsPerArcsec; // Invert Y

    // Draw glow effect
    final glowPaint = Paint()
      ..color = colors.error.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(Offset(x, y), 8, glowPaint);

    // Draw X marker
    final paint = Paint()
      ..color = colors.error
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const markerSize = 6.0;
    canvas.drawLine(
      Offset(x - markerSize, y - markerSize),
      Offset(x + markerSize, y + markerSize),
      paint,
    );
    canvas.drawLine(
      Offset(x + markerSize, y - markerSize),
      Offset(x - markerSize, y + markerSize),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TargetDisplayPainter oldDelegate) {
    return errorHistory != oldDelegate.errorHistory ||
        currentRaError != oldDelegate.currentRaError ||
        currentDecError != oldDelegate.currentDecError ||
        scaleArcsec != oldDelegate.scaleArcsec ||
        unitSuffix != oldDelegate.unitSuffix;
  }
}
