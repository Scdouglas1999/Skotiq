import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// One row of the Scheduler screen's target queue table.
///
/// Renders the target name, current score, status (eligible, below
/// horizon, wrong side of meridian, time-windowed, etc.), and a compact
/// summary of per-filter remaining frames. Tapping the row fires
/// [onTap] which the screen uses to open the per-target constraints
/// editor and integration goals editor.
class TargetScoreRow extends StatelessWidget {
  final TargetScore score;
  final List<IntegrationGoalProgress> progress;
  final bool isCurrent;
  final bool isWinner;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const TargetScoreRow({
    super.key,
    required this.score,
    required this.progress,
    required this.isCurrent,
    required this.isWinner,
    this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final eligible = !score.hardConstraintFailed;
    final statusLabel = _statusLabel();
    final statusColor = _statusColor(colors);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceLg,
            vertical: SkotiqTokens.spaceMd,
          ),
          decoration: BoxDecoration(
            color: isCurrent
                ? colors.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: isCurrent
                  ? colors.primary.withValues(alpha: 0.35)
                  : colors.border.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              // Trophy / current-target marker (38 px wide for alignment).
              SizedBox(
                width: 38,
                child: Center(
                  child: isWinner
                      ? Icon(
                          LucideIcons.trophy,
                          size: SkotiqTokens.iconSm,
                          color: colors.warning,
                          semanticLabel: 'Winning target',
                        )
                      : isCurrent
                          ? Icon(
                              LucideIcons.play,
                              size: SkotiqTokens.iconSm,
                              color: colors.primary,
                              semanticLabel: 'Currently active target',
                            )
                          : const SizedBox.shrink(),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              // Target name and rejection reasons (if any).
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      score.targetName,
                      style: SkotiqTypography.bodyStrong.copyWith(
                        color: eligible ? colors.textPrimary : colors.textMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    if (!eligible && score.rejectionReasons.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        score.rejectionReasons.first,
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.error),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              // Score (right-aligned, monospace-ish for column scanning).
              SizedBox(
                width: 78,
                child: Text(
                  score.totalScore.toStringAsFixed(3),
                  textAlign: TextAlign.right,
                  style: SkotiqTypography.bodyStrong.copyWith(
                      color: eligible ? colors.textPrimary : colors.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              // Status pill.
              SizedBox(
                width: 130,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _StatusPill(
                    label: statusLabel,
                    color: statusColor,
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              // Per-filter remaining frames summary.
              Expanded(
                flex: 4,
                child: _GoalSummary(progress: progress, colors: colors),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: SkotiqTokens.spaceSm),
                SkotiqIconButton(
                  key: ValueKey('scheduler-delete-row-${score.targetId}'),
                  icon: LucideIcons.x,
                  tooltip: 'Remove ${score.targetName} from scheduler',
                  size: IconButtonSize.sm,
                  onPressed: onDelete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Render the reason the engine gave; do not re-interpret it here. The reason
  /// ladder lives once, in skotiq_core's `rejection_labels.dart` — a second
  /// copy in this file wins on screen and contradicts the sentence beside it.
  /// `target_score_row_status_test.dart` fails if one reappears.
  String _statusLabel() {
    if (score.hardConstraintFailed) {
      if (score.rejectionReasons.isEmpty) return 'Rejected';
      return schedulerRejectionChipLabel(score.rejectionReasons.first);
    }
    if (isCurrent) return 'Active';
    if (isWinner) return 'Selected';
    return 'Eligible';
  }

  Color _statusColor(SkotiqColors colors) {
    if (score.hardConstraintFailed) return colors.error;
    if (isCurrent) return colors.primary;
    if (isWinner) return colors.success;
    return colors.textSecondary;
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    // The chip's own fill IS its boundary in this language (05 §10), so this
    // uses the shared chip decoration rather than a hand-rolled tint + border.
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: 3,
      ),
      decoration: SkotiqDecorations.chip(
        SkotiqColors.of(context),
        tone: color,
      ),
      // Flexible, not a bare Text: `eyebrow` carries +0.7 tracking, which is
      // enough to push some labels past the 130px column the row gives this
      // slot. Ellipsising is the row's job, not an overflow stripe's.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              style: SkotiqTypography.eyebrow.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _GoalSummary extends StatelessWidget {
  final List<IntegrationGoalProgress> progress;
  final SkotiqColors colors;

  const _GoalSummary({required this.progress, required this.colors});

  @override
  Widget build(BuildContext context) {
    if (progress.isEmpty) {
      return Text(
        'No integration goals',
        style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final p in progress)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: p.isComplete
                  ? colors.success.withValues(alpha: 0.12)
                  : colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              border: Border.all(
                color: p.isComplete
                    ? colors.success.withValues(alpha: 0.4)
                    : colors.border,
              ),
            ),
            child: Text(
              '${p.goal.filter} ${p.capturedCount}/${p.goal.frameCount}',
              style: SkotiqTypography.caption.copyWith(
                  color: p.isComplete ? colors.success : colors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }
}
