import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart' show DbCapturedImage;

import 'adaptive_chart_container.dart';
import 'chart_axis.dart';

/// Chart data point with timestamp and value
class ChartDataPoint {
  final DateTime timestamp;
  final double value;

  const ChartDataPoint({
    required this.timestamp,
    required this.value,
  });
}

/// Generic session chart for a measured time series.
///
/// Draws what was measured: samples are joined with straight segments (a spline
/// invents values between samples and overshoots past the real minimum, which
/// on an HFR trace reads as focus the run never achieved), and the median is
/// marked so a frame can be judged against the night rather than by eye.
class SessionChart extends StatelessWidget {
  final String title;

  /// Axis label including units, e.g. `HFR (px)`.
  final String yAxisLabel;

  /// What the series measures, as a noun phrase for prose — "sensor
  /// temperature", "guiding RMS". Separate from [yAxisLabel] because the axis
  /// label carries units and reads as a typo in a sentence: composing the empty
  /// state from it produced "No HFR (px) recorded for these frames" and, for
  /// the temperature chart whose axis is just the unit, "No °C recorded for
  /// these frames". Falls back to the card title.
  final String? measurementName;

  final List<ChartDataPoint> dataPoints;

  /// The series hue this chart names, as a fixed [SkotiqChartColors]
  /// constant. It is a NAME, not the colour that gets painted: [build] runs it
  /// through [SkotiqChartColors.forTheme] so red night receives a red-axis
  /// series instead. Mapping here rather than at each caller means a chart
  /// added later cannot reintroduce a blue line on a red-night page.
  final Color lineColor;
  final double? minY;
  final double? maxY;

  /// Values above this read as a problem; drawn as a threshold line when the
  /// data comes near it. Optional — most series have no meaningful limit.
  final double? warnAbove;

