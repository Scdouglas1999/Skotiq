// Top-of-screen chrome: the planner header (title + icon) and the controls bar that arranges search, filter chips, and sort.
part of '../planner_screen.dart';

/// The two facts the page header carries about tonight: the moon's
/// illumination and the astronomical-dark window.
///
/// Both are measured FROM the observing site, so with no site there is nothing
/// to state and the chips are absent — the tab body's one `EmptyState` is then
/// the single place that problem is represented (06 §Plan; 02 rule 5).
class _PlanNightChips extends ConsumerWidget {
  const _PlanNightChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(appObserverLocationProvider);
    if (plannerSiteUnset(location)) return const SizedBox.shrink();
    // Below the shell's layout breakpoint the header is 48px of title and tab
    // strip with nothing to spare; two chips of prose there push the row into
    // overflow. The same two facts are one tap away in the tab body.
    if (MediaQuery.sizeOf(context).width <
        ShellChromeMetrics.shellLayoutBreakpoint) {
      return const SizedBox.shrink();
    }

    final now = DateTime.now();
    final illumination = AstronomyCalculations.moonIllumination(now);
    final twilight = AstronomyCalculations.calculateTwilightTimes(
      date: now,
      latitudeDeg: location!.latitude,
      longitudeDeg: location.longitude,
    );
    final dusk = twilight.astronomicalDusk;
    final dawn = twilight.astronomicalDawn;
    final l10n = context.l10n;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqChip(
          icon: LucideIcons.moon,
          label: l10n.text(
            'plannerChipMoon',
            params: {'value': illumination.round().toString()},
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SkotiqChip(
          icon: LucideIcons.clock,
          label: dusk == null || dawn == null
              ? l10n.text('plannerChipDarkNone')
              : l10n.text(
                  'plannerChipDark',
                  params: {'start': _hhmm(dusk), 'end': _hhmm(dawn)},
                ),
        ),
      ],
    );
  }

  /// 24-hour clock, zero-padded. `DateFormat.Hm()` would follow the device
  /// locale into a 12-hour clock; every other time on this screen is 24-hour.
  static String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

// Controls bar (search, filters, sort)

/// The search field's width on the desktop filter row (06 §Plan: "300 px
/// search field").
const double _kPlannerSearchWidth = 300;

/// Below this much remaining height the controls bar is in its
/// keyboard-compact form: the outer vertical padding goes and the strip
/// becomes the one row a phone keeps while the software keyboard is up.
const double _kPlannerControlsCompactHeight = 120;

/// The controls bar's bottom hairline, which every fit calculation below has
/// to leave room for.
const double _kPlannerControlsHairline = 1;

class _PlannerControlsBar extends ConsumerWidget {
  final SkotiqColors colors;
  final TextEditingController controller;
  final SuggestionFilterState filters;
  final AsyncValue<List<TargetSuggestion>> candidatesAsync;

  /// The height this bar's parent has left to give it, or
  /// [double.infinity] when the parent is unbounded.
  final double availableHeight;

