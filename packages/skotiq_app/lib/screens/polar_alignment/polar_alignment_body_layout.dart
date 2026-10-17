import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Responsive three-panel body for [PolarAlignmentScreen].
///
/// Wide viewports use a horizontal row (settings | guide | error display).
/// Medium viewports stack the guide on top with settings and errors below.
/// Narrow viewports collapse into tabs so the center column never shrinks
/// below readable width (~400 logical px).
class PolarAlignmentBodyLayout extends StatelessWidget {
  final Widget leftPanel;
  final Widget centerPanel;
  final Widget rightPanel;

  const PolarAlignmentBodyLayout({
    super.key,
    required this.leftPanel,
    required this.centerPanel,
    required this.rightPanel,
  });

  /// Minimum width before attempting wide three-column row layout.
  static const double wideBreakpoint = 1100;

  /// Below this width, side-by-side bottom panels are too cramped — use tabs.
  static const double compactBreakpoint = 700;

  /// Guide column must stay readable in wide mode; medium/tabs used if tighter.
  static const double minCenterWidth = 400;

  static const double layoutDividerWidth = 2;

  /// Preferred side widths at full wide layout (clamped down when space is tight).
  static const double leftPanelPreferred = 320;
  static const double rightPanelPreferred = 400;

  static const double leftPanelMin = 240;
  static const double rightPanelMin = 280;

  /// Legacy names — same as preferred widths.
  static const double leftPanelWidth = leftPanelPreferred;
  static const double rightPanelWidth = rightPanelPreferred;

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

        if (shouldUseWideLayout(width)) {
          final panels = panelWidthsForWide(width);
          return _WideLayout(
            colors: colors,
            leftWidth: panels.left,
            rightWidth: panels.right,
            leftPanel: leftPanel,
            centerPanel: centerPanel,
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
  final Widget centerPanel;
  final Widget rightPanel;

  const _MediumLayout({
    required this.colors,
    required this.leftPanel,
    required this.centerPanel,
    required this.rightPanel,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: centerPanel),
        Container(height: 1, color: colors.border),
        Expanded(
          flex: 2,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: leftPanel),
              Container(width: 1, color: colors.border),
              Expanded(child: rightPanel),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactTabLayout extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final Widget leftPanel;
  final Widget centerPanel;
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

  void _syncTabController(int index) {
    if (_tabController != null) {
      if (_tabController!.index != index) {
        _applyingExternalIndex = true;
        try {
          _tabController!.index = index;
        } finally {
          _applyingExternalIndex = false;
        }
      }
      return;
    }
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: index,
    );
    _tabController!.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_applyingExternalIndex) return;
    if (_tabController == null || _tabController!.indexIsChanging) {
      return;
    }
    ref
        .read(polarAlignmentUiStateProvider.notifier)
        .setCompactTabIndex(_tabController!.index);
  }

  @override
  Widget build(BuildContext context) {
    final tabIndex = ref.watch(polarAlignmentUiStateProvider).compactTabIndex;
    _syncTabController(tabIndex);
    final controller = _tabController!;

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
            tabs: const [
              Tab(text: 'Settings'),
              Tab(text: 'Guide'),
              Tab(text: 'Errors'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [
              widget.leftPanel,
              widget.centerPanel,
              widget.rightPanel,
            ],
          ),
        ),
      ],
    );
  }
}
