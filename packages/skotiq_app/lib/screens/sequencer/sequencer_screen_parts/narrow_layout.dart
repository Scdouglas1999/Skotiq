part of '../sequencer_screen.dart';

class _NarrowDesktopLayout extends ConsumerWidget {
  final SkotiqColors colors;

  const _NarrowDesktopLayout({required this.colors});

  static const double _railWidth = 48.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final selectedNodeId = ref.watch(selectedNodeIdProvider);

    return Stack(
      children: [
        Row(
          children: [
            _NarrowNodePaletteRail(
              colors: colors,
              width: _railWidth,
              onShowFullPalette: () => showSequencerNodeSheet(context, colors),
            ),
            Expanded(
              child: SequenceTree(
                  key: SequencerTutorialKeys.canvas, colors: colors),
            ),
          ],
        ),

        // Properties FAB — selecting a node still needs an editing affordance
        // on the narrow layout. The rail handles node insertion.
        if (selectedNodeId != null)
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.small(
              heroTag: 'narrow_properties_fab',
              backgroundColor: colors.accent,
              onPressed: () => showSequencerPropertiesSheet(context, colors),
              child: Icon(
                LucideIcons.settings2,
                color: onPrimary,
                size: 20,
              ),
            ),
          ),
      ],
    );
  }
}

/// Vertical icon strip showing one draggable button per palette item,
/// for use under the narrow-desktop threshold. Each icon is
/// a `Draggable<NodePaletteItem>` whose drop is accepted by the same
/// `DragTarget<Object>` in `sequence_tree.dart` that the expanded palette
/// uses, so insertion semantics are identical.
class _NarrowNodePaletteRail extends ConsumerWidget {
  final SkotiqColors colors;
  final double width;
  final VoidCallback onShowFullPalette;

  const _NarrowNodePaletteRail({
    required this.colors,
    required this.width,
    required this.onShowFullPalette,
  });

  Color _categoryColor(String name) {
    switch (name) {
      case 'Target':
        return colors.warning;
      case 'Imaging':
        return colors.primary;
      case 'Mount':
        return colors.info;
      case 'Focus':
        return colors.accent;
      case 'Camera':
        return colors.primary;
      case 'Logic':
        return colors.accent;
      case 'Timing':
        return colors.warning;
      case 'Utilities':
        return colors.textMuted;
      case 'Flat Panel':
        return colors.warning;
      case 'Dome':
        return colors.info;
      case 'Guiding':
        return colors.primary;
      default:
        return colors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The flattening is memoized in a provider, so this rebuild (hover /
    // resize) just reads the cached list instead of re-flattening the palette.
    final flat = ref.watch(flatNodePaletteProvider);

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              // Single source of truth for the row height so the extent
              // can't drift from the tile + margin.
              itemExtent: _RailDraggable.rowExtent,
              itemCount: flat.length,
              itemBuilder: (context, index) {
                final entry = flat[index];
                // Resolve the category tint per-row from the live theme; the
                // provider only carries the category name. Icons reuse
                // the shared palette icon map (no duplicate switch).
                return _RailDraggable(
                  item: entry.item,
                  tint: _categoryColor(entry.categoryName),
                  icon: nodePaletteIconFor(entry.item.icon),
                  colors: colors,
                );
              },
            ),
          ),
          Divider(height: 1, color: colors.border),
          SkotiqIconButton(
            icon: LucideIcons.moreHorizontal,
            tooltip: 'More nodes…',
            onPressed: onShowFullPalette,
          ),
        ],
      ),
    );
  }
}

class _RailDraggable extends ConsumerStatefulWidget {
  final NodePaletteItem item;
  final Color tint;
  final IconData icon;
  final SkotiqColors colors;

  const _RailDraggable({
    required this.item,
    required this.tint,
    required this.icon,
    required this.colors,
  });

  /// The tile geometry is the single source of truth shared between this
  /// widget's build and the rail's `itemExtent`, so changing either can't
  /// silently desync the list metrics.
  static const double tileHeight = 36.0;
  static const double verticalMargin = 3.0;

  /// Total row height = tile + top & bottom margin.
  static const double rowExtent = tileHeight + verticalMargin * 2;

  @override
  ConsumerState<_RailDraggable> createState() => _RailDraggableState();
}

class _RailDraggableState extends ConsumerState<_RailDraggable> {
  bool _hovered = false;

  void _addNodeViaDoubleTap() {
    // Mirrors `_NodePaletteItem._addNode` in node_palette.dart so the rail
    // double-tap matches the expanded-palette insertion semantics — including
    // the run-lock guard, since `addNode` throws SequenceLockedException while
    // the executor owns the tree.
    if (!ref.read(canEditSequenceProvider)) return;
    final node = widget.item.createNode();
    final selectedId = ref.read(selectedNodeIdProvider);
    final notifier = ref.read(currentSequenceProvider.notifier);
    notifier.addNode(node, parentId: selectedId);
    final children = widget.item.createChildren?.call();
    if (children != null) {
      for (final c in children) {
        notifier.addNode(c, parentId: node.id);
      }
    }
    ref.read(selectedNodeIdProvider.notifier).state = node.id;
  }

  @override
  Widget build(BuildContext context) {
    return Draggable<NodePaletteItem>(
      data: widget.item,
      onDragStarted: () =>
          ref.read(isDraggingNodeProvider.notifier).state = true,
      onDragEnd: (_) => ref.read(isDraggingNodeProvider.notifier).state = false,
      onDraggableCanceled: (_, __) =>
          ref.read(isDraggingNodeProvider.notifier).state = false,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: SkotiqDecorations.selectedSurface(
            widget.tint,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            fillAlpha: 0.2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: widget.tint),
              const SizedBox(width: 6),
              Text(
                widget.item.name,
                style: SkotiqTypography.labelSm
                    .copyWith(color: widget.colors.textPrimary),
              ),
            ],
          ),
        ),
      ),
      child: Tooltip(
        message: widget.item.name,
        waitDuration: const Duration(milliseconds: 300),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onDoubleTap: _addNodeViaDoubleTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: _RailDraggable.verticalMargin,
              ),
              height: _RailDraggable.tileHeight,
              decoration: BoxDecoration(
                color: _hovered
                    ? SkotiqDecorations.tintedBadge(
                        widget.tint,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusMd),
                      ).color
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(
                  color: _hovered
                      ? widget.tint.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(widget.icon, size: 18, color: widget.tint),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mobile layout: Full-screen tree with FAB and bottom sheets
