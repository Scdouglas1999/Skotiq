// Shared mutable screen state used by the responsive section mixins.
part of '../guiding_screen.dart';

mixin _GuidingStateFields on ConsumerState<GuidingScreen> {
  GraphTimeScale _timeScale = GraphTimeScale.fiveMinutes;
  GraphYScale _yScale = GraphYScale.two;
  bool _showBrainPanel = false;

  // Dither / settle parameters bound to GuideControlsPanel.
  //
  // These are a live cache of the CANONICAL persisted authority
  // ([appSettingsProvider]): they are seeded from the persisted settle/dither
  // settings on first build (see `_hydrateGuidingSettings`) and every edit is
  // written straight back through the AppSettings notifier. Because the source
  // of truth is the persisted store, the values survive navigation and full
  // screen reconstruction, and a remote companion writes through the same
  // canonical settings sync rather than spinning up a competing local store.
  // The initial values below are placeholders only until hydration runs.
  double _ditherAmount = 5.0;
  bool _ditherRaOnly = false;
  double _settlePixels = 1.5;
  double _settleTime = 10.0;
  double _settleTimeout = 60.0;

  /// Guards the one-time seed from persisted AppSettings. Reset per State, so a
  /// fresh screen re-hydrates from the persisted values (survives reconstruction).
  bool _guidingSettingsHydrated = false;

  // Tab controller for the narrow layout's header tabs.
  late TabController _tabController;

  /// True when the viewport cannot hold the three columns.
  ///
  /// Two ways in. [Responsive.isPhone] is width-only (`< 600`), which
  /// misclassifies a phone held in landscape (a large phone is ~932 px wide),
  /// so a phone in EITHER orientation is caught on its shortest side. A narrow
  /// desktop WINDOW is caught on width alone: 224 + 300 of fixed columns plus
  /// the gutters leaves the graph a sliver below the shell's own layout
  /// breakpoint, and a sliver of a plot is worse than a reflow.
  bool _isNarrowViewport(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.shortestSide < BreakpointTokens.breakpointPhone ||
        size.width < _GuidingDesktopSections._threeColumnMinWidth;
  }
}
