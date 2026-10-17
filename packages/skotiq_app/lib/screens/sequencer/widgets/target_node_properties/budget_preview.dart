part of '../target_node_properties.dart';

class _BudgetPreview extends StatelessWidget {
  final SkotiqColors colors;
  final IntegrationBudget budget;

  const _BudgetPreview({required this.colors, required this.budget});

  String _formatDuration(double secs) => DurationFormat.seconds(
        secs,
        style: DurationStyle.compactTrimmed,
        roundToMinute: true,
      );

  @override
  Widget build(BuildContext context) {
    final resolved = <String, double>{
      for (final f in budget.perFilter.keys)
        if (budget.resolvedFilterCap(f) != null)
          f: budget.resolvedFilterCap(f)!,
    };

    final totalResolved = resolved.values.fold<double>(0, (a, b) => a + b);
    final summary = budget.totalSecs > 0
        ? 'Total: ${_formatDuration(budget.totalSecs)}'
        : 'Total: ${_formatDuration(totalResolved)} (sum of caps)';

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Resolved budget',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w700,
              color: colors.textMuted,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textPrimary),
          ),
          if (resolved.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              resolved.entries
                  .map((e) => '${e.key} ${_formatDuration(e.value)}')
                  .join(' · '),
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
