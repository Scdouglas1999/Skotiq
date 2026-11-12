import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Dialog for quick session resumption on app startup.
///
/// Shows when a previous imaging session is available and offers three options:
/// - Start Fresh: loads profile, target, sequence but resets to frame 1
/// - Resume Progress: continues from where the sequence left off
/// - Skip: dismisses and goes to normal dashboard
class QuickStartDialog extends ConsumerWidget {
  final QuickStartContext quickStartContext;
  final VoidCallback onStartFresh;
  final VoidCallback onResumeProgress;
  final VoidCallback onSkip;

  const QuickStartDialog({
    super.key,
    required this.quickStartContext,
    required this.onStartFresh,
    required this.onResumeProgress,
    required this.onSkip,
  });

  static Future<void> show(
    BuildContext buildContext, {
    required QuickStartContext quickStartContext,
    required VoidCallback onStartFresh,
    required VoidCallback onResumeProgress,
    required VoidCallback onSkip,
  }) {
    return showDialog(
      context: buildContext,
      barrierDismissible: true,
      builder: (ctx) => QuickStartDialog(
        quickStartContext: quickStartContext,
        onStartFresh: () {
          Navigator.of(ctx).pop();
          onStartFresh();
        },
        onResumeProgress: () {
          Navigator.of(ctx).pop();
          onResumeProgress();
        },
        onSkip: () {
          Navigator.of(ctx).pop();
          onSkip();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final colors = SkotiqColors.of(buildContext);
    final theme = Theme.of(buildContext);

    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXl),
        side: BorderSide(color: colors.primary.withValues(alpha: 0.3)),
      ),
      title: _buildTitle(colors, theme),
      content: ConstrainedBox(
        constraints: Responsive.dialogConstraints(
          buildContext,
          preferredWidth: 560,
          preferredHeight: 480,
          minWidth: 400,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSessionCard(colors, theme),
              const SizedBox(height: SkotiqTokens.spaceLg),
              _buildEquipmentSettingsCard(colors, theme),
              const SizedBox(height: SkotiqTokens.spaceXl),
              _buildProgressInfo(colors, theme),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceSm,
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceLg,
      ),
      actions: [
        _buildActions(buildContext, colors),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    // Calendar days apart, not elapsed hours. `Duration.inDays` truncates, so a
    // session that ended at 14:57 yesterday is 19 h old when the app opens at
    // 10:00 the next morning and reported `inDays == 0` — the dialog dated
    // yesterday's session as "Today at 14:57". Anything a week old or more (or
    // stamped in the future by a clock jump) gets an explicit date instead of a
    // relative phrase that would be guessing.
    final days =
        DateUtils.dateOnly(now).difference(DateUtils.dateOnly(dt)).inDays;

    if (days == 0) {
      return 'Today at ${ClockFormat.hm(dt)}';
    } else if (days == 1) {
      return 'Yesterday at ${ClockFormat.hm(dt)}';
    } else if (days > 1 && days < 7) {
      return '$days days ago at ${ClockFormat.hm(dt)}';
    } else {
      return '${ClockFormat.date(dt)} at ${ClockFormat.hm(dt)}';
    }
  }

  Widget _buildTitle(SkotiqColors colors, ThemeData theme) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: SkotiqDecorations.tintedBadge(
            colors.primary,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          ),
          child: Icon(
            LucideIcons.play,
            color: colors.primary,
            size: SkotiqTokens.iconLg,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Continue Session',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${quickStartContext.stoppedByOperator ? 'You stopped it' : 'Interrupted'}'
                ' · ${_formatDate(quickStartContext.lastSessionDate)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(LucideIcons.x, color: colors.textMuted, size: 20),
          onPressed: onSkip,
          tooltip: 'Skip',
          style: IconButton.styleFrom(
            padding: const EdgeInsets.all(8),
          ),
        ),
      ],
    );
  }