  const _PlannerControlsBar({
    required this.colors,
    required this.controller,
    required this.filters,
    required this.candidatesAsync,
    this.availableHeight = double.infinity,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keyboardCompact = availableHeight < _kPlannerControlsCompactHeight;

    // A filter chip paints at [SkotiqFilterChip.height] but carries a
    // 48 dp interactive box on a phone (03 §3.3), so that box — not the paint
    // — is what the strip has to be tall enough for. When the slot left over
    // cannot hold one, the chip is dropped rather than shrunk: 07 forbids
    // scaling a control down to make it fit, and while the keyboard is up the
    // field being typed into is the only control that has to be reachable.
    // The filters come back the moment the keyboard closes.
    final chipExtent = math.max(
      SkotiqFilterChip.height,
      SkotiqTouchTarget.minExtent(context),
    );
    final showFilterControls =
        availableHeight >= chipExtent + _kPlannerControlsHairline;

    final constellations = ref.watch(availableConstellationsProvider);
    final magRange = ref.watch(availableMagnitudeRangeProvider);
    final sizeRange = ref.watch(availableSizeRangeProvider);

    // Phone-tier (device-class, orientation-independent) collapses the filter
    // cluster behind one "Filters" button. Keyed off [Responsive.isPhone] — NOT
    // the controls bar's own width — so a wide-but-short phone landscape (e.g. a
    // Fold cover screen at 905x369) still collapses instead of falling through
    // to the desktop chip wrap because its *width* happens to clear 600px.
    final isPhone = Responsive.isPhone(context);

    final searchField = _SearchField(
      controller: controller,
      colors: colors,
      compact: isPhone,
      onChanged: (value) {
        final notifier = ref.read(suggestionFilterProvider.notifier);
        notifier.state = notifier.state.copyWith(searchQuery: value);
        ref.read(_plannerVisibleCountProvider.notifier).state =
            _kPlannerPageSize;
      },
    );

    // The row the mockup draws: a 300px search field, the two or three
    // most-used filters, a "More" chip for the rest, and the sort right-
    // aligned. Everything past "More" lives in the same sheet the phone
    // layout has always used, so no filter loses its control.
    final moreChip = _ControlChip(
      colors: colors,
      icon: LucideIcons.filter,
      label: filters.activeCount > 0 ? 'More (${filters.activeCount})' : 'More',
      active: filters.activeCount > 0,
      onTap: () => _openFiltersSheet(
        context,
        ref,
        constellations: constellations,
        magRange: magRange,
        sizeRange: sizeRange,
      ),
    );

    return Container(
      padding: EdgeInsets.fromLTRB(
        isPhone ? SkotiqTokens.spaceLg : SkotiqTokens.space2xl,
        keyboardCompact ? 0 : SkotiqTokens.spaceMd,
        isPhone ? SkotiqTokens.spaceLg : SkotiqTokens.space2xl,
        keyboardCompact ? 0 : SkotiqTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colors.border,
            width: _kPlannerControlsHairline,
          ),
        ),
      ),
      child: isPhone
          ? Row(
              children: [
                // Search and the Filters chip share one compact row on phone
                // so the controls bar is a single strip rather than two stacked
                // rows — reclaiming a whole row's height for the candidate
                // list.
                Expanded(child: searchField),
                if (showFilterControls) ...[
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  moreChip,
                ],
              ],
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // Same rule as the phone row above: with no room for a chip's
                // touch box the strip is the search field alone.
                if (!showFilterControls) {
                  return Row(children: [Expanded(child: searchField)]);
                }

                final sort = _SortDropdown(
                  colors: colors,
                  value: filters.plannerSort ?? PlannerSortMode.score,
                );

                // Below the desktop breakpoint the three inline chips do not
                // fit beside a 300 px search field and the sort, and the
                // horizontal scroll they used to live in simply SLICED the
                // last one — "Alt now: any" was cut mid-chip with the sort
                // apparently sitting on top of it, which reads as a broken
                // layout rather than as something scrollable.
                //
                // So they collapse into the Filters sheet, which already
                // carries all six controls (see _ControlsBarChips): nothing
                // loses its control, and the row keeps the two things the
                // mockup insists on, search and sort.
                if (constraints.maxWidth < SkotiqTokens.breakpointDesktop) {
                  return Row(
                    children: [
                      Expanded(child: searchField),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      moreChip,
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      sort,
                    ],
                  );
                }

                return Row(
                  children: [
                    SizedBox(width: _kPlannerSearchWidth, child: searchField),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _ObjectTypeMultiSelect(
                              colors: colors,
                              selected: filters.selectedObjectTypes,
                            ),
                            const SizedBox(width: SkotiqTokens.spaceSm),
                            _MinAltitudeControl(
                              colors: colors,
                              value: filters.minCurrentAltitude,
                            ),
                            const SizedBox(width: SkotiqTokens.spaceSm),
                            _MoonSeparationControl(
                              colors: colors,
                              value: filters.minMoonDistance,
                            ),
                            const SizedBox(width: SkotiqTokens.spaceSm),
                            moreChip,
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    sort,
                  ],
                );
              },
            ),
    );
  }

  void _resetFilters(WidgetRef ref) {
    ref.read(suggestionFilterProvider.notifier).state =
        const SuggestionFilterState();
    controller.clear();
    ref.read(_plannerVisibleCountProvider.notifier).state = _kPlannerPageSize;
  }

  Future<void> _openFiltersSheet(
    BuildContext context,
    WidgetRef ref, {
    required List<String> constellations,
    required (double, double)? magRange,
    required (double, double)? sizeRange,
  }) {
    return showAdaptiveModal<void>(
      context: context,
      designWidth: 520,
      designHeight: 520,
      builder: (sheetContext) {
        // Re-read the live filter state inside the sheet so chips reflect taps
        // made while the sheet is open (each chip mutates the provider, which
        // rebuilds this consumer).
        return Consumer(
          builder: (innerContext, innerRef, _) {
            final liveFilters = innerRef.watch(suggestionFilterProvider);
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Filters & sort',
                            style: SkotiqTypography.sectionTitle.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        if (liveFilters.activeCount > 0)
                          SkotiqButton(
                            label: 'Reset',
                            variant: ButtonVariant.ghost,
                            size: ButtonSize.small,
                            icon: LucideIcons.rotateCcw,
                            onPressed: () => _resetFilters(innerRef),
                          ),
                      ],
                    ),
                    const SizedBox(height: SkotiqTokens.spaceMd),
                    Wrap(
                      spacing: SkotiqTokens.spaceSm,
                      runSpacing: SkotiqTokens.spaceSm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: _ControlsBarChips(
                        colors: colors,
                        filters: liveFilters,
                        constellations: constellations,
                        magRange: magRange,
                        sizeRange: sizeRange,
                        controller: controller,
                      ).chips(innerRef),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceLg),
                    SizedBox(
                      width: double.infinity,
                      child: SkotiqButton(
                        label: 'Done',
                        variant: ButtonVariant.primary,
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Pin to share the chip-building logic between the inline desktop row and the
/// phone filter sheet without duplicating the chip list. Constructed per-build
/// from the live filter state.
class _ControlsBarChips {
  final SkotiqColors colors;
  final SuggestionFilterState filters;
  final List<String> constellations;
  final (double, double)? magRange;
  final (double, double)? sizeRange;
  final TextEditingController controller;

  const _ControlsBarChips({
    required this.colors,
    required this.filters,
    required this.constellations,
    required this.magRange,
    required this.sizeRange,
    required this.controller,
  });

  List<Widget> chips(WidgetRef ref) {
    void resetFilters() {
      ref.read(suggestionFilterProvider.notifier).state =
          const SuggestionFilterState();
      controller.clear();
      ref.read(_plannerVisibleCountProvider.notifier).state = _kPlannerPageSize;
    }

    return [
      _ObjectTypeMultiSelect(
        colors: colors,
        selected: filters.selectedObjectTypes,
      ),
      _ConstellationDropdown(
        colors: colors,
        available: constellations,
        selected: filters.selectedConstellations.isEmpty
            ? null
            : filters.selectedConstellations.first,
      ),
      _MagnitudeRangeControl(
        colors: colors,
        bounds: magRange,
        min: filters.minMagnitude,
        max: filters.maxMagnitude,
      ),
      _SizeRangeControl(
        colors: colors,
        bounds: sizeRange,
        min: filters.minSizeArcmin,
        max: filters.maxSizeArcmin,
      ),
      _MinAltitudeControl(
        colors: colors,
        value: filters.minCurrentAltitude,
      ),
      _MoonSeparationControl(
        colors: colors,
        value: filters.minMoonDistance,
      ),
      _SortDropdown(
        colors: colors,
        value: filters.plannerSort ?? PlannerSortMode.score,
      ),
      if (filters.activeCount > 0)
        _ResetChip(colors: colors, onPressed: resetFilters),
    ];
  }
}
