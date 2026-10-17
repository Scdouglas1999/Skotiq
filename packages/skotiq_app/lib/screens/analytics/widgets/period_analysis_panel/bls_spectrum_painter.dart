part of '../period_analysis_panel.dart';

/// Paints the BLS SR spectrum (SR vs trial period).
class _BlsSpectrumPainter extends StatelessWidget {
  final SkotiqColors colors;
  final List<double> trialPeriods;
  final List<double> srSpectrum;
  final double bestPeriod;

  const _BlsSpectrumPainter({
    required this.colors,
    required this.trialPeriods,
    required this.srSpectrum,
    required this.bestPeriod,
  });

  @override
  Widget build(BuildContext context) {
    if (trialPeriods.isEmpty) {
      return Center(
        child: Text(
          'No BLS data',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _BlsSpectrumCustomPainter(
        trialPeriods: trialPeriods,
        srSpectrum: srSpectrum,
        bestPeriod: bestPeriod,
        plotColor: SkotiqChartColors.forTheme(
            SkotiqChartColors.seriesGreen, colors),
        peakColor: SkotiqChartColors.forTheme(
            SkotiqChartColors.seriesAmber, colors),
        borderColor: colors.border,
        textColor: colors.textSecondary,
        gridColor: colors.border.withValues(alpha: 0.3),
      ),
    );
  }
}

class _BlsSpectrumCustomPainter extends CustomPainter {
  final List<double> trialPeriods;
  final List<double> srSpectrum;
  final double bestPeriod;
  final Color plotColor;
  final Color peakColor;
  final Color borderColor;
  final Color textColor;
  final Color gridColor;

  _BlsSpectrumCustomPainter({
    required this.trialPeriods,
    required this.srSpectrum,
    required this.bestPeriod,
    required this.plotColor,
    required this.peakColor,
    required this.borderColor,
    required this.textColor,
    required this.gridColor,
  });

  /// Peak signal residual; 1.0 for an all-zero spectrum so the axis is still
  /// drawable.
  double get _peakSr {
    var maxSr = 0.0;
    for (final sr in srSpectrum) {
      if (sr > maxSr) maxSr = sr;
    }
    return maxSr > 0 ? maxSr : 1.0;
  }

  /// Y scale for the signal-residual axis.
  ///
  /// SR is a small unnormalised quantity — on a real light curve the whole
  /// spectrum sat below 0.05 and five ticks at one decimal all printed "0.0".
  /// Same treatment as the Lomb-Scargle power axis.
  NiceAxis get srAxis => NiceAxis.forRange(0, _peakSr, padFraction: 0.1);

  int get srTickCount => math.max(1, (srAxis.max / srAxis.interval).round());

  /// The Y tick labels this painter draws, bottom to top. [paint] renders
  /// exactly these strings.
  List<String> get srAxisLabels {
    final axis = srAxis;
    return [
      for (var i = 0; i <= srTickCount; i++) axis.label(axis.interval * i),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (trialPeriods.isEmpty) return;

    const leftMargin = 45.0;
    const bottomMargin = 28.0;
    const topMargin = 8.0;
    const rightMargin = 12.0;
    final plotWidth = size.width - leftMargin - rightMargin;
    final plotHeight = size.height - topMargin - bottomMargin;
    final plotRect =
        Rect.fromLTWH(leftMargin, topMargin, plotWidth, plotHeight);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(plotRect, borderPaint);

    // Use log scale for period axis.
    final logMinP = math.log(trialPeriods.first);
    final logMaxP = math.log(trialPeriods.last);
    final logRange = logMaxP - logMinP;
    if (logRange <= 0) return;

    final srRange = srAxis.max;
    final tickCount = srTickCount;

    // Grid.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < tickCount; i++) {
      final y = plotRect.bottom - plotHeight * (i / tickCount);
      canvas.drawLine(
          Offset(plotRect.left, y), Offset(plotRect.right, y), gridPaint);
    }

    // Axis labels.
    final textStyle = SkotiqTypography.caption.copyWith(color: textColor);

    // Y-axis.
    final labels = srAxisLabels;
    for (var i = 0; i < labels.length; i++) {
      final y = plotRect.bottom - (i / (labels.length - 1)) * plotHeight;
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plotRect.left - tp.width - 4, y - tp.height / 2));
    }

    // X-axis: log-spaced period labels.
    for (var i = 0; i <= 4; i++) {
      final logVal = logMinP + logRange * i / 4.0;
      final period = math.exp(logVal);
      final x = plotRect.left + plotWidth * i / 4.0;
      final label = period < 1
          ? '${(period * 24).toStringAsFixed(1)}h'
          : '${period.toStringAsFixed(1)}d';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, plotRect.bottom + 4));
    }

    final xLabelPainter = TextPainter(
      // The tick labels below carry their own h/d suffix per tick because the
      // axis is log-spaced and can span both; say so rather than leaving a bare
      // "Period" over a mixture of units.
      text: TextSpan(text: 'Period (h / d, log)', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    xLabelPainter.paint(
      canvas,
      Offset(
        plotRect.left + plotWidth / 2 - xLabelPainter.width / 2,
        plotRect.bottom + 16,
      ),
    );

    final yLabelPainter = TextPainter(
      text: TextSpan(text: 'SR (signal residue)', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(
        10, plotRect.top + plotHeight / 2 + yLabelPainter.width / 2);
    canvas.rotate(-math.pi / 2);
    yLabelPainter.paint(canvas, Offset.zero);
    canvas.restore();

    // Draw the SR spectrum.
    final linePaint = Paint()
      ..color = plotColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..isAntiAlias = true;

    final step = math.max(1, trialPeriods.length ~/ plotWidth.toInt());
    final path = Path();
    var first = true;
    for (var i = 0; i < trialPeriods.length; i += step) {
      final logP = math.log(trialPeriods[i]);
      final x = plotRect.left + (logP - logMinP) / logRange * plotWidth;
      final y = plotRect.bottom - (srSpectrum[i] / srRange) * plotHeight;
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);

    // Mark best period.
    final bestLogP = math.log(bestPeriod);
    final bestX = plotRect.left + (bestLogP - logMinP) / logRange * plotWidth;
    final peakPaint = Paint()
      ..color = peakColor
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(bestX, plotRect.top),
      Offset(bestX, plotRect.bottom),
      peakPaint,
    );

    final peakLabel = TextPainter(
      text: TextSpan(
        text: blsPeakLabel(bestPeriod),
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

  @override
  bool shouldRepaint(covariant _BlsSpectrumCustomPainter oldDelegate) {
    return oldDelegate.trialPeriods != trialPeriods ||
        oldDelegate.srSpectrum != srSpectrum ||
        oldDelegate.bestPeriod != bestPeriod;
  }
}
