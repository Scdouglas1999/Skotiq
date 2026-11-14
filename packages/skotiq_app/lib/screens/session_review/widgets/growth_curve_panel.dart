import 'package:flutter/material.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/adaptive_chart_container.dart';
import '../session_review_controller.dart' show ReviewBestNight, GrowthPoint;

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
  final ReviewBestNight? best;

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
    final growth = [
      for (var i = 0; i < sorted.length; i++)
        Offset(i.toDouble(), sorted[i].cumulativeHours),
    ];
    final totalHours = sorted.last.cumulativeHours;
    final totalFrames = sorted.last.framesToDate;

    final bestIndex = best == null
        ? -1
        : sorted.indexWhere((p) => _sameDay(p.date, best!.date));

    String night(double x) {
      final i = x.round();
      return i >= 0 && i < sorted.length
          ? ClockFormat.monthDay(sorted[i].date)
          : '';
    }

    String hours(double value) =>
        '${value.toStringAsFixed(value >= 10 ? 0 : 1)}h';

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
              child: SkotiqChart(
                semanticLabel: 'Project growth: ${hours(totalHours)} over '
                    '${sorted.length} night${sorted.length == 1 ? '' : 's'}',
                series: <ChartSeries>[
                  ChartSeries(
                    points: growth,
                    label: 'Total',
                    color: SkotiqChartColors.seriesBlue,
                    strokeWidth: 2.5,
                    filled: true,
                  ),
                  ChartSeries(
                    points: growth,
                    color: SkotiqChartColors.seriesBlue,
                    kind: ChartSeriesKind.scatter,
                    dotRadius: 3,
                  ),
                  if (bestIndex >= 0)
                    ChartSeries(
                      points: [growth[bestIndex]],
                      label: 'Best night',
                      color: SkotiqChartColors.seriesGreen,
                      kind: ChartSeriesKind.scatter,
                      dotRadius: 5,
                    ),
                ],
                x: ChartAxis(
                  min: 0,
                  max: (sorted.length - 1).toDouble(),
                  ticks: [
                    for (var i = 0;
                        i < sorted.length;
                        i += _axisInterval(sorted.length))
                      i.toDouble(),
                  ],
                  format: night,
                  readout: night,
                ),
                y: ChartAxis(
                  includeZero: true,
                  format: hours,
                  readout: (value) => '${value.toStringAsFixed(1)}h total',
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

  Widget _bestNightBadge(ReviewBestNight best) {
    return StatusPill(
      icon: SkotiqIcons.star,
      label: 'Best night',
      value: '${ClockFormat.monthDay(best.date)} · '
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

  /// Keep ≤ ~5 date labels on the bottom axis.
  int _axisInterval(int count) => count <= 5 ? 1 : (count / 5).ceil();
}
