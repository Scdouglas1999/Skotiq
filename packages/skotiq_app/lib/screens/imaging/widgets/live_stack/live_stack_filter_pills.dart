import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'live_stack_formatters.dart';
import 'package:skotiq_core/models.dart';

/// Compact Observatory per-filter live stack selector strip.
///
/// Renders one selectable pill per active filter stack with its filter
/// chart-palette dot, filter name, frame count, and optional integration time.
/// Shared between the Live Stack canvas toolbar and Night Control's frame stage
/// so filter switching works identically in both places.
class LiveStackFilterPills extends StatelessWidget {
  const LiveStackFilterPills({
    super.key,
    required this.filters,
    required this.stacks,
    required this.selectedFilter,
    required this.onSelect,
    this.showIntegration = true,
    this.compact = false,
  });

  final List<String> filters;
  final Map<String, FilterStackSnapshot> stacks;
  final String? selectedFilter;
  final ValueChanged<String> onSelect;
  final bool showIntegration;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (filters.isEmpty) return const SizedBox.shrink();
    final colors = SkotiqColors.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < filters.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: SkotiqTokens.spaceXs + 2),
            _FilterStackPill(
              filterKey: filters[i],
              snapshot: stacks[filters[i]],
              selected: filters[i] == selectedFilter,
              colors: colors,
              showIntegration: showIntegration,
              compact: compact,
              onTap: () => onSelect(filters[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterStackPill extends StatelessWidget {
  const _FilterStackPill({
    required this.filterKey,
    required this.snapshot,
    required this.selected,
    required this.colors,
    required this.showIntegration,
    required this.compact,
    required this.onTap,
  });

  final String filterKey;
  final FilterStackSnapshot? snapshot;
  final bool selected;
  final SkotiqColors colors;
  final bool showIntegration;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final frames = snapshot?.stats.stackedFrameCount ?? 0;
    final integration = snapshot?.totalIntegrationSecs ?? 0.0;
    final label = liveStackFilterDisplayName(filterKey);
    final dotColor = liveStackFilterDotColor(filterKey, colors);
    final integrationText = showIntegration && integration > 0
        ? ' · ${formatLiveIntegration(integration)}'
        : '';

    return Semantics(
      button: true,
      selected: selected,
      label: '$label live stack, $frames frames$integrationText',
      child: InkWell(
        key: ValueKey('live_stack_filter_pill_$filterKey'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        child: AnimatedContainer(
          duration: SkotiqTokens.durationFast,
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 5,
          ),
          decoration: BoxDecoration(
            color:
                selected ? colors.primary.withValues(alpha: 0.16) : colors.well,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            border: Border.all(
              color: selected
                  ? colors.primary.withValues(alpha: 0.7)
                  : colors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: SkotiqTypography.labelSm.copyWith(
                  color: selected ? colors.textPrimary : colors.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$frames$integrationText',
                style: SkotiqTypography.monoCaption.copyWith(
                  color: selected ? colors.primary : colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