  const SessionChart({
    super.key,
    required this.title,
    required this.yAxisLabel,
    required this.dataPoints,
    this.measurementName,
    this.lineColor = SkotiqChartColors.seriesBlue,
    this.minY,
    this.maxY,
    this.warnAbove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // Red night is a wavelength constraint, so the named series hue cannot be
    // painted as-is: #6B95B8 on the HFR line lit this card blue while the rest
    // of the screen was red.
    final seriesColor = SkotiqChartColors.forTheme(lineColor, colors);

    if (dataPoints.isEmpty) {
      return _ChartShell(
        title: title,
        yAxisLabel: yAxisLabel,
        colors: colors,
        child: AdaptiveChartContainer.fixed(
          height: 150,
          child: Center(
            child: Text(
              'No ${measurementName ?? title.toLowerCase()} recorded for '
              'these frames',
              textAlign: TextAlign.center,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          ),
        ),
      );
    }

    // Never trust the caller's ordering: the standalone-image query returns
    // newest-first while the per-session query returns oldest-first, and an
    // unsorted series silently draws the night backwards (and, with x measured
    // from the first point, produced a negative axis whose labels vanished).
    final points = dataPoints.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final values = points.map((p) => p.value).toList(growable: false);
    final sorted = values.toList()..sort();
    final median = _percentile(sorted, 0.5);
    final p90 = _percentile(sorted, 0.9);
    final dataMin = sorted.first;
    final dataMax = sorted.last;

    final NiceAxis axis = NiceAxis.forRange(minY ?? dataMin, maxY ?? dataMax);
    final isFlat = dataMax - dataMin <= 0;

    final firstTimestamp = points.first.timestamp;
    final spots = points
        .map((point) => FlSpot(
              point.timestamp.difference(firstTimestamp).inMilliseconds /
                  1000.0,
              point.value,
            ))
        .toList(growable: false);
    final maxX = spots.last.x <= 0 ? 1.0 : spots.last.x;
    // Divide the span exactly rather than snapping to a round step: that puts
    // the final tick ON the axis end, so fl_chart's boundary label coincides
    // with a tick instead of drawing a second offset copy of it — and it does
    // not pad the plot out to a tick the data never reaches.
    final xInterval = maxX / 4;

    return _ChartShell(
      title: title,
      yAxisLabel: yAxisLabel,
      colors: colors,
      summary: _ChartSummary(
        colors: colors,
        median: axis.label(median),
        spread: '${axis.label(dataMin)}–${axis.label(dataMax)}',
        p90: axis.label(p90),
        count: points.length,
      ),
      child: AdaptiveChartContainer(
        preferredHeight: 150,
        child: LineChart(
          LineChartData(
            gridData: FlGridData(
              show: true,
              drawVerticalLine: true,
              horizontalInterval: axis.interval,
              verticalInterval: xInterval,
              getDrawingHorizontalLine: (_) => FlLine(
                color: colors.border.withValues(alpha: 0.3),
                strokeWidth: 1,
              ),
              getDrawingVerticalLine: (_) => FlLine(
                color: colors.border.withValues(alpha: 0.3),
                strokeWidth: 1,
              ),
            ),
            titlesData: FlTitlesData(
              show: true,
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 28,
                  interval: xInterval,
                  getTitlesWidget: (value, meta) => Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Text(
                      elapsedAxisLabel(value),
                      style: SkotiqTypography.monoCaption
                          .copyWith(color: colors.textSecondary),
                    ),
                  ),
                ),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: axis.interval,
                  getTitlesWidget: (value, meta) => Text(
                    axis.label(value),
                    style: SkotiqTypography.monoCaption
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border.all(color: colors.border),
            ),
            minX: 0,
            maxX: maxX,
            minY: axis.min,
            maxY: axis.max,
            extraLinesData: ExtraLinesData(
              horizontalLines: [
                // The median is the honest "typical" value for a skewed
                // quantity like HFR, where a few clouded frames drag the mean.
                HorizontalLine(
                  y: median,
                  color: colors.textMuted.withValues(alpha: 0.55),
                  strokeWidth: 1,
                  dashArray: const [4, 4],
                ),
                if (warnAbove != null &&
                    warnAbove! <= axis.max &&
                    warnAbove! >= axis.min)
                  HorizontalLine(
                    y: warnAbove!,
                    color: colors.warning.withValues(alpha: 0.5),
                    strokeWidth: 1,
                    dashArray: const [2, 4],
                  ),
              ],
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                // Straight segments only: these are measurements, not a model.
                isCurved: false,
                color: seriesColor,
                barWidth: 1.6,
                isStrokeCapRound: true,
                dotData: FlDotData(show: spots.length <= 40),
                belowBarData: BarAreaData(
                  // A filled area under a constant series implies a magnitude
                  // that isn't being measured — the sensor sitting at 20.0 C
                  // filled half the card.
                  show: !isFlat,
                  color: seriesColor.withValues(alpha: 0.08),
                ),
              ),
            ],
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => colors.surfaceElevated,
                getTooltipItems: (touchedSpots) => touchedSpots.map((spot) {
                  final when = firstTimestamp
                      .add(Duration(milliseconds: (spot.x * 1000).round()));
                  return LineTooltipItem(
                    '${axis.label(spot.y)} $yAxisLabel\n'
                    '${DateFormat('HH:mm:ss').format(when)}'
                    '  ·  +${elapsedAxisLabel(spot.x)}',
                    SkotiqTypography.labelQuiet.copyWith(
                      color: colors.textPrimary,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Linear-interpolated percentile of an already-sorted list.
  static double _percentile(List<double> sorted, double fraction) {
    if (sorted.isEmpty) return 0;
    if (sorted.length == 1) return sorted.first;
    final position = fraction * (sorted.length - 1);
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    final weight = position - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
  }
}

/// The narrowest a chart panel can be and still hold its title and its four
/// summary readouts on one line.
const double _chartHeaderInlineWidth = 420;

/// Card, title and axis caption shared by the populated and empty states so the
/// two never differ in height or padding.
class _ChartShell extends StatelessWidget {
  final String title;
  final String yAxisLabel;
  final SkotiqColors colors;
  final Widget child;
  final Widget? summary;

  const _ChartShell({
    required this.title,
    required this.yAxisLabel,
    required this.colors,
    required this.child,
    this.summary,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final titleBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: SkotiqTypography.bodyStrong
                        .copyWith(color: colors.textPrimary),
                  ),
                  Text(
                    yAxisLabel,
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                ],
              );
              if (summary == null) return titleBlock;

              // Side by side only when the panel can hold both. Below that the
              // summary takes its own line rather than wrapping the title one
              // character at a time.
              if (constraints.maxWidth < _chartHeaderInlineWidth) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    titleBlock,
                    const SizedBox(height: SkotiqTokens.spaceMd),
                    summary!,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: titleBlock),
                  summary!,
                ],
              );
            },
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          // The well around the plot is painted by AdaptiveChartContainer,
          // which every chart body here goes through (06: charts sit in
          // wells).
          child,
        ],
      ),
    );
  }
}

/// Median / spread / n, so the chart answers "was this a good night?" without
/// the user reading values off the line.
class _ChartSummary extends StatelessWidget {
  final SkotiqColors colors;
  final String median;
  final String spread;
  final String p90;
  final int count;

