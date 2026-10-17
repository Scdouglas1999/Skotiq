part of '../projects_tab_content.dart';

// Active project progress: targets + accrued-vs-remaining roll-up.

class _ActiveProjectProgress extends ConsumerWidget {
  final SkotiqColors colors;
  final Future<void> Function(int projectId, Set<int> attachedIds) onAddTarget;
  final Future<void> Function(int projectId, int targetId, String targetName)
      onRemoveTarget;
  final Future<void> Function(int targetId, String targetName) onEditGoals;
  final bool mutationsEnabled;

  const _ActiveProjectProgress({
    required this.colors,
    required this.onAddTarget,
    required this.onRemoveTarget,
    required this.onEditGoals,
    required this.mutationsEnabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressAsync = ref.watch(activeProjectProgressProvider);

    return progressAsync.when(
      loading: () => const _ProjectsSkeleton(),
      error: (err, _) => _ProjectsError(
        error: err,
        onRetry: () => ref.invalidate(activeProjectProgressProvider),
      ),
      data: (progress) {
        if (progress == null) {
          // No active project resolved — the header still lets the operator
          // pick one. This is a transient state during selection settling.
          return const EmptyState.compact(
            icon: LucideIcons.folderOpen,
            title: 'Select a project',
            body: 'Choose a project from the list to see its targets and '
                'progress.',
          );
        }

        final project = progress.project;
        final projectId = project.id;
        if (projectId == null) {
          throw StateError('Active project progress has a null project id');
        }

        final targets = progress.targets;
        final attachedIds = targets.map((t) => t.targetId).toSet();

        // Sort incomplete-first; within each group, least-complete first, then
        // by name for a stable order between rebuilds.
        final sorted = List<ProjectTargetProgress>.of(targets)
          ..sort((a, b) {
            if (a.isComplete != b.isComplete) {
              return a.isComplete ? 1 : -1;
            }
            final c = a.percentComplete.compareTo(b.percentComplete);
            if (c != 0) return c;
            return a.targetName
                .toLowerCase()
                .compareTo(b.targetName.toLowerCase());
          });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProjectSummaryHeader(
              colors: colors,
              totalTargets: progress.totalTargets,
              completeTargets: progress.completeTargets,
              percentComplete: progress.totalPercentComplete,
              accruedSeconds: progress.totalAccruedSeconds,
              goalSeconds: progress.totalGoalSeconds,
              onAddTarget: mutationsEnabled
                  ? () => onAddTarget(projectId, attachedIds)
                  : null,
            ),
            Expanded(
              child: targets.isEmpty
                  ? EmptyState.compact(
                      icon: LucideIcons.target,
                      title: 'No targets yet',
                      body: 'Add catalog targets to this project and set '
                          'per-filter integration goals to track progress.',
                      action: SkotiqButton(
                        label: 'Add target',
                        icon: LucideIcons.plus,
                        size: ButtonSize.small,
                        onPressed: mutationsEnabled
                            ? () => onAddTarget(projectId, attachedIds)
                            : null,
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(
                        SkotiqTokens.spaceLg,
                        SkotiqTokens.spaceSm,
                        SkotiqTokens.spaceLg,
                        SkotiqTokens.space2xl,
                      ),
                      itemCount: sorted.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: SkotiqTokens.spaceSm),
                      itemBuilder: (context, index) {
                        final t = sorted[index];
                        return _TargetProgressCard(
                          key: ValueKey('project-target-${t.targetId}'),
                          colors: colors,
                          target: t,
                          onEditGoals: () =>
                              onEditGoals(t.targetId, t.targetName),
                          onRemove: mutationsEnabled
                              ? () => onRemoveTarget(
                                  projectId, t.targetId, t.targetName)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Project-level summary + "Add Target" action, shown above the target list.
class _ProjectSummaryHeader extends StatelessWidget {
  final SkotiqColors colors;
  final int totalTargets;
  final int completeTargets;
  final double percentComplete;
  final double accruedSeconds;
  final double goalSeconds;
  final VoidCallback? onAddTarget;

  const _ProjectSummaryHeader({
    required this.colors,
    required this.totalTargets,
    required this.completeTargets,
    required this.percentComplete,
    required this.accruedSeconds,
    required this.goalSeconds,
    required this.onAddTarget,
  });

  @override
  Widget build(BuildContext context) {
    final pctFraction = percentComplete;
    final pct = (pctFraction * 100).clamp(0.0, 100.0);
    final accruedLabel = _formatHours(accruedSeconds);
    final goalLabel = _formatHours(goalSeconds);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        0,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceSm,
      ),
      child: SkotiqPanel(
          padding: SkotiqTokens.cardPadding,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '$totalTargets target${totalTargets == 1 ? '' : 's'}',
                          style: SkotiqTypography.labelSm.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                        if (totalTargets > 0) ...[
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          Text(
                            '· $completeTargets complete',
                            style: SkotiqTypography.labelSm.copyWith(
                              color: completeTargets == totalTargets &&
                                      totalTargets > 0
                                  ? colors.success
                                  : colors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: SkotiqProgressBar(
                            value: pctFraction,
                            style: SkotiqProgressStyle.thick,
                            state: pctFraction >= 1.0
                                ? SkotiqProgressState.success
                                : SkotiqProgressState.normal,
                          ),
                        ),
                        const SizedBox(width: SkotiqTokens.spaceMd),
                        Text(
                          '${pct.toStringAsFixed(0)}%',
                          style: SkotiqTypography.telemetryMd.copyWith(
                            color: colors.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: SkotiqTokens.spaceXs),
                    Text(
                      '$accruedLabel / $goalLabel integration',
                      style: SkotiqTypography.monoSm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              SkotiqButton(
                label: 'Add target',
                icon: LucideIcons.plus,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: onAddTarget,
              ),
            ],
          )),
    );
  }
}

/// One per-target card with a project-level bar, accrued-vs-goal hours, percent,
/// completion indicator, and a per-filter captured/goal breakdown.
class _TargetProgressCard extends StatelessWidget {
  final SkotiqColors colors;
  final ProjectTargetProgress target;
  final VoidCallback onEditGoals;
  final VoidCallback? onRemove;

  const _TargetProgressCard({
    super.key,
    required this.colors,
    required this.target,
    required this.onEditGoals,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final pctFraction = target.percentComplete;
    final pct = (pctFraction * 100).clamp(0.0, 100.0);
    final accruedLabel = _formatHours(target.accruedSeconds);
    final goalLabel = _formatHours(target.goalSeconds);
    final hasGoals = target.goalSeconds > 0.0;

    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        target.targetName,
                        style: SkotiqTypography.bodyStrong.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      if (!hasGoals)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: SkotiqTokens.spaceXs,
                          ),
                          child: Text(
                            'No integration goals set',
                            style: SkotiqTypography.captionSm.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (target.isComplete) ...[
                  const StatusPill(
                    icon: LucideIcons.checkCircle2,
                    label: '',
                    value: 'Complete',
                    status: StatusPillStatus.success,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                ],
                AccessibleIconButton(
                  icon: LucideIcons.sliders,
                  label: 'Edit goals',
                  tooltip: 'Edit goals',
                  size: SkotiqTokens.iconMd,
                  onPressed: onEditGoals,
                ),
                AccessibleIconButton(
                  icon: LucideIcons.x,
                  label: 'Remove from project',
                  tooltip: 'Remove from project',
                  color: colors.textMuted,
                  size: SkotiqTokens.iconMd,
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Row(
              children: [
                Expanded(
                  child: SkotiqProgressBar(
                    value: pctFraction,
                    state: target.isComplete
                        ? SkotiqProgressState.success
                        : SkotiqProgressState.normal,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Text(
                  '${pct.toStringAsFixed(0)}%',
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.monoSm,
                  ).copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Text(
                  '$accruedLabel / $goalLabel',
                  style: SkotiqTypography.monoSm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
            if (target.filters.isNotEmpty) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              Divider(color: colors.border, height: 1),
              const SizedBox(height: SkotiqTokens.spaceMd),
              _FilterBreakdown(colors: colors, filters: target.filters),
            ],
          ],
        ));
  }
}

/// Per-filter captured/goal frame breakdown for a target card.
class _FilterBreakdown extends StatelessWidget {
  final SkotiqColors colors;
  final List<FilterProgressLine> filters;

  const _FilterBreakdown({required this.colors, required this.filters});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      children: [
        for (final f in filters) _FilterChip(colors: colors, filter: f),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final SkotiqColors colors;
  final FilterProgressLine filter;

  const _FilterChip({required this.colors, required this.filter});

  @override
  Widget build(BuildContext context) {
    // Color the chip by completion: success when the goal is met, primary while
    // in progress. A zero-frame goal is inert (treated as in-progress).
    final complete = filter.goalFrames > 0 && filter.isComplete;
    final tint = complete ? colors.success : colors.primary;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: SkotiqDecorations.chip(colors, tone: tint),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (complete) ...[
            Icon(
              LucideIcons.check,
              size: SkotiqTokens.iconXs,
              color: tint,
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
          ],
          Text(
            filter.filter,
            style: SkotiqTypography.labelSm.copyWith(
              color: tint,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            '${filter.capturedFrames} / ${filter.goalFrames}',
            style: SkotiqTypography.monoXs.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
