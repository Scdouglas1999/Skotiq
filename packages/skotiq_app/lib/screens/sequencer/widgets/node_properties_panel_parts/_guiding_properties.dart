// Properties widgets for the guiding instruction nodes: StartGuiding (settle
// pixels/time/timeout + auto-select star) and StopGuiding (a descriptive
// info card; the node has no configurable fields).
part of '../node_properties_panel.dart';

class _StartGuidingProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final StartGuidingNode node;

  const _StartGuidingProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Pixel scale (arcsec/px) derived from the active equipment profile's
    // focal length + camera pixel size. Drives the smart settle presets so a
    // chip means the same physical tolerance across very different optics.
    final pixelScale = ref.watch(opticalConfigProvider)?.imageScale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Guiding Settings',
          style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 12),
        _SettlePresetChips(
          colors: colors,
          pixelScaleArcsecPerPixel: pixelScale,
          onApply: (values) {
            ref.read(currentSequenceProvider.notifier).updateNode(
                  node.copyWith(
                    settlePixels: values.settlePixels,
                    settleTime: values.settleTime,
                  ),
                );
            ref.read(sequencerDefaultsProvider.notifier).updateDitherDefaults(
                  settlePixels: values.settlePixels,
                  settleTime: values.settleTime,
                );
          },
        ),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Settle threshold',
          helpText:
              'Guiding is considered settled once the guide-star error stays '
              'below this many pixels for the settle time. Lower = tighter '
              'guiding before imaging resumes.',
          child: NodeNumberInput(
            colors: colors,
            value: node.settlePixels,
            suffix: 'px',
            min: 0.1,
            max: 10,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(settlePixels: value),
                  );
              ref.read(sequencerDefaultsProvider.notifier).updateDitherDefaults(
                    settlePixels: value,
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
            min: 1,
            max: 120,
            decimals: 0,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(settleTime: value),
                  );
              ref.read(sequencerDefaultsProvider.notifier).updateDitherDefaults(
                    settleTime: value,
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
          label: 'Auto-select star',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.autoSelectStar,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(autoSelectStar: value),
                  );
            },
          ),
        ),
      ],
    );
  }
}

/// Smart settle presets: tappable chips that compute a sane settle threshold
/// (px) + dwell time (s) for common observing scenarios from the rig's pixel
/// scale, killing opaque-slider friction. Tapping a chip applies both values.
class _SettlePresetChips extends StatelessWidget {
  final SkotiqColors colors;
  final double? pixelScaleArcsecPerPixel;
  final ValueChanged<DitherSettleValues> onApply;

  const _SettlePresetChips({
    required this.colors,
    required this.pixelScaleArcsecPerPixel,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final scale = pixelScaleArcsecPerPixel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Presets',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: DitherSettlePreset.values.map((preset) {
            final values = deriveDitherSettleValues(
              preset: preset,
              pixelScaleArcsecPerPixel: scale,
            );
            return ActionChip(
              key: ValueKey('settle_preset_${preset.name}'),
              label: Text(
                '${preset.label} · ${values.settlePixels.toStringAsFixed(1)}px / '
                '${values.settleTime.toStringAsFixed(0)}s',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textPrimary,
                ),
              ),
              backgroundColor: colors.surfaceAlt,
              side: BorderSide(color: colors.border),
              onPressed: () => onApply(values),
            );
          }).toList(),
        ),
        if (scale == null) ...[
          const SizedBox(height: 6),
          Text(
            'Set focal length + camera pixel size in your equipment profile for '
            'rig-tuned values.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}

class _StopGuidingProperties extends StatelessWidget {
  final SkotiqColors colors;
  final StopGuidingNode node;

  const _StopGuidingProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          Icon(LucideIcons.xCircle, size: 32, color: colors.primary),
          const SizedBox(height: 12),
          Text(
            'Stops PHD2 guiding. The mount continues tracking, but guide '
            'corrections are no longer applied. This instruction has no '
            'additional settings.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: colors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
