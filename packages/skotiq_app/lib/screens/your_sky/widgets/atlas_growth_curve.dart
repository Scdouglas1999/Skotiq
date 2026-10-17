import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../analytics/widgets/adaptive_chart_container.dart';
import '../sky_atlas_format.dart';

/// Region-detail growth card: plots the region's cumulative integration HOURS
/// against the nights folded into it — the "your sky keeps getting deeper"
/// curve. Fed the native [AtlasGrowthCurve] (one point per fold night,
/// chronological), it renders the deepening line that the prior static stat
/// strip only summarised as a single number.
///
/// X axis is the night index (0..n-1) relabelled to calendar dates so a
/// single-night region still plots cleanly; Y axis is cumulative integration
/// hours. An empty / single-night curve renders an inviting placeholder rather
/// than a degenerate one-dot chart.
class AtlasGrowthCurvePanel extends StatelessWidget {
  final AtlasGrowthCurve curve;

  const AtlasGrowthCurvePanel({super.key, required this.curve});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final points = curve.points;

    if (points.length < 2) {
      return _placeholder();
    }

    final spots = [
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].cumulativeSeconds / 3600.0),
    ];
    final maxHours = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final yMax = maxHours <= 0 ? 1.0 : maxHours * 1.15;
    final lastN = points.length - 1;

    // The series hue is a NAME, not the colour that gets painted. Red night is
    // a WAVELENGTH constraint, so painting the constant raw put #6B95B8 — a
    // solid blue line and its area fill — on a card whose every other pixel was
    // red, undoing the dark adaptation the mode exists to protect. Resolved
    // once here so the line and the fill below cannot drift apart.
    final lineColor = SkotiqChartColors.forTheme(
      SkotiqChartColors.seriesBlue,
      colors,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Deepening over time',
          subtitle:
              '${formatIntegration(curve.totalSeconds)} integrated across '
              '${points.length} nights',
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqPanel(
            padding: SkotiqTokens.cardPadding,
            child: AdaptiveChartContainer(
              preferredHeight: 170,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: lastN.toDouble(),
                  minY: 0,
                  maxY: yMax,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    horizontalInterval: yMax / 4,
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
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        interval: _axisInterval(points.length),
                        getTitlesWidget: (value, meta) {
                          final i = value.round();
                          if (i < 0 || i >= points.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(
                              top: SkotiqTokens.spaceSm,
                            ),
                            child: Text(
                              _shortLabel(points[i]),
                              style: SkotiqTypography.captionSm.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        interval: yMax / 4,
                        getTitlesWidget: (value, meta) => Text(
                          '${value.toStringAsFixed(value >= 10 ? 0 : 1)}h',
                          style: SkotiqTypography.captionSm.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: colors.border),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: false,
                      color: lineColor,
                      barWidth: 2.5,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: true),
                      belowBarData: BarAreaData(
                        show: true,
                        color: lineColor.withValues(alpha: 0.1),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => colors.surface,
                      getTooltipItems: (touchedSpots) =>
                          touchedSpots.map((spot) {
                        final i = spot.x.round();
                        final label = (i >= 0 && i < points.length)
                            ? _shortLabel(points[i])
                            : '';
                        return LineTooltipItem(
                          '$label\n${spot.y.toStringAsFixed(1)}h total',
                          SkotiqTypography.labelQuiet.copyWith(
                            color: colors.textPrimary,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            )),
      ],
    );
  }

  Widget _placeholder() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Deepening over time'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqPanel(
          padding: SkotiqTokens.cardPadding,
          // A FIXED chart-sized box clipped this copy: the icon, a wrapped
          // title and a three-line body need more than 170px once the empty
          // state is narrowed to its 360px column, so the card rendered the
          // overflow stripe. Keep 170 as the FLOOR (so the card still holds
          // the chart's place in the scroll) and let the words have their
          // height.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 170),
            child: const EmptyState.compact(
              icon: LucideIcons.trendingUp,
              title: 'Image this region again to see it deepen',
              body: 'The growth curve plots cumulative integration once you '
                  'fold a second night here.',
            ),
          ),
        ),
      ],
    );
  }

  static String _shortLabel(AtlasGrowthPoint point) {
    final date = point.date;
    if (date == null) {
      // Non-dated session-id label: show it verbatim (trimmed).
      final label = point.label.trim();
      return label.length > 8 ? label.substring(0, 8) : label;
    }
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final m = months[(date.month - 1).clamp(0, 11)];
    return '$m ${date.day}';
  }

  /// Keep <= ~5 labels on the bottom axis.
  static double _axisInterval(int count) {
    if (count <= 5) return 1;
    return (count / 5).ceilToDouble();
  }
}
