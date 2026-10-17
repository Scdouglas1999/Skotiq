part of '../snippet_palette.dart';

class _SnippetCategorySection extends StatefulWidget {
  final SnippetCategory category;
  final List<TemplateSnippet> snippets;
  final SkotiqColors colors;
  final Color categoryColor;
  final String categoryName;
  final IconData categoryIcon;
  final IconData Function(String) getIcon;
  final bool isMobile;
  final bool platformHasShareSheet;
  final Function(TemplateSnippet)? onSnippetDragStart;
  final Function(TemplateSnippet)? onSnippetTap;
  final Function(TemplateSnippet)? onDeleteSnippet;
  final Function(TemplateSnippet)? onExportSnippet;
  final Function(TemplateSnippet)? onShareSnippet;

  const _SnippetCategorySection({
    required this.category,
    required this.snippets,
    required this.colors,
    required this.categoryColor,
    required this.categoryName,
    required this.categoryIcon,
    required this.getIcon,
    this.isMobile = false,
    this.platformHasShareSheet = false,
    this.onSnippetDragStart,
    this.onSnippetTap,
    this.onDeleteSnippet,
    this.onExportSnippet,
    this.onShareSnippet,
  });

  @override
  State<_SnippetCategorySection> createState() =>
      _SnippetCategorySectionState();
}

class _SnippetCategorySectionState extends State<_SnippetCategorySection> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    final isMobile = widget.isMobile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category header
        InkWell(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 16 : 16,
              vertical: isMobile ? 12 : 8,
            ),
            child: Row(
              children: [
                Container(
                  width: isMobile ? 32 : 24,
                  height: isMobile ? 32 : 24,
                  decoration: SkotiqDecorations.statusChip(
                    widget.categoryColor,
                    borderRadius: BorderRadius.circular(isMobile
                        ? SkotiqTokens.radiusInline8
                        : SkotiqTokens.radiusMd),
                    bordered: false,
                  ),
                  child: Icon(
                    widget.categoryIcon,
                    size: isMobile ? 16 : 12,
                    color: widget.categoryColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.categoryName,
                    style: TextStyle(
                      fontSize: isMobile
                          ? SkotiqTypography.fontSize14
                          : SkotiqTypography.fontSize12,
                      fontWeight: FontWeight.w600,
                      color: widget.colors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${widget.snippets.length}',
                  style: TextStyle(
                    fontSize: isMobile
                        ? SkotiqTypography.fontSize12
                        : SkotiqTypography.fontSize10,
                    color: widget.colors.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedRotation(
                  turns: _isExpanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: isMobile ? 18 : 14,
                    color: widget.colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Snippet items
        AnimatedCrossFade(
          firstChild: Padding(
            padding: EdgeInsets.only(
              left: isMobile ? 16 : 12,
              right: isMobile ? 16 : 12,
              bottom: 8,
            ),
            child: Column(
              children: widget.snippets.map((snippet) {
                return _DraggableSnippetItem(
                  snippet: snippet,
                  colors: widget.colors,
                  categoryColor: widget.categoryColor,
                  getIcon: widget.getIcon,
                  isMobile: isMobile,
                  platformHasShareSheet: widget.platformHasShareSheet,
                  onSnippetDragStart: widget.onSnippetDragStart,
                  onSnippetTap: widget.onSnippetTap,
                  onDelete: widget.onDeleteSnippet,
                  onExport: widget.onExportSnippet,
                  onShare: widget.onShareSnippet,
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
