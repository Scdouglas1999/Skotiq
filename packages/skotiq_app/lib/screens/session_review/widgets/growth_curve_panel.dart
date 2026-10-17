import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../analytics/widgets/adaptive_chart_container.dart';
import '../session_review_controller.dart' show BestNight, GrowthPoint;

/// Narrative-view card charting a target's multi-night growth: cumulative
/// integration hours accrued against calendar date as nights are folded into
/// the accumulating master.
///
/// Carries a "best night" badge — the night whose accepted subs held the
/// highest mean integration weight.
///
/// Fed `SessionReviewState.growthPoints` (the controller's hours-based
/// [GrowthPoint]) and `SessionReviewState.bestNight`. An empty list renders a
/// placeholder.
class GrowthCurvePanel extends StatelessWidget {
  /// Cumulative-integration growth points, date-ascending.
  final List<GrowthPoint> points;

  /// The standout night to badge, or null when none is distinguished.
  final BestNight? best;

  const GrowthCurvePanel({super.key, required this.points, this.best});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (points.isEmpty) {
      return _placeholder();
    }

    // X axis is the day-index (0..n-1); we relabel ticks to calendar dates so a
    // single-night project still plots cleanly without date-arithmetic on the
    // axis. Y axis is cumulative integration HOURS.
    final sorted = [...points]..sort((a, b) => a.date.compareTo(b.date));
    final spots = [
      for (var i = 0; i < sorted.length; i++)
        FlSpot(i.toDouble(), sorted[i].cumulativeHours),
    ];

    final maxHours = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final yMax = maxHours <= 0 ? 1.0 : maxHours * 1.15;
    final lastN = sorted.length - 1;
    final totalHours = sorted.last.cumulativeHours;
    final totalFrames = sorted.last.framesToDate;

    final bestIndex = best == null
        ? -1
        : sorted.indexWhere((p) => _sameDay(p.date, best!.date));

    // The series hue is a NAME, not the colour that gets painted. Red night is
    // a WAVELENGTH constraint, so painting the constant raw put #6B95B8 — a
    // solid blue line, its dots and its area fill — on a card whose every other
    // pixel was red, undoing the dark adaptation the mode exists to protect.
    // Resolved once here so the line, the dots and the fill below cannot drift
    // apart.
    final lineColor = SkotiqChartColors.forTheme(
      SkotiqChartColors.seriesBlue,
      colors,
    );

    return SkotiqPanel(
      child: Padding(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(colors, totalHours: totalHours, totalFrames: totalFrames),
            if (best != null) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              _bestNightBadge(best!),
            ],
            const SizedBox(height: SkotiqTokens.spaceMd),
            AdaptiveChartContainer(
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
                        interval: _axisInterval(sorted.length),
                        getTitlesWidget: (value, meta) {
                          final i = value.round();
                          if (i < 0 || i >= sorted.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(
                              top: SkotiqTokens.spaceSm,
                            ),
                            child: Text(
                              _shortDate(sorted[i].date),
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
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, _, __, ___) {
                          final isBest = spot.x.round() == bestIndex;
                          return FlDotCirclePainter(
                            radius: isBest ? 5 : 3,
                            color: isBest ? colors.success : lineColor,
                            strokeColor: colors.surface,
                            strokeWidth: isBest ? 2 : 1,
                          );
                        },
                      ),
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
                        final date = (i >= 0 && i < sorted.length)
                            ? _shortDate(sorted[i].date)
                            : '';
                        return LineTooltipItem(
                          '$date\n${spot.y.toStringAsFixed(1)}h total',
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
          ],
        ),
      ),
    );
  }

  Widget _header(
    SkotiqColors colors, {
    required double totalHours,
    required int totalFrames,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          SkotiqIcons.activity,
          size: SkotiqTokens.iconSm,
          color: colors.primary,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Project growth',
                style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                '${totalHours.toStringAsFixed(1)}h integrated · '
                '$totalFrames frames across ${points.length} '
                'night${points.length == 1 ? '' : 's'}',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bestNightBadge(BestNight best) {
    return StatusPill(
      icon: SkotiqIcons.star,
      label: 'Best night',
      value: '${_shortDate(best.date)} · '
          '${best.integrationHours.toStringAsFixed(1)}h',
      status: StatusPillStatus.success,
    );
  }

  Widget _placeholder() {
    return const SkotiqPanel(
      child: Padding(
        padding: SkotiqTokens.cardPadding,
        child: AdaptiveChartContainer.fixed(
          height: 170,
          child: EmptyState.compact(
            icon: SkotiqIcons.activity,
            title: 'No multi-night history yet',
            body:
                'Fold tonight\'s data into a master to start the growth curve.',
          ),
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _shortDate(DateTime d) {
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
    final m = months[(d.month - 1).clamp(0, 11)];
    return '$m ${d.day}';
  }

  /// Keep ≤ ~5 date labels on the bottom axis.
  double _axisInterval(int count) {
    if (count <= 5) return 1;
    return (count / 5).ceilToDouble();
  }
}
