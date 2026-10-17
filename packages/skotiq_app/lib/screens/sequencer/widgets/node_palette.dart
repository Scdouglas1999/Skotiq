import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'node_palette_empty_state.dart';
import 'node_palette_search.dart';
import 'palette_copy.dart';
import 'palette_icon_map.dart';

class NodePalette extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final ScrollController? scrollController;
  final bool isMobileSheet;
  final VoidCallback? onNodeAdded;
  final VoidCallback? onCollapse;

  const NodePalette({
    super.key,
    required this.colors,
    this.scrollController,
    this.isMobileSheet = false,
    this.onNodeAdded,
    this.onCollapse,
  });

  @override
  ConsumerState<NodePalette> createState() => _NodePaletteState();
}

class _NodePaletteState extends ConsumerState<NodePalette> {
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  IconData _getIcon(String iconName) => nodePaletteIconFor(iconName);

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  Color _getCategoryColor(String categoryName) =>
      nodePaletteCategoryColor(categoryName, widget.colors);

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(nodePaletteProvider);

    // Filter AND rank: a name hit must outrank a description hit, or the
    // first row (the one people click) is the wrong node. See
    // node_palette_search.dart.
    final filteredCategories = rankNodePaletteMatches(categories, _searchQuery);

    // Mobile bottom sheet layout
    if (widget.isMobileSheet) {
      return _buildMobileSheetContent(filteredCategories);
    }

