part of '../sequencer_screen.dart';

class _NodePaletteContent extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _NodePaletteContent({required this.colors});

  @override
  ConsumerState<_NodePaletteContent> createState() =>
      _NodePaletteContentState();
}

class _NodePaletteContentState extends ConsumerState<_NodePaletteContent> {
  String _searchQuery = '';
  final _searchController = TextEditingController();

  /// Horizontal padding of the palette column (06 §Sequencer: 10 / 12).
  static const EdgeInsets _columnPadding = EdgeInsets.fromLTRB(
      SkotiqTokens.spaceMd, 0, SkotiqTokens.spaceMd, SkotiqTokens.spaceSm);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(nodePaletteProvider);

    // Filter AND rank: a name hit must outrank a description hit, or the
    // first row (the one people click) is the wrong node. See
    // widgets/node_palette_search.dart.
    final filteredCategories = rankNodePaletteMatches(categories, _searchQuery);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.spaceMd,
            0,
            SkotiqTokens.spaceMd,
            SkotiqTokens.spaceSm,
          ),
          child: SkotiqTextField(
            controller: _searchController,
            hint: 'Search nodes…',
            prefixIcon: LucideIcons.search,
            dense: true,
            onChanged: (value) => setState(() => _searchQuery = value),
            suffixWidget: _searchQuery.isEmpty
                ? null
                : SkotiqIconButton(
                    icon: LucideIcons.x,
                    tooltip: 'Clear search',
                    size: IconButtonSize.sm,
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
          ),
        ),

        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
              },
            ),
            child: filteredCategories.isEmpty
                ? NodePaletteEmptyState(
                    colors: widget.colors,
                    query: _searchQuery,
                    onClear: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  )
                : ListView.builder(
                    padding: _columnPadding,
                    itemCount: filteredCategories.length,
                    itemBuilder: (context, index) {
                      final category = filteredCategories[index];
                      return _NodeCategorySection(
                        category: category,
                        colors: widget.colors,
                      );
                    },
                  ),
          ),
        ),
        // The "drag nodes or double-click to add" tip is gone: the canvas
        // already says "Drop a node here, or double-click one in the palette"
        // exactly once, where the drop happens.
      ],
    );
  }
}

/// One eyebrow-labelled group of palette rows.
///
/// Flat, not collapsible: the palette is a list to scan, and a chevron per
/// group turned eight nodes into eight decisions. The category is a label, not
/// a colour — chrome carries no rainbow (02 "What Observatory is not").
class _NodeCategorySection extends ConsumerWidget {
  final NodePaletteCategory category;
  final SkotiqColors colors;

  const _NodeCategorySection({
    required this.category,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.spaceXs,
            SkotiqTokens.spaceSm,
            SkotiqTokens.spaceXs,
            2,
          ),
          child: Text(
            category.name.toUpperCase(),
            style: SkotiqTypography.eyebrow.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
        for (final item in category.items)
          _DraggableNodeItemCompact(
            item: item,
            colors: colors,
          ),
      ],
    );
  }
}

/// A palette row: `[26 px icon square in well] [name 13] [one-line
/// description 12 muted] … [plus muted]` (06 §Sequencer). Draggable onto the
/// canvas, and a single tap on the trailing plus adds it under the selection.
class _DraggableNodeItemCompact extends ConsumerStatefulWidget {
  final NodePaletteItem item;
  final SkotiqColors colors;

  const _DraggableNodeItemCompact({
    required this.item,
    required this.colors,
  });

  @override
  ConsumerState<_DraggableNodeItemCompact> createState() =>
      _DraggableNodeItemCompactState();
}

class _DraggableNodeItemCompactState
    extends ConsumerState<_DraggableNodeItemCompact> {
  bool _isHovered = false;

  /// The row's icon square (06 §Sequencer).
  static const double _iconSquare = 26;

  /// Glyph inside that square, and the trailing plus.
  static const double _glyph = 14;

  /// The narrowest a tile can draw its full furniture in: the glyph square,
  /// the gap after it and the add button's 18 px box. Below this the row
  /// overflows, which is reachable only while the pane is animating.
  static const double _tileMinWidth =
      _iconSquare + SkotiqTokens.spaceSm + 2 + _glyph + 4;

  void _addNode() => insertIntoTree(
    context,
    ref,
    widget.item,
    parentId: ref.read(selectedNodeIdProvider),
  );

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return Draggable<NodePaletteItem>(
      data: widget.item,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
            vertical: SkotiqTokens.spaceSm,
          ),
          decoration: SkotiqDecorations.popover(colors),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                nodeIcon(widget.item.icon),
                size: _glyph,
                color: colors.primary,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                paletteSentenceCase(widget.item.name),
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onDoubleTap: _addNode,
          child: Container(
            margin: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm + 2,
              vertical: SkotiqTokens.spaceXs + 2,
            ),
            decoration: _isHovered
                ? SkotiqDecorations.panel(colors).copyWith(
                    color: colors.surfaceHover,
                  )
                : SkotiqDecorations.panel(colors),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The palette pane animates its WIDTH open and shut, and its
                // tiles are laid out at every width on the way — including
                // widths narrower than a tile's own fixed furniture (the glyph
                // square, the gap and the add button), where the row overflowed
                // by 20 px on every collapse. Below that cost the tile keeps
                // the one thing that still identifies it. The threshold is the
                // furniture's own width, so a settled palette never sees it.
                final tight = constraints.maxWidth < _tileMinWidth;
                return Row(
                  children: [
                    Container(
                      width: _iconSquare,
                      height: _iconSquare,
                      decoration: SkotiqDecorations.well(colors),
                      child: Icon(
                        nodeIcon(widget.item.icon),
                        size: _glyph,
                        color: colors.textSecondary,
                      ),
                    ),
                    if (!tight) ...[
                      const SizedBox(width: SkotiqTokens.spaceSm + 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              // Sentence case at the point of DRAWING: the
                              // strings live in skotiq_core, which this
                              // wave may not touch, and the name a node carries
                              // once it is in a sequence is the user's data
                              // (see palette_copy.dart).
                              paletteSentenceCase(widget.item.name),
                              style: SkotiqTypography.bodySm.copyWith(
                                color: colors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // One line, so a screenful of the palette holds
                            // twice the nodes; the whole sentence is on hover.
                            SkotiqTooltip(
                              message: widget.item.description,
                              child: Text(
                                widget.item.description,
                                style: SkotiqTypography.caption.copyWith(
                                  color: colors.textMuted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Always-visible single-tap add button (drag still works
                      // on the tile). The hidden double-tap was undiscoverable.
                      Tooltip(
                        message: 'Add to sequence',
                        excludeFromSemantics: true,
                        child: Semantics(
                          container: true,
                          button: true,
                          // A button node without `enabled` reads as disabled to AT-SPI.
                          enabled: true,
                          label: 'Add ${paletteSentenceCase(widget.item.name)} '
                              'to the sequence',
                          onTap: _addNode,
                          excludeSemantics: true,
                          child: GestureDetector(
                            onTap: _addNode,
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                LucideIcons.plus,
                                size: _glyph,
                                color: _isHovered
                                    ? colors.textSecondary
                                    : colors.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
