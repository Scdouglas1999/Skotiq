// Polar alignment error visualizations: the sparkline error-trend chart (public ErrorTrendChart), the bullseye overlay painter, and the radar-style live error indicator.
part of '../polar_alignment_screen.dart';

// Task 4.5: error trend sparkline chart

class ErrorTrendChart extends StatelessWidget {
  final SkotiqColors colors;
  final List<PolarAlignmentError> errors;
  final double threshold;

  const ErrorTrendChart({
    super.key,
    required this.colors,
    required this.errors,
    required this.threshold,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SparklinePainter(
        colors: colors,
        errors: errors,
        threshold: threshold,
      ),
      size: Size.infinite,
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final SkotiqColors colors;
  final List<PolarAlignmentError> errors;
  final double threshold;

  _SparklinePainter({
    required this.colors,
    required this.errors,
    required this.threshold,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (errors.isEmpty) return;

    const padding = 4.0;
    final chartWidth = size.width - padding * 2;
    final chartHeight = size.height - padding * 2;

    // Find max error for scaling
    final maxError = errors.fold<double>(
      threshold,
      (max, e) => e.totalError > max ? e.totalError : max,
    );

    // Scale to fit
    final yScale = chartHeight / maxError;
    final xStep = chartWidth / (errors.length - 1).clamp(1, double.infinity);

    // Draw threshold line
    final thresholdY = size.height - padding - (threshold * yScale);
    final thresholdPaint = Paint()
      ..color = colors.success.withValues(alpha: 0.5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // Dashed line for threshold
    const dashWidth = 4.0;
    const dashSpace = 4.0;
    var startX = padding;
    while (startX < size.width - padding) {
      canvas.drawLine(
        Offset(startX, thresholdY),
        Offset((startX + dashWidth).clamp(0, size.width - padding), thresholdY),
        thresholdPaint,
      );
      startX += dashWidth + dashSpace;
    }

    // Build path for error line
    final path = ui.Path();
    final points = <Offset>[];

    for (int i = 0; i < errors.length; i++) {
      final x = padding + i * xStep;
      final y = size.height - padding - (errors[i].totalError * yScale);
      points.add(Offset(x, y.clamp(padding, size.height - padding)));
    }

    if (points.isNotEmpty) {
      path.moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
    }

    // Draw gradient fill under the line
    final fillPath = ui.Path.from(path);
    fillPath.lineTo(points.last.dx, size.height - padding);
    fillPath.lineTo(points.first.dx, size.height - padding);
    fillPath.close();

    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(0, size.height),
        [
          colors.primary.withValues(alpha: 0.3),
          colors.primary.withValues(alpha: 0.05),
        ],
      );
    canvas.drawPath(fillPath, gradientPaint);

    // Draw the line
    final linePaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    // Draw current value dot
    if (points.isNotEmpty) {
      final lastPoint = points.last;
      final dotPaint = Paint()
        ..color = colors.primary
        ..style = PaintingStyle.fill;
      canvas.drawCircle(lastPoint, 4, dotPaint);

      // Outer ring
      final ringPaint = Paint()
        ..color = colors.primary.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(lastPoint, 7, ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.errors.length != errors.length ||
        (errors.isNotEmpty &&
            oldDelegate.errors.isNotEmpty &&
            oldDelegate.errors.last.totalError != errors.last.totalError);
  }
}

// Bullseye and polar error visualization painters

class _BullseyeOverlayPainter extends CustomPainter {
  final SkotiqColors colors;
  final double? azimuthError;
  final double? altitudeError;

  _BullseyeOverlayPainter({
    required this.colors,
    this.azimuthError,
    this.altitudeError,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius =
        (size.width < size.height ? size.width : size.height) / 2 - 40;

    // Scale: 120 arcseconds = maxRadius
    final scale = maxRadius / 120.0;

    // Draw concentric rings at 30", 60", 120"
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (final arcsec in [30.0, 60.0, 120.0]) {
      ringPaint.color = arcsec == 30.0
          ? colors.success.withValues(alpha: 0.6)
          : arcsec == 60.0
              ? colors.warning.withValues(alpha: 0.6)
              : colors.error.withValues(alpha: 0.6);
      canvas.drawCircle(center, arcsec * scale, ringPaint);

      // Draw labels
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${arcsec.toInt()}"',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            color: ringPaint.color,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
            center.dx + arcsec * scale + 4, center.dy - textPainter.height / 2),
      );
    }

    // Draw crosshairs
    final crossPaint = Paint()
      ..color = colors.textMuted.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      crossPaint,
    );

    // Draw center target
    final targetPaint = Paint()
      ..color = colors.primary
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 6, targetPaint);

    // Draw error position
    if (azimuthError != null && altitudeError != null) {
      final errorX = azimuthError!.clamp(-120.0, 120.0) * scale;
      final errorY = -altitudeError!.clamp(-120.0, 120.0) *
          scale; // Negative because screen Y is inverted
      final errorPos = Offset(center.dx + errorX, center.dy + errorY);

      // Draw line from center to error position
      final linePaint = Paint()
        ..color = colors.error.withValues(alpha: 0.5)
        ..strokeWidth = 2;
      canvas.drawLine(center, errorPos, linePaint);

      final errorPaint = Paint()
        ..color = colors.error
        ..style = PaintingStyle.fill;
      canvas.drawCircle(errorPos, 8, errorPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _BullseyeOverlayPainter oldDelegate) {
    return oldDelegate.azimuthError != azimuthError ||
        oldDelegate.altitudeError != altitudeError;
  }
}

class _PolarErrorVisualization extends StatelessWidget {
  final SkotiqColors colors;
  final PolarAlignmentError? error;
  final PolarAlignPhase phase;
  final AnimationController pulseAnimation;

  const _PolarErrorVisualization({
    required this.colors,
    required this.error,
    required this.phase,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (context, child) {
        return CustomPaint(
          painter: _PolarErrorPainter(
            colors: colors,
            error: error,
            phase: phase,
            pulseValue: pulseAnimation.value,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _PolarErrorPainter extends CustomPainter {
  final SkotiqColors colors;
  final PolarAlignmentError? error;
  final PolarAlignPhase phase;
  final double pulseValue;

  _PolarErrorPainter({
    required this.colors,
    required this.error,
    required this.phase,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius =
        size.width < size.height ? size.width / 2 - 20 : size.height / 2 - 20;

    // Draw error zones (120", 60", 30")
    final zones = [
      (120.0, colors.error.withValues(alpha: 0.1)),
      (60.0, colors.warning.withValues(alpha: 0.1)),
      (30.0, colors.success.withValues(alpha: 0.1)),
    ];

    for (final (errorVal, color) in zones) {
      final radius = maxRadius * (errorVal / 120.0);
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = color,
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    // Draw crosshairs
    final crossPaint = Paint()
      ..color = colors.border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      crossPaint,
    );

    // The centre mark is where a measurement WOULD sit if the mount were
    // perfectly aligned. Filled, it is indistinguishable from a measurement of
    // zero, so with nothing measured it is an empty target.
    //
    // The gate is the MEASUREMENT, not the phase: gating on `adjusting` snaps a
    // finished run's marker back to dead centre and captions it "No measurement
    // yet" while the row beneath reports the final error.
    final hasMeasurement = error != null && phase != PolarAlignPhase.idle;
    if (hasMeasurement) {
      final targetRadius = 8.0 + pulseValue * 4;
      canvas.drawCircle(
        center,
        targetRadius,
        Paint()
          ..color = colors.primary.withValues(alpha: 0.3 + pulseValue * 0.3),
      );
      canvas.drawCircle(
        center,
        4,
        Paint()..color = colors.primary,
      );
    } else {
      canvas.drawCircle(
        center,
        5,
        Paint()
          ..color = colors.textMuted.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Draw error position
    if (hasMeasurement) {
      final scale = maxRadius / 120.0; // 120 arcseconds = max radius
      final errorX = error!.azimuthError.clamp(-120.0, 120.0) * scale;
      final errorY = -error!.altitudeError.clamp(-120.0, 120.0) * scale;
      final errorPos = Offset(center.dx + errorX, center.dy + errorY);

      canvas.drawCircle(
        errorPos,
        6,
        Paint()..color = colors.error,
      );
    }

    // Draw labels
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final labels = ['120"', '60"', '30"'];
    final positions = [120.0, 60.0, 30.0];
    for (int i = 0; i < labels.length; i++) {
      final radius = maxRadius * (positions[i] / 120.0);
      textPainter.text = TextSpan(
        text: labels[i],
        style: TextStyle(
            fontSize: SkotiqTypography.fontSize9, color: colors.textMuted),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(center.dx + radius + 4, center.dy - textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PolarErrorPainter oldDelegate) {
    return oldDelegate.error != error ||
        oldDelegate.phase != phase ||
        oldDelegate.pulseValue != pulseValue;
  }
}
