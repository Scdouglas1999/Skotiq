part of '../darkroom_screen.dart';

/// Below this window width the header chip's text is shortened.
const double _narrowHeader = 600;

/// The tab icons, in [DarkroomTab] order.
IconData _darkroomTabIcon(DarkroomTab tab) => switch (tab) {
      DarkroomTab.targets => SkotiqIcons.target,
      DarkroomTab.calibration => SkotiqIcons.sliders,
      DarkroomTab.edit => SkotiqIcons.edit,
      DarkroomTab.activity => SkotiqIcons.activity,
    };

/// The Darkroom's four tabs under the standard page header. The selected tab
/// lives in the location, so a link, a notification or Back reopens it.
class _DarkroomTabsView extends StatelessWidget {
  const _DarkroomTabsView({required this.route});

  final DarkroomRoute route;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Darkroom',
          icon: SkotiqIcons.aperture,
          tabs: AdaptiveTabBar(
            tabs: [
              for (final tab in DarkroomTab.values)
                AdaptiveTab(
                  label: tab.label,
                  icon: _darkroomTabIcon(tab),
                  buttonKey: ValueKey('darkroom_tab_${tab.name}'),
                ),
            ],
            selectedIndex: route.tab.index,
            onSelected: (index) {
              final tab = DarkroomTab.values[index];
              if (tab == route.tab && route.target == null) return;
              context.go(darkroomTabLocation(tab));
            },
          ),
          actions: [
            // A phone header keeps the title and the chip on one row.
            DarkroomStatusChip(
              maxValueWidth:
                  MediaQuery.sizeOf(context).width < _narrowHeader ? 120 : 320,
            ),
          ],
        ),
        const _ActiveLiveStacksStrip(),
        Expanded(
          child: DarkroomRouteScope(
            route: route,
            child: switch (route.tab) {
              DarkroomTab.targets => const DarkroomTargetsTab(),
              DarkroomTab.calibration => const DarkroomCalibrationTab(),
              DarkroomTab.edit => const DarkroomEditTab(),
              DarkroomTab.activity => const DarkroomActivityTab(),
            },
          ),
        ),
      ],
    );
  }
}

/// Active-only strip surfacing live stacks inside the Darkroom so operators can
/// promote any running per-filter live stack directly into the full Darkroom
/// editor in one click. Completely hidden (`SizedBox.shrink`) when idle.
class _ActiveLiveStacksStrip extends ConsumerStatefulWidget {
  const _ActiveLiveStacksStrip();

  @override
  ConsumerState<_ActiveLiveStacksStrip> createState() =>
      _ActiveLiveStacksStripState();
}

class _ActiveLiveStacksStripState
    extends ConsumerState<_ActiveLiveStacksStrip> {
  String? _promotingKey;

  Future<void> _promote(String filterKey) async {
    if (_promotingKey != null) return;
    final refusal = darkroomHostOnlyRefusal(ref);
    if (refusal != null) {
      context.showInfoSnackBar(refusal);
      return;
    }
    setState(() => _promotingKey = filterKey);
    try {
      final promoted = await promoteLiveStackToDarkroom(
        ref: ref,
        filterKey: filterKey,
      );
      if (!mounted) return;
      final loc = promoted.recipeId != null
          ? darkroomEditLocation(
              masterId: promoted.masterId,
              recipeId: promoted.recipeId,
            )
          : darkroomEditLocation(masterId: promoted.masterId);
      context.go(loc);
    } catch (error) {
      if (!mounted) return;
      context.showErrorSnackBar(
        'Could not open live stack: ${userFacingError(error)}',
      );
    } finally {
      if (mounted) setState(() => _promotingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(isRemoteClientProvider)) return const SizedBox.shrink();
    final hasStacks = ref.watch(
      liveStackingProvider.select((s) => s.hasStackedFrames),
    );
    if (!hasStacks) return const SizedBox.shrink();

    final stack = ref.watch(liveStackingProvider);
    final colors = SkotiqColors.of(context);
    final filters = stack.availableFilters;
    if (filters.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const ValueKey('darkroom_active_live_stacks_strip'),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: Row(
        children: <Widget>[
          StatusDot(
            color: colors.success,
            live: stack.status == LiveStackingStatus.running,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            'Active live stacks',
            style: SkotiqTypography.labelSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (var i = 0; i < filters.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: SkotiqTokens.spaceSm),
                    _LiveStackPromoteChip(
                      filterKey: filters[i],
                      snapshot: stack.filterStacks[filters[i]]!,
                      busy: _promotingKey == filters[i],
                      colors: colors,
                      onTap: _promotingKey == null
                          ? () => _promote(filters[i])
                          : null,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveStackPromoteChip extends StatelessWidget {
  const _LiveStackPromoteChip({
    required this.filterKey,
    required this.snapshot,
    required this.busy,
    required this.colors,
    required this.onTap,
  });

  final String filterKey;
  final FilterStackSnapshot snapshot;
  final bool busy;
  final SkotiqColors colors;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final frames = snapshot.stats.stackedFrameCount;
    final label = liveStackFilterDisplayName(filterKey);
    final integration = formatLiveIntegration(snapshot.totalIntegrationSecs);
    final dotColor = liveStackFilterDotColor(filterKey, colors);

    return InkWell(
      key: ValueKey('darkroom_live_stack_chip_$filterKey'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          border: Border.all(color: colors.border),
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
              '$label · $frames f'
              '${integration != '—' ? ' · $integration' : ''}',
              style: SkotiqTypography.monoCaption.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              busy ? 'Opening…' : 'Develop →',
              style: SkotiqTypography.labelSm.copyWith(
                color: colors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
