part of '../mobile_widgets.dart';

/// Compact top overlay for mobile screens
/// Adapts layout for very narrow screens (below 360px)
class MobileTopOverlay extends ConsumerWidget {
  final SkotiqColors colors;

  const MobileTopOverlay({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final time = ref.watch(observationTimeProvider);
    // Simulated sidereal time, beside the simulated clock — see the desktop
    // TopOverlay for why the shell chrome reads the real one instead.
    final lst = ref.watch(observationSiderealTimeProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isVeryNarrow = screenWidth < 360;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            // Time chip (compact)
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.surfaceOverlay.withValues(alpha: 0.85),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
                child: Text(
                  DateFormat('HH:mm').format(time.time),
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textSecondary,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // Only show LST on screens wide enough
            if (!isVeryNarrow) ...[
              const SizedBox(width: 8),
              // LST chip
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.surfaceOverlay.withValues(alpha: 0.85),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                  ),
                  child: Text(
                    'LST ${_formatHours(lst)}',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textSecondary,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
            const Spacer(),
            // Quick toggle buttons
            MobileToggleButton(
              icon: SkotiqIcons.grid,
              isActive: ref.watch(skyRenderConfigProvider).showCoordinateGrid,
              onTap: ref.read(skyRenderConfigProvider.notifier).toggleGrid,
            ),
            MobileToggleButton(
              icon: SkotiqIcons.activity,
              isActive:
                  ref.watch(skyRenderConfigProvider).showConstellationLines,
              onTap: ref
                  .read(skyRenderConfigProvider.notifier)
                  .toggleConstellationLines,
            ),
          ],
        ),
      ),
    );
  }

  /// Sidereal time needs a site: an em dash rather than a number for a longitude
  /// nobody gave.
  String _formatHours(double? hours) {
    if (hours == null) return kReadoutUnknown;
    final h = hours.floor();
    final m = ((hours - h) * 60).floor();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}

/// Compact toggle button for mobile top bar
/// Minimum 44px touch target per accessibility guidelines
class MobileToggleButton extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const MobileToggleButton({
    super.key,
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final outer = _mobileTouchOuter(context);
    final inner = _mobileTouchInner(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: outer,
        height: outer,
        child: Center(
          child: Container(
            width: inner,
            height: inner,
            decoration: BoxDecoration(
              color: isActive
                  ? ImageOverlayColors.foreground.withValues(alpha: 0.2)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            ),
            child: Icon(
              icon,
              size: inner * 0.5,
              color: isActive
                  ? ImageOverlayColors.foreground
                  : ImageOverlayColors.secondary,
            ),
          ),
        ),
      ),
    );
  }
}
