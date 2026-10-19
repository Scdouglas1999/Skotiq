// The Tonight screen's responsive frame: a header over three columns (plan,
// frame, panel) that folds to two columns plus a plan drawer, then to one
// scrolling column. The slots are opaque widgets; what each one needs to know
// about the space it got is published through [NightControlDensity].
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';

/// How [NightControlLayout] arranged its slots.
enum NightControlMode {
  /// Content at least [NightControlLayout.threeColumnMinWidth] wide:
  /// plan 272 | frame | panel 300.
  threeColumn,

  /// [NightControlLayout.drawerMinWidth] up to the three-column width: frame
  /// | panel 300, and the plan column slides in from the left on demand.
  planDrawer,

  /// Narrower: one scrolling column of header, center, panel, then plan.
  singleColumn,
}

/// What the slots of a [NightControlLayout] need to know about their space.
///
/// Read it with [NightControlDensity.of] from any widget inside a slot.
class NightControlDensity extends InheritedWidget {
  const NightControlDensity({
    super.key,
    required this.mode,
    required this.centerWidth,
    required this.compactHeight,
    required this.planDrawerOpen,
    required this.openPlanDrawer,
    required this.closePlanDrawer,
    required super.child,
  });

  final NightControlMode mode;

  /// The center slot's width.
  final double centerWidth;

  /// The body under the header is shorter than
  /// [NightControlLayout.compactBodyHeight]: the chart row shrinks to
  /// [NightControlLayout.compactChartRowHeight].
  final bool compactHeight;

  /// Whether the plan drawer is showing. Always false outside
  /// [NightControlMode.planDrawer].
  final bool planDrawerOpen;

  /// The header's "Plan" button calls this. Null outside
  /// [NightControlMode.planDrawer], which is also the header's cue to hide
  /// the button.
  final VoidCallback? openPlanDrawer;

  /// Closes the drawer; null outside [NightControlMode.planDrawer]. The
  /// steps list calls it after "open in Sequencer" navigates away.
  final VoidCallback? closePlanDrawer;

  /// In the column modes the left and panel slots get a bounded height and
  /// scroll their own content; in [NightControlMode.singleColumn] the page
  /// scrolls and every slot must size to its content (no `Expanded`, no
  /// scroll view of its own on the main axis).
  bool get slotsScrollThemselves => mode != NightControlMode.singleColumn;

  /// The "Manual actions pause the run…" hint becomes an info icon with a
  /// tooltip.
  bool get collapseActionHint =>
      centerWidth < NightControlLayout.actionHintMinWidth;

  /// The action buttons drop their second line ("5 s", "Ha").
  bool get hideActionSubLabels =>
      centerWidth < NightControlLayout.actionSubLabelMinWidth;

  /// The session chart row's height.
  double get chartRowHeight => compactHeight
      ? NightControlLayout.compactChartRowHeight
      : NightControlLayout.chartRowHeight;

  static NightControlDensity? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NightControlDensity>();

  static NightControlDensity of(BuildContext context) {
    final density = maybeOf(context);
    assert(density != null, 'No NightControlLayout above this widget.');
    return density!;
  }

  @override
  bool updateShouldNotify(NightControlDensity oldWidget) =>
      mode != oldWidget.mode ||
      centerWidth != oldWidget.centerWidth ||
      compactHeight != oldWidget.compactHeight ||
      planDrawerOpen != oldWidget.planDrawerOpen ||
      openPlanDrawer != oldWidget.openPlanDrawer ||
      closePlanDrawer != oldWidget.closePlanDrawer;
}

/// The Tonight screen's four slots and the rules that place them (plan
/// section 2).
///
/// Focus order follows the reading order: header, plan, center, panel. In
/// the single column the plan comes last, after the panel.
class NightControlLayout extends StatefulWidget {
  const NightControlLayout({
    super.key,
    required this.header,
    required this.left,
    required this.center,
    required this.panel,
  });

  /// Title, run pill, timeline and run controls. At least [headerHeight]
  /// tall in the column modes.
  final Widget header;

  /// Target, plan, steps and coming up.
  final Widget left;

  /// Frame, action bar, strip and charts.
  final Widget center;

  /// The tabbed right panel.
  final Widget panel;

  static const double threeColumnMinWidth = 1180;
  static const double drawerMinWidth = 900;
  static const double leftWidth = 272;
  static const double panelWidth = 300;
  static const double headerHeight = 48;
  static const double compactBodyHeight = 720;
  static const double actionHintMinWidth = 900;
  static const double actionSubLabelMinWidth = 820;
  static const double chartRowHeight = 120;
  static const double compactChartRowHeight = 96;

  /// The frame never gets shorter than this in the column modes; the chart
  /// row folds into a toggle first.
  static const double minFrameHeight = 280;

