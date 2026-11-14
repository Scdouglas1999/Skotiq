import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Responsive three-panel body for [PolarAlignmentScreen].
///
/// Wide viewports use a horizontal row (settings | run view | error display).
/// Medium viewports stack the run view on top with settings and errors below.
/// Narrow viewports collapse into tabs so the center column never shrinks
/// below readable width (~400 logical px).
///
/// [centerPanel] is null while nothing is running: the instructions then live
/// at the top of the settings column, and the error display takes the space a
/// centre column would have left as an empty band.
class PolarAlignmentBodyLayout extends StatelessWidget {
  final Widget leftPanel;
  final Widget? centerPanel;
  final Widget rightPanel;

  const PolarAlignmentBodyLayout({
    super.key,
    required this.leftPanel,
    required this.centerPanel,
    required this.rightPanel,
  });

  /// Logical compact-tab indices, stable whether or not the run view exists.
  static const int settingsTab = 0;
  static const int runTab = 1;
  static const int errorsTab = 2;

  /// Minimum width before attempting wide three-column row layout.
  static const double wideBreakpoint = 1100;

  /// Below this width, side-by-side bottom panels are too cramped — use tabs.
  static const double compactBreakpoint = 700;

  /// Guide column must stay readable in wide mode; medium/tabs used if tighter.
  static const double minCenterWidth = 400;

  static const double layoutDividerWidth = 2;

  /// Preferred side widths at full wide layout (clamped down when space is tight).
  ///
  /// 360 rather than 320: at idle the setup checklist shares this column with
  /// the settings, and its step titles wrapped to two lines at 320.
  static const double leftPanelPreferred = 360;

  ///
  /// The right column is 440 so the error row can give Total a degrees-sized
  /// value without wrapping it under the other two.
  static const double rightPanelPreferred = 440;

  static const double leftPanelMin = 240;
  static const double rightPanelMin = 280;

  /// Computes side panel widths for [width] so the center column is at least
  /// [minCenterWidth], shrinking sides down to their minimums first.
  static ({double left, double right}) panelWidthsForWide(double width) {
    var left = leftPanelPreferred;
    var right = rightPanelPreferred;

    double centerFor(double l, double r) => width - l - r - layoutDividerWidth;

    if (centerFor(left, right) >= minCenterWidth) {
      return (left: left, right: right);
    }

    final deficit = minCenterWidth - centerFor(left, right);
    final leftRoom = left - leftPanelMin;
    final rightRoom = right - rightPanelMin;
    final totalRoom = leftRoom + rightRoom;

    if (totalRoom <= 0) {
      return (left: leftPanelMin, right: rightPanelMin);
    }

    final takeLeft = deficit * (leftRoom / totalRoom);
    final takeRight = deficit - takeLeft;
    left = (left - takeLeft).clamp(leftPanelMin, leftPanelPreferred);
    right = (right - takeRight).clamp(rightPanelMin, rightPanelPreferred);

    if (centerFor(left, right) < minCenterWidth) {
      var remaining = minCenterWidth - centerFor(left, right);
      final fromLeft = remaining.clamp(0.0, left - leftPanelMin);
      left -= fromLeft;
      remaining -= fromLeft;
      right = (right - remaining).clamp(rightPanelMin, rightPanelPreferred);
    }

    return (left: left, right: right);
  }

  static double centerWidthFor(double width, double left, double right) =>
      width - left - right - layoutDividerWidth;

  static bool shouldUseWideLayout(double width) {
    if (width < wideBreakpoint) {
      return false;
    }
    final panels = panelWidthsForWide(width);
    return centerWidthFor(width, panels.left, panels.right) >= minCenterWidth;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        if (shouldUseWideLayout(width) && centerPanel == null) {
          return _IdleWideLayout(
            colors: colors,
            leftWidth: panelWidthsForWide(width).left,
            leftPanel: leftPanel,
            rightPanel: rightPanel,
          );
        }

        if (shouldUseWideLayout(width)) {
          final panels = panelWidthsForWide(width);
          return _WideLayout(
            colors: colors,
            leftWidth: panels.left,
            rightWidth: panels.right,
            leftPanel: leftPanel,
            centerPanel: centerPanel!,
            rightPanel: rightPanel,
          );
        }

        if (width >= compactBreakpoint) {
          return _MediumLayout(
            colors: colors,
            leftPanel: leftPanel,
            centerPanel: centerPanel,
            rightPanel: rightPanel,
          );
        }

        return _CompactTabLayout(
          colors: colors,
          leftPanel: leftPanel,
          centerPanel: centerPanel,
          rightPanel: rightPanel,
        );
      },
    );
  }
}

