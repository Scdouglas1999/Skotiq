part of '../snippet_palette.dart';

class _DraggableSnippetItem extends StatefulWidget {
  final TemplateSnippet snippet;
  final SkotiqColors colors;
  final Color categoryColor;
  final IconData Function(String) getIcon;
  final bool isMobile;
  final bool platformHasShareSheet;
  final Function(TemplateSnippet)? onSnippetDragStart;
  final Function(TemplateSnippet)? onSnippetTap;
  final Function(TemplateSnippet)? onDelete;
  final Function(TemplateSnippet)? onExport;
  final Function(TemplateSnippet)? onShare;

  const _DraggableSnippetItem({
    required this.snippet,
    required this.colors,
    required this.categoryColor,
    required this.getIcon,
    this.isMobile = false,
    this.platformHasShareSheet = false,
    this.onSnippetDragStart,
    this.onSnippetTap,
    this.onDelete,
    this.onExport,
    this.onShare,
  });

  @override
  State<_DraggableSnippetItem> createState() => _DraggableSnippetItemState();
}

class _DraggableSnippetItemState extends State<_DraggableSnippetItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isMobile = widget.isMobile;

    // On mobile, use tap instead of drag
    if (isMobile) {
      return _buildMobileItem();
    }

    return _buildDesktopItem();
  }

  Widget _buildMobileItem() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onSnippetTap?.call(widget.snippet),
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
                  widget.getIcon(widget.snippet.iconName),
                  size: 20,
                  color: widget.categoryColor,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.snippet.name,
                            style: SkotiqTypography.h5
                                .copyWith(color: widget.colors.textPrimary),
                          ),
                        ),
                        if (widget.snippet.isBuiltIn)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: SkotiqDecorations.tintedBadge(
                              widget.colors.info,
                              borderRadius: BorderRadius.circular(
                                  SkotiqTokens.radiusInline4),
                            ),
                            child: Text(
                              'Built-in',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize10,
                                fontWeight: FontWeight.w500,
                                color: widget.colors.info,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.snippet.description,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: widget.colors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _buildOverflowMenu(iconSize: 18),
              if (widget.snippet.isBuiltIn)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    LucideIcons.plus,
                    size: 18,
                    color: widget.categoryColor,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopItem() {
    return Draggable<TemplateSnippet>(
      data: widget.snippet,
      onDragStarted: () => widget.onSnippetDragStart?.call(widget.snippet),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: widget.categoryColor.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border:
                Border.all(color: widget.categoryColor.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(
                color: widget.categoryColor.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.getIcon(widget.snippet.iconName),
                size: 14,
                color: widget.categoryColor,
              ),
              const SizedBox(width: 8),
              Text(
                widget.snippet.name,
                style: SkotiqTypography.labelSm
                    .copyWith(color: widget.colors.textPrimary),
              ),
            ],
          ),
        ),
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.colors.surfaceAlt
                : widget.colors.background,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: _isHovered
                  ? widget.categoryColor.withValues(alpha: 0.5)
                  : widget.colors.border,
            ),
          ),
          child: Row(
            children: [
              // Double-click covers the CARD BODY only. Keeping it as an
              // ancestor of the '+' made every click on '+' wait out the
              // double-tap timeout before anything happened, because a
              // pending DoubleTapGestureRecognizer holds the gesture arena.
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => widget.onSnippetTap?.call(widget.snippet),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: SkotiqDecorations.tintedBadge(
                          widget.categoryColor,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusMd),
                        ),
                        child: Icon(
                          widget.getIcon(widget.snippet.iconName),
                          size: 14,
                          color: widget.categoryColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.snippet.name,
                                    style: SkotiqTypography.labelQuiet.copyWith(
                                        color: _isHovered
                                            ? widget.colors.textPrimary
                                            : widget.colors.textSecondary),
                                  ),
                                ),
                                if (widget.snippet.isBuiltIn)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: SkotiqDecorations.tintedBadge(
                                      widget.colors.info,
                                      borderRadius: BorderRadius.circular(
                                          SkotiqTokens.radiusXs),
                                    ),
                                    child: Text(
                                      'Built-in',
                                      style: TextStyle(
                                        fontSize: SkotiqTypography.fontSize8,
                                        fontWeight: FontWeight.w500,
                                        color: widget.colors.info,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            Text(
                              widget.snippet.description,
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize9,
                                color: widget.colors.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_isHovered) ...[
                _buildOverflowMenu(iconSize: 14),
                const SizedBox(width: 4),
              ],
              // The '+' is a real, always-visible button, so the panel's own
              // "tap to insert" promise has a handler behind it — a bare
              // hover-only Icon leaves drag as the only working path.
              Semantics(
                // Semantics publishes isEnabled only when this field is given;
                // omitting it makes assistive tech announce a live control as
                // disabled. Measured on the running app 2026-08-09.
                enabled: true,
                button: true,
                label: 'Insert ${widget.snippet.name}',
                child: Tooltip(
                  message: 'Insert into sequence',
                  excludeFromSemantics: true,
                  child: GestureDetector(
                    onTap: () => widget.onSnippetTap?.call(widget.snippet),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        LucideIcons.plus,
                        size: 12,
                        color: _isHovered
                            ? widget.categoryColor
                            : widget.categoryColor.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact context menu offering Export / Share / Delete actions.
  ///
  /// Built-in snippets get Export (so the user can share a copy of a
  /// preset) but not Delete (built-ins are not user-owned). When the
  /// running platform has no system share sheet, the Share entry is
  /// hidden — desktop users get Export which produces the same file
  /// they can attach to anything manually.
  Widget _buildOverflowMenu({required double iconSize}) {
    return PopupMenuButton<_SnippetAction>(
      tooltip: 'Snippet actions',
      icon: Icon(
        LucideIcons.moreVertical,
        size: iconSize,
        color: widget.colors.textMuted,
      ),
      padding: EdgeInsets.zero,
      iconSize: iconSize,
      splashRadius: iconSize + 4,
      color: widget.colors.surfaceOverlay,
      onSelected: (action) {
        switch (action) {
          case _SnippetAction.export:
            widget.onExport?.call(widget.snippet);
            break;
          case _SnippetAction.share:
            widget.onShare?.call(widget.snippet);
            break;
          case _SnippetAction.delete:
            widget.onDelete?.call(widget.snippet);
            break;
        }
      },
      itemBuilder: (ctx) {
        final items = <PopupMenuEntry<_SnippetAction>>[
          PopupMenuItem(
            value: _SnippetAction.export,
            child: _menuRow(
              LucideIcons.download,
              'Export…',
              widget.colors.textPrimary,
            ),
          ),
        ];
        if (widget.platformHasShareSheet) {
          items.add(
            PopupMenuItem(
              value: _SnippetAction.share,
              child: _menuRow(
                LucideIcons.share2,
                'Share…',
                widget.colors.textPrimary,
              ),
            ),
          );
        }
        if (!widget.snippet.isBuiltIn) {
          items.add(const PopupMenuDivider());
          items.add(
            PopupMenuItem(
              value: _SnippetAction.delete,
              child: _menuRow(
                LucideIcons.trash2,
                'Delete',
                widget.colors.error,
              ),
            ),
          );
        }
        return items;
      },
    );
  }

  Widget _menuRow(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 10),
        Text(label,
            style:
                TextStyle(color: color, fontSize: SkotiqTypography.fontSize13)),
      ],
    );
  }
}

enum _SnippetAction { export, share, delete }