  const _ChartSummary({
    required this.colors,
    required this.median,
    required this.spread,
    required this.p90,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    // Four measurements, so four Readouts (05 §3). They were a label above a
    // `labelSm` value, which is a readout upside down.
    return ReadoutRow(
      gap: SkotiqTokens.spaceLg,
      children: [
        Readout(label: 'Median', value: median, size: ReadoutSize.sm),
        Readout(label: 'P90', value: p90, size: ReadoutSize.sm),
        Readout(label: 'Range', value: spread, size: ReadoutSize.sm),
        Readout(label: 'n', value: '$count', size: ReadoutSize.sm),
      ],
    );
  }
}

/// The one frame population every chart on the session card plots.
///
/// One population for all of them, so the card cannot report n=10 beside n=12
/// for the same night, and so the guiding trace cannot average in frames the
/// grader threw out and claim a p90 the accepted subs never saw. Calibration
/// frames are excluded for the same reason: a dark's sensor temperature is
/// real but it is not part of the night the rest of the card describes.
List<DbCapturedImage> sessionChartFrames(List<DbCapturedImage> images) => images
    .where(
        (image) => image.isAccepted && image.frameType.toLowerCase() == 'light')
    .toList(growable: false);

/// HFR (Half-Flux Radius) trend chart
class HfrChart extends StatelessWidget {
  final List<DbCapturedImage> images;

  const HfrChart({super.key, required this.images});

  @override
  Widget build(BuildContext context) {
    // No per-chart population filter here (or in the three charts below): the
    // caller passes [sessionChartFrames] so all four describe the same frames.
    final dataPoints = images
        .where((img) => img.hfr != null)
        .map((img) => ChartDataPoint(
              timestamp: img.capturedAt,
              value: img.hfr!,
            ))
        .toList();

    return SessionChart(
      title: 'Image quality',
      yAxisLabel: 'HFR (px)',
      measurementName: 'half-flux radius',
      dataPoints: dataPoints,
      lineColor: SkotiqChartColors.seriesBlue,
    );
  }
}

/// Temperature trend chart
class TemperatureChart extends StatelessWidget {
  final List<DbCapturedImage> images;

  const TemperatureChart({super.key, required this.images});

  @override
  Widget build(BuildContext context) {
    final dataPoints = images
        .where((img) => img.sensorTemp != null)
        .map((img) => ChartDataPoint(
              timestamp: img.capturedAt,
              value: img.sensorTemp!,
            ))
        .toList();

    return SessionChart(
      title: 'Sensor temperature',
      yAxisLabel: '°C',
      dataPoints: dataPoints,
      lineColor: SkotiqChartColors.seriesOrange,
    );
  }
}

/// Guiding RMS chart
class GuidingRmsChart extends StatelessWidget {
  final List<DbCapturedImage> images;

  const GuidingRmsChart({super.key, required this.images});

  @override
  Widget build(BuildContext context) {
    final dataPoints = images
        .where((img) => img.guidingRmsTotal != null)
        .map((img) => ChartDataPoint(
              timestamp: img.capturedAt,
              value: img.guidingRmsTotal!,
            ))
        .toList();

    return SessionChart(
      title: 'Guiding performance',
      yAxisLabel: 'RMS (arcsec)',
      measurementName: 'guiding RMS',
      dataPoints: dataPoints,
      lineColor: SkotiqChartColors.seriesGreen,
      // Guiding worse than about 1" starts to bloat stars at typical
      // amateur focal lengths, so it is worth marking on the plot.
      warnAbove: 1.0,
    );
  }
}

/// Focuser position chart (for focus drift tracking)
class FocuserPositionChart extends StatelessWidget {
  final List<DbCapturedImage> images;

  const FocuserPositionChart({super.key, required this.images});

  @override
  Widget build(BuildContext context) {
    final dataPoints = images
        .where((img) => img.focuserPosition != null)
        .map((img) => ChartDataPoint(
              timestamp: img.capturedAt,
              value: img.focuserPosition!.toDouble(),
            ))
        .toList();

    return SessionChart(
      title: 'Focus drift',
      yAxisLabel: 'Focuser position (steps)',
      measurementName: 'focuser position',
      dataPoints: dataPoints,
      lineColor: SkotiqChartColors.seriesViolet,
    );
  }
}
