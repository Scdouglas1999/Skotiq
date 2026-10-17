// Dither node properties editor (amount, settle time/threshold/timeout,
// RA-only, and pattern/grid). The exposure, cool/warm camera, filter-change
// and notification editors moved to _exposure_rich.dart / _capture_rich.dart
// during the single-editor-library consolidation.
part of '../node_properties_panel.dart';

class _DitherProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final DitherNode node;

  const _DitherProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dither Settings',
          style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Dither amount',
          child: NodeNumberInput(
            colors: colors,
            value: node.pixels,
            suffix: 'px',
            min: 1,
            max: 50,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(pixels: value),
                  );
              // Save as default for future nodes
              ref.read(sequencerDefaultsProvider.notifier).updateDitherDefaults(
                    pixels: value,
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Settle time',
          child: NodeNumberInput(
            colors: colors,
            value: node.settleTime,
            suffix: 's',
            min: 5,
            max: 120,
            decimals: 0,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(settleTime: value),
                  );
              // Save as default for future nodes
              ref.read(sequencerDefaultsProvider.notifier).updateDitherDefaults(
                    settleTime: value,
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Settle threshold',
          child: NodeNumberInput(
            colors: colors,
            value: node.settlePixels,
            suffix: 'px',
            min: 0.1,
            max: 5,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(settlePixels: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Settle timeout',
          child: NodeNumberInput(
            colors: colors,
            value: node.settleTimeout,
            suffix: 's',
            min: 10,
            max: 300,
            decimals: 0,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(settleTimeout: value),
                  );
              ref.read(sequencerDefaultsProvider.notifier).updateDitherDefaults(
                    settleTimeout: value,
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'RA only',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.raOnly,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(raOnly: value),
                  );
              ref.read(sequencerDefaultsProvider.notifier).updateDitherDefaults(
                    raOnly: value,
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Pattern',
          child: NodeDropdown<DitherPattern>(
            colors: colors,
            value: node.pattern,
            items: const [DitherPattern.random, DitherPattern.grid],
            labelBuilder: (p) => switch (p) {
              DitherPattern.random => 'Random (classic)',
              DitherPattern.grid => 'Grid (systematic NxN)',
            },
            onChanged: (newPattern) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(pattern: newPattern),
                  );
            },
          ),
        ),
        if (node.pattern == DitherPattern.grid)
          NodePropertyField(
            colors: colors,
            label: 'Grid size (N)',
            child: NodeNumberInput(
              colors: colors,
              value: node.gridSize.toDouble(),
              min: 2,
              max: 9,
              suffix: 'x N',
              onChanged: (value) {
                final n = value.round().clamp(2, 9);
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(gridSize: n),
                    );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            node.pattern == DitherPattern.grid
                ? 'Walks a ${node.gridSize}x${node.gridSize} grid — visits ${node.gridSize * node.gridSize} positions before cycling. Best for uniform sky coverage.'
                : 'Random offsets each dither. Best for averaging out fixed-pattern noise; classic choice.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }
}
