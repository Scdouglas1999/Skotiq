// Cleanup header row, summary stats header and sort bar.
part of '../project_tracking_panel.dart';

// Cleanup header row

/// Opt-in affordance to remove "untracked" library targets (no goal, no
/// favorite, no captured data, no sessions) that accumulated as phantom rows.
/// Hidden entirely when there is nothing to remove. Works against both the
/// local Drift DB and a remote imaging host (the session-aware cleanup runs
/// host-side over the analytics API).
class _CleanupHeaderRow extends ConsumerWidget {
  const _CleanupHeaderRow();

  Future<void> _runCleanup(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final authority = ref.read(backendProvider);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Remove untracked targets?'),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              dialogContext,
              designMaxWidth: 420,
            ),
            child: Text(
              'This permanently removes $count target'
              '${count == 1 ? '' : 's'} that have no integration goal, no '
              'captured data, and no imaging sessions. Favorites and any target '
              'you have imaged are kept. This cannot be undone.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;
    if (!context.mounted) return;
    if (!identical(ref.read(backendProvider), authority)) {
      ref.invalidate(untrackedTargetsCountProvider);
      context.showWarningSnackBar(
        'Imaging host changed. Cleanup was cancelled.',
      );
      return;
    }

    try {
      final deleted = authority is NetworkBackend
          ? await authority.removeUntrackedTargets()
          : await ref.read(targetsDaoProvider).deleteUntrackedTargets();
      if (!context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }
      // Refresh the library-backed views and this panel's count.
      ref.invalidate(allDbTargetsProvider);
      ref.invalidate(favoriteDbTargetsProvider);
      ref.invalidate(untrackedTargetsCountProvider);
      context.showSuccessSnackBar(
        'Removed $deleted untracked target${deleted == 1 ? '' : 's'}',
      );
    } catch (e) {
      if (!context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }
      context.showErrorSnackBar('Failed to remove untracked targets: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final countAsync = ref.watch(untrackedTargetsCountProvider);

    final count = countAsync.valueOrNull ?? 0;
    if (count <= 0) {
      // Nothing to clean up — don't clutter the header.
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => _runCleanup(context, ref, count),
          icon: Icon(LucideIcons.trash2, size: 14, color: colors.error),
          label: Text(
            'Remove untracked targets ($count)',
            style: SkotiqTypography.caption.copyWith(color: colors.error),
          ),
        ),
      ),
    );
  }
}

// Summary stats header

class _SummaryStatsHeader extends ConsumerWidget {
  final List<ProjectProgress> projects;
  final SkotiqColors colors;

  const _SummaryStatsHeader({
    required this.projects,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totalTargets = projects.length;
    final trackedTargets = projects.where((p) => p.isTracked).length;
    final completedTargets = projects.where((p) => p.isCompleted).length;
    final totalIntegrationHours =
        projects.fold<double>(0.0, (sum, p) => sum + p.integratedSecs) / 3600.0;

    // Counted over a rolling 30 nights, not the calendar month: an observing
    // run straddles the 1st, and on Aug 1 a calendar-month window reported "0
    // Active" for targets imaged on Jul 25, 28 and 30. The tile counts TARGETS
    // (it folds over projects), so the label says a period and not a subject —
    // it sits in a row of target-scoped stats.
    final activeCutoff =
        ref.watch(clockProvider).now().subtract(const Duration(days: 30));
    final activeTargets = projects.fold<int>(0, (sum, p) {
      if (p.lastSessionAt != null && p.lastSessionAt!.isAfter(activeCutoff)) {
        return sum + 1;
      }
      return sum;
    });

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Row(
        children: [
          Expanded(
            child: _SummaryStat(
              icon: LucideIcons.star,
              label: 'Targets',
              value: '$totalTargets',
              colors: colors,
            ),
          ),
          _divider(),
          Expanded(
            child: _SummaryStat(
              icon: LucideIcons.target,
              label: 'Tracked',
              value: '$trackedTargets',
              colors: colors,
            ),
          ),
          _divider(),
          Expanded(
            child: _SummaryStat(
              icon: LucideIcons.checkCircle,
              label: 'Completed',
              value: '$completedTargets',
              colors: colors,
            ),
          ),
          _divider(),
          Expanded(
            child: _SummaryStat(
              icon: LucideIcons.timer,
              label: 'Total integration',
              value: '${totalIntegrationHours.toStringAsFixed(1)}h',
              colors: colors,
            ),
          ),
          _divider(),
          Expanded(
            child: _SummaryStat(
              icon: LucideIcons.calendar,
              label: 'Active (30d)',
              value: '$activeTargets',
              colors: colors,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 40,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: colors.border,
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;

  const _SummaryStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: colors.textSecondary),
        const SizedBox(height: 4),
        Text(
          value,
          style: SkotiqTypography.readoutMd
              .copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// Sort bar

class _SortBar extends StatelessWidget {
  final ProjectSortMode currentSort;
  final ValueChanged<ProjectSortMode> onSortChanged;
  final SkotiqColors colors;

  const _SortBar({
    required this.currentSort,
    required this.onSortChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(LucideIcons.arrowUpDown, size: 14, color: colors.textMuted),
        const SizedBox(width: 8),
        Text(
          'Sort by:',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(width: 8),
        _sortChip('Completion', ProjectSortMode.completion),
        const SizedBox(width: 6),
        _sortChip('Total Time', ProjectSortMode.totalTime),
        const SizedBox(width: 6),
        _sortChip('Last Imaged', ProjectSortMode.lastImaged),
        const SizedBox(width: 6),
        _sortChip('Name', ProjectSortMode.name),
      ],
    );
  }

  Widget _sortChip(String label, ProjectSortMode mode) {
    final isSelected = currentSort == mode;
    return Semantics(
        button: true,
        enabled: true,
        selected: isSelected,
        child: GestureDetector(
          onTap: () => onSortChanged(mode),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: isSelected
                ? SkotiqDecorations.panelSelected(colors)
                : BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(color: colors.border),
                  ),
            child: Text(
              label,
              style: SkotiqTypography.caption.copyWith(
                  color: isSelected ? colors.primary : colors.textSecondary,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ));
  }
}
