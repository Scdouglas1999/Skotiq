part of '../focus_model_curve_card.dart';

class _HfrScatterChart extends StatelessWidget {
  final List<FocusHistoryPoint> points;
  final FocusModel? model;
  final int? currentPosition;
  final SkotiqColors colors;

  const _HfrScatterChart({
    required this.points,
    required this.model,
    required this.currentPosition,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        child: CustomPaint(
          painter: _HfrCurvePainter(
            points: points,
            model: model,
            currentPosition: currentPosition,
            gridColor: colors.border,
            textColor: colors.textMuted,
            lineColor: colors.primary,
            markerColor: colors.accent,
            warningColor: colors.warning,
            successColor: colors.success,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Painter that draws (position, HFR) scatter points coloured by sample
/// temperature, the fitted regression line projected through the data, a
/// vertical marker for the current focuser position, and a vertical marker for
/// the inferred best-focus position (the median position of the temperature
/// model, which is the regression's prediction at the median sample
/// temperature).
class _HfrCurvePainter extends CustomPainter {
  final List<FocusHistoryPoint> points;
  final FocusModel? model;
  final int? currentPosition;
  final Color gridColor;
  final Color textColor;
  final Color lineColor;
  final Color markerColor;
  final Color warningColor;
  final Color successColor;

  _HfrCurvePainter({
    required this.points,
    required this.model,
    required this.currentPosition,
    required this.gridColor,
    required this.textColor,
    required this.lineColor,
    required this.markerColor,
    required this.warningColor,
    required this.successColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width < 50 || size.height < 50) return;

    const leftPadding = 44.0;
    const rightPadding = 12.0;
    const topPadding = 12.0;
    const bottomPadding = 26.0;

    final plotRect = Rect.fromLTRB(
      leftPadding,
      topPadding,
      size.width - rightPadding,
      size.height - bottomPadding,
    );

    if (plotRect.width <= 0 || plotRect.height <= 0) return;

    // Data bounds.
    double minPos = points.first.focusPosition.toDouble();
    double maxPos = points.first.focusPosition.toDouble();
    double minHfr = points.first.hfr;
    double maxHfr = points.first.hfr;
    double minTemp = points.first.temperatureCelsius;
    double maxTemp = points.first.temperatureCelsius;
    for (final p in points) {
      if (p.focusPosition < minPos) minPos = p.focusPosition.toDouble();
      if (p.focusPosition > maxPos) maxPos = p.focusPosition.toDouble();
      if (p.hfr < minHfr) minHfr = p.hfr;
      if (p.hfr > maxHfr) maxHfr = p.hfr;
      if (p.temperatureCelsius < minTemp) minTemp = p.temperatureCelsius;
      if (p.temperatureCelsius > maxTemp) maxTemp = p.temperatureCelsius;
    }

    final posRange = (maxPos - minPos).abs();
    final hfrRange = (maxHfr - minHfr).abs();

    // Pad ranges so points don't sit on the axis.
    final posPad = posRange < 10 ? 50.0 : posRange * 0.08;
    final hfrPad = hfrRange < 0.5 ? 0.5 : hfrRange * 0.15;
    minPos -= posPad;
    maxPos += posPad;
    minHfr -= hfrPad;
    maxHfr += hfrPad;
    if (minHfr < 0) minHfr = 0; // HFR is non-negative.

    double mapX(double pos) =>
        plotRect.left + ((pos - minPos) / (maxPos - minPos)) * plotRect.width;
    double mapY(double hfr) =>
        plotRect.bottom -
        ((hfr - minHfr) / (maxHfr - minHfr)) * plotRect.height;

    // Grid.
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.3)
      ..strokeWidth = 0.5;
    // Horizontal grid (HFR labels).
    final hfrStep = _niceStep(maxHfr - minHfr, 4);
    final hfrStart = (minHfr / hfrStep).ceil() * hfrStep;
    for (double v = hfrStart; v <= maxHfr; v += hfrStep) {
      final y = mapY(v);
      canvas.drawLine(
        Offset(plotRect.left, y),
        Offset(plotRect.right, y),
        gridPaint,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: v.toStringAsFixed(1),
          style:
              TextStyle(fontSize: SkotiqTypography.fontSize9, color: textColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plotRect.left - tp.width - 4, y - tp.height / 2));
    }
    // Vertical grid (position labels).
    final posStep = _niceStep(maxPos - minPos, 4);
    final posStart = (minPos / posStep).ceil() * posStep;
    for (double v = posStart; v <= maxPos; v += posStep) {
      final x = mapX(v);
      canvas.drawLine(
        Offset(x, plotRect.top),
        Offset(x, plotRect.bottom),
        gridPaint,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: v.toInt().toString(),
          style:
              TextStyle(fontSize: SkotiqTypography.fontSize9, color: textColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, plotRect.bottom + 4));
    }

    // Border.
    final borderPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(plotRect, borderPaint);

    // Optional fitted curve: project the focus-model regression line into
    // the (position, HFR) space. The model is `position = intercept +
    // slope * temperature`, so for each sample temperature the model
    // predicts a position. We draw the best-focus position (model
    // prediction at the median sample temperature) as a vertical line —
    // that's the spot the model "trusts" most under current conditions.
    if (model != null) {
      final mTemp = _medianTemp(points);
      final predicted = model!.predictPosition(mTemp);
      if (predicted >= minPos && predicted <= maxPos) {
        final x = mapX(predicted.toDouble());
        final bestPaint = Paint()
          ..color = successColor.withValues(alpha: 0.8)
          ..strokeWidth = 2;
        canvas.drawLine(
          Offset(x, plotRect.top),
          Offset(x, plotRect.bottom),
          bestPaint,
        );
        final tp = TextPainter(
          text: TextSpan(
            text: 'Best $predicted',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize9,
              color: successColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Offset label so it doesn't clip the right edge.
        final tx =
            (x + 4 + tp.width > plotRect.right) ? x - tp.width - 4 : x + 4;
        tp.paint(canvas, Offset(tx, plotRect.top + 2));
      }
    }

    // Scatter points coloured by temperature (blue cool -> orange warm).
    final tempSpan = (maxTemp - minTemp).abs();
    final pointStrokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final p in points) {
      final x = mapX(p.focusPosition.toDouble());
      final y = mapY(p.hfr);
      if (!plotRect.contains(Offset(x, y))) continue;
      final t = tempSpan < 0.1
          ? 0.5
          : ((p.temperatureCelsius - minTemp) / tempSpan).clamp(0.0, 1.0);
      final colour = _temperatureColor(t);
      final fillPaint = Paint()
        ..color = colour
        ..style = PaintingStyle.fill;
      pointStrokePaint.color = colour.withValues(alpha: 0.55);
      canvas.drawCircle(Offset(x, y), 3.5, fillPaint);
      canvas.drawCircle(Offset(x, y), 4.2, pointStrokePaint);
    }

    // Current focuser position marker (triangle on X axis).
    if (currentPosition != null &&
        currentPosition! >= minPos &&
        currentPosition! <= maxPos) {
      final x = mapX(currentPosition!.toDouble());
      final triPath = Path()
        ..moveTo(x, plotRect.bottom - 6)
        ..lineTo(x - 5, plotRect.bottom + 4)
        ..lineTo(x + 5, plotRect.bottom + 4)
        ..close();
      final triPaint = Paint()
        ..color = markerColor
        ..style = PaintingStyle.fill;
      canvas.drawPath(triPath, triPaint);
      final vertical = Paint()
        ..color = markerColor.withValues(alpha: 0.4)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(x, plotRect.top),
        Offset(x, plotRect.bottom),
        vertical,
      );
    }

    // Axis labels.
    final xLabel = TextPainter(
      text: TextSpan(
        text: 'Focuser position',
        style:
            TextStyle(fontSize: SkotiqTypography.fontSize9, color: textColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    xLabel.paint(
      canvas,
      Offset(
        plotRect.left + (plotRect.width - xLabel.width) / 2,
        plotRect.bottom + 14,
      ),
    );
    canvas.save();
    canvas.translate(6, plotRect.top + plotRect.height / 2);
    canvas.rotate(-math.pi / 2);
    final yLabel = TextPainter(
      text: TextSpan(
        text: 'HFR',
        style:
            TextStyle(fontSize: SkotiqTypography.fontSize9, color: textColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    yLabel.paint(canvas, Offset(-yLabel.width / 2, 0));
    canvas.restore();
  }

  /// Map a normalised temperature value (0 = coldest sample, 1 = warmest) to
  /// a colour ramp: cool blue → neutral → warm orange. We blend linearly in
  /// RGB; for the small colour range used here that's perceptually adequate
  /// without introducing an HSL conversion. The result is consistent with
  /// what the existing desktop focus-model panel renders.
  Color _temperatureColor(double t) {
    // Anchor colours: cool ~ #4F8BFF, mid ~ #B9A26A, warm ~ #FF8A3D.
    const cool = SciencePlotColors.temperatureCool;
    const mid = SciencePlotColors.temperatureMid;
    const warm = SciencePlotColors.temperatureWarm;
    if (t <= 0.5) {
      final f = t * 2;
      return Color.lerp(cool, mid, f) ?? mid;
    }
    final f = (t - 0.5) * 2;
    return Color.lerp(mid, warm, f) ?? warm;
  }

  double _medianTemp(List<FocusHistoryPoint> ps) {
    final sorted = ps.map((p) => p.temperatureCelsius).toList()..sort();
    final n = sorted.length;
    final mid = n ~/ 2;
    if (n.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  double _niceStep(double range, int targetLines) {
    if (range <= 0) return 1;
    final rough = range / targetLines;
    final mag = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
    final normalized = rough / mag;
    double nice;
    if (normalized <= 1.5) {
      nice = 1;
    } else if (normalized <= 3.5) {
      nice = 2;
    } else if (normalized <= 7.5) {
      nice = 5;
    } else {
      nice = 10;
    }
    return nice * mag;
  }

  @override
  bool shouldRepaint(covariant _HfrCurvePainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.model != model ||
        oldDelegate.currentPosition != currentPosition;
  }
}

/// Compact legend strip describing the temperature colour ramp. We draw the
/// gradient with a Container + LinearGradient because that's much simpler
/// than another CustomPainter for ~24 pixels of UI.
class _TemperatureLegend extends StatelessWidget {
  final List<FocusHistoryPoint> points;
  final SkotiqColors colors;

  const _TemperatureLegend({required this.points, required this.colors});

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    double minTemp = points.first.temperatureCelsius;
    double maxTemp = points.first.temperatureCelsius;
    for (final p in points) {
      if (p.temperatureCelsius < minTemp) minTemp = p.temperatureCelsius;
      if (p.temperatureCelsius > maxTemp) maxTemp = p.temperatureCelsius;
    }
    return Row(
      children: [
        Text('Cool ${minTemp.toStringAsFixed(1)}°',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: colors.textMuted)),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            height: 6,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              gradient: const LinearGradient(colors: [
                SciencePlotColors.temperatureCool,
                SciencePlotColors.temperatureMid,
                SciencePlotColors.temperatureWarm,
              ]),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text('Warm ${maxTemp.toStringAsFixed(1)}°',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: colors.textMuted)),
      ],
    );
  }
}
