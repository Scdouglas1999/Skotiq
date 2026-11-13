import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart' show IntegrationCurve;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/adaptive_chart_container.dart';

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

    final curvePoints = [
      for (final p in points) Offset(p.n.toDouble(), p.snr),
    ];
    final kept = [
      for (final p in curvePoints)
        if (p.dx <= keepN) p,
    ];
    final tail = [
      for (final p in curvePoints)
        if (p.dx >= keepN) p,
    ];
    final keepPoint = curvePoints.firstWhere((p) => p.dx == keepN);

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
              child: SkotiqChart(
                semanticLabel: 'Predicted SNR against subs kept: keep $keepN '
                    'of $total',
                series: <ChartSeries>[
                  ChartSeries(
                    points: kept,
                    label: 'Kept',
                    color: SkotiqChartColors.seriesGreen,
                    strokeWidth: 2.5,
                    filled: true,
                  ),
                  ChartSeries(
                    points: tail,
                    label: 'Past the cut',
                    tone: SeriesChartTone.warning,
                    strokeWidth: 2,
                  ),
                  ChartSeries(
                    points: [keepPoint],
                    tone: SeriesChartTone.primary,
                    kind: ChartSeriesKind.scatter,
                    dotRadius: 4,
                  ),
                ],
                x: ChartAxis(
                  min: 1,
                  max: total.toDouble(),
                  format: (n) => '${n.round()}',
                  readout: (n) => 'n=${n.round()}',
                ),
                y: ChartAxis(
                  readout: (snr) => 'SNR ${snr.toStringAsFixed(2)}',
                ),
                rules: [
                  ChartRule.x(
                    keepN.toDouble(),
                    tone: SeriesChartTone.primary,
                    dashed: true,
                    label: 'keep $keepN',
                  ),
                ],
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
}
