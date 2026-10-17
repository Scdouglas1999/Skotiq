part of '../target_node_properties.dart';

class _IntegrationBudgetSection extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetHeaderNode node;

  const _IntegrationBudgetSection({
    required this.colors,
    required this.node,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budget = node.integrationBudget;
    final enabled = budget != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.target, size: 14, color: colors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Integration budget',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              NodeToggleSwitch(
                colors: colors,
                value: enabled,
                onChanged: (on) {
                  if (on) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(
                              integrationBudget: const IntegrationBudget()),
                        );
                  } else {
                    // TargetHeaderNode.copyWith uses a plain
                    // `?? this.integrationBudget`, so clearing back to
                    // null is rebuild-explicit.
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          TargetHeaderNode(
                            id: node.id,
                            name: node.name,
                            isEnabled: node.isEnabled,
                            childIds: node.childIds,
                            parentId: node.parentId,
                            orderIndex: node.orderIndex,
                            comment: node.comment,
                            targetName: node.targetName,
                            raHours: node.raHours,
                            decDegrees: node.decDegrees,
                            rotation: node.rotation,
                            priority: node.priority,
                            minAltitude: node.minAltitude,
                            maxAltitude: node.maxAltitude,
                            startAfter: node.startAfter,
                            endBefore: node.endBefore,
                            mosaicPanel: node.mosaicPanel,
                            startWhen: node.startWhen,
                            endWhen: node.endWhen,
                            triggerPollIntervalSecs:
                                node.triggerPollIntervalSecs,
                            brightnessTierHint: node.brightnessTierHint,
                          ),
                        );
                  }
                },
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 12),
            _BudgetEditor(colors: colors, node: node, budget: budget),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              'Stop a target once it has accumulated N hours of '
              'integration, with optional per-filter caps or ratios.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BudgetEditor extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetHeaderNode node;
  final IntegrationBudget budget;

  const _BudgetEditor({
    required this.colors,
    required this.node,
    required this.budget,
  });

  void _updateBudget(WidgetRef ref, IntegrationBudget next) {
    ref
        .read(currentSequenceProvider.notifier)
        .updateNode(node.copyWith(integrationBudget: next));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodePropertyField(
          colors: colors,
          label: 'Total time (hours)',
          child: NodeNumberInput(
            colors: colors,
            value: budget.totalSecs / 3600.0,
            suffix: 'h',
            min: 0,
            max: 24,
            decimals: 2,
            onChanged: (value) {
              _updateBudget(ref, budget.copyWith(totalSecs: value * 3600.0));
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Per-filter caps',
          style: SkotiqTypography.labelStrongSm
              .copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        ...budget.perFilter.entries.map(
          (e) => _FilterRow(
            colors: colors,
            filterName: e.key,
            entry: e.value,
            onChanged: (next) {
              final newMap =
                  Map<String, FilterBudgetEntry>.from(budget.perFilter);
              newMap[e.key] = next;
              _updateBudget(ref, budget.copyWith(perFilter: newMap));
            },
            onRemove: () {
              final newMap =
                  Map<String, FilterBudgetEntry>.from(budget.perFilter);
              newMap.remove(e.key);
              _updateBudget(ref, budget.copyWith(perFilter: newMap));
            },
          ),
        ),
        const SizedBox(height: 4),
        _AddFilterRow(
          colors: colors,
          existingFilters: budget.perFilter.keys.toSet(),
          onAdd: (name) {
            final newMap =
                Map<String, FilterBudgetEntry>.from(budget.perFilter);
            // Default new entries to a ratio of 1 so a user clicking
            // through L/R/G/B yields the canonical 1:1:1:1.
            newMap[name] = const FilterBudgetEntry.ratio(1);
            _updateBudget(ref, budget.copyWith(perFilter: newMap));
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Stop target when budget met',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary),
              ),
            ),
            NodeToggleSwitch(
              colors: colors,
              value: budget.stopOnBudgetMet,
              onChanged: (v) {
                _updateBudget(ref, budget.copyWith(stopOnBudgetMet: v));
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        _BudgetPreview(colors: colors, budget: budget),
      ],
    );
  }
}

/// One row in the per-filter list. The Absolute/Ratio toggle is a small
