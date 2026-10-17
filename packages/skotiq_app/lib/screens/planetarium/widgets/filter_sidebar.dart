import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class FilterSidebar extends ConsumerWidget {
  final bool isExpanded;
  final VoidCallback onToggle;

  const FilterSidebar({
    super.key,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tokenized surface so Red Night theme stays red instead of falling
    // back to neutral grey.
    final colors = SkotiqColors.of(context);
    final expandedWidth = AdaptiveDialogConstraints.clampPanelWidth(
      context,
      designWidth: 220,
      minWidth: 180,
      maxWidth: 280,
    );
    final collapsedWidth = AdaptiveDialogConstraints.clampPanelWidth(
      context,
      designWidth: 48,
      minWidth: 44,
      maxWidth: 56,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: isExpanded ? expandedWidth : collapsedWidth,
      decoration: BoxDecoration(
        color: colors.surfaceOverlay.withValues(alpha: 0.95),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(SkotiqTokens.radiusInline8),
          bottomLeft: Radius.circular(SkotiqTokens.radiusInline8),
        ),
      ),
      child: isExpanded
          ? _buildExpandedContent(ref, colors)
          : _buildCollapsedContent(ref, colors),
    );
  }

  Widget _buildCollapsedContent(WidgetRef ref, SkotiqColors colors) {
    // Compact status dots mirror KStars filter-count badges so users can see
    // which categories are on without expanding. Listed in same order as the
    // expanded toggles.
    final config = ref.watch(skyRenderConfigProvider);
    final showGround = ref.watch(showGroundPlaneProvider);

    final categories = <_CategoryStatus>[
      _CategoryStatus('Stars', config.showStars, colors.warning),
      _CategoryStatus('Planets', config.showPlanets, colors.info),
      _CategoryStatus('Deep Sky', config.showDSOs, colors.accent),
      _CategoryStatus('Grid', config.showCoordinateGrid, colors.textSecondary),
      _CategoryStatus(
          'Constellations', config.showConstellationLines, colors.primary),
      _CategoryStatus(
          'Boundaries', config.showConstellationBoundaries, colors.border),
      _CategoryStatus(
          'Constellation Art', config.showConstellationArt, colors.accent),
      _CategoryStatus('Ground', showGround, colors.success),
    ];

    return Column(
      children: [
        IconButton(
          icon: const Icon(LucideIcons.panelRightOpen),
          onPressed: onToggle,
          tooltip: 'Show filters',
        ),
        const SizedBox(height: 4),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final cat in categories)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _FilterStatusDot(
                      label: cat.label,
                      active: cat.active,
                      accent: cat.accent,
                      mutedBorder: colors.border,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExpandedContent(WidgetRef ref, SkotiqColors colors) {
    final config = ref.watch(skyRenderConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text('Filters',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(LucideIcons.panelRightClose, size: 18),
                onPressed: onToggle,
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Toggles
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _FilterToggle(
                label: 'Stars',
                value: config.showStars,
                onChanged: (_) =>
                    ref.read(skyRenderConfigProvider.notifier).toggleStars(),
              ),
              _FilterToggle(
                label: 'Planets',
                value: config.showPlanets,
                onChanged: (_) =>
                    ref.read(skyRenderConfigProvider.notifier).togglePlanets(),
              ),
              _FilterToggle(
                label: 'Deep sky',
                value: config.showDSOs,
                onChanged: (_) =>
                    ref.read(skyRenderConfigProvider.notifier).toggleDSOs(),
              ),
              const Divider(),
              _FilterToggle(
                label: 'Grid',
                value: config.showCoordinateGrid,
                onChanged: (_) =>
                    ref.read(skyRenderConfigProvider.notifier).toggleGrid(),
              ),
              _FilterToggle(
                label: 'Constellations',
                value: config.showConstellationLines,
                onChanged: (_) => ref
                    .read(skyRenderConfigProvider.notifier)
                    .toggleConstellationLines(),
              ),
              _FilterToggle(
                label: 'Boundaries',
                value: config.showConstellationBoundaries,
                onChanged: (_) => ref
                    .read(skyRenderConfigProvider.notifier)
                    .toggleConstellationBoundaries(),
              ),
              _FilterToggle(
                label: 'Constellation art',
                value: config.showConstellationArt,
                onChanged: (_) => ref
                    .read(skyRenderConfigProvider.notifier)
                    .toggleConstellationArt(),
              ),
              _FilterToggle(
                // The ground is occluding terrain, which only the horizon view
                // has — the equatorial star atlas draws none, so leaving this
                // unqualified made it look broken there.
                label: 'Ground (horizon view)',
                value: ref.watch(showGroundPlaneProvider),
                onChanged: (v) =>
                    ref.read(showGroundPlaneProvider.notifier).state = v,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryStatus {
  final String label;
  final bool active;
  final Color accent;
  const _CategoryStatus(this.label, this.active, this.accent);
}

class _FilterStatusDot extends StatelessWidget {
  final String label;
  final bool active;
  final Color accent;
  final Color mutedBorder;

  const _FilterStatusDot({
    required this.label,
    required this.active,
    required this.accent,
    required this.mutedBorder,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label: ${active ? 'on' : 'off'}',
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? accent : Colors.transparent,
          border: Border.all(
            color: active ? accent : mutedBorder,
            width: 1,
          ),
        ),
      ),
    );
  }
}

class _FilterToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _FilterToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(label),
      value: value,
      onChanged: onChanged,
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }
}
