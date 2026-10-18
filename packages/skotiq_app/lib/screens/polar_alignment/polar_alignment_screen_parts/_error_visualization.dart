// Polar alignment error visualizations: the sparkline error-trend chart (public ErrorTrendChart) and the auto-scaling error bullseye.
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

// Polar error bullseye

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

/// Outer-ring scales the TPPA bullseye steps through, in arcseconds.
///
/// The finest is the classic 120"/60"/30" target. The rest exist because the
/// first measurement on a mount set up by eye is routinely several arcminutes
/// to degrees off, and a fixed 120" target pinned every such marker to the rim
/// — it did not move while the operator turned a bolt, which is the one thing
/// a bullseye is for.
const List<double> kPolarBullseyeScalesArcsec = <double>[
  120,
  240,
  600,
  1200,
  2400,
  7200,
  14400,
  36000,
  72000,
];

/// The bullseye's outer-ring scale for an error of ([azimuth], [altitude])
/// arcseconds: the finest scale that contains the marker, so the marker sits
/// inside the rings and moves as the error changes. As the error shrinks the
/// target zooms in, step by step, to the 120" target.
double polarBullseyeOuterScaleArcsec(double? azimuth, double? altitude) {
  if (azimuth == null || altitude == null) {
    return kPolarBullseyeScalesArcsec.first;
  }
  final magnitude = math.sqrt(azimuth * azimuth + altitude * altitude);
  if (!magnitude.isFinite) return kPolarBullseyeScalesArcsec.last;
  for (final scale in kPolarBullseyeScalesArcsec) {
    if (magnitude <= scale) return scale;
  }
  return kPolarBullseyeScalesArcsec.last;
}

/// A ring label: arcseconds up to the finest outer ring (120"), arcminutes
/// below a degree, then degrees — the unit the operator would say out loud.
String polarBullseyeRingLabel(double arcsec) {
  String trim(double v) {
    final fixed = v.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }

  // The finest target keeps its familiar 120"/60"/30" labels.
  if (arcsec <= kPolarBullseyeScalesArcsec.first) return '${trim(arcsec)}"';
  if (arcsec < 3600) return "${trim(arcsec / 60)}'";
  return '${trim(arcsec / 3600)}°';
}

/// Gap between a bullseye ring and its label.
const double kPolarBullseyeLabelGap = 4;

/// Largest outer-ring radius. Beyond this a bigger target only spreads the
/// same three rings further apart; it shows nothing more.
const double kPolarBullseyeMaxRadius = 300;

/// The bullseye's outer-ring radius in a paint area of [size], leaving room
/// for the outer ring's label, [labelWidth] wide, beside it.
///
/// The radius used to be half the short side less 20px, but the label is
/// drawn 4px OUTSIDE the ring and is wider than the 16px that left, so in a
/// square-ish column the outer label — and on a wide one the ring itself —
/// was cut off at the column edge.
double polarBullseyeOuterRadius(Size size, double labelWidth) {
  final horizontal = size.width / 2 - kPolarBullseyeLabelGap - labelWidth;
  final vertical = size.height / 2;
  final fit = horizontal < vertical ? horizontal : vertical;
  if (fit <= 0) return 0;
  return fit < kPolarBullseyeMaxRadius ? fit : kPolarBullseyeMaxRadius;
}

/// The style of a bullseye ring label, before its colour.
const TextStyle kPolarBullseyeLabelStyle = SkotiqTypography.caption;

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

  TextPainter _ringLabel(String text) => TextPainter(
        text: TextSpan(
          text: text,
          style: kPolarBullseyeLabelStyle.copyWith(color: colors.textMuted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  /// Zone colour for a ring at [arcsec]: the same 30"/60" grading the error
  /// readouts use, so a coarse-scale target is honestly all red.
  Color _zoneColor(double arcsec) {
    if (arcsec <= 30) return colors.success;
    if (arcsec <= 60) return colors.warning;
    return colors.error;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final hasMeasurement = error != null && phase != PolarAlignPhase.idle;
    final outerScale = hasMeasurement
        ? polarBullseyeOuterScaleArcsec(
            error!.azimuthError,
            error!.altitudeError,
          )
        : kPolarBullseyeScalesArcsec.first;
    // Outer, half and quarter: 120"/60"/30" on the finest scale.
    final rings = [outerScale, outerScale / 2, outerScale / 4];
    final labels = [
      for (final arcsec in rings) _ringLabel(polarBullseyeRingLabel(arcsec)),
    ];
    final maxRadius = polarBullseyeOuterRadius(size, labels.first.width);
    if (maxRadius <= 0) return;

    for (final arcsec in rings) {
      final color = _zoneColor(arcsec).withValues(alpha: 0.1);
      final radius = maxRadius * (arcsec / outerScale);
      canvas.drawCircle(center, radius, Paint()..color = color);
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

    if (hasMeasurement) {
      // Clamped RADIALLY, past the coarsest scale only. Clamping each axis
      // to the square put every large error on the same 45° corner, outside
      // the outer ring, whatever its direction.
      final scale = maxRadius / outerScale;
      var dx = error!.azimuthError * scale;
      var dy = -error!.altitudeError * scale;
      final reach = math.sqrt(dx * dx + dy * dy);
      if (reach.isFinite && reach > maxRadius) {
        dx *= maxRadius / reach;
        dy *= maxRadius / reach;
      }
      if (dx.isFinite && dy.isFinite) {
        canvas.drawCircle(
          Offset(center.dx + dx, center.dy + dy),
          6,
          Paint()..color = colors.error,
        );
      }
    }

    // Ring labels, just outside each ring on the horizontal axis.
    for (int i = 0; i < labels.length; i++) {
      final radius = maxRadius * (rings[i] / outerScale);
      labels[i].paint(
        canvas,
        Offset(
          center.dx + radius + kPolarBullseyeLabelGap,
          center.dy - labels[i].height / 2,
        ),
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