    // Desktop sidebar layout
    return _buildDesktopSidebarContent(filteredCategories);
  }

  Widget _buildMobileSheetContent(
      List<NodePaletteCategory> filteredCategories) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Handle bar
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: widget.colors.border,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline2),
            ),
          ),
        ),

        // Header with search
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.layoutGrid,
                    size: 18,
                    color: widget.colors.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Add Node',
                    style: SkotiqTypography.sectionTitle.copyWith(
                      color: widget.colors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Search
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: widget.colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                  border: Border.all(color: widget.colors.border),
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.search,
                      size: 16,
                      color: widget.colors.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (value) =>
                            setState(() => _searchQuery = value),
                        style: SkotiqTypography.body.copyWith(
                          color: widget.colors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search nodes…',
                          hintStyle: SkotiqTypography.body.copyWith(
                            color: widget.colors.textMuted,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    if (_searchQuery.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        child: Icon(
                          LucideIcons.x,
                          size: 16,
                          color: widget.colors.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        Divider(color: widget.colors.border, height: 1),

        // Categories list - using provided scroll controller for DraggableScrollableSheet
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
                    onClear: _clearSearch,
                  )
                : ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: filteredCategories.length,
                    itemBuilder: (context, index) {
                      final category = filteredCategories[index];
                      return _CategorySection(
                        category: category,
                        colors: widget.colors,
                        categoryColor: _getCategoryColor(category.name),
                        getIcon: _getIcon,
                        isMobile: true,
                        onNodeAdded: widget.onNodeAdded,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopSidebarContent(
      List<NodePaletteCategory> filteredCategories) {
    return Builder(builder: (context) {
      final headerIconSize = Responsive.iconSize(context, 16);
      final searchIconSize = Responsive.iconSize(context, 15);
      final tipIconSize = Responsive.iconSize(context, 14);
      final headerPadding = Responsive.spacing(context, 16);
      final searchPadding = Responsive.spacing(context, 12);
      final tipPadding = Responsive.spacing(context, 12);

      return Container(
        decoration: BoxDecoration(
          color: widget.colors.surface,
          border: Border(right: BorderSide(color: widget.colors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(headerPadding),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: widget.colors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        LucideIcons.layoutGrid,
                        size: headerIconSize,
                        color: widget.colors.textMuted,
                      ),
                      SizedBox(width: Responsive.spacing(context, 8)),
                      Expanded(
                        child: Text(
                          'Node Palette',
                          style: SkotiqTypography.sectionTitle.copyWith(
                            color: widget.colors.textPrimary,
                          ),
                        ),
                      ),
                      if (widget.onCollapse != null)
                        Tooltip(
                          message: 'Collapse panel',
                          child: InkWell(
                            onTap: widget.onCollapse,
                            borderRadius: BorderRadius.circular(
                                SkotiqTokens.radiusInline4),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                LucideIcons.panelLeftClose,
                                size: headerIconSize,
                                color: widget.colors.textMuted,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: Responsive.spacing(context, 12)),
                  // Search
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: searchPadding),
                    decoration: BoxDecoration(
                      color: widget.colors.surfaceAlt,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline8),
                      border: Border.all(color: widget.colors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.search,
                          size: searchIconSize,
                          color: widget.colors.textMuted,
                        ),
                        SizedBox(width: Responsive.spacing(context, 8)),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: (value) =>
                                setState(() => _searchQuery = value),
                            style: SkotiqTypography.bodySm.copyWith(
                              color: widget.colors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Search nodes…',
                              hintStyle: SkotiqTypography.bodySm.copyWith(
                                color: widget.colors.textMuted,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: Responsive.spacing(context, 10),
                              ),
                            ),
                          ),
                        ),
                        if (_searchQuery.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            child: Icon(
                              LucideIcons.x,
                              size: searchIconSize,
                              color: widget.colors.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Categories
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
                        onClear: _clearSearch,
                      )
                    : ListView.builder(
                        padding: EdgeInsets.symmetric(
                          vertical: Responsive.spacing(context, 8),
                        ),
                        itemCount: filteredCategories.length,
                        itemBuilder: (context, index) {
                          final category = filteredCategories[index];
                          return _CategorySection(
                            category: category,
                            colors: widget.colors,
                            categoryColor: _getCategoryColor(category.name),
                            getIcon: _getIcon,
                          );
                        },
                      ),
              ),
            ),

            // Insertion target indicator: surfaces *where* the + / tap-to-add
            // affordance will drop the new node so the implicit "selected
            // node is the insert parent" rule is no longer invisible.
            _AddTargetIndicator(colors: widget.colors),

            // Category color legend so the palette is self-describing.
            _PaletteColorLegend(colors: widget.colors),

            // Help tip
            Container(
              padding: EdgeInsets.all(tipPadding),
              margin:
                  EdgeInsets.fromLTRB(tipPadding, 0, tipPadding, tipPadding),
              decoration: SkotiqDecorations.iconChip(
                widget.colors.info,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                borderAlpha: 0.2,
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.info,
                    size: tipIconSize,
                    color: widget.colors.info,
                  ),
                  SizedBox(width: Responsive.spacing(context, 8)),
                  Expanded(
                    child: Text(
                      'Drag nodes to the tree, or tap + to add',
                      style: SkotiqTypography.caption.copyWith(
                        color: widget.colors.info,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _CategorySection extends ConsumerStatefulWidget {
  final NodePaletteCategory category;
  final SkotiqColors colors;
  final Color categoryColor;
  final IconData Function(String) getIcon;
  final bool isMobile;
  final VoidCallback? onNodeAdded;

  const _CategorySection({
    required this.category,
    required this.colors,
    required this.categoryColor,
    required this.getIcon,
    this.isMobile = false,
    this.onNodeAdded,
  });

  @override
  ConsumerState<_CategorySection> createState() => _CategorySectionState();
}

class _CategorySectionState extends ConsumerState<_CategorySection> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    final isMobile = widget.isMobile;

    final badgeSize = isMobile ? 32.0 : Responsive.spacing(context, 28);
    final badgeIconSize = isMobile ? 16.0 : Responsive.iconSize(context, 14);
    final chevronSize = isMobile ? 18.0 : Responsive.iconSize(context, 15);
    final hPadding = isMobile ? 16.0 : Responsive.spacing(context, 16);
    final vPadding = isMobile ? 12.0 : Responsive.spacing(context, 10);
    final itemPadding = isMobile ? 16.0 : Responsive.spacing(context, 12);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category header
        InkWell(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: hPadding,
              vertical: vPadding,
            ),
            child: Row(
              children: [
                Container(
                  width: badgeSize,
                  height: badgeSize,
                  decoration: SkotiqDecorations.statusChip(
                    widget.categoryColor,
                    borderRadius: BorderRadius.circular(isMobile
                        ? SkotiqTokens.radiusInline8
                        : SkotiqTokens.radiusMd),
                    bordered: false,
                  ),
                  child: Icon(
                    widget.getIcon(widget.category.icon),
                    size: badgeIconSize,
                    color: widget.categoryColor,
                  ),
                ),
                SizedBox(width: Responsive.spacing(context, 10)),
                Expanded(
                  child: Text(
                    widget.category.name,
                    style: SkotiqTypography.eyebrow.copyWith(
                      color: widget.colors.textMuted,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _isExpanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: chevronSize,
                    color: widget.colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Items
        AnimatedCrossFade(
          firstChild: Padding(
            padding: EdgeInsets.only(
              left: itemPadding,
              right: itemPadding,
              bottom: 8,
            ),
            child: Column(
              children: widget.category.items.map((item) {
                return _DraggableNodeItem(
                  item: item,
                  colors: widget.colors,
                  categoryColor: widget.categoryColor,
                  getIcon: widget.getIcon,
                  isMobile: isMobile,
                  onNodeAdded: widget.onNodeAdded,
                );
              }).toList(),
            ),
          ),
          secondChild: const SizedBox.shrink(),
          crossFadeState: _isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}

class _DraggableNodeItem extends ConsumerStatefulWidget {
  final NodePaletteItem item;
  final SkotiqColors colors;
  final Color categoryColor;
  final IconData Function(String) getIcon;
  final bool isMobile;
  final VoidCallback? onNodeAdded;

  const _DraggableNodeItem({
    required this.item,
    required this.colors,
    required this.categoryColor,
    required this.getIcon,
    this.isMobile = false,
    this.onNodeAdded,
  });

  @override
  ConsumerState<_DraggableNodeItem> createState() => _DraggableNodeItemState();
}

class _DraggableNodeItemState extends ConsumerState<_DraggableNodeItem> {
  bool _isHovered = false;

  void _addNode() {
    // Refuse the click while the executor owns the
    // tree. Editor still throws SequenceLockedException as a last line
    // of defense; this just keeps the affordance honest.
    if (!ref.read(canEditSequenceProvider)) return;
    final node = widget.item.createNode();
    final selectedId = ref.read(selectedNodeIdProvider);
    final notifier = ref.read(currentSequenceProvider.notifier);
    notifier.addNode(
      node,
      parentId: selectedId,
    );

    // Add any pre-configured children (e.g. Autofocus inside HFR Triggered AF)
    final children = widget.item.createChildren?.call();
    if (children != null) {
      for (final child in children) {
        notifier.addNode(child, parentId: node.id);
      }
    }

    ref.read(selectedNodeIdProvider.notifier).state = node.id;
    widget.onNodeAdded?.call();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(canEditSequenceProvider);
    final isMobile = widget.isMobile;

    final inner = isMobile ? _buildMobileItem() : _buildDesktopItem();

    if (!canEdit) {
      // Disable taps, dragging, and visually wash out the palette item.
      // Wrap in Tooltip so hovering explains why the tile is inert.
      return Tooltip(
        message: 'Cannot edit while sequence is running',
        child: IgnorePointer(
          ignoring: true,
          child: Opacity(opacity: 0.45, child: inner),
        ),
      );
    }
    return inner;
  }

  Widget _buildMobileItem() {
    // FocusRing wraps the InkWell so keyboard nav lands here with a visible
    // accent ring; the InkWell only paints a ripple on pointer events.
    return FocusRing(
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _addNode,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: widget.colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              border: Border.all(color: widget.colors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: SkotiqDecorations.tintedBadge(
                    widget.categoryColor,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                  ),
                  child: Icon(
                    widget.getIcon(widget.item.icon),
                    size: 20,
                    color: widget.categoryColor,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.name,
                        style: SkotiqTypography.h5
                            .copyWith(color: widget.colors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.item.description,
                        style: SkotiqTypography.caption.copyWith(
                          color: widget.colors.textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  LucideIcons.plus,
                  size: 18,
                  color: widget.categoryColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopItem() {
    return Builder(builder: (context) {
      final iconBoxSize = Responsive.spacing(context, 30);
      final itemIconSize = Responsive.iconSize(context, 15);
      final feedbackIconSize = Responsive.iconSize(context, 14);
      final plusIconSize = Responsive.iconSize(context, 13);
      final hPadding = Responsive.spacing(context, 10);
      final vPadding = Responsive.spacing(context, 8);

      return Draggable<NodePaletteItem>(
        data: widget.item,
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            padding:
                EdgeInsets.symmetric(horizontal: hPadding, vertical: vPadding),
            decoration: SkotiqDecorations.selectedSurface(
              widget.categoryColor,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              fillAlpha: 0.2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.getIcon(widget.item.icon),
                  size: feedbackIconSize,
                  color: widget.categoryColor,
                ),
                SizedBox(width: Responsive.spacing(context, 8)),
                Text(
                  paletteSentenceCase(widget.item.name),
                  style: SkotiqTypography.bodySm.copyWith(
                    color: widget.colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        // FocusRing surfaces keyboard focus on the otherwise mouse-only
        // GestureDetector (double-tap activator), keeping the node palette
        // navigable for keyboard-only users.
        child: FocusRing(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: GestureDetector(
              onDoubleTap: _addNode,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(top: 4),
                padding: EdgeInsets.symmetric(
                    horizontal: hPadding, vertical: vPadding),
                decoration: BoxDecoration(
                  color: _isHovered
                      ? widget.colors.surfaceAlt
                      : widget.colors.background,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(
                    color: _isHovered
                        ? widget.categoryColor.withValues(alpha: 0.5)
                        : widget.colors.border,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: iconBoxSize,
                      height: iconBoxSize,
                      decoration: SkotiqDecorations.tintedBadge(
                        widget.categoryColor,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusMd),
                      ),
                      child: Icon(
                        widget.getIcon(widget.item.icon),
                        size: itemIconSize,
                        color: widget.categoryColor,
                      ),
                    ),
                    SizedBox(width: Responsive.spacing(context, 10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            paletteSentenceCase(widget.item.name),
                            style: SkotiqTypography.bodySm.copyWith(
                              color: _isHovered
                                  ? widget.colors.textPrimary
                                  : widget.colors.textSecondary,
                            ),
                          ),
                          Text(
                            widget.item.description,
                            style: SkotiqTypography.caption.copyWith(
                              color: widget.colors.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    // Always-visible add button: a single tap adds the node
                    // (drag still works on the surrounding tile).
                    Tooltip(
                      message: 'Add to sequence',
                      child: GestureDetector(
                        onTap: _addNode,
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            LucideIcons.plus,
                            size: plusIconSize,
                            color: _isHovered
                                ? widget.categoryColor
                                : widget.categoryColor.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// Shows where the palette's add affordance (+ / tap) will drop the new
/// node: under the currently-selected node, or at the sequence root when
/// nothing is selected. Surfaces the otherwise-invisible implicit-parent
/// rule so the user isn't surprised by where a node lands.
class _AddTargetIndicator extends ConsumerWidget {
  final SkotiqColors colors;

  const _AddTargetIndicator({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedNodeProvider);
    final targetLabel = selected?.name ?? 'Sequence root';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Icon(LucideIcons.plus, size: 13, color: colors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Adds to: ',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                  TextSpan(
                    text: targetLabel,
                    style: SkotiqTypography.buttonSm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact category color legend, surfaced in the palette so the swatches
/// the tree uses are documented next to where the user picks nodes. Reads
/// the same [nodePaletteCategoryColor] map the palette items use so the
/// swatches always match.
class _PaletteColorLegend extends StatelessWidget {
  final SkotiqColors colors;

  const _PaletteColorLegend({required this.colors});

  static const _entries = <String>[
    'Target',
    'Imaging',
    'Science',
    'Mount',
    'Camera',
    'Focus',
    'Logic',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          for (final name in _entries)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: nodePaletteCategoryColor(name, colors),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline2),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  name,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
