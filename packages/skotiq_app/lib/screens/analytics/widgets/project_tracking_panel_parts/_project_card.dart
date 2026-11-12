// Enhanced project card, metric chips, filter breakdown and loading skeleton.
part of '../project_tracking_panel.dart';

class _EnhancedProjectCard extends ConsumerWidget {
  final ProjectProgress progress;

  const _EnhancedProjectCard({required this.progress});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final completionPct = progress.completionFraction * 100.0;
    final l10n = context.l10n;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: progress.isCompleted
                      ? colors.success
                      : progress.isTracked
                          ? colors.primary
                          : colors.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      progress.target.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.sectionTitle
                          .copyWith(color: colors.textPrimary),
                    ),
                    if (progress.target.catalogId != null ||
                        progress.target.objectType != null)
                      Text(
                        progress.target.catalogId ??
                            progress.target.objectType ??
                            '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textSecondary),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => CampaignRollupDialog.show(
                  context,
                  progress.target.id,
                ),
                icon: const Icon(LucideIcons.lineChart, size: 14),
                label: const Text(
                  'View Campaign',
                  style: SkotiqTypography.caption,
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () => showIntegrationGoalsDialog(
                  context,
                  ref,
                  targetId: progress.target.id,
                  targetName: progress.target.name,
                ),
                icon: const Icon(LucideIcons.target, size: 14),
                label: Text(
                  progress.isTracked
                      ? l10n.text('analyticsEditGoal')
                      : l10n.text('analyticsSetGoal'),
                  style: SkotiqTypography.caption,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (progress.isTracked) ...[
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
                    child: LinearProgressIndicator(
                      value: progress.completionFraction,
                      minHeight: 10,
                      backgroundColor: colors.well,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        progress.isCompleted ? colors.success : colors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${completionPct.toStringAsFixed(0)}%',
                  style: SkotiqTypography.bodySm.copyWith(
                      color: progress.isCompleted
                          ? colors.success
                          : colors.textPrimary,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _MetricChip(
                icon: LucideIcons.timer,
                label: 'Integrated',
                value: DurationFormat.decimalHours(progress.integratedSecs),
                colors: colors,
              ),
              _MetricChip(
                icon: LucideIcons.target,
                label: progress.goal.allFilters ? 'Goal (all filters)' : 'Goal',
                value: progress.isTracked
                    ? DurationFormat.decimalHours(progress.goalIntegrationSecs)
                    : 'Not set',
                colors: colors,
              ),
              _MetricChip(
                icon: LucideIcons.hourglass,
                label: 'Remaining',
                value: progress.isTracked
                    ? DurationFormat.decimalHours(progress.remainingSecs)
                    : kReadoutUnknown,
                colors: colors,
              ),
              _MetricChip(
                icon: LucideIcons.layers,
                label: 'Sessions',
                value: '${progress.sessionCount}',
                colors: colors,
              ),
              _MetricChip(
                icon: LucideIcons.image,
                label: 'Frames accepted',
                value: '${progress.acceptedFrames}',
                colors: colors,
              ),
            ],
          ),
          if (progress.filters.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FilterBreakdownRow(
              filters: progress.filters,
              colors: colors,
            ),
          ],
          if (progress.lastImagedAt case final lastImagedAt?) ...[
            const SizedBox(height: 10),
            Text(
              'Last imaged: ${ClockFormat.monthDayYearHm(lastImagedAt.toLocal())}',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;

  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: colors.textMuted),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
            Text(
              value,
              style: SkotiqTypography.labelStrong.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _FilterBreakdownRow extends StatelessWidget {
  final List<FilterIntegration> filters;
  final SkotiqColors colors;

  const _FilterBreakdownRow({
    required this.filters,
    required this.colors,
  });

  Color _filterColor(String filterName) =>
      FilterColors.forName(filterName, colors: colors);

  @override
  Widget build(BuildContext context) {
    final sortedEntries = [...filters]
      ..sort((a, b) => b.seconds.compareTo(a.seconds));

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: sortedEntries.map((entry) {
        final color = _filterColor(entry.filter);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: SkotiqDecorations.chip(colors, tone: color),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${entry.filter}: '
                '${DurationFormat.decimalHours(entry.seconds)}',
                style: SkotiqTypography.labelStrongSm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// Skeleton placeholder for the project list while progress data loads.
/// Renders card-shaped shimmer rows that match the production tile height
/// so the layout doesn't shift when the data resolves.
class _ProjectsLoadingSkeleton extends StatelessWidget {
  final SkotiqColors colors;

  const _ProjectsLoadingSkeleton({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: List.generate(4, (_) {
        return const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: ShimmerLoading(
            child: SkotiqPanel(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 220, height: 16),
                  SizedBox(height: 10),
                  SkeletonBox(height: 8, borderRadius: 4),
                  SizedBox(height: 12),
                  SkeletonBox(width: 160, height: 12),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