class _IdleWideLayout extends StatelessWidget {
  final SkotiqColors colors;
  final double leftWidth;
  final Widget leftPanel;
  final Widget rightPanel;

  const _IdleWideLayout({
    required this.colors,
    required this.leftWidth,
    required this.leftPanel,
    required this.rightPanel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: leftWidth, child: leftPanel),
        Container(width: 1, color: colors.border),
        Expanded(child: rightPanel),
      ],
    );
  }
}

class _WideLayout extends StatelessWidget {
  final SkotiqColors colors;
  final double leftWidth;
  final double rightWidth;
  final Widget leftPanel;
  final Widget centerPanel;
  final Widget rightPanel;

  const _WideLayout({
    required this.colors,
    required this.leftWidth,
    required this.rightWidth,
    required this.leftPanel,
    required this.centerPanel,
    required this.rightPanel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: leftWidth, child: leftPanel),
        Container(width: 1, color: colors.border),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: PolarAlignmentBodyLayout.minCenterWidth,
            ),
            child: centerPanel,
          ),
        ),
        Container(width: 1, color: colors.border),
        SizedBox(width: rightWidth, child: rightPanel),
      ],
    );
  }
}

class _MediumLayout extends StatelessWidget {
  final SkotiqColors colors;
  final Widget leftPanel;
  final Widget? centerPanel;
  final Widget rightPanel;

  const _MediumLayout({
    required this.colors,
    required this.leftPanel,
    required this.centerPanel,
    required this.rightPanel,
  });

  @override
  Widget build(BuildContext context) {
    final sides = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: leftPanel),
        Container(width: 1, color: colors.border),
        Expanded(child: rightPanel),
      ],
    );
    final center = centerPanel;
    if (center == null) return sides;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: center),
        Container(height: 1, color: colors.border),
        Expanded(flex: 2, child: sides),
      ],
    );
  }
}

class _CompactTabLayout extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final Widget leftPanel;
  final Widget? centerPanel;
  final Widget rightPanel;

  const _CompactTabLayout({
    required this.colors,
    required this.leftPanel,
    required this.centerPanel,
    required this.rightPanel,
  });

  @override
  ConsumerState<_CompactTabLayout> createState() => _CompactTabLayoutState();
}

class _CompactTabLayoutState extends ConsumerState<_CompactTabLayout>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  /// True only while [build] is pushing the provider's index INTO the
  /// controller. Assigning `TabController.index` notifies its listeners
  /// synchronously with `indexIsChanging` already back to false, so without
  /// this flag `_onTabChanged` would write the very same index straight back
  /// into the provider from inside build — which Riverpod asserts on
  /// ("Tried to modify a provider while the widget tree was building").
  ///
  /// Reachable because the tab moves from OUTSIDE this widget: the header's
  /// History toggle selects the Settings tab, so the guard above
  /// (`index != index`) no longer short-circuits every time.
  bool _applyingExternalIndex = false;

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  /// Logical tabs shown, in order. Without a run view the Guide tab would be
  /// an empty page, so it is left out until a run starts.
  List<int> get _logicalTabs => widget.centerPanel == null
      ? const [
          PolarAlignmentBodyLayout.settingsTab,
          PolarAlignmentBodyLayout.errorsTab,
        ]
      : const [
          PolarAlignmentBodyLayout.settingsTab,
          PolarAlignmentBodyLayout.runTab,
          PolarAlignmentBodyLayout.errorsTab,
        ];

  /// Position of a logical tab in the visible strip. A logical tab that is not
  /// shown (the run view, before a run) falls back to Settings, which now
  /// carries the instructions that page used to hold.
  int _positionOf(int logical, List<int> tabs) {
    final i = tabs.indexOf(logical);
    return i < 0 ? 0 : i;
  }

  void _syncTabController(int logicalIndex, List<int> tabs) {
    final position = _positionOf(logicalIndex, tabs);
    final existing = _tabController;
    if (existing != null && existing.length == tabs.length) {
      if (existing.index != position) {
        _applyingExternalIndex = true;
        try {
          existing.index = position;
        } finally {
          _applyingExternalIndex = false;
        }
      }
      return;
    }
    if (existing != null) {
      existing.removeListener(_onTabChanged);
      // The TabBar and TabBarView still hold the old controller until this
      // build replaces them, and they detach from it as they update. Dispose
      // after that frame, not under them.
      WidgetsBinding.instance.addPostFrameCallback((_) => existing.dispose());
    }
    _tabController = TabController(
      length: tabs.length,
      vsync: this,
      initialIndex: position,
    );
    _tabController!.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_applyingExternalIndex) return;
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) {
      return;
    }
    ref
        .read(polarAlignmentUiStateProvider.notifier)
        .setCompactTabIndex(_logicalTabs[controller.index]);
  }

  static const Map<int, String> _tabLabels = {
    PolarAlignmentBodyLayout.settingsTab: 'Settings',
    PolarAlignmentBodyLayout.runTab: 'Guide',
    PolarAlignmentBodyLayout.errorsTab: 'Errors',
  };

  @override
  Widget build(BuildContext context) {
    final tabIndex = ref.watch(polarAlignmentUiStateProvider).compactTabIndex;
    final tabs = _logicalTabs;
    _syncTabController(tabIndex, tabs);
    final controller = _tabController!;

    Widget pageFor(int logical) => switch (logical) {
          PolarAlignmentBodyLayout.settingsTab => widget.leftPanel,
          PolarAlignmentBodyLayout.runTab => widget.centerPanel!,
          _ => widget.rightPanel,
        };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: widget.colors.surface,
          child: TabBar(
            controller: controller,
            labelColor: widget.colors.primary,
            unselectedLabelColor: widget.colors.textMuted,
            indicatorColor: widget.colors.primary,
            dividerColor: widget.colors.border,
            labelStyle: SkotiqTypography.h6,
            unselectedLabelStyle:
                const TextStyle(fontSize: SkotiqTypography.fontSize12),
            tabs: [for (final t in tabs) Tab(text: _tabLabels[t])],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [for (final t in tabs) pageFor(t)],
          ),
        ),
      ],
    );
  }
}

