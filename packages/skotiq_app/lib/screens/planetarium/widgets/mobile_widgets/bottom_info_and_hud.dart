part of '../mobile_widgets.dart';

// NOTE (design tokens): the `Colors.white*` / `Colors.black*` literals in this
// file are canvas-absolute HUD colors for the mobile planetarium overlays drawn
// over the sky. The planetarium is wrapped in `_NightVisionFilter` (luminance→
// red conversion for dark adaptation), so they are intentionally NOT mapped to
// the theme-relative semantic palette.

class MobileBottomInfoBar extends ConsumerWidget {
  final SkotiqColors colors;

  const MobileBottomInfoBar({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(skyViewStateProvider);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SafeArea(
        top: false,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'RA ${CoordinateFormatUtils.formatRACompact(viewState.centerRA)}',
                style: const TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  color: Colors.white60,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Dec ${CoordinateFormatUtils.formatDecCompact(viewState.centerDec)}',
                style: const TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  color: Colors.white60,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'FOV ${CoordinateFormatUtils.formatFOVCompact(viewState.fieldOfView)}',
                style: const TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  color: Colors.white60,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact selected object HUD for mobile (tap to expand)
class MobileSelectedObjectHud extends StatelessWidget {
  final SkotiqColors colors;
  final SelectedObjectState selectedObject;
  final VoidCallback onTap;

  const MobileSelectedObjectHud({
    super.key,
    required this.colors,
    required this.selectedObject,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final obj = selectedObject.object;
    if (obj == null) return const SizedBox.shrink();

    String displayName;
    String catalogTag;
    if (obj is DeepSkyObject) {
      final info = getDsoDisplayInfo(obj);
      displayName = info.$1;
      catalogTag = info.$2;
    } else {
      displayName = obj.name;
      catalogTag = switch (obj) {
        SolarSystemBody() => obj.designation.toUpperCase(),
        Star() => 'STAR',
        _ => obj.id,
      };
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(color: colors.primary.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.2),
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
              child: Text(
                catalogTag,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize9,
                  fontWeight: FontWeight.bold,
                  color: colors.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    SkotiqTypography.h6.copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              SkotiqIcons.chevronDown,
              size: 14,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}