  static NightControlMode modeFor(double width) {
    if (width >= threeColumnMinWidth) return NightControlMode.threeColumn;
    if (width >= drawerMinWidth) return NightControlMode.planDrawer;
    return NightControlMode.singleColumn;
  }

  @override
  State<NightControlLayout> createState() => _NightControlLayoutState();
}

class _NightControlLayoutState extends State<NightControlLayout> {
  bool _drawerOpen = false;
  final FocusScopeNode _drawerScope = FocusScopeNode(debugLabel: 'plan');

  @override
  void dispose() {
    _drawerScope.dispose();
    super.dispose();
  }

  void _openDrawer() {
    if (_drawerOpen) return;
    setState(() => _drawerOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _drawerOpen) _drawerScope.requestFocus();
    });
  }

  void _closeDrawer() {
    if (!_drawerOpen) return;
    setState(() => _drawerOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return ColoredBox(
      color: colors.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final mode = NightControlLayout.modeFor(width);
          final drawerMode = mode == NightControlMode.planDrawer;
          // Leaving the drawer width forgets the drawer, so narrowing the
          // window again does not throw it open over the frame.
          if (!drawerMode) _drawerOpen = false;
          final drawerOpen = _drawerOpen;
          final bodyHeight = constraints.hasBoundedHeight
              ? constraints.maxHeight - NightControlLayout.headerHeight
              : null;
          final centerWidth = switch (mode) {
            NightControlMode.threeColumn => width -
                NightControlLayout.leftWidth -
                NightControlLayout.panelWidth,
            NightControlMode.planDrawer =>
              width - NightControlLayout.panelWidth,
            NightControlMode.singleColumn => width,
          };
          return NightControlDensity(
            mode: mode,
            centerWidth: centerWidth,
            compactHeight: bodyHeight != null &&
                bodyHeight < NightControlLayout.compactBodyHeight,
            planDrawerOpen: drawerOpen,
            openPlanDrawer: drawerMode ? _openDrawer : null,
            closePlanDrawer: drawerMode ? _closeDrawer : null,
            child: switch (mode) {
              NightControlMode.singleColumn => _singleColumn(colors),
              _ => _columns(colors, mode, drawerOpen),
            },
          );
        },
      ),
    );
  }

  Widget _columns(SkotiqColors colors, NightControlMode mode, bool drawerOpen) {
    final threeColumn = mode == NightControlMode.threeColumn;
    final divider = BorderSide(color: colors.border);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: NightControlLayout.headerHeight,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: divider)),
            child: _slot(widget.header),
          ),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (threeColumn)
                      SizedBox(
                        width: NightControlLayout.leftWidth,
                        child: _leftColumn(colors, divider),
                      ),
                    Expanded(child: _slot(widget.center)),
                    SizedBox(
                      width: NightControlLayout.panelWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surface,
                          border: Border(left: divider),
                        ),
                        child: _slot(widget.panel),
                      ),
                    ),
                  ],
                ),
              ),
              if (!threeColumn) ..._drawer(colors, divider, drawerOpen),
            ],
          ),
        ),
      ],
    );
  }

  Widget _leftColumn(SkotiqColors colors, BorderSide divider) => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.well,
          border: Border(right: divider),
        ),
        child: _slot(widget.left),
      );

  /// The plan column over the body, with a scrim that closes it. Kept in the
  /// tree while closed so its scroll position and state survive, but hidden
  /// from pointer, focus and semantics.
  List<Widget> _drawer(
    SkotiqColors colors,
    BorderSide divider,
    bool open,
  ) {
    final l10n = SkotiqLocalizations.of(context);
    return <Widget>[
      if (open)
        Positioned.fill(
          child: Semantics(
            button: true,
            enabled: true,
            label: l10n.text('nightPlanDrawerClose'),
            onTap: _closeDrawer,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeDrawer,
              excludeFromSemantics: true,
              child: ColoredBox(
                color: colors.background.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: NightControlLayout.leftWidth,
        child: Visibility(
          visible: open,
          maintainState: true,
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.escape): _closeDrawer,
            },
            child: FocusScope(
              node: _drawerScope,
              child: Semantics(
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                label: l10n.text('nightPlanDrawer'),
                child: _leftColumn(colors, divider),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _singleColumn(SkotiqColors colors) {
    final divider = BorderSide(color: colors.border);
    return SingleChildScrollView(
      primary: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: divider)),
            child: _slot(widget.header),
          ),
          _slot(widget.center),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(top: divider),
            ),
            child: _slot(widget.panel),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.well,
              border: Border(top: divider),
            ),
            child: _slot(widget.left),
          ),
        ],
      ),
    );
  }

  /// Each slot is its own semantics container and focus group, so traversal
  /// finishes one region before entering the next.
  Widget _slot(Widget child) => FocusTraversalGroup(
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: child,
        ),
      );
}
