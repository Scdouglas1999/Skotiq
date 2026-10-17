part of '../interactive_sky_view.dart';

/// Sky view toolbar widget
class SkyViewToolbar extends ConsumerWidget {
  /// Whether to show extended options (solar system objects, milky way)
  final bool showExtendedOptions;

  const SkyViewToolbar({super.key, this.showExtendedOptions = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(skyRenderConfigProvider);
    final configNotifier = ref.read(skyRenderConfigProvider.notifier);

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _ToolbarToggle(
          label: 'Stars',
          isActive: config.showStars,
          onTap: configNotifier.toggleStars,
        ),
        _ToolbarToggle(
          label: 'Constellations',
          isActive: config.showConstellationLines,
          onTap: configNotifier.toggleConstellationLines,
        ),
        _ToolbarToggle(
          label: 'DSOs',
          isActive: config.showDSOs,
          onTap: configNotifier.toggleDSOs,
        ),
        _ToolbarToggle(
          label: 'Grid',
          isActive: config.showCoordinateGrid,
          onTap: configNotifier.toggleGrid,
        ),
        _ToolbarToggle(
          label: 'Horizon',
          isActive: config.showHorizon,
          onTap: configNotifier.toggleHorizon,
        ),
        _ToolbarToggle(
          label: 'Ecliptic',
          isActive: config.showEcliptic,
          onTap: configNotifier.toggleEcliptic,
        ),
        _ToolbarToggle(
          label: 'Galactic',
          isActive: config.showGalacticPlane,
          onTap: configNotifier.toggleGalacticPlane,
        ),
        if (showExtendedOptions) ...[
          _ToolbarToggle(
            label: 'Milky Way',
            isActive: config.showMilkyWay,
            onTap: configNotifier.toggleMilkyWay,
          ),
          _ToolbarToggle(
            label: 'Sun',
            isActive: config.showSun,
            onTap: configNotifier.toggleSun,
          ),
          _ToolbarToggle(
            label: 'Moon',
            isActive: config.showMoon,
            onTap: configNotifier.toggleMoon,
          ),
          _ToolbarToggle(
            label: 'Planets',
            isActive: config.showPlanets,
            onTap: configNotifier.togglePlanets,
          ),
        ],
      ],
    );
  }
}

class _ToolbarToggle extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ToolbarToggle({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive
                ? Colors.white.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isActive ? Colors.white : Colors.white70,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
