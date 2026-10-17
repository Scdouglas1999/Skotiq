import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Dialog to prompt user to resume from a checkpoint
class CheckpointResumeDialog extends StatelessWidget {
  final CheckpointInfo checkpointInfo;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  const CheckpointResumeDialog({
    super.key,
    required this.checkpointInfo,
    required this.onResume,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final timeAgo = _formatTimeAgo(checkpointInfo.ageSeconds);

    // Format integration time
    final integrationMins = checkpointInfo.completedIntegrationSecs / 60.0;
    final integrationText = integrationMins < 60
        ? '${integrationMins.toStringAsFixed(1)} min'
        : '${(integrationMins / 60).toStringAsFixed(1)} hr';

    return SkotiqDialog(
      title: 'Resume Sequence?',
      icon: LucideIcons.rotateCcw,
      width: 420,
      actions: [
        SkotiqButton(
          onPressed: onDiscard,
          label: 'Discard',
          variant: ButtonVariant.destructive,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: onResume,
          label: 'Resume',
          icon: LucideIcons.play,
          size: ButtonSize.small,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'An interrupted sequence was found. Would you like to resume where you left off?',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          _buildInfoCard(
            context,
            checkpointInfo: checkpointInfo,
            timeAgo: timeAgo,
            integrationText: integrationText,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context, {
    required CheckpointInfo checkpointInfo,
    required String timeAgo,
    required String integrationText,
  }) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sequence name
          Row(
            children: [
              Icon(Icons.science, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  checkpointInfo.sequenceName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Progress stats
          _buildStatRow(
            context,
            icon: Icons.camera_alt,
            label: 'Completed',
            value: '${checkpointInfo.completedExposures} exposures',
          ),
          const SizedBox(height: 8),
          _buildStatRow(
            context,
            icon: Icons.timer,
            label: 'Integration',
            value: integrationText,
          ),
          const SizedBox(height: 8),
          _buildStatRow(
            context,
            icon: Icons.access_time,
            label: 'Interrupted',
            value: timeAgo,
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);

    return Row(
      children: [
        Icon(icon, size: 16, color: colors.textSecondary),
        const SizedBox(width: 8),
        Text(
          '$label:',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  String _formatTimeAgo(int seconds) {
    if (seconds < 60) {
      return 'Just now';
    } else if (seconds < 3600) {
      final mins = seconds ~/ 60;
      return '$mins ${mins == 1 ? 'minute' : 'minutes'} ago';
    } else if (seconds < 86400) {
      final hours = seconds ~/ 3600;
      return '$hours ${hours == 1 ? 'hour' : 'hours'} ago';
    } else {
      final days = seconds ~/ 86400;
      return '$days ${days == 1 ? 'day' : 'days'} ago';
    }
  }

  /// Show the checkpoint resume dialog
  static Future<bool?> show(
    BuildContext context,
    CheckpointInfo checkpointInfo,
  ) async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CheckpointResumeDialog(
        checkpointInfo: checkpointInfo,
        onResume: () => Navigator.of(context).pop(true),
        onDiscard: () => Navigator.of(context).pop(false),
      ),
    );
  }
}
