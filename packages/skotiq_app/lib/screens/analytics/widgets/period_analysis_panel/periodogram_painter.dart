part of '../period_analysis_panel.dart';

// Custom painters for the periodogram and phase-fold plots

/// Paints the Lomb-Scargle power spectrum.
class _PeriodogramPainter extends StatelessWidget {
  final SkotiqColors colors;
  final List<double> frequencies;
  final List<double> powers;
  final double bestFrequency;

  /// Named series hues, mapped onto the active theme in [build] — red night
  /// needs a red-axis plot, not the fixed blue and amber.
  final Color plotColor;
  final Color peakColor;
  final String xLabel;
  final String yLabel;

  const _PeriodogramPainter({
    required this.colors,
    required this.frequencies,
    required this.powers,
    required this.bestFrequency,
    required this.plotColor,
    required this.peakColor,
    required this.xLabel,
    required this.yLabel,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _PeriodogramCustomPainter(
        frequencies: frequencies,
        powers: powers,
        bestFrequency: bestFrequency,
        plotColor: SkotiqChartColors.forTheme(plotColor, colors),
        peakColor: SkotiqChartColors.forTheme(peakColor, colors),
        borderColor: colors.border,
        textColor: colors.textSecondary,
        gridColor: colors.border.withValues(alpha: 0.3),
        xLabel: xLabel,
        yLabel: yLabel,
      ),
    );
  }
}

class _PeriodogramCustomPainter extends CustomPainter {
  final List<double> frequencies;
  final List<double> powers;
  final double bestFrequency;
  final Color plotColor;
  final Color peakColor;
  final Color borderColor;
  final Color textColor;
  final Color gridColor;
  final String xLabel;
  final String yLabel;

  _PeriodogramCustomPainter({
    required this.frequencies,
    required this.powers,
    required this.bestFrequency,
    required this.plotColor,
    required this.peakColor,
    required this.borderColor,
    required this.textColor,
    required this.gridColor,
    required this.xLabel,
    required this.yLabel,
  });

  /// Peak power in the spectrum. Falls back to 1.0 so an all-zero spectrum
  /// still gets a drawable axis.
  double get _peakPower {
    var maxPower = 0.0;
    for (final p in powers) {
      if (p > maxPower) maxPower = p;
    }
    return maxPower > 0 ? maxPower : 1.0;
  }

  /// Y scale for the power axis.
  ///
  /// Normalised LS power lives below 0.1 for anything short of a strong
  /// detection — the ordinary case. Five evenly spaced ticks printed at one
  /// decimal read "0.1 / 0.1 / 0.0 / 0.0 / 0.0", three of them identical, and
  /// no point on the curve could be valued. NiceAxis snaps the top of the plot
  /// to a round multiple and carries the matching precision.
  NiceAxis get powerAxis => NiceAxis.forRange(0, _peakPower, padFraction: 0.1);

  int get powerTickCount =>
      math.max(1, (powerAxis.max / powerAxis.interval).round());

