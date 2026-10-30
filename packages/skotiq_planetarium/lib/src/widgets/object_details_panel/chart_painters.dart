part of '../object_details_panel.dart';

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color.withValues(alpha: 0.7)),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.5),
            fontSize: SkotiqTypography.fontSize10,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Paints the altitude graph with optional cloud cover background band.
class _AltitudeGraphPainter extends CustomPainter {
  final CelestialObject object;
  final WidgetRef ref;
  final Color lineColor;
  final Color gridColor;

  /// Current cloud cover percentage (0-100). When non-null, draws a
  /// semi-transparent background band across the chart:
  /// green (<20%), yellow (20-60%), red (>60%).
  final double? cloudCoverPercent;

  /// The user-configured effective horizon in degrees (e.g. 20° to clear
  /// trees). 0 = no shading. Sourced from
  /// `planetariumEffectiveHorizonDegProvider`, which the app layer overrides to
  /// pull from `skotiq_core`'s persisted setting.
  final double effectiveHorizonDeg;

  _AltitudeGraphPainter({
    required this.object,
    required this.ref,
    required this.lineColor,
    required this.gridColor,
    this.cloudCoverPercent,
    this.effectiveHorizonDeg = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Altitude is measured from the observer's horizon: with no site there is
    // no curve to draw.
    final site = ref.read(observerLocationProvider).site;
    if (site == null) return;
    final now = ref.read(observationTimeProvider).time;

    // Draw cloud cover background band (behind everything else)
    if (cloudCoverPercent != null) {
      final cc = cloudCoverPercent!;
      Color bandColor;
      if (cc < 20) {
        // Clear: green
        bandColor = SkyPlotColors.good.withValues(alpha: 0.12);
      } else if (cc < 60) {
        // Partial: yellow/amber
        bandColor = SkyPlotColors.caution.withValues(alpha: 0.12);
      } else {
        // Overcast: red
        bandColor = SkyPlotColors.poor.withValues(alpha: 0.12);
      }
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = bandColor,
      );

      // Draw a small cloud cover label in the top-right
      final ccLabel = '${cc.round()}% cloud';
      Color labelColor;
      if (cc < 20) {
        labelColor = SkyPlotColors.good;
      } else if (cc < 60) {
        labelColor = SkyPlotColors.caution;
      } else {
        labelColor = SkyPlotColors.poor;
      }
      final textPainter = TextPainter(
        text: TextSpan(
          text: ccLabel,
          style: TextStyle(
            color: labelColor.withValues(alpha: 0.7),
            fontSize: SkotiqTypography.fontSize8,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(size.width - textPainter.width - 4, 2));
    }

    // Draw grid
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    // Horizon line at 0° (centre of chart).
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      gridPaint,
    );

    // Effective-horizon shading: paint the unreachable band (0° to the
    // user's effective horizon) so the user can see at a glance when a
    // target clears the trees. We render it AFTER the cloud band but
    // BEFORE the altitude curve so the curve stays on top.
    if (effectiveHorizonDeg > 0) {
      // Top of "below-effective-horizon" band is the effective horizon,
      // bottom is the 0° line. y = (height/2) - (alt/90) * (height/2).
      final horizonY =
          size.height / 2 - (effectiveHorizonDeg / 90) * (size.height / 2);
      canvas.drawRect(
        Rect.fromLTRB(0, horizonY, size.width, size.height / 2),
        Paint()..color = SkyPlotColors.horizon.withValues(alpha: 0.10),
      );
      // Effective-horizon dashed line so the boundary is unambiguous.
      final dashPaint = Paint()
        ..color = SkyPlotColors.horizon.withValues(alpha: 0.6)
        ..strokeWidth = 1;
      const double dashWidth = 4;
      const double dashGap = 3;
      double x = 0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, horizonY),
          Offset((x + dashWidth).clamp(0, size.width), horizonY),
          dashPaint,
        );
        x += dashWidth + dashGap;
      }
    }

    // Calculate altitudes over 24 hours
    final points = <Offset>[];
    for (int hour = 0; hour < 24; hour++) {
      final time = DateTime(now.year, now.month, now.day, hour);
      final (alt, _) = AstronomyCalculations.objectAltAz(
        raDeg: object.coordinates.ra * 15,
        decDeg: object.coordinates.dec,
        dt: time,
        latitudeDeg: site.latitude,
        longitudeDeg: site.longitude,
      );

      final x = (hour / 24) * size.width;
      final y = size.height / 2 - (alt / 90) * (size.height / 2);
      points.add(Offset(x, y.clamp(0, size.height)));
    }

    // Draw the altitude curve
    if (points.length > 1) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }

      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;

      canvas.drawPath(path, linePaint);
    }

    // Draw current time indicator
    final currentHour = now.hour + now.minute / 60;
    final currentX = (currentHour / 24) * size.width;
    canvas.drawLine(
      Offset(currentX, 0),
      Offset(currentX, size.height),
      Paint()
        ..color = ImageOverlayColors.foreground.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _AltitudeGraphPainter oldDelegate) {
    return object != oldDelegate.object ||
        cloudCoverPercent != oldDelegate.cloudCoverPercent ||
        effectiveHorizonDeg != oldDelegate.effectiveHorizonDeg;
  }
}

