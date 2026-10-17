// Narrow-layout section list, search results and the shared nav item.
part of '../settings_screen.dart';

// Narrow: one flat list with search

class _MobileSectionList extends StatelessWidget {
  const _MobileSectionList({
    required this.groups,
    required this.searchController,
    required this.query,
    required this.results,
    required this.onQueryChanged,
    required this.onSectionTap,
    required this.colors,
    required this.title,
  });

  final List<SettingsGroupDef> groups;
  final TextEditingController searchController;
  final String query;
  final List<SettingsSearchResult> results;
  final ValueChanged<String> onQueryChanged;
  final void Function(String key, String? rowTitle) onSectionTap;
  final SkotiqColors colors;
  final String title;

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The app shell may consume the keyboard inset before this screen can
        // observe it. Actual remaining height is therefore the reliable signal
        // for a route-level search field: keep only the field in the transient
        // compact viewport and restore the title when the keyboard closes.
        final keyboardCompact = constraints.maxHeight < 160;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!keyboardCompact)
              SafeArea(
                bottom: false,
                child: PageHeader(icon: LucideIcons.settings, title: title),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceMd,
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceSm,
              ),
              child: _SearchField(
                controller: searchController,
                colors: colors,
                onChanged: onQueryChanged,
                onClear: () {
                  searchController.clear();
                  onQueryChanged('');
                },
              ),
            ),
            Expanded(
              // Sides + bottom SafeArea so list rows clear a rotated phone's
              // notch / home indicator in landscape (the header handles the top).
              child: SafeArea(
                top: false,
                child: searching
                    ? _MobileSearchResults(
                        results: results,
                        colors: colors,
                        onSectionTap: onSectionTap,
                      )
                    : ListView.builder(
                        key: SettingsTutorialKeys.categories,
                        padding: const EdgeInsets.symmetric(
                          horizontal: SkotiqTokens.spaceSm,
                          vertical: SkotiqTokens.spaceSm,
                        ),
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          final group = groups[index];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _NavEyebrow(
                                label: group.displayTitle,
                                colors: colors,
                              ),
                              ...group.sections.map(
                                (section) => _CategoryItem(
                                  icon: section.icon,
                                  label: section.label,
                                  isSelected: false,
                                  onTap: () => onSectionTap(section.key, null),
                                  colors: colors,
                                  isMobile: true,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MobileSearchResults extends StatelessWidget {
  const _MobileSearchResults({
    required this.results,
    required this.colors,
    required this.onSectionTap,
  });

  final List<SettingsSearchResult> results;
  final SkotiqColors colors;
  final void Function(String key, String? rowTitle) onSectionTap;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.searchX,
        title: 'No settings match',
        body:
            'Try a shorter word, or the name of the thing you want to change.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceSm,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        final section = result.section;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CategoryItem(
              icon: section.icon,
              label: section.label,
              isSelected: false,
              onTap: () => onSectionTap(section.key, null),
              colors: colors,
              isMobile: true,
            ),
            for (final row in result.rows)
              _SearchRowResult(
                label: row,
                colors: colors,
                onTap: () => onSectionTap(section.key, row),
                // The same trailing inset the section rows of this list carry,
                // so the sub-result's rounded corner is on screen with them.
                endInset: SkotiqTokens.spaceSm,
              ),
          ],
        );
      },
    );
  }
}

// The shared navigation item, used by both the 240 px column and the narrow
// list.

class _CategoryItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  /// Narrow layout: a taller touch target with a trailing chevron, because at
  /// this width the row is a navigation step rather than a selection.
  final bool isMobile;

  const _CategoryItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
    this.isMobile = false,
  });

  @override
  State<_CategoryItem> createState() => _CategoryItemState();
}

class _CategoryItemState extends State<_CategoryItem> {
  bool _isHovered = false;
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final selected = widget.isSelected;
    final ink = selected ? colors.primary : colors.textSecondary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      // A settings section is a CONTROL, not a panel: as a bare GestureDetector
      // keyboard-only and screen-reader users cannot change section at all.
      // InkWell supplies traversal, Enter/Space activation and the button role
      // in one widget; Semantics adds the selected state so AT can announce
      // which section is open.
      child: MergeSemantics(
        child: Semantics(
          // Semantics publishes isEnabled only when this field is given;
          // omitting it makes assistive tech announce a live control as
          // disabled.
          enabled: true,
          button: true,
          selected: selected,
          child: InkWell(
            onTap: widget.onTap,
            onFocusChange: (value) => setState(() => _isFocused = value),
            borderRadius: SkotiqTokens.borderRadiusSm,
            child: Container(
              height: widget.isMobile
                  ? SkotiqTokens.minTouchTarget
                  : _navItemHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceMd,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? colors.primary.withValues(
                        alpha: SkotiqTokens.opacityAccentTint,
                      )
                    : _isHovered
                        ? colors.surfaceHover
                        : Colors.transparent,
                borderRadius: SkotiqTokens.borderRadiusSm,
                // Keyboard focus has to be VISIBLE, not just held. Selection
                // keeps its softer tint, so the two states stay apart.
                border: _isFocused
                    ? Border.all(color: colors.primary, width: 2)
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: _navIconSize,
                    color: selected ? colors.primary : colors.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.button.copyWith(color: ink),
                    ),
                  ),
                  if (widget.isMobile)
                    Icon(
                      LucideIcons.chevronRight,
                      size: _navIconSize,
                      color: colors.textMuted,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