  /// The Y tick labels this painter draws, bottom to top.
  ///
  /// [paint] renders exactly these strings; they are exposed because canvas
  /// text leaves nothing in the widget tree for a test to read.
  List<String> get powerAxisLabels {
    final axis = powerAxis;
    return [
      for (var i = 0; i <= powerTickCount; i++) axis.label(axis.interval * i),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (frequencies.isEmpty || powers.isEmpty) return;

    const leftMargin = 45.0;
    const bottomMargin = 28.0;
    const topMargin = 8.0;
    const rightMargin = 12.0;
    final plotWidth = size.width - leftMargin - rightMargin;
    final plotHeight = size.height - topMargin - bottomMargin;
    final plotRect =
        Rect.fromLTWH(leftMargin, topMargin, plotWidth, plotHeight);

    // Draw border.
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(plotRect, borderPaint);

    // Compute data range.
    final minFreq = frequencies.first;
    final maxFreq = frequencies.last;
    final freqRange = maxFreq - minFreq;
    if (freqRange <= 0) return;

    final powerRange = powerAxis.max;
    final tickCount = powerTickCount;

    // Draw grid lines.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < tickCount; i++) {
      final y = plotRect.bottom - plotHeight * (i / tickCount);
      canvas.drawLine(
          Offset(plotRect.left, y), Offset(plotRect.right, y), gridPaint);
    }
    for (var i = 1; i < 5; i++) {
      final x = plotRect.left + plotWidth * i / 5.0;
      canvas.drawLine(
          Offset(x, plotRect.top), Offset(x, plotRect.bottom), gridPaint);
    }

    // Draw axis labels.
    _drawAxisLabels(canvas, plotRect, minFreq, maxFreq);

    // Down-sample for rendering if there are too many points.
    final step = math.max(1, frequencies.length ~/ plotWidth.toInt());

    // Draw the power spectrum line.
    final linePaint = Paint()
      ..color = plotColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..isAntiAlias = true;

    final path = Path();
    var first = true;
    for (var i = 0; i < frequencies.length; i += step) {
      final x =
          plotRect.left + (frequencies[i] - minFreq) / freqRange * plotWidth;
      final y = plotRect.bottom - (powers[i] / powerRange) * plotHeight;
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);

    // Mark the best frequency with a vertical line.
    final bestX =
        plotRect.left + (bestFrequency - minFreq) / freqRange * plotWidth;
    final peakPaint = Paint()
      ..color = peakColor
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(bestX, plotRect.top),
      Offset(bestX, plotRect.bottom),
      peakPaint,
    );

    // Draw a small label at the peak.
    final peakLabel = TextPainter(
      text: TextSpan(
        text: periodogramPeakLabel(bestFrequency),
        style: SkotiqTypography.caption
            .copyWith(color: peakColor, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // A label wider than the plot would drop the right bound below the left
    // one and throw out of paint(); pin it to the left edge and let it clip.
    final double maxLabelX =
        math.max(plotRect.left, plotRect.right - peakLabel.width);
    final labelX = (bestX + 4).clamp(plotRect.left, maxLabelX);
    peakLabel.paint(canvas, Offset(labelX, plotRect.top + 2));
  }

  void _drawAxisLabels(
      Canvas canvas, Rect plotRect, double minFreq, double maxFreq) {
    final textStyle = SkotiqTypography.caption.copyWith(color: textColor);

    // Y-axis labels: one per tick of the snapped axis, at its own precision.
    final labels = powerAxisLabels;
    for (var i = 0; i < labels.length; i++) {
      final y = plotRect.bottom - (i / (labels.length - 1)) * plotRect.height;
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plotRect.left - tp.width - 4, y - tp.height / 2));
    }

    // X-axis labels. Frequency spans anything from ~0.01 c/d (a season-long
    // baseline) to ~100 c/d (one night), so the precision has to come from the
    // range rather than being fixed at one decimal.
    final xDecimals = NiceAxis.decimalsFor((maxFreq - minFreq) / 4.0);
    for (var i = 0; i <= 4; i++) {
      final value = minFreq + (maxFreq - minFreq) * i / 4.0;
      final x = plotRect.left + plotRect.width * i / 4.0;
      final tp = TextPainter(
        text:
            TextSpan(text: value.toStringAsFixed(xDecimals), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, plotRect.bottom + 4));
    }

    // Axis names.
    final xLabelPainter = TextPainter(
      text: TextSpan(text: xLabel, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    xLabelPainter.paint(
      canvas,
      Offset(
        plotRect.left + plotRect.width / 2 - xLabelPainter.width / 2,
        plotRect.bottom + 16,
      ),
    );

    final yLabelPainter = TextPainter(
      text: TextSpan(text: yLabel, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(
        10, plotRect.top + plotRect.height / 2 + yLabelPainter.width / 2);
    canvas.rotate(-math.pi / 2);
    yLabelPainter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PeriodogramCustomPainter oldDelegate) {
    return oldDelegate.frequencies != frequencies ||
        oldDelegate.powers != powers ||
        oldDelegate.bestFrequency != bestFrequency;
  }
}
