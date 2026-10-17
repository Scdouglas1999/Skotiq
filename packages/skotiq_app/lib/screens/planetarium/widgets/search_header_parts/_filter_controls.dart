// Search filter controls and the search category header.
part of '../search_header.dart';

/// Filter controls panel for search
class _SearchFilterControls extends StatelessWidget {
  final SkotiqColors colors;
  final SearchFilters filters;
  final ValueChanged<SearchFilters> onFiltersChanged;

  const _SearchFilterControls({
    required this.colors,
    required this.filters,
    required this.onFiltersChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Object type filter chips
        Text(
          'Object Type',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            fontWeight: FontWeight.w600,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: SearchObjectTypeFilter.values.map((type) {
            final isSelected = filters.typeFilter == type;
            return GestureDetector(
              onTap: () => onFiltersChanged(filters.copyWith(typeFilter: type)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isSelected
                      ? colors.accent.withValues(alpha: 0.2)
                      : colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(
                    color: isSelected ? colors.accent : colors.border,
                  ),
                ),
                child: Text(
                  _typeFilterLabel(type),
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected ? colors.accent : colors.textSecondary,
                  ),
                ),
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: 12),

        // Magnitude range
        Row(
          children: [
            Text(
              'Magnitude',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                fontWeight: FontWeight.w600,
                color: colors.textMuted,
              ),
            ),
            const Spacer(),
            if (filters.maxMagnitude != null)
              GestureDetector(
                onTap: () =>
                    onFiltersChanged(filters.copyWith(clearMaxMagnitude: true)),
                child: Text(
                  'Clear',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: colors.accent,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              'Max:',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: colors.accent,
                  inactiveTrackColor: colors.border,
                  thumbColor: colors.accent,
                ),
                child: Slider(
                  value: filters.maxMagnitude ?? 20.0,
                  min: 1.0,
                  max: 20.0,
                  divisions: 38,
                  onChanged: (val) =>
                      onFiltersChanged(filters.copyWith(maxMagnitude: val)),
                ),
              ),
            ),
            SizedBox(
              width: 32,
              child: Text(
                filters.maxMagnitude?.toStringAsFixed(1) ?? '--',
                style: SkotiqTypography.labelQuiet
                    .copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Observable now toggle
        GestureDetector(
          onTap: () => onFiltersChanged(
              filters.copyWith(observableNow: !filters.observableNow)),
          child: Row(
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: filters.observableNow
                      ? colors.accent
                      : Colors.transparent,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                  border: Border.all(
                    color:
                        filters.observableNow ? colors.accent : colors.border,
                    width: 1.5,
                  ),
                ),
                child: filters.observableNow
                    ? Icon(SkotiqIcons.check, size: 12, color: colors.surface)
                    : null,
              ),
              const SizedBox(width: 8),
              Text(
                'Observable now (>10\u00b0 alt)',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: filters.observableNow
                      ? colors.textPrimary
                      : colors.textSecondary,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // Constellation filter
        Row(
          children: [
            Text(
              'Constellation:',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                fontWeight: FontWeight.w600,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 28,
                child: TextField(
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. Orion',
                    hintStyle: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textMuted),
                    filled: true,
                    fillColor: colors.surfaceAlt,
                    border: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                      borderSide: BorderSide(color: colors.primary),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    isDense: true,
                  ),
                  onChanged: (val) {
                    if (val.isEmpty) {
                      onFiltersChanged(
                          filters.copyWith(clearConstellation: true));
                    } else {
                      onFiltersChanged(
                          filters.copyWith(constellationFilter: val));
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _typeFilterLabel(SearchObjectTypeFilter type) {
    switch (type) {
      case SearchObjectTypeFilter.all:
        return 'All';
      case SearchObjectTypeFilter.stars:
        return 'Stars';
      case SearchObjectTypeFilter.galaxies:
        return 'Galaxies';
      case SearchObjectTypeFilter.nebulae:
        return 'Nebulae';
      case SearchObjectTypeFilter.clusters:
        return 'Clusters';
    }
  }
}

/// Category header for grouped search results
class SearchCategoryHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final SkotiqColors colors;

  const SearchCategoryHeader({
    super.key,
    required this.title,
    required this.icon,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.5),
        border: Border(
            bottom: BorderSide(color: colors.border.withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: colors.textMuted),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w600,
              color: colors.textMuted,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
