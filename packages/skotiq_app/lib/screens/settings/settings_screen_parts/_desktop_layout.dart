// Desktop search field, grouped nav list and search-result widgets.
part of '../settings_screen.dart';

// Geometry of the settings navigation column (06 §Settings, mockups/settings.html).

/// Width of the left navigation column.
const double _navWidth = 240;

/// Height of one navigation item.
const double _navItemHeight = 34;

/// Leading icon size inside a navigation item.
const double _navIconSize = 15;

// Search field

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.colors,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final SkotiqColors colors;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return SkotiqTextField(
      controller: controller,
      onChanged: onChanged,
      hint: context.l10n.text('settingsSearchHint'),
      prefixIcon: LucideIcons.search,
      dense: true,
      suffixWidget: controller.text.isEmpty
          ? null
          : SkotiqIconButton(
              icon: LucideIcons.x,
              tooltip: 'Clear the search',
              size: IconButtonSize.sm,
              onPressed: onClear,
            ),
    );
  }
}

// Desktop: the navigation column

/// The 240 px left column: search field, then eyebrow-labelled groups of
/// section items (06 §Settings).
///
/// The groups do not collapse. The mockup's nav is a flat, scannable list under
/// three quiet labels; a chevron per group turned the taxonomy itself into
/// eleven controls the operator had to operate before they could read it.
class _DesktopNav extends StatelessWidget {
  const _DesktopNav({
    required this.groups,
    required this.selectedKey,
    required this.colors,
    required this.searchController,
    required this.searching,
    required this.results,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onSelect,
  });

  final List<SettingsGroupDef> groups;
  final String selectedKey;
  final SkotiqColors colors;
  final TextEditingController searchController;
  final bool searching;
  final List<SettingsSearchResult> results;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final void Function(String key, String? rowTitle) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _navWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceXs,
              0,
              SkotiqTokens.spaceXs,
              SkotiqTokens.spaceSm,
            ),
            child: _SearchField(
              controller: searchController,
              colors: colors,
              onChanged: onQueryChanged,
              onClear: onClearQuery,
            ),
          ),
          Expanded(
            child: searching
                ? _DesktopSearchResults(
                    results: results,
                    selectedKey: selectedKey,
                    colors: colors,
                    onTap: onSelect,
                  )
                : _DesktopGroupedList(
                    groups: groups,
                    selectedKey: selectedKey,
                    colors: colors,
                    onSelect: (key) => onSelect(key, null),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DesktopGroupedList extends StatelessWidget {
  const _DesktopGroupedList({
    required this.groups,
    required this.selectedKey,
    required this.colors,
    required this.onSelect,
  });

  final List<SettingsGroupDef> groups;
  final String selectedKey;
  final SkotiqColors colors;
  final void Function(String key) onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: SettingsTutorialKeys.categories,
      padding: EdgeInsets.zero,
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Display title: the group's `title` is the structural id and stays
            // English, so rendering it would leave the header untranslated
            // above translated child items.
            _NavEyebrow(label: group.displayTitle, colors: colors),
            ...group.sections.map(
              (section) => _CategoryItem(
                icon: section.icon,
                label: section.label,
                isSelected: section.key == selectedKey,
                onTap: () => onSelect(section.key),
                colors: colors,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The quiet group label above a run of navigation items.
class _NavEyebrow extends StatelessWidget {
  const _NavEyebrow({required this.label, required this.colors});

  final String label;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceXs,
      ),
      child: Text(
        label.toUpperCase(),
        style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
      ),
    );
  }
}

// Desktop: flat search results

class _DesktopSearchResults extends StatelessWidget {
  const _DesktopSearchResults({
    required this.results,
    required this.selectedKey,
    required this.colors,
    required this.onTap,
  });

  final List<SettingsSearchResult> results;
  final String selectedKey;
  final SkotiqColors colors;
  final void Function(String key, String? rowTitle) onTap;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const EmptyState.compact(
        icon: LucideIcons.searchX,
        title: 'No settings match',
        body:
            'Try a shorter word, or the name of the thing you want to change.',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
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
              isSelected: section.key == selectedKey,
              onTap: () => onTap(section.key, null),
              colors: colors,
            ),
            // The rows that actually matched. Tapping one opens the section
            // scrolled to that row instead of at the top of a long page.
            for (final row in result.rows)
              _SearchRowResult(
                label: row,
                colors: colors,
                onTap: () => onTap(section.key, row),
                // The sidebar list already pads its own sides.
                endInset: 0,
              ),
          ],
        );
      },
    );
  }
}

/// A single matched setting beneath its section in the search results.
class _SearchRowResult extends StatefulWidget {
  const _SearchRowResult({
    required this.label,
    required this.colors,
    required this.onTap,
    required this.endInset,
  });

  final String label;
  final SkotiqColors colors;
  final VoidCallback onTap;

  /// Space between the row's rounded container and the trailing edge of the
  /// list, stated by the layout that owns the list rather than assumed here.
  ///
  /// The desktop sidebar pads its own list; the mobile list is full-bleed, so
  /// its section rows can carry an edge-to-edge divider. Inset on the left only,
  /// this row ran flat off the right edge of a 430px window with its corner
  /// radius cut away, while the section rows above and below it were inset on
  /// both sides.
  final double endInset;

  @override
  State<_SearchRowResult> createState() => _SearchRowResultState();
}

class _SearchRowResultState extends State<_SearchRowResult> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Semantics(
      // Semantics publishes isEnabled only when this field is given;
      // omitting it makes assistive tech announce a live control as
      // disabled. Measured on the running app 2026-08-09.
      enabled: true,
      button: true,
      child: InkWell(
        onTap: widget.onTap,
        onFocusChange: (value) => setState(() => _focused = value),
        borderRadius: SkotiqTokens.borderRadiusSm,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Container(
            margin: EdgeInsets.only(
              left: SkotiqTokens.spaceXl,
              right: widget.endInset,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceMd,
              vertical: SkotiqTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              color: _hovered ? colors.surfaceHover : Colors.transparent,
              borderRadius: SkotiqTokens.borderRadiusSm,
              border:
                  _focused ? Border.all(color: colors.primary, width: 2) : null,
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.cornerDownRight,
                  size: SkotiqTokens.iconXs,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
