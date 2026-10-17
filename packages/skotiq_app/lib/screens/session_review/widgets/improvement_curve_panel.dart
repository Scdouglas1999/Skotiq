import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart' show IntegrationCurve;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../analytics/widgets/adaptive_chart_container.dart';

/// Narrative-view card visualising the marginal-SNR integration curve produced
/// by the native optimizer (`api_analyze_night`).
///
/// Plots predicted integrated SNR against the number of weight-ranked subs kept
/// (`n`), draws a dashed vertical cut marker at the recommended `keepN`, tints
/// the kept prefix vs the dropped tail, and surfaces a "use best N of M" callout
/// with the predicted SNR gain.
///
/// Fed the `IntegrationCurve?` carried on `SessionReviewState.improvementCurve`.
/// A null or empty curve renders a tasteful placeholder rather than an empty
/// chart frame.
class ImprovementCurvePanel extends StatelessWidget {
  /// The predicted integration curve + keep/cull recommendation, or null when
  /// no analysis has run for this scope yet.
  final IntegrationCurve? curve;

  const ImprovementCurvePanel({super.key, required this.curve});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final points = curve?.points ?? const [];

    if (curve == null || points.length < 2) {
      return _placeholder();
    }

    final total = points.length;
    final rec = curve!.recommendation;
    // Clamp the recommended cut into the plotted domain so the marker is always
    // on-chart even if a forward-migrated payload over/under-shoots.
    final keepN = rec.keepN.clamp(1, total);
    final gainPct = rec.predictedSnrGainPct;

    final spots = [
      for (final p in points) FlSpot(p.n.toDouble(), p.snr),
    ];

    // Kept prefix (1..keepN) and dropped tail (keepN..N) as two segments so the
    // area fill can be tinted by region. The tail repeats the boundary spot so
    // the line stays continuous across the cut.
    final keptSpots = spots.where((s) => s.x <= keepN).toList(growable: false);
    final tailSpots = spots.where((s) => s.x >= keepN).toList(growable: false);

    final snrValues = points.map((p) => p.snr).toList(growable: false);
    final minSnr = snrValues.reduce((a, b) => a < b ? a : b);
    final maxSnr = snrValues.reduce((a, b) => a > b ? a : b);
    final snrRange = (maxSnr - minSnr).abs() < 1e-6 ? 1.0 : maxSnr - minSnr;

    // Snap the Y axis to a "nice" interval so the left-axis labels are evenly
    // spaced and never collide at the top: fl_chart draws a label at maxY *and*
    // at every interval step, so an interval that doesn't divide the range
    // lands a step-label fractionally below maxY (the original overlap bug).
    // Rounding minY/maxY to multiples of a nice step makes the top step-label
    // coincide exactly with maxY — one label, not two stacked.
    final yInterval = _niceInterval(snrRange);
    final minY = (minSnr / yInterval).floorToDouble() * yInterval;
    var maxY = (maxSnr / yInterval).ceilToDouble() * yInterval;
    // Guarantee a little headroom above the peak so the curve never touches the
    // frame and the top label keeps clear air around it.
    if (maxY - maxSnr < yInterval * 0.05) maxY += yInterval;

    final keptColor = colors.success;
    final tailColor = colors.warning;