/// Body of a run in progress: the live frame is the screen, and the error
/// readout and the step card sit in one narrow column beside it.
///
/// The three-panel layout gave a running alignment a frame about 370 px wide
/// on a 1600 px window, between a locked settings column and a bullseye
/// column 440 px wide. The settings cannot change mid-run, so they are left
/// out unless the operator opened History, and the bullseye shrinks to a
/// readout. The column moves under the frame when that shows the frame larger
/// (see [besideShowsFrameLarger]).
class PolarAlignmentLiveLayout extends StatelessWidget {
  /// The progress rail over the frame.
  final Widget rail;

  /// The live frame. Takes all the room the layout has left.
  final Widget frame;

  /// The compact readout and the step card.
  final Widget side;

  /// The settings column, shown only when non-null (History is open).
  final Widget? settings;

  const PolarAlignmentLiveLayout({
    super.key,
    required this.rail,
    required this.frame,
    required this.side,
    this.settings,
  });

  /// Narrowest the frame gets with the readout column beside it.
  static const double minFrameWidthBeside = 320;

  /// Height the progress rail takes over the frame, near enough.
  static const double railAllowance = 72;

  /// The camera frame's aspect, near enough: sensors are landscape.
  static const double frameAspect = 1.5;

  static const double sideWidth = 300;

  /// Tallest the readout strip under the frame may get, as a share of the
  /// body, before it scrolls.
  static const double stackedSideMaxShare = 0.45;

  /// Whether a [width] x [height] body shows a landscape frame wider with the
  /// readout column beside it than with the readout strip under it.
  ///
  /// A width breakpoint alone stacks a landscape phone (640x360), leaving the
  /// frame a strip about 50 px tall, and sets a tall tablet side by side with
  /// the frame squeezed into what the column leaves.
  static bool besideShowsFrameLarger(double width, double height) {
    final besideWidth = width - sideWidth;
    if (besideWidth < minFrameWidthBeside) return false;
    if (!height.isFinite) return true;
    final beside =
        math.min(besideWidth, (height - railAllowance) * frameAspect);
    final stacked = math.min(
      width,
      (height * (1 - stackedSideMaxShare) - railAllowance) * frameAspect,
    );
    return beside >= stacked;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final settingsPanel = settings;
        final besideWidth = settingsPanel == null
            ? width
            : width - PolarAlignmentBodyLayout.leftPanelPreferred;
        final frameColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [rail, Expanded(child: frame)],
        );

        if (besideShowsFrameLarger(besideWidth, constraints.maxHeight)) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (settingsPanel != null) ...[
                SizedBox(
                  width: PolarAlignmentBodyLayout.leftPanelPreferred,
                  child: settingsPanel,
                ),
                Container(width: 1, color: colors.border),
              ],
              Expanded(child: frameColumn),
              Container(width: 1, color: colors.border),
              SizedBox(width: sideWidth, child: side),
            ],
          );
        }

        final strip = settingsPanel ?? side;
        final maxStrip = constraints.hasBoundedHeight
            ? constraints.maxHeight * stackedSideMaxShare
            : double.infinity;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: frameColumn),
            Container(height: 1, color: colors.border),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxStrip),
              child: strip,
            ),
          ],
        );
      },
    );
  }
}
