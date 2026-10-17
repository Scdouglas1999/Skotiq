// Narrow layout: the graph over the page-header tabs' body.
part of '../guiding_screen.dart';

mixin _GuidingMobileSections
    on
        ConsumerState<GuidingScreen>,
        _GuidingStateFields,
        _GuidingDesktopSections {
  /// Preferred height the live guide graph is given on a narrow viewport so it
  /// never collapses to an unreadable sliver — especially in landscape where
  /// the viewport height is small. The graph stays mounted (so it keeps
  /// streaming) in both orientations because the same [_buildGraphPanel]
  /// instance is the `start`/top pane in either branch.
  ///
  /// This is a *preference*, not a hard floor: [_stackedGraphHeight] caps it
  /// against the ceiling so the two bounds can never invert.
  static const double _phoneGraphMinHeight = 200.0;

  /// Height below which the stacked layout trades chrome for content — the
  /// graph panel's outer gutter shrinks so the plot keeps a usable share of a
  /// short viewport instead of spending it on padding.
  static const double _phoneCompactHeight = 380.0;

  /// Width above which a landscape narrow viewport gets the graph and the
  /// controls side by side instead of stacked.
  static const double _twoPaneMinWidth = 560.0;

  /// Height below which neither the graph nor the tab chrome is usable, so the
  /// covered background is kept quiet instead of overflowing.
  static const double _unusableHeight = 80.0;

  /// Height of the graph pane in the stacked (portrait / narrow landscape)
  /// layout.
  ///
  /// Total-order safe by construction: the preferred height is raised to
  /// [_phoneGraphMinHeight] and only then capped at 60% of what is available,
  /// so a short viewport (a small device, a split-screen window) degrades to
  /// the cap instead of inverting a clamp's bounds and throwing.
  static double _stackedGraphHeight(double availableHeight) {
    final ceiling = availableHeight * 0.6;
    final preferred = math.max(availableHeight * 0.42, _phoneGraphMinHeight);
    return math.min(preferred, ceiling);
  }

  /// The three narrow-layout tabs. They live in the [PageHeader] (04 §4), not
  /// in a second header row of the screen's own.
  static const List<AdaptiveTab> _narrowTabs = [
    AdaptiveTab(label: 'Star view', icon: SkotiqIcons.star),
    AdaptiveTab(label: 'Controls', icon: SkotiqIcons.sliders),
    AdaptiveTab(label: 'Settings', icon: SkotiqIcons.settings),
  ];

  /// The tab strip on a row of its own, mirroring the one [PageHeader] paints
  /// below its own breakpoint (background + bottom hairline), for the sizes
  /// where the header keeps its single row but the body has still reflowed.
  Widget _buildTabStripRow(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: _buildNarrowTabs(),
    );
  }

  Widget _buildNarrowTabs() {
    return AdaptiveTabBar(
      horizontalPadding: 0,
      selectedIndex: _tabController.index,
      onSelected: (i) {
        _tabController.index = i;
        setState(() {});
      },
      tabs: _narrowTabs,
    );
  }

  Widget _buildMobileLayout(
    SkotiqColors colors,
    bool isConnected,
    Phd2State phd2State,
    Phd2GuideStats guideStats,
  ) {
    // The graph is the dominant, always-mounted element. The tabbed body is
    // the secondary region. In landscape they sit side-by-side (graph left,
    // body right) via TwoPane; in portrait they stack with the graph pinned to
    // a sensible min height and the body filling the rest.
    final body = _buildNarrowTabBody(
      colors,
      isConnected,
      phd2State,
      guideStats,
    );

    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The shared app shell may already have consumed a modal keyboard's
          // inset before this backing route is laid out. At the resulting
          // near-zero height neither the graph nor the tab chrome is usable;
          // keep the covered background quiet instead of overflowing behind
          // the PHD2 dialog.
          if (constraints.maxHeight < _unusableHeight) {
            return ColoredBox(color: colors.background);
          }
          final isLandscape = constraints.maxWidth > constraints.maxHeight;

          Widget graphPane(double gutter) => Padding(
                padding: EdgeInsets.all(gutter),
                child: _buildGraphPanel(colors, guideStats),
              );

          // Landscape with enough width: graph beside the body. TwoPane keeps
          // both panes mounted so the graph keeps streaming, and each pane
          // already has the full viewport height to work with.
          if (isLandscape && constraints.maxWidth >= _twoPaneMinWidth) {
            return TwoPane(
              start: graphPane(SkotiqTokens.spaceMd),
              end: body,
              startFlex: 3,
              endFlex: 2,
            );
          }

          // Portrait / narrow landscape: stack. Give the graph its preferred
          // legible height, capped to leave room for the body, and let the
          // tabbed body take the remainder.
          final graphHeight = _stackedGraphHeight(constraints.maxHeight);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: graphHeight,
                child: graphPane(
                  constraints.maxHeight < _phoneCompactHeight
                      ? SkotiqTokens.spaceSm
                      : SkotiqTokens.spaceMd,
                ),
              ),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  /// The body under the header tabs. A hand-driven switch (rather than a
  /// TabBarView) so it composes inside [TwoPane] without needing a bounded
  /// width from a Material TabBar.
  Widget _buildNarrowTabBody(
    SkotiqColors colors,
    bool isConnected,
    Phd2State phd2State,
    Phd2GuideStats guideStats,
  ) {
    switch (_tabController.index) {
      case 1:
        return _buildNarrowControlsTab(colors, isConnected, phd2State);
      case 2:
        return _buildNarrowSettingsTab(colors);
      case 0:
      default:
        return _buildNarrowStarViewTab(colors, isConnected, guideStats);
    }
  }

  Widget _buildNarrowStarViewTab(
    SkotiqColors colors,
    bool isConnected,
    Phd2GuideStats stats,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // Side by side where the width allows; stacked otherwise.
              if (constraints.maxWidth > _sideBySideMinWidth) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildGuideStarPanel(colors, isConnected, stats),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceMd),
                    Expanded(
                      child: _buildTargetDisplayPanel(colors, stats),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildGuideStarPanel(colors, isConnected, stats),
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  _buildTargetDisplayPanel(colors, stats),
                ],
              );
            },
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _buildStarStatisticsPanel(colors, stats),
        ],
      ),
    );
  }

  /// Width above which the guide star and the target display sit side by side.
  static const double _sideBySideMinWidth = 400.0;

  Widget _buildNarrowControlsTab(
    SkotiqColors colors,
    bool isConnected,
    Phd2State phd2State,
  ) {
    final guiderId = ref.watch(guiderStateProvider).deviceId;
    final isPhd2Guider = guiderId == null || isPhd2DeviceId(guiderId);

    // The two blocks share the pane 3 : 2, but never below the height at
    // which the guiding controls stop fitting: under that the tab scrolls
    // instead of squeezing them into an overflow.
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight -
            SkotiqTokens.spaceMd * 3 -
            SkotiqTokens.spaceMd;
        final total = math.max(available, _controlsTabMinBodyHeight);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: total * _controlsShare,
                child: _buildControls(isConnected, phd2State),
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              SizedBox(
                height: total * (1 - _controlsShare),
                child: isPhd2Guider
                    ? _buildCalibrationSection(colors, isConnected, phd2State)
                    : _buildNonPhd2GuiderInfo(colors),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Height below which the Controls tab scrolls rather than compress.
  static const double _controlsTabMinBodyHeight = 400.0;

  /// The controls block's share of the Controls tab (the old 3 : 2 flex).
  static const double _controlsShare = 0.6;

  Widget _buildNarrowSettingsTab(SkotiqColors colors) {
    final guiderId = ref.watch(guiderStateProvider).deviceId;
    final isPhd2Guider = guiderId == null || isPhd2DeviceId(guiderId);

    if (!isPhd2Guider) {
      return Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SkotiqButton(
              key: GuidingTutorialKeys.brainBtn,
              label: 'Open guider settings',
              icon: SkotiqIcons.settings,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => context.go('/equipment'),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Expanded(child: _buildNonPhd2GuiderInfo(colors)),
          ],
        ),
      );
    }

    // Same rule as the Controls tab: the body keeps a usable height and the
    // tab scrolls under it rather than overflowing on a short viewport.
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight - _settingsTabChromeHeight;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SkotiqButton(
                key: GuidingTutorialKeys.brainBtn,
                label: _showBrainPanel
                    ? 'Hide brain settings'
                    : 'Show brain settings',
                icon: SkotiqIcons.brain,
                variant: _showBrainPanel
                    ? ButtonVariant.primary
                    : ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () =>
                    setState(() => _showBrainPanel = !_showBrainPanel),
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              SizedBox(
                height: math.max(available, _settingsTabBodyMinHeight),
                child: _showBrainPanel
                    ? _buildBrainPanel(colors)
                    : const EmptyState(
                        icon: SkotiqIcons.brain,
                        title: 'PHD2 brain settings',
                        body: 'Tune the RA and Dec guide algorithm parameters '
                            'that PHD2 itself holds.',
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The Settings tab's toggle, gap and padding above the body.
  static const double _settingsTabChromeHeight =
      28 + SkotiqTokens.spaceMd * 3;

  /// Height below which the Settings tab body scrolls rather than compress.
  static const double _settingsTabBodyMinHeight = 200.0;
}
