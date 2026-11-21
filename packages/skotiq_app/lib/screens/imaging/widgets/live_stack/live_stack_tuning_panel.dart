import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../panel_widgets.dart';

/// Deep customization & quality-gate panel for Live Stacking.
///
/// Exposes one-click tuning presets, per-filter routing, auto-feed control,
/// pre-stack HFR/star-count quality gates, alignment residual ceiling, and
/// star detection sensitivity — with live updates pushed directly to active
/// stacks without discarding accumulated frames.
class LiveStackTuningPanel extends ConsumerWidget {
  const LiveStackTuningPanel({super.key, required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stack = ref.watch(liveStackingProvider);
    final config = stack.config;
    final notifier = ref.read(liveStackingProvider.notifier);
    final activePreset = config.matchedPreset;
    final isRunning = stack.status == LiveStackingStatus.running;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(
            icon: SkotiqIcons.settings,
            title: 'Presets & quality gates',
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Curated presets
          SkotiqPanel(
            head: PanelHead(
              label: 'Tuning preset',
              trailing: <Widget>[
                if (isRunning)
                  Text(
                    'Applies live',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.success,
                    ),
                  ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: SkotiqTokens.spaceXs + 2,
                  runSpacing: SkotiqTokens.spaceXs + 2,
                  children: <Widget>[
                    for (final preset in LiveStackingPreset.values)
                      _PresetChip(
                        preset: preset,
                        selected: activePreset == preset,
                        colors: colors,
                        onTap: () => notifier.updateConfig(
                          preset.applyTo(config),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  activePreset?.summary ??
                      'Custom parameters active. Pick any preset above to '
                          'reset alignment and clipping tuning.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Workflow routing
          SkotiqPanel(
            head: const PanelHead(label: 'Session routing'),
            child: Column(
              children: <Widget>[
                SkotiqSwitchRow(
                  label: 'Separate stacks by filter',
                  subtitle:
                      'Keep independent live stacks for L, R, G, B, Ha, OIII, SII',
                  value: config.separateByFilter,
                  onChanged: (v) => notifier
                      .updateConfig(config.copyWith(separateByFilter: v)),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqSwitchRow(
                  label: 'Auto-feed captures',
                  subtitle:
                      'Automatically stack new manual and sequenced light frames',
                  value: config.autoFeedEnabled,
                  onChanged: (v) => notifier
                      .updateConfig(config.copyWith(autoFeedEnabled: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Pre-stack quality gates
          SkotiqPanel(
            head: const PanelHead(label: 'Quality gates'),
            child: Column(
              children: <Widget>[
                SkotiqSwitchRow(
                  label: 'Reject high-HFR subs',
                  subtitle:
                      'Skip blurry or poorly focused frames before alignment',
                  value: config.maxHfrPx != null,
                  onChanged: (enabled) => notifier.updateConfig(
                    enabled
                        ? config.copyWith(maxHfrPx: 3.5)
                        : config.copyWith(clearMaxHfrPx: true),
                  ),
                ),
                if (config.maxHfrPx != null) ...<Widget>[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Max HFR',
                    value: config.maxHfrPx!.clamp(1.5, 8.0),
                    min: 1.5,
                    max: 8.0,
                    suffix: 'px',
                    colors: colors,
                    onChanged: (v) =>
                        notifier.updateConfig(config.copyWith(maxHfrPx: v)),
                  ),
                ],
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqSwitchRow(
                  label: 'Minimum star count',
                  subtitle: 'Skip cloud-obscured frames with too few stars',
                  value: config.minStarCount != null,
                  onChanged: (enabled) => notifier.updateConfig(
                    enabled
                        ? config.copyWith(minStarCount: 15)
                        : config.copyWith(clearMinStarCount: true),
                  ),
                ),
                if (config.minStarCount != null) ...<Widget>[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Min stars',
                    value: config.minStarCount!.toDouble().clamp(5.0, 200.0),
                    min: 5.0,
                    max: 200.0,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) => notifier.updateConfig(
                      config.copyWith(minStarCount: v.round()),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Alignment ceiling & star detection sensitivity
          SkotiqPanel(
            head: const PanelHead(label: 'Alignment & detection'),
            child: Column(
              children: <Widget>[
                SliderRowInteractive(
                  label: 'Max residual',
                  value: config.maxAlignmentResidualPx.clamp(0.5, 8.0),
                  min: 0.5,
                  max: 8.0,
                  suffix: 'px',
                  colors: colors,
                  onChanged: (v) => notifier.updateConfig(
                    config.copyWith(maxAlignmentResidualPx: v),
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                SliderRowInteractive(
                  label: 'Detect threshold',
                  value: config.starDetectionSigma.clamp(2.0, 8.0),
                  min: 2.0,
                  max: 8.0,
                  suffix: 'σ',
                  colors: colors,
                  onChanged: (v) => notifier.updateConfig(
                    config.copyWith(starDetectionSigma: v),
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                SliderRowInteractive(
                  label: 'Min star SNR',
                  value: config.starDetectionMinSnr.clamp(3.0, 20.0),
                  min: 3.0,
                  max: 20.0,
                  suffix: '',
                  colors: colors,
                  onChanged: (v) => notifier.updateConfig(
                    config.copyWith(starDetectionMinSnr: v),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.preset,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final LiveStackingPreset preset;
  final bool selected;
  final SkotiqColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('live_stack_preset_${preset.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color:
              selected ? colors.primary.withValues(alpha: 0.16) : colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          border: Border.all(
            color: selected
                ? colors.primary.withValues(alpha: 0.7)
                : colors.border,
          ),
        ),
        child: Text(
          preset.label,
          style: SkotiqTypography.labelSm.copyWith(
            color: selected ? colors.textPrimary : colors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
