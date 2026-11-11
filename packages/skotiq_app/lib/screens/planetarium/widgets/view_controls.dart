import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class QualitySettingsButton extends ConsumerWidget {
  final SkotiqColors colors;

  const QualitySettingsButton({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(renderQualityProvider);

    return _namedCommandBarPopup(
      name: 'Render quality',
      child: PopupMenuButton<RenderQuality>(
        icon: const Icon(
          SkotiqIcons.settings2,
          size: 18,
          color: ImageOverlayColors.secondary,
        ),
        // Empty, deliberately: see [_namedCommandBarPopup].
        tooltip: '',
        color: colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
        offset: const Offset(-120, 0),
        onSelected: (tier) {
          ref.read(renderQualityProvider.notifier).setQuality(tier);
        },
        itemBuilder: (context) => [
          _buildQualityMenuItem(
            context,
            RenderQuality.minimal,
            'Minimal',
            'Raspberry Pi / low-power',
            quality.quality,
          ),
          _buildQualityMenuItem(
            context,
            RenderQuality.performance,
            'Performance',
            'Low-end devices',
            quality.quality,
          ),
          _buildQualityMenuItem(
            context,
            RenderQuality.balanced,
            'Balanced',
            'Recommended',
            quality.quality,
          ),
          _buildQualityMenuItem(
            context,
            RenderQuality.quality,
            'Quality',
            'Best visuals',
            quality.quality,
          ),
        ],
      ),
    );
  }

  PopupMenuItem<RenderQuality> _buildQualityMenuItem(
    BuildContext context,
    RenderQuality tier,
    String title,
    String subtitle,
    RenderQuality current,
  ) {
    final isSelected = tier == current;
    return PopupMenuItem<RenderQuality>(
      value: tier,
      child: Row(
        children: [
          Icon(
            isSelected ? SkotiqIcons.success : SkotiqIcons.circle,
            size: 16,
            color: isSelected ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Wrap a command-bar [PopupMenuButton] so it has a NAME and its message is
/// carried by the trigger.
///
/// Two things are wrong with a bare `PopupMenuButton(tooltip: 'X')` here:
///
///  * The icon carries no label, so the control dumps as a bare `button: ` —
///    unidentifiable to anyone driving the bar from the keyboard or a screen
///    reader.
///  * Material's `Tooltip` publishes its message as a semantics node of its
///    own, which survives the pointer and strands a stale `panel: …` in the
///    tree for the rest of the session after one hover. Passing an EMPTY
///    tooltip makes `Tooltip` return its child untouched, so no such node is
///    ever created; the hover message comes from [SkotiqTooltip], which
///    retires with the pointer.
Widget _namedCommandBarPopup({required String name, required Widget child}) {
  // The NAME itself goes on the icon (`Icon(semanticLabel:)`), because
  // `PopupMenuButton` builds an `IconButton` whose semantics node is a
  // container of its own: a parent `Semantics(label: …)` — even merged —
  // lands beside that node and leaves the button announcing `button: ` with
  // nothing after it. The icon's label is the one string that ends up ON the
  // button node, with its role and its tap action.
  return SkotiqTooltip(
    message: name,
    position: SkotiqTooltipPosition.bottom,
    child: child,
  );
}

class ProjectionSelectorButton extends ConsumerWidget {
  final SkotiqColors colors;

  const ProjectionSelectorButton({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(skyViewStateProvider);
    final currentProjection = viewState.projection;

    final name = 'Projection: ${_projectionName(currentProjection)}';
    return _namedCommandBarPopup(
      name: name,
      child: PopupMenuButton<SkyProjection>(
        icon: Icon(
          _projectionIcon(currentProjection),
          size: 18,
          color: ImageOverlayColors.secondary,
          semanticLabel: name,
        ),
        // Empty, deliberately: see [_namedCommandBarPopup].
        tooltip: '',
        color: colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
        offset: const Offset(-140, 0),
        onSelected: (projection) {
          ref.read(skyViewStateProvider.notifier).setProjection(projection);
        },
        itemBuilder: (context) => SkyProjection.values.map((projection) {
          final isSelected = projection == currentProjection;
          return PopupMenuItem<SkyProjection>(
            value: projection,
            child: Row(
              children: [
                Icon(
                  isSelected ? SkotiqIcons.success : SkotiqIcons.circle,
                  size: 16,
                  color: isSelected ? colors.accent : colors.textSecondary,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _projectionName(projection),
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    Text(
                      _projectionDescription(projection),
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  static String _projectionName(SkyProjection projection) {
    switch (projection) {
      case SkyProjection.stereographic:
        return 'Stereographic';
      case SkyProjection.orthographic:
        return 'Orthographic';
      case SkyProjection.azimuthalEquidistant:
        return 'Equidistant';
    }
  }

  static String _projectionDescription(SkyProjection projection) {
    switch (projection) {
      case SkyProjection.stereographic:
        return 'Conformal, preserves angles';
      case SkyProjection.orthographic:
        return 'Perspective from infinity';
      case SkyProjection.azimuthalEquidistant:
        return 'Preserves distances from center';
    }
  }

  static IconData _projectionIcon(SkyProjection projection) {
    switch (projection) {
      case SkyProjection.stereographic:
        return SkotiqIcons.globe;
      case SkyProjection.orthographic:
        return SkotiqIcons.circle;
      case SkyProjection.azimuthalEquidistant:
        return SkotiqIcons.target;
    }
  }
}

