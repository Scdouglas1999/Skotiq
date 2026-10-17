// Enhanced project card, metric chips, filter breakdown and loading skeleton.
part of '../project_tracking_panel.dart';

// Enhanced project card

class _EnhancedProjectCard extends ConsumerWidget {
  final ProjectProgress progress;
  final Map<String, double> filterBreakdown;

  const _EnhancedProjectCard({
    required this.progress,
    required this.filterBreakdown,
  });

  String _formatHours(double seconds) =>
      '${(seconds / 3600.0).toStringAsFixed(1)}h';

  Future<void> _editGoal(BuildContext context, WidgetRef ref) async {
    final authority = ref.read(backendProvider);
    final l10n = context.l10n;
    var draftGoal = progress.goalIntegrationSecs > 0
        ? (progress.goalIntegrationSecs / 3600.0).toStringAsFixed(1)
        : '';
    final submitted = await showDialog<double>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            l10n.text(
              'analyticsGoalDialogTitle',
              params: {'target': progress.target.name},
            ),
          ),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              dialogContext,
              designMaxWidth: 420,
            ),
            child: TextFormField(
              initialValue: draftGoal,
              onChanged: (value) => draftGoal = value,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: l10n.text('analyticsGoalHours'),
                hintText: 'e.g. 10.0',
                suffixText: 'hours',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.text('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(0.0),
              child: Text(l10n.text('analyticsClearGoal')),
            ),
            FilledButton(
              onPressed: () {
                final hours = double.tryParse(draftGoal.trim());
                if (hours == null || hours < 0) return;
                Navigator.of(dialogContext).pop(hours);
              },
              child: Text(l10n.text('analyticsSave')),
            ),
          ],
        );
      },
    );

    if (submitted == null) return;
    if (!context.mounted) return;
    if (!identical(ref.read(backendProvider), authority)) {
      context.showWarningSnackBar(
        'Imaging host changed. Goal update was cancelled.',
      );
      return;
    }

    try {
      if (authority is NetworkBackend) {
        await authority.updateTarget(progress.target.id, {
          'goalIntegrationSecs': submitted * 3600.0,
        });
      } else {
        await ref
            .read(targetsDaoProvider)
            .setGoalIntegrationSecs(progress.target.id, submitted * 3600.0);
      }
      if (!context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }
      ref.invalidate(allDbTargetsProvider);
      ref.invalidate(projectProgressListProvider);
      context.showSuccessSnackBar('Goal updated');
    } catch (e) {
      if (!context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }
      context.showErrorSnackBar('Failed to save goal: $e');
    }
  }

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
          // Header row: name, catalog ID, edit goal button
          Row(
            children: [
              // Status indicator
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
                onPressed: () => _editGoal(context, ref),
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

          // Progress bar
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

          // Stats row
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _MetricChip(
                icon: LucideIcons.timer,
                label: 'Integrated',
                value: _formatHours(progress.integratedSecs),
                colors: colors,
              ),
              _MetricChip(
                icon: LucideIcons.target,
                label: 'Goal',
                value: progress.isTracked
                    ? _formatHours(progress.goalIntegrationSecs)
                    : 'Not set',
                colors: colors,
              ),
              _MetricChip(
                icon: LucideIcons.hourglass,
                label: 'Remaining',
                value: progress.isTracked
                    ? _formatHours(progress.remainingSecs)
                    : kReadoutUnknown,
                colors: colors,
              ),
              _MetricChip(
                icon: LucideIcons.layers,
                label: 'Sessions',
                value: '${progress.sessionCount}',
                colors: colors,
              ),
              // "Frames returned", not "Frames": the sum is over each
              // session's `successful_exposures`, which counts what the
              // camera handed back rather than what the culling kept.
              _MetricChip(
                icon: LucideIcons.image,
                label: 'Frames returned',
                value: '${progress.successfulExposures}',
                colors: colors,
              ),
            ],
          ),

          // Per-filter breakdown
          if (filterBreakdown.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FilterBreakdownRow(
              filterData: filterBreakdown,
              colors: colors,
            ),
          ],

          // Last imaged date
          if (progress.lastSessionAt != null) ...[
            const SizedBox(height: 10),
            Text(
              'Last imaged: ${DateFormat('MMM d, yyyy HH:mm').format(progress.lastSessionAt!)}',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

// Metric chip

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

// Filter breakdown row

class _FilterBreakdownRow extends StatelessWidget {
  final Map<String, double> filterData;
  final SkotiqColors colors;

  const _FilterBreakdownRow({
    required this.filterData,
    required this.colors,
  });

  Color _filterColor(String filterName) {
    switch (filterName.toUpperCase()) {
      case 'L':
      case 'LUMINANCE':
        return const Color(0xFFD4D4D8);
      case 'R':
      case 'RED':
        return const Color(0xFFF87171);
      case 'G':
      case 'GREEN':
        return const Color(0xFF4ADE80);
      case 'B':
      case 'BLUE':
        return const Color(0xFF60A5FA);
      case 'HA':
      case 'H-ALPHA':
        return const Color(0xFFB91C1C);
      case 'OIII':
      case 'O-III':
        return const Color(0xFF2DD4BF);
      case 'SII':
      case 'S-II':
        return const Color(0xFFFB923C);
      default:
        return colors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sort filters by total time descending
    final sortedEntries = filterData.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: sortedEntries.map((entry) {
        final hours = entry.value / 3600.0;
        final color = _filterColor(entry.key);
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
                '${entry.key}: ${hours.toStringAsFixed(1)}h',
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
