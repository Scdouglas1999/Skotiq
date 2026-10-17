part of '../period_analysis_panel.dart';

/// Paints a phase-folded light curve.
class _PhaseFoldPainter extends StatelessWidget {
  final SkotiqColors colors;
  final List<PhaseFoldedPoint> points;

  /// Named series hue, mapped onto the active theme in [build].
  final Color plotColor;

  const _PhaseFoldPainter({
    required this.colors,
    required this.points,
    required this.plotColor,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return Center(
        child: Text(
          'No data to display',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _PhaseFoldCustomPainter(
        points: points,
        plotColor: SkotiqChartColors.forTheme(plotColor, colors),
        borderColor: colors.border,
        textColor: colors.textSecondary,
        gridColor: colors.border.withValues(alpha: 0.3),
      ),
    );
  }
}

class _PhaseFoldCustomPainter extends CustomPainter {
  final List<PhaseFoldedPoint> points;
  final Color plotColor;
  final Color borderColor;
  final Color textColor;
  final Color gridColor;

  _PhaseFoldCustomPainter({
    required this.points,
    required this.plotColor,
    required this.borderColor,
    required this.textColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const leftMargin = 58.0;
    const bottomMargin = 28.0;
    const topMargin = 8.0;
    const rightMargin = 12.0;
    final plotWidth = size.width - leftMargin - rightMargin;
    final plotHeight = size.height - topMargin - bottomMargin;
    final plotRect =
        Rect.fromLTWH(leftMargin, topMargin, plotWidth, plotHeight);

    // Border.
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(plotRect, borderPaint);

    // Compute magnitude range. Note: magnitudes are inverted (brighter = lower number).
    var minMag = points.first.magnitude;
    var maxMag = points.first.magnitude;
    for (final p in points) {
      if (p.magnitude < minMag) minMag = p.magnitude;
      if (p.magnitude > maxMag) maxMag = p.magnitude;
    }
    final magRange = math.max(0.01, maxMag - minMag);
    final displayMin = minMag - magRange * 0.15;
    final displayMax = maxMag + magRange * 0.15;
    final displayRange = displayMax - displayMin;

    // Grid.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < 4; i++) {
      final y = plotRect.top + plotHeight * i / 4.0;
      canvas.drawLine(
          Offset(plotRect.left, y), Offset(plotRect.right, y), gridPaint);
    }
    for (var i = 1; i < 5; i++) {
      final x = plotRect.left + plotWidth * i / 5.0;
      canvas.drawLine(
          Offset(x, plotRect.top), Offset(x, plotRect.bottom), gridPaint);
    }

    // Axis labels.
    final textStyle = SkotiqTypography.caption.copyWith(color: textColor);

    // Y-axis (inverted — brighter at top, so displayMax at top and displayMin at bottom).
    for (var i = 0; i <= 4; i++) {
      // Inverted: top of plot = displayMin (brightest), bottom = displayMax (faintest).
      final value = displayMax - (displayRange * i / 4.0);
      final y = plotRect.top + plotHeight * (1.0 - i / 4.0);
      final tp = TextPainter(
        text: TextSpan(text: value.toStringAsFixed(3), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plotRect.left - tp.width - 4, y - tp.height / 2));
    }

    // X-axis (phase 0 to 1).
    for (var i = 0; i <= 5; i++) {
      final phase = i / 5.0;
      final x = plotRect.left + plotWidth * phase;
      final tp = TextPainter(
        text: TextSpan(text: phase.toStringAsFixed(1), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, plotRect.bottom + 4));
    }

    // Phase label.
    final phaseLabelPainter = TextPainter(
      text: TextSpan(text: 'Phase', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    phaseLabelPainter.paint(
      canvas,
      Offset(
        plotRect.left + plotWidth / 2 - phaseLabelPainter.width / 2,
        plotRect.bottom + 16,
      ),
    );

    final yLabelPainter = TextPainter(
      text: TextSpan(text: 'Magnitude (brighter up)', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(
        10, plotRect.top + plotHeight / 2 + yLabelPainter.width / 2);
    canvas.rotate(-math.pi / 2);
    yLabelPainter.paint(canvas, Offset.zero);
    canvas.restore();

    // Draw error bars and data points.
    final dotPaint = Paint()
      ..color = plotColor
      ..style = PaintingStyle.fill;
    final errorPaint = Paint()
      ..color = plotColor.withValues(alpha: 0.4)
      ..strokeWidth = 0.8;

    canvas.save();
    canvas.clipRect(plotRect);
    for (final point in points) {
      final x = plotRect.left + point.phase * plotWidth;
      // Inverted Y: lower magnitude = higher on screen.
      final yNorm = (point.magnitude - displayMin) / displayRange;
      final y = plotRect.top + yNorm * plotHeight;

      // Error bar.
      final errPixels = (point.uncertainty / displayRange) * plotHeight;
      canvas.drawLine(
          Offset(x, y - errPixels), Offset(x, y + errPixels), errorPaint);

      // Data point.
      canvas.drawCircle(Offset(x, y), 2.5, dotPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PhaseFoldCustomPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.plotColor != plotColor;
  }
}
