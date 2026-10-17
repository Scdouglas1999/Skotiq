part of '../logic_node_properties.dart';

class ParallelProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final ParallelNode node;

  const ParallelProperties(
      {super.key, required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Parallel Execution',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 13),
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Required successes',
          child: NodeNumberInput(
            colors: colors,
            value: (node.requiredSuccesses ?? 1).toDouble(),
            min: 1,
            max: 10,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(requiredSuccesses: value.toInt()),
                  );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: SkotiqDecorations.tintedBadge(
            colors.info,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info, size: 14, color: colors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'All child nodes will execute simultaneously. Node succeeds when required number of children complete.',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
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
