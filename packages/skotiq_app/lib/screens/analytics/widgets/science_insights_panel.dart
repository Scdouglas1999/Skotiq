import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Plain-language guidance for the current session.
///
/// All rules live in [ScienceInsightsEngine] so the same set drives the
/// Analytics insights panel, the Imaging HUD, and any push notifications
/// we wire up later. The widget itself only renders the result.
class ScienceInsightsPanel extends ConsumerWidget {
  final SkotiqColors colors;
  final ScienceFrameQualityMetricsRow? frameMetrics;
  final FramePhotometricCalibrationRow? latestCalibration;
  final TransparencySampleRow? latestTransparency;
  final OpticalTrainDiagnostics? diagnostics;
  final EquipmentHealthReport? healthReport;

  /// Number of calibrated frames in this session — used by the engine to
  /// surface the "transparency unlocks after N more frames" hint.
  final int calibratedFrameCount;

  /// Processed and solved frame counts so the engine can surface plate-solve
  /// guidance when the rate is low.
  final int processedFrameCount;
  final int solvedFrameCount;

  const ScienceInsightsPanel({
    super.key,
    required this.colors,
    required this.frameMetrics,
    required this.latestCalibration,
    required this.latestTransparency,
    this.diagnostics,
    this.healthReport,
    this.calibratedFrameCount = 0,
    this.processedFrameCount = 0,
    this.solvedFrameCount = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastFailure =
        ref.watch(scienceProcessingStatusProvider).valueOrNull?.lastFailure;

    const engine = ScienceInsightsEngine();
    final insights = engine.evaluate(
      ScienceInsightsInputs(
        latestFrameQuality: frameMetrics,
        latestCalibration: latestCalibration,
        latestTransparency: latestTransparency,
        diagnostics: diagnostics,
        healthReport: healthReport,
        calibratedFrameCount: calibratedFrameCount,
        processedFrameCount: processedFrameCount,
        solvedFrameCount: solvedFrameCount,
        lastFailure: lastFailure,
      ),
    );

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.lightbulb, size: 14, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                'Insights',
                style: SkotiqTypography.bodyStrong
                    .copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              if (insights.isNotEmpty)
                Text(
                  '${insights.length}',
                  style: SkotiqTypography.labelStrongSm.copyWith(
                    color: colors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (insights.isEmpty)
            Text(
              'No actionable insights yet. Keep capturing frames.',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            )
          else
            ...insights.map(
              (insight) => _InsightRow(insight: insight, colors: colors),
            ),
        ],
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  final ScienceInsight insight;
  final SkotiqColors colors;

  const _InsightRow({required this.insight, required this.colors});

  @override
  Widget build(BuildContext context) {
    final accent = _colorFor(insight.severity, colors);
    final icon = _iconFor(insight.severity);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  insight.headline,
                  style: SkotiqTypography.caption.copyWith(
                      color: colors.textPrimary,
                      height: 1.3,
                      fontWeight: FontWeight.w600),
                ),
                if (insight.body != null && insight.body!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      insight.body!,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textSecondary, height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _colorFor(ScienceInsightSeverity s, SkotiqColors c) {
    switch (s) {
      case ScienceInsightSeverity.success:
        return c.success;
      case ScienceInsightSeverity.info:
        return c.info;
      case ScienceInsightSeverity.warning:
        return c.warning;
      case ScienceInsightSeverity.error:
        return c.error;
    }
  }

  static IconData _iconFor(ScienceInsightSeverity s) {
    switch (s) {
      case ScienceInsightSeverity.success:
        return LucideIcons.checkCircle;
      case ScienceInsightSeverity.info:
        return LucideIcons.info;
      case ScienceInsightSeverity.warning:
        return LucideIcons.alertTriangle;
      case ScienceInsightSeverity.error:
        return LucideIcons.alertOctagon;
    }
  }
}