/// Paints the airmass chart with color zones
/// Y-axis is inverted: 1.0 at top (best), higher values toward bottom (worse)
/// Color zones: green < 1.5, yellow 1.5-2.0, red > 2.0
class _AirmassChartPainter extends CustomPainter {
  final CelestialObject object;
  final WidgetRef ref;
  final Color txtColor;

  // Airmass display range: 1.0 (top) to 3.0 (bottom)
  static const double _minAirmass = 1.0;
  static const double _maxAirmass = 3.0;

  _AirmassChartPainter({
    required this.object,
    required this.ref,
    required this.txtColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Altitude is measured from the observer's horizon: with no site there is
    // no curve to draw.
    final site = ref.read(observerLocationProvider).site;
    if (site == null) return;
    final now = ref.read(observationTimeProvider).time;

    final gridColor = txtColor.withValues(alpha: 0.15);
    final labelStyle = TextStyle(
      color: txtColor.withValues(alpha: 0.4),
      fontSize: SkotiqTypography.fontSize9,
    );

    // Chart margins for labels
    const leftMargin = 28.0;
    const rightMargin = 4.0;
    const topMargin = 4.0;
    const bottomMargin = 14.0;
    final chartWidth = size.width - leftMargin - rightMargin;
    final chartHeight = size.height - topMargin - bottomMargin;

    // Draw color zone backgrounds
    final greenZoneBottom = _airmassToY(1.5, chartHeight) + topMargin;
    final yellowZoneBottom = _airmassToY(2.0, chartHeight) + topMargin;

    // Green zone: 1.0 to 1.5
    canvas.drawRect(
      Rect.fromLTRB(
        leftMargin,
        topMargin,
        leftMargin + chartWidth,
        greenZoneBottom,
      ),
      Paint()..color = SkyPlotColors.good.withValues(alpha: 0.08),
    );

    // Yellow zone: 1.5 to 2.0
    canvas.drawRect(
      Rect.fromLTRB(
        leftMargin,
        greenZoneBottom,
        leftMargin + chartWidth,
        yellowZoneBottom,
      ),
      Paint()..color = SkyPlotColors.caution.withValues(alpha: 0.08),
    );

    // Red zone: 2.0 to 3.0
    canvas.drawRect(
      Rect.fromLTRB(
        leftMargin,
        yellowZoneBottom,
        leftMargin + chartWidth,
        topMargin + chartHeight,
      ),
      Paint()..color = SkyPlotColors.poor.withValues(alpha: 0.08),
    );

    // Draw horizontal grid lines at airmass values
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;

    for (final am in [1.0, 1.5, 2.0, 2.5, 3.0]) {
      final y = _airmassToY(am, chartHeight) + topMargin;
      canvas.drawLine(
        Offset(leftMargin, y),
        Offset(leftMargin + chartWidth, y),
        gridPaint,
      );

      // Y-axis label
      final tp = TextPainter(
        text: TextSpan(text: am.toStringAsFixed(1), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftMargin - tp.width - 4, y - tp.height / 2));
    }

    // Calculate airmass values over 24 hours (every 15 minutes for smoothness)
    final points = <Offset>[];
    final airmassValues = <double>[];
    double? bestAirmass;
    int? bestTimeMinute;

    for (int minute = 0; minute < 24 * 60; minute += 15) {
      final hour = minute ~/ 60;
      final min = minute % 60;
      final time = DateTime(now.year, now.month, now.day, hour, min);
      final (alt, _) = AstronomyCalculations.objectAltAz(
        raDeg: object.coordinates.ra * 15,
        decDeg: object.coordinates.dec,
        dt: time,
        latitudeDeg: site.latitude,
        longitudeDeg: site.longitude,
      );

      if (alt > 0) {
        final am = AstronomyCalculations.airmass(alt);
        final clampedAm = am.clamp(_minAirmass, _maxAirmass);
        final x = leftMargin + (minute / (24 * 60)) * chartWidth;
        final y = _airmassToY(clampedAm, chartHeight) + topMargin;
        points.add(Offset(x, y));
        airmassValues.add(am);

        if (bestAirmass == null || am < bestAirmass) {
          bestAirmass = am;
          bestTimeMinute = minute;
        }
      } else {
        // Object below horizon - break the line
        if (points.isNotEmpty) {
          _drawAirmassSegment(
            canvas,
            points,
            airmassValues,
            chartHeight,
            topMargin,
          );
          points.clear();
          airmassValues.clear();
        }
      }
    }

    // Draw remaining points
    if (points.isNotEmpty) {
      _drawAirmassSegment(
        canvas,
        points,
        airmassValues,
        chartHeight,
        topMargin,
      );
    }

    // Draw current time indicator
    final currentMinute = now.hour * 60 + now.minute;
    final currentX = leftMargin + (currentMinute / (24 * 60)) * chartWidth;
    canvas.drawLine(
      Offset(currentX, topMargin),
      Offset(currentX, topMargin + chartHeight),
      Paint()
        ..color = ImageOverlayColors.foreground.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );

    // Mark best observing window
    if (bestTimeMinute != null &&
        bestAirmass != null &&
        bestAirmass < _maxAirmass) {
      final bestX = leftMargin + (bestTimeMinute / (24 * 60)) * chartWidth;
      final bestY =
          _airmassToY(
            bestAirmass.clamp(_minAirmass, _maxAirmass),
            chartHeight,
          ) +
          topMargin;

      // Draw diamond marker
      final markerPath = Path()
        ..moveTo(bestX, bestY - 4)
        ..lineTo(bestX + 4, bestY)
        ..lineTo(bestX, bestY + 4)
        ..lineTo(bestX - 4, bestY)
        ..close();
      canvas.drawPath(
        markerPath,
        Paint()
          ..color = SkyPlotColors.good
          ..style = PaintingStyle.fill,
      );

      // Label "best" below marker
      final bestLabel = TextPainter(
        text: const TextSpan(
          text: 'best',
          style: TextStyle(
            color: SkyPlotColors.good,
            fontSize: SkotiqTypography.fontSize8,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelX = (bestX - bestLabel.width / 2).clamp(
        leftMargin,
        leftMargin + chartWidth - bestLabel.width,
      );
      bestLabel.paint(canvas, Offset(labelX, bestY + 6));
    }

    // Draw time labels at bottom
    for (final hour in [0, 6, 12, 18]) {
      final x = leftMargin + (hour / 24) * chartWidth;
      final label = '${hour.toString().padLeft(2, '0')}h';
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, topMargin + chartHeight + 2));
    }
  }

  /// Convert airmass value to Y pixel coordinate within the chart area
  double _airmassToY(double airmass, double chartHeight) {
    // Inverted: 1.0 at top, 3.0 at bottom
    final fraction = (airmass - _minAirmass) / (_maxAirmass - _minAirmass);
    return fraction * chartHeight;
  }

  /// Draw a segment of the airmass curve with color coding
  void _drawAirmassSegment(
    Canvas canvas,
    List<Offset> points,
    List<double> airmassValues,
    double chartHeight,
    double topMargin,
  ) {
    if (points.length < 2) return;

    // Draw line segments with colors based on airmass zone
    for (int i = 0; i < points.length - 1; i++) {
      final am = airmassValues[i];
      Color segmentColor;
      if (am < 1.5) {
        segmentColor = SkyPlotColors.good; // Green
      } else if (am < 2.0) {
        segmentColor = SkyPlotColors.caution; // Yellow
      } else {
        segmentColor = SkyPlotColors.poor; // Red
      }

      canvas.drawLine(
        points[i],
        points[i + 1],
        Paint()
          ..color = segmentColor
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AirmassChartPainter oldDelegate) {
    return object != oldDelegate.object;
  }
}