  Widget _buildSessionCard(SkotiqColors colors, ThemeData theme) {
    final targetDisplay = quickStartContext.targetName ??
        quickStartContext.sessionName ??
        'Session #${quickStartContext.sessionId}';
    final profileDisplay = quickStartContext.profileName ?? 'Unknown Profile';
    final sequenceDisplay = quickStartContext.sequenceName ?? 'No Sequence';

    return SkotiqCard(
      variant: CardVariant.elevated,
      padding: SkotiqTokens.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.target,
                color: colors.primary,
                size: SkotiqTokens.iconMd,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  targetDisplay,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          const Divider(height: 1),
          const SizedBox(height: SkotiqTokens.spaceMd),

          _SessionDetailRow(
            icon: LucideIcons.settings2,
            label: 'Equipment profile',
            value: profileDisplay,
            colors: colors,
            theme: theme,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _SessionDetailRow(
            icon: LucideIcons.listOrdered,
            label: 'Sequence',
            value: sequenceDisplay,
            colors: colors,
            theme: theme,
          ),
        ],
      ),
    );
  }

  Widget _buildEquipmentSettingsCard(SkotiqColors colors, ThemeData theme) {
    final snapshot = quickStartContext.equipmentSnapshot;
    if (snapshot == null || !snapshot.hasEquipmentData) {
      return const SizedBox.shrink();
    }

    return SkotiqCard(
      variant: CardVariant.standard,
      padding: SkotiqTokens.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.wrench,
                color: colors.textSecondary,
                size: SkotiqTokens.iconSm,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Settings it used',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              if (snapshot.coolerTargetTemp != null)
                _EquipmentChip(
                  icon: LucideIcons.thermometer,
                  label: 'Cooler '
                      '${snapshot.coolerTargetTemp!.toStringAsFixed(0)}\u00B0C',
                  colors: colors,
                ),
              if (snapshot.cameraGain != null)
                _EquipmentChip(
                  icon: LucideIcons.sliders,
                  label: 'Gain: ${snapshot.cameraGain}',
                  colors: colors,
                ),
              if (snapshot.cameraOffset != null)
                _EquipmentChip(
                  icon: LucideIcons.sliders,
                  label: 'Offset: ${snapshot.cameraOffset}',
                  colors: colors,
                ),
              if (snapshot.filterPosition != null)
                _EquipmentChip(
                  icon: LucideIcons.aperture,
                  label: snapshot.filterName ??
                      'Filter slot ${snapshot.filterPosition! + 1}',
                  colors: colors,
                ),
              if (snapshot.focuserPosition != null)
                _EquipmentChip(
                  icon: LucideIcons.focus,
                  label: '${snapshot.focuserPosition} steps',
                  colors: colors,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressInfo(SkotiqColors colors, ThemeData theme) {
    final frames = quickStartContext.completedFrames;
    final total = quickStartContext.totalFrames;
    final integration = quickStartContext.totalIntegrationHours;

    String progressText;
    if (frames > 0 && total > 0) {
      progressText =
          '$frames/$total frames captured, ${DurationFormat.seconds(integration * 3600)} integration';
    } else if (frames > 0) {
      progressText =
          '$frames frames captured, ${DurationFormat.seconds(integration * 3600)} integration';
    } else if (integration > 0) {
      progressText = '${DurationFormat.seconds(integration * 3600)} integration';
    } else {
      progressText = 'No progress yet';
    }

    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.image,
            color: colors.primary,
            size: SkotiqTokens.iconMd,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Progress',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  progressText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Whether "Load Previous Setup" has anything at all to load.
  ///
  /// The restore path can only re-activate an equipment profile, re-open a
  /// sequence, and re-apply the recorded camera/filter/focuser settings. A
  /// session that recorded none of those — which is exactly the session this
  /// dialog is already describing as "Unknown Profile" / "No Sequence" two rows
  /// above the button — leaves the action nothing to do, so it is offered as
  /// disabled with the reason rather than closing the dialog and reporting
  /// success.
  bool get _hasRestorableSetup =>
      quickStartContext.profileId != null ||
      quickStartContext.sequenceId != null ||
      quickStartContext.equipmentSnapshot?.hasEquipmentData == true;

  Widget _buildActions(BuildContext buildContext, SkotiqColors colors) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Only advertise an execution resume when the backend confirms a
        // matching, resumable checkpoint. Historical frame totals alone do
        // not let Skotiq continue a partially executed node tree.
        if (quickStartContext.canResumeFromCheckpoint)
          Row(
            children: [
              Expanded(
                child: SkotiqButton(
                  label: 'Start fresh',
                  icon: LucideIcons.refreshCw,
                  variant: ButtonVariant.outline,
                  size: ButtonSize.large,
                  onPressed: onStartFresh,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: SkotiqButton(
                  label: 'Restore progress',
                  icon: LucideIcons.play,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.large,
                  onPressed: onResumeProgress,
                ),
              ),
            ],
          ),
        if (quickStartContext.canResumeFromCheckpoint) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Start fresh loads the plan and its settings from the first step. '
            'Restore progress picks up where the run ended and waits for '
            'Start. Skip changes nothing.',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            textAlign: TextAlign.center,
          ),
        ] else if (_hasRestorableSetup)
          SkotiqButton(
            label: 'Load Previous Setup',
            icon: LucideIcons.history,
            variant: ButtonVariant.primary,
            size: ButtonSize.large,
            onPressed: onStartFresh,
          )
        else ...[
          const SkotiqButton(
            label: 'Load Previous Setup',
            icon: LucideIcons.history,
            variant: ButtonVariant.primary,
            size: ButtonSize.large,
            onPressed: null,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Nothing to load: that session recorded no equipment profile, '
            'no sequence and no camera settings.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: colors.textMuted,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceMd),
        Center(
          child: SkotiqButton(
            onPressed: onSkip,
            label: 'Skip',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
        ),
      ],
    );
  }
}

class _SessionDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;
  final ThemeData theme;

  const _SessionDetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          color: colors.textMuted,
          size: SkotiqTokens.iconSm,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _EquipmentChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;

  const _EquipmentChip({
    required this.icon,
    required this.label,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(
          color: colors.border.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: SkotiqTokens.iconXs,
            color: colors.textSecondary,
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize13,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
