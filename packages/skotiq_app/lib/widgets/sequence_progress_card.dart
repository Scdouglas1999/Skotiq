import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Mobile-optimized sequence progress card
class SequenceProgressCard extends ConsumerWidget {
  const SequenceProgressCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(sequenceProgressProvider);
    final colors = SkotiqColors.of(context);

    final surfaceColor = colors.surface;
    final borderColor = colors.border;
    final textColor = colors.textPrimary;
    final textSecondary = colors.textSecondary;
    final primaryColor = colors.primary;

    // Don't show card if sequence is idle
    if (progress.state == SequenceExecutionState.idle) {
      return const SizedBox.shrink();
    }

    final progressPercent = progress.progressPercent;
    final estimatedRemaining = progress.estimatedRemainingSecs;

    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with status
          Row(
            children: [
              // Status indicator
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _getStatusColor(
                    progress.state,
                    colors,
                    primaryColor,
                    textSecondary,
                  ),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _getStatusText(progress.state),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const Spacer(),
              // Overall progress percentage
              Text(
                '${(progressPercent * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: primaryColor,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Target and node info
          if (progress.currentTarget != null) ...[
            Row(
              children: [
                Icon(Icons.location_on, size: 16, color: textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    progress.currentTarget!,
                    style: TextStyle(
                      fontSize: 13,
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],

          if (progress.currentNodeName != null) ...[
            Row(
              children: [
                Icon(Icons.play_circle_outline, size: 16, color: textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    progress.currentNodeName!,
                    style: TextStyle(
                      fontSize: 12,
                      color: textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            child: LinearProgressIndicator(
              value: progressPercent,
              backgroundColor: borderColor.withValues(alpha: 0.3),
              color: primaryColor,
              minHeight: 6,
            ),
          ),

          const SizedBox(height: 12),

          // Exposure info
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Completed exposures
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Frames',
                    style: TextStyle(
                      fontSize: 10,
                      color: textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${progress.completedExposures}/${progress.totalExposures}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ],
              ),

              // Integration time
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'Integration',
                    style: TextStyle(
                      fontSize: 10,
                      color: textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    DurationFormat.seconds(progress.completedIntegrationSecs,
                        style: DurationStyle.hoursMinutes),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ],
              ),

              // Time remaining
              if (estimatedRemaining != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Remaining',
                      style: TextStyle(
                        fontSize: 10,
                        color: textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DurationFormat.seconds(estimatedRemaining,
                          style: DurationStyle.hoursMinutes),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // Current filter
          if (progress.currentFilter != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.filter_alt, size: 14, color: textSecondary),
                const SizedBox(width: 6),
                Text(
                  progress.currentFilter!,
                  style: TextStyle(
                    fontSize: 11,
                    color: textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ],

          // Status message
          if (progress.message != null && progress.message!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: borderColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
              child: Text(
                progress.message!,
                style: TextStyle(
                  fontSize: 11,
                  color: textSecondary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _getStatusColor(
    SequenceExecutionState state,
    SkotiqColors? colors,
    Color primaryColor,
    Color mutedColor,
  ) {
    switch (state) {
      case SequenceExecutionState.idle:
        return colors?.textMuted ?? mutedColor;
      case SequenceExecutionState.running:
        return colors?.success ?? primaryColor;
      case SequenceExecutionState.paused:
        return colors?.warning ?? primaryColor;
      case SequenceExecutionState.stopping:
        return colors?.error ?? primaryColor;
      case SequenceExecutionState.completed:
        return colors?.info ?? primaryColor;
      case SequenceExecutionState.failed:
        return colors?.error ?? primaryColor;
      case SequenceExecutionState.recovering:
        // Recovery shares the error palette so the progress
        // card and the recovery banner agree visually.
        return colors?.error ?? primaryColor;
      case SequenceExecutionState.stopFailed:
        // Native stop failed — hardware may still be imaging. Error palette.
        return colors?.error ?? primaryColor;
      case SequenceExecutionState.cleanupFailed:
        // Hardware stopped; session save failed and needs a retry.
        return colors?.warning ?? primaryColor;
      case SequenceExecutionState.finalizing:
        // Run ended, durable cleanup wrapping up — calm, transient.
        return colors?.info ?? primaryColor;
    }
  }

  String _getStatusText(SequenceExecutionState state) {
    switch (state) {
      case SequenceExecutionState.idle:
        return 'Idle';
      case SequenceExecutionState.running:
        return 'Running';
      case SequenceExecutionState.paused:
        return 'Paused';
      case SequenceExecutionState.stopping:
        return 'Stopping';
      case SequenceExecutionState.completed:
        return 'Completed';
      case SequenceExecutionState.failed:
        return 'Failed';
      case SequenceExecutionState.recovering:
        return 'Recovering';
      case SequenceExecutionState.stopFailed:
        return 'Stop failed';
      case SequenceExecutionState.cleanupFailed:
        return 'Cleanup failed';
      case SequenceExecutionState.finalizing:
        return 'Finalizing';
    }
  }
}
