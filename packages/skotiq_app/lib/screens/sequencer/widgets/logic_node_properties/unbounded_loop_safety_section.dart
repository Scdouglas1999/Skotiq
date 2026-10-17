part of '../logic_node_properties.dart';

class _UnboundedLoopSafetySection extends ConsumerWidget {
  final SkotiqColors colors;
  final LoopNode node;

  const _UnboundedLoopSafetySection({
    required this.colors,
    required this.node,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasLimit = node.maxSafetyIterations != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Warning banner when no limit is set
        if (!hasLimit)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: SkotiqDecorations.emphasisSurface(
              colors.warning,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.alertTriangle,
                    size: 14, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This loop has no safety limit and could run indefinitely. '
                    'Set a max iterations limit as a safety net.',
                    style: TextStyle(
                      fontSize: Responsive.fontSize(context, 12),
                      color: colors.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),

        NodePropertyField(
          colors: colors,
          label: 'Max Iterations (safety)',
          child: Row(
            children: [
              Expanded(
                child: NodeNumberInput(
                  colors: colors,
                  value: (node.maxSafetyIterations ?? 999).toDouble(),
                  min: 1,
                  max: 99999,
                  onChanged: (value) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(maxSafetyIterations: value.toInt()),
                        );
                  },
                ),
              ),
              if (hasLimit) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Remove safety limit',
                  child: GestureDetector(
                    onTap: () {
                      // Create a new LoopNode with maxSafetyIterations explicitly null.
                      // Since copyWith uses ?? semantics, we must construct directly.
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            LoopNode(
                              id: node.id,
                              name: node.name,
                              isEnabled: node.isEnabled,
                              childIds: node.childIds,
                              parentId: node.parentId,
                              orderIndex: node.orderIndex,
                              comment: node.comment,
                              conditionType: node.conditionType,
                              repeatCount: node.repeatCount,
                              repeatUntil: node.repeatUntil,
                              repeatUntilAltitude: node.repeatUntilAltitude,
                              integrationTimeTarget: node.integrationTimeTarget,
                              maxSafetyIterations: null,
                            ),
                          );
                    },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: colors.surfaceAlt,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusMd),
                        border: Border.all(color: colors.border),
                      ),
                      child: Icon(LucideIcons.x,
                          size: 14, color: colors.textMuted),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // Info box
        Container(
          padding: const EdgeInsets.all(10),
          decoration: SkotiqDecorations.tintedBadge(
            colors.info,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info, size: 12, color: colors.info),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasLimit
                      ? 'Loop will stop after ${node.maxSafetyIterations} iterations even if the condition is still met.'
                      : 'Tap the field above to set a safety limit (recommended: 999).',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 11),
                    color: colors.info,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
