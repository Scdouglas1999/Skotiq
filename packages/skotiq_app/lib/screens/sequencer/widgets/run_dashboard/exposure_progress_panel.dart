import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'run_dashboard_format.dart';

/// Compact "this frame" + "this run" progress.
///
/// Reads `exposureProgressProvider` (per-frame, populated by the imaging
/// service) and `sequenceProgressProvider` (overall sequence). It does not
/// duplicate the wide `SequenceProgressBar` widget — that bar sits at the
/// top of the screen on all sequencer tabs; this card adds the per-frame
/// countdown the bar doesn't have room to surface.
class RunDashboardExposureProgress extends ConsumerWidget {
  const RunDashboardExposureProgress({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final exposure = ref.watch(exposureProgressProvider);
    final seq = ref.watch(sequenceProgressProvider);

    final hasFrame = exposure.frameNumber > 0 && exposure.remaining > 0;
    final exposurePct = exposure.percent.clamp(0.0, 100.0) / 100.0;

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.timer, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'EXPOSURE',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                hasFrame
                    ? 'Frame ${exposure.frameNumber}'
                        '${exposure.totalFrames != null ? ' / ${exposure.totalFrames}' : ''}'
                    : 'Idle',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.labelQuiet.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Big remaining-time digit
          Center(
            child: Text(
              hasFrame
                  ? formatSeconds(exposure.remaining)
                  : exposure.isDownloading
                      ? 'Downloading…'
                      : '—',
              style: SkotiqTypography.telemetryLg.copyWith(
                fontWeight: FontWeight.w700,
                color: hasFrame
                    ? colors.primary
                    : exposure.isDownloading
                        ? colors.warning
                        : colors.textMuted,
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),

          // Per-frame progress
          SkotiqProgressBar(
            value: hasFrame ? exposurePct : 0,
            height: 6,
          ),

          const SizedBox(height: SkotiqTokens.spaceLg),
          Divider(height: 1, color: colors.border),
          const SizedBox(height: SkotiqTokens.spaceLg),

          // Overall sequence progress
          Row(
            children: [
              Text(
                'Sequence',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              Text(
                '${seq.completedExposures} / ${seq.totalExposures}',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.labelSm.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: SkotiqDecorations.statusChip(
                  colors.primary,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                  bordered: false,
                ),
                child: Text(
                  '${(seq.progressPercent * 100).toStringAsFixed(0)}%',
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.captionSm.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqProgressBar(
            value: seq.progressPercent.clamp(0.0, 1.0),
            height: 4,
          ),
          if (seq.estimatedRemainingSecs != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Row(
              children: [
                Icon(LucideIcons.hourglass, size: 11, color: colors.textMuted),
                const SizedBox(width: 4),
                Text(
                  '~${formatSeconds(seq.estimatedRemainingSecs!)} remaining',
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.labelQuiet.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
