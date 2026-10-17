import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../dashboard_layout.dart';

class DashboardTile extends StatelessWidget {
  final DashboardTileConfig tile;
  final double width;
  final SkotiqColors colors;
  final Widget child;
  final bool isEditing;
  final CardVariant cardVariant;
  final bool isHero;

  /// When true, the wrapped panel provides its own chrome, so the frame skips
  /// its resting border/background (see DashboardWidgetDefinition.selfChromed).
  final bool selfChromed;
  final void Function(DashboardWidgetId dragged, DashboardWidgetId target)
      onReorder;
  final void Function(DashboardWidgetId id) onResize;
  final void Function(DashboardWidgetId id, bool enabled) onToggleEnabled;

  const DashboardTile({
    super.key,
    required this.tile,
    required this.width,
    required this.colors,
    required this.child,
    required this.isEditing,
    required this.onReorder,
    required this.onResize,
    required this.onToggleEnabled,
    this.cardVariant = CardVariant.standard,
    this.isHero = false,
    this.selfChromed = false,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<DashboardWidgetId>(
      onWillAcceptWithDetails: (details) =>
          isEditing && details.data != tile.widgetId,
      onAcceptWithDetails: (details) {
        if (isEditing) onReorder(details.data, tile.widgetId);
      },
      builder: (context, candidateData, _) {
        final isDropTarget = candidateData.isNotEmpty;
        final frame = DashboardTileFrame(
          colors: colors,
          isEditing: isEditing,
          isDropTarget: isDropTarget,
          size: tile.size,
          cardVariant: cardVariant,
          isHero: isHero,
          selfChromed: selfChromed,
          onResize: () => onResize(tile.widgetId),
          onHide: () => onToggleEnabled(tile.widgetId, false),
          child: child,
        );

        if (!isEditing) {
          // Flutter's Linux embedder has no damage region: ANY dirty frame
          // re-rasterises the whole window, and the status bar's wall clock
          // dirties one every second on every screen. Without a boundary per
          // tile the whole dashboard is one layer, so that one ticking digit
          // repaints every card's text, gradient and chart from scratch.
          // A boundary per tile lets the raster cache hand back the tiles that
          // did not change and repaint only the one that did.
          //
          // Not applied while editing: a tile being dragged is repainting every
          // frame anyway, and a boundary around a moving layer only adds a
          // cache miss per frame.
          return RepaintBoundary(child: frame);
        }

        return LongPressDraggable<DashboardWidgetId>(
          data: tile.widgetId,
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: width,
              child: Opacity(
                opacity: 0.9,
                child: DashboardTileFrame(
                  colors: colors,
                  isEditing: false,
                  isDropTarget: false,
                  size: tile.size,
                  cardVariant: cardVariant,
                  isHero: isHero,
                  selfChromed: selfChromed,
                  onResize: () {},
                  onHide: () {},
                  child: child,
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.4,
            child: frame,
          ),
          child: frame,
        );
      },
    );
  }
}

class DashboardTileFrame extends StatelessWidget {
  final SkotiqColors colors;
  final bool isEditing;
  final bool isDropTarget;
  final DashboardTileSize size;
  final Widget child;
  final CardVariant cardVariant;
  final bool isHero;

  /// When true, the wrapped panel provides its own border/background. The frame
  /// then draws a border only to signal an active highlight state (editing,
  /// drop-target, or hero), and is fully transparent at rest.
  final bool selfChromed;
  final VoidCallback onResize;
  final VoidCallback onHide;

  const DashboardTileFrame({
    super.key,
    required this.colors,
    required this.isEditing,
    required this.isDropTarget,
    required this.size,
    required this.child,
    required this.onResize,
    required this.onHide,
    this.cardVariant = CardVariant.standard,
    this.isHero = false,
    this.selfChromed = false,
  });

  @override
  Widget build(BuildContext context) {
    // Border with hero accent and edit mode highlight. Self-chromed panels draw
    // no resting border (their own card supplies it); they still get the
    // highlight border so editing/drop-target/hero states read correctly.
    final Color? borderColor;
    if (isDropTarget) {
      borderColor = colors.primary.withValues(alpha: 0.7);
    } else if (isEditing) {
      borderColor = colors.primary.withValues(alpha: 0.3);
    } else if (isHero) {
      borderColor = colors.primary.withValues(alpha: 0.2);
    } else {
      borderColor = selfChromed ? null : colors.border;
    }

    return Stack(
      children: [
        // Card container with visual hierarchy
        AnimatedContainer(
          duration: SkotiqTokens.durationNormal,
          decoration: BoxDecoration(
            borderRadius: SkotiqTokens.borderRadiusMd,
            border: borderColor == null
                ? null
                : Border.all(
                    color: borderColor,
                    width: isDropTarget ? 2 : (isHero ? 1.5 : 1),
                  ),
          ),
          child: ClipRRect(
            borderRadius: SkotiqTokens.borderRadiusMd,
            child: isEditing
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _EditTileStrip(
                        colors: colors,
                        sizeLabel: size.label,
                        onResize: onResize,
                        onHide: onHide,
                      ),
                      IgnorePointer(child: child),
                    ],
                  )
                : child,
          ),
        ),
      ],
    );
  }
}

/// Reserves space for editing controls above the panel content.
class _EditTileStrip extends StatelessWidget {
  const _EditTileStrip({
    required this.colors,
    required this.sizeLabel,
    required this.onResize,
    required this.onHide,
  });

  final SkotiqColors colors;
  final String sizeLabel;
  final VoidCallback onResize;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceXs,
        SkotiqTokens.spaceXs,
        0,
      ),
      child: Row(
        children: [
          _DragHandleIndicator(colors: colors),
          const Spacer(),
          SkotiqIconButton(
            icon: LucideIcons.maximize2,
            tooltip: 'Resize ($sizeLabel)',
            size: IconButtonSize.sm,
            onPressed: onResize,
          ),
          SkotiqIconButton(
            icon: LucideIcons.eyeOff,
            tooltip: 'Hide tile',
            size: IconButtonSize.sm,
            onPressed: onHide,
          ),
        ],
      ),
    );
  }
}

/// The grip the operator drags a tile by in Edit layout.
class _DragHandleIndicator extends StatelessWidget {
  final SkotiqColors colors;

  const _DragHandleIndicator({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceXs + 2),
      decoration: SkotiqDecorations.panelSelected(colors),
      child: Icon(
        LucideIcons.gripVertical,
        size: 14,
        color: colors.primary,
      ),
    );
  }
}

class DashboardLoading extends StatelessWidget {
  const DashboardLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: SkotiqTokens.space4xl),
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      ),
    );
  }
}

/// The one error pattern: an [EmptyState] with ONE button (05 §12). It replaced
/// a bordered glass card with its own title row, which was a second error style
/// on a screen that already had one.
class DashboardLayoutError extends StatelessWidget {
  final Object error;
  final VoidCallback onReset;
  final String title;
  final String buttonLabel;

  const DashboardLayoutError({
    super.key,
    required this.error,
    required this.onReset,
    this.title = 'The dashboard layout could not be read',
    this.buttonLabel = 'Reset layout',
  });

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: LucideIcons.alertTriangle,
      title: title,
      body: '$error',
      action: SkotiqButton(
        label: buttonLabel,
        icon: LucideIcons.refreshCw,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: onReset,
      ),
    );
  }
}
