// Shared mutable screen state used by the responsive section mixins.
part of '../guiding_screen.dart';

mixin _GuidingStateFields on ConsumerState<GuidingScreen> {
  GraphTimeScale _timeScale = GraphTimeScale.fiveMinutes;
  GraphYScale _yScale = GraphYScale.two;
  bool _showBrainPanel = false;

  late TabController _tabController;

  /// True when the viewport cannot hold the three columns.
  ///
  /// Two ways in: a phone in either orientation, and a window narrower than
  /// the three columns, where 224 + 300 of fixed columns plus the gutters
  /// leave the graph a sliver and a sliver of a plot is worse than a reflow.
  bool _isNarrowViewport(BuildContext context) {
    return ShellLayout.of(context).isPhone ||
        MediaQuery.sizeOf(context).width <
            _GuidingDesktopSections._threeColumnMinWidth;
  }
}
