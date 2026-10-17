import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'glass_card.dart';
import '../../../utils/filter_label.dart';

class SessionProgressCard extends ConsumerWidget {
  final SkotiqColors colors;

  const SessionProgressCard({super.key, required this.colors});

  String _formatIntegrationTime(double seconds) =>
      DurationFormat.of(Duration(seconds: seconds.toInt()),
          style: DurationStyle.hoursMinutes);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionState = ref.watch(sessionStateProvider);
    final progress = ref.watch(sessionProgressProvider);
    final exposureSettings = ref.watch(exposureSettingsProvider);
    final exposureProgress = ref.watch(exposureProgressProvider);

    final isActive = sessionState.isActive;
    final progressValue = progress.clamp(0.0, 1.0);
    final targetName = sessionState.targetName ?? 'No target';

    // Format exposure count
    final exposureText =
        '${sessionState.completedExposures}/${sessionState.totalExposures}';

    // Format integration time
    final integrationText = sessionState.totalIntegrationSecs > 0
        ? _formatIntegrationTime(sessionState.totalIntegrationSecs)
        : '0m';

    // Format elapsed time
    final elapsedText = sessionState.startTime != null
        ? DurationFormat.of(DateTime.now().difference(sessionState.startTime!),
            style: DurationStyle.hoursMinutes)
        : kReadoutUnknown;

    // Calculate remaining time
    String remainingText = kReadoutUnknown;
    if (isActive &&
        progressValue > 0 &&
        progressValue < 1.0 &&
        sessionState.startTime != null) {
      final elapsed = DateTime.now().difference(sessionState.startTime!);
      final estimatedTotal = Duration(
        milliseconds: (elapsed.inMilliseconds / progressValue).round(),
      );
      final remaining = estimatedTotal - elapsed;
      if (remaining.inMilliseconds > 0) {
        remainingText =
            DurationFormat.of(remaining, style: DurationStyle.hoursMinutes);
      }
    }

    // Current exposure info
    final currentExpText =
        '${exposureSettings.exposureTime}s ${filterLabel(exposureSettings.filter)}';

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with target name
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.target,
            title: isActive ? targetName : 'Sequence',
            accent: isActive ? colors.success : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isActive)
                  Text(
                    currentExpText,
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                  ),
                if (isActive) const SizedBox(width: 8),
                DashboardStatusChip(
                  colors: colors,
                  label: isActive ? 'Running' : 'Idle',
                  active: isActive,
                ),
              ],
            ),
          ),

          const SizedBox(height: DashboardCardStyle.headerGap),

          // Progress bar with percentage
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline2),
                  ),
                  child: FractionallySizedBox(
                    widthFactor: progressValue,
                    alignment: Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline2),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(progressValue * 100).toInt()}%',
                style: SkotiqTypography.labelStrongSm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // Current exposure progress row (only show when actively exposing)
          if (exposureProgress.percent > 0 || exposureProgress.isDownloading)
            _ExposureProgressRow(
              progress: exposureProgress,
              exposureTime: exposureSettings.exposureTime,
              colors: colors,
            ),

          if (exposureProgress.percent > 0 || exposureProgress.isDownloading)
            const SizedBox(height: 6),

          // Stats grid - compact layout
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
            decoration: BoxDecoration(
              color: colors.surfaceAlt.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            child: Row(
              children: [
                _CompactStat(label: 'Frm', value: exposureText, colors: colors),
                _CompactStat(
                    label: 'Int', value: integrationText, colors: colors),
                _CompactStat(label: 'Elap', value: elapsedText, colors: colors),
                _CompactStat(
                    label: 'Rem',
                    value: remainingText,
                    colors: colors,
                    highlight: isActive),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows current exposure progress during active capture
class _ExposureProgressRow extends StatelessWidget {
  final ExposureProgress progress;
  final double exposureTime;
  final SkotiqColors colors;

  const _ExposureProgressRow({
    required this.progress,
    required this.exposureTime,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final elapsedText = progress.elapsed.toStringAsFixed(1);
    final totalText = exposureTime.toStringAsFixed(1);
    final progressPercent = (progress.percent / 100).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Row(
        children: [
          Icon(
            progress.isDownloading ? LucideIcons.download : LucideIcons.camera,
            size: 12,
            color: progress.isDownloading ? colors.info : colors.primary,
          ),
          const SizedBox(width: 6),
          Text(
            progress.isDownloading
                ? 'Downloading...'
                : '$elapsedText s / $totalText s',
            style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline2),
              ),
              child: FractionallySizedBox(
                widthFactor: progressPercent,
                alignment: Alignment.centerLeft,
                child: Container(
                  decoration: BoxDecoration(
                    color:
                        progress.isDownloading ? colors.info : colors.primary,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact stat for dense information display
class _CompactStat extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool highlight;

  const _CompactStat({
    required this.label,
    required this.value,
    required this.colors,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: SkotiqTypography.h6.copyWith(
              color: highlight ? colors.primary : colors.textPrimary,
            ),
          ),
          Text(
            label,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// MiniStat used by FocusCard and other cards for compact stat display.
class DashboardMiniStat extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const DashboardMiniStat({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Text(
              value,
              style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
