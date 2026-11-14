// Shared mutable screen state used by the responsive section mixins.
part of '../guiding_screen.dart';

mixin _GuidingStateFields on ConsumerState<GuidingScreen> {
  GraphTimeScale _timeScale = GraphTimeScale.fiveMinutes;
  GraphYScale _yScale = GraphYScale.two;
  bool _showBrainPanel = false;

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