    return SkotiqPanel(
      child: Padding(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(colors, keepN, total),
            const SizedBox(height: SkotiqTokens.spaceMd),
            AdaptiveChartContainer(
              preferredHeight: 170,
              child: LineChart(
                LineChartData(
                  minX: 1,
                  maxX: total.toDouble(),
                  minY: minY,
                  maxY: maxY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    horizontalInterval: yInterval,
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
                        interval: _axisInterval(total),
                        getTitlesWidget: (value, meta) => Padding(
                          padding: const EdgeInsets.only(
                            top: SkotiqTokens.spaceSm,
                          ),
                          child: Text(
                            value.toInt().toString(),
                            style: SkotiqTypography.captionSm.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        interval: yInterval,
                        getTitlesWidget: (value, meta) => Text(
                          value.toStringAsFixed(_yLabelDecimals(yInterval)),
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
                  extraLinesData: ExtraLinesData(
                    verticalLines: [
                      VerticalLine(
                        x: keepN.toDouble(),
                        color: colors.primary,
                        strokeWidth: 1.5,
                        dashArray: const [4, 4],
                        label: VerticalLineLabel(
                          show: true,
                          alignment: Alignment.topRight,
                          padding: const EdgeInsets.only(
                            left: SkotiqTokens.spaceXs,
                            bottom: SkotiqTokens.spaceXs,
                          ),
                          style: SkotiqTypography.captionSm.copyWith(
                            color: colors.primary,
                          ),
                          labelResolver: (_) => 'keep $keepN',
                        ),
                      ),
                    ],
                  ),
                  lineBarsData: [
                    // Kept prefix — green, filled.
                    LineChartBarData(
                      spots: keptSpots,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      color: keptColor,
                      barWidth: 2.5,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: true,
                        checkToShowDot: (spot, _) => spot.x == keepN.toDouble(),
                        getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                          radius: 4,
                          color: colors.primary,
                          strokeColor: colors.surface,
                          strokeWidth: 2,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: keptColor.withValues(alpha: 0.12),
                      ),
                    ),
                    // Dropped tail — amber, lighter, no end dots.
                    LineChartBarData(
                      spots: tailSpots,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      color: tailColor.withValues(alpha: 0.7),
                      barWidth: 2,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: tailColor.withValues(alpha: 0.08),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => colors.surface,
                      getTooltipItems: (touchedSpots) => touchedSpots
                          .map(
                            (spot) => LineTooltipItem(
                              'n=${spot.x.toInt()}\nSNR ${spot.y.toStringAsFixed(2)}',
                              SkotiqTypography.labelQuiet.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            _callout(colors, keepN: keepN, total: total, gainPct: gainPct),
          ],
        ),
      ),
    );
  }

  Widget _header(SkotiqColors colors, int keepN, int total) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          SkotiqIcons.chart,
          size: SkotiqTokens.iconSm,
          color: colors.primary,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Integration improvement',
                style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                'Predicted SNR vs subs kept (weight-ranked)',
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

  /// "Use best {keepN} of {N} (+{gain}%)" pill.
  Widget _callout(
    SkotiqColors colors, {
    required int keepN,
    required int total,
    required double gainPct,
  }) {
    final gainLabel = gainPct >= 0.05
        ? '+${gainPct.toStringAsFixed(gainPct >= 10 ? 0 : 1)}% SNR'
        : 'no SNR cost';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.success.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            SkotiqIcons.sparkle,
            size: SkotiqTokens.iconSm,
            color: colors.success,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textPrimary,
                ),
                children: [
                  const TextSpan(text: 'Use best '),
                  TextSpan(
                    text: '$keepN',
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: colors.success,
                    ),
                  ),
                  TextSpan(text: ' of $total subs  ·  '),
                  TextSpan(
                    text: gainLabel,
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: colors.success,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() {
    return const SkotiqPanel(
      child: Padding(
        padding: SkotiqTokens.cardPadding,
        child: AdaptiveChartContainer.fixed(
          height: 170,
          child: EmptyState.compact(
            icon: SkotiqIcons.chart,
            title: 'Improvement curve pending',
            body: 'Run night analysis to predict the optimal subs to keep.',
          ),
        ),
      ),
    );
  }

  /// Keep ≤ ~6 bottom-axis labels regardless of sub count.
  double _axisInterval(int total) {
    if (total <= 6) return 1;
    return (total / 6).ceilToDouble();
  }

  /// A "nice" Y-axis step (1/2/2.5/5 × a power of ten) sized to yield ~5 evenly
  /// spaced SNR labels across [range]. Snapping the axis to a multiple of this
  /// keeps the labels collision-free at the top of the chart.
  double _niceInterval(double range, {int targetTicks = 5}) {
    final raw = range / targetTicks;
    final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()) * 1.0;
    final normalized = raw / magnitude; // in [1, 10)
    final double step;
    if (normalized <= 1) {
      step = 1;
    } else if (normalized <= 2) {
      step = 2;
    } else if (normalized <= 2.5) {
      step = 2.5;
    } else if (normalized <= 5) {
      step = 5;
    } else {
      step = 10;
    }
    return step * magnitude;
  }

  /// One decimal place for sub-unit steps (e.g. 0.5), none for whole steps, so
  /// labels read cleanly ("20", "40" not "20.0").
  int _yLabelDecimals(double interval) => interval < 1 ? 1 : 0;
}
