part of '../sequencer_screen.dart';

class _BuilderContent extends ConsumerWidget {
  final SkotiqColors colors;

  const _BuilderContent({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Phone-first reflow. We treat the builder as a phone whenever the
    // *shorter* side of the region is below the phone breakpoint (`< 600`).
    // That keeps a phone held in LANDSCAPE (e.g. 844×390) on the phone-first
    // mobile builder — which uses the extra width for a side-by-side
    // tree+properties split — instead of falling into the desktop 3-column
    // layout, whose dense toolbar/header rows overflow at that height.
    //
    // `Responsive.isMobile` (`< 768`) would lump small tablets in with phones
    // AND switch on width alone, dropping a rotated phone into the squished
    // desktop path. Branching on the short side avoids both.
    return LayoutBuilder(
      builder: (context, constraints) {
        // The DEVICE's short side, not this region's: under the header, the
        // tabs and a running plan's progress band a tablet or an unfolded
        // Fold in landscape has less than 600 dp of height left, and read
        // as a phone held sideways it got a fixed tree / "Select a node"
        // split with phone cards instead of the builder its size can hold.
        final screen = MediaQuery.sizeOf(context);
        final shortSide = screen.shortestSide;
        if (BreakpointTokens.isPhone(shortSide)) {
          return _MobileBuilderLayout(colors: colors);
        }
        // Thread this LayoutBuilder's width down to the desktop layout
        // instead of opening a second nested LayoutBuilder. The outer builder
        // is intentionally kept (not MediaQuery) so the short-side / split-
        // pane logic stays correct when the sequencer is embedded in a
        // sub-region (see the comment above).
        return _DesktopBuilderLayout(
          colors: colors,
          availableWidth: constraints.maxWidth,
        );
      },
    );
  }
}

/// Desktop layout: 3-column with collapsible panels
/// Uses mutually exclusive panel expansion - when one opens, the other closes
/// Adapts to screen width by using collapsed states on narrower screens
class _DesktopBuilderLayout extends ConsumerWidget {
  final SkotiqColors colors;
  final double availableWidth;

  const _DesktopBuilderLayout({
    required this.colors,
    required this.availableWidth,
  });

  // Base panel dimension constants (for ~1024px screens)
  static const double minCenterWidth = 300.0;
  static const double collapsedPanelWidth = 48.0;

  /// The width the document pane needs before the side panels may keep theirs.
  ///
  /// The center is the document: below this width the SIDE panels collapse
  /// rather than the canvas. `minCenterWidth` alone does not cover it — the
  /// rail fallback only fires below palette+300+properties *collapsed*, which a
  /// 900px window clears easily while squeezing the canvas to ~180px, where the
  /// node's inline editors break to one control per line and values clip
  /// mid-string.
  static const double comfortableCenterWidth = 380.0;

  /// The canvas width at which the ledger reads whole: step names like
  /// "Luminance Loop (40 x 120s)" and the target's RA/Dec chips untruncated
  /// at four levels of nesting. Measured on the M51 starter at 1280 x 800,
  /// where the 652 px canvas cut them to "Luminance Lo…" and "13h…".
  static const double readableCanvasWidth = 800.0;

  /// The palette column's width (06 §Sequencer: 264 / 1fr / 300).
  static const double paletteWidth = 264.0;

  static const double propertiesWidth = 300.0;

  /// Bucket the raw available width to the nearest 64px before computing
  /// panel dimensions, so a continuous window-resize drag only steps the
  /// derived panel sizes occasionally instead of re-tweening every frame.
  static double _bucketWidth(double width) => (width / 64.0).round() * 64.0;

  /// The three-column geometry.
  ///
  /// The columns are a FIXED 264 / 1fr / 300 at every width the layout is
  /// used at, because the spec's widths are what the palette rows and the
  /// property form were drawn against; the canvas takes the whole remainder.
  /// The min/max are the bounds of the operator's own drag, not a responsive
  /// scale — the previous scale-with-the-window rule made the same screen a
  /// different shape on every monitor.
  static ({
    double leftExpanded,
    double leftMin,
    double leftMax,
    double rightExpanded,
    double rightMin,
    double rightMax,
  }) _panelDimensions(double screenWidth) {
    return (
      leftExpanded: paletteWidth,
      leftMin: 220.0,
      leftMax: 400.0,
      rightExpanded: propertiesWidth,
      rightMin: 270.0,
      rightMax: 500.0,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toolboxCollapsed = ref.watch(sequencerToolboxCollapsedProvider);
    final propertiesCollapsed = ref.watch(sequencerPropertiesCollapsedProvider);
    // The operator's answer to the derived collapse below.
    final toolboxForceOpen = ref.watch(sequencerToolboxForceOpenProvider);
    final propertiesForceOpen = ref.watch(sequencerPropertiesForceOpenProvider);
    final persistedLeftWidth = ref.watch(sequencerLeftPanelWidthProvider);
    final persistedRightWidth = ref.watch(sequencerRightPanelWidthProvider);
    // An EMPTY properties column is 300 px of "Select a node"; below the
    // desktop breakpoint that width belongs to the document. See
    // autoCollapseEmptyProperties below.
    // A step of the open plan, not just an id: loading another plan leaves
    // the old id behind, and the column stayed open on "Select a node".
    final hasSelection =
        ref.watch(selectedNodeProvider.select((node) => node != null));

    // Derive panel sizes from a bucketed width so a continuous resize
    // drag only steps the dimensions every ~64px instead of every frame.
    final dims = _panelDimensions(_bucketWidth(availableWidth));

    final bothExpandedWidth =
        dims.leftExpanded + minCenterWidth + dims.rightExpanded;
    const bothCollapsedMinWidth =
        collapsedPanelWidth + minCenterWidth + collapsedPanelWidth;

    return Column(
      children: [
        // The screen's title lives in the PageHeader; the canvas bar below
        // carries the live sequence's own name and actions. A second title
        // block here would be the app introducing itself twice.

        Consumer(
          builder: (context, ref, child) {
            final executionState = ref.watch(sequenceExecutionStateProvider);
            final isExecuting =
                executionState == SequenceExecutionState.running ||
                    executionState == SequenceExecutionState.paused;
            if (!isExecuting) return const SizedBox.shrink();
            return EquipmentTelemetryStrip(colors: colors);
          },
        ),

        Consumer(
          builder: (context, ref, child) {
            final isMultiSelect = ref.watch(isMultiSelectActiveProvider);
            if (!isMultiSelect) return const SizedBox.shrink();
            return BatchOperationsToolbar(colors: colors);
          },
        ),

        // Main content. Width comes from _BuilderContent's LayoutBuilder, so
        // there is no second nested LayoutBuilder here.
        Expanded(
          child: Builder(
            builder: (context) {
              // Below the absolute minimum, fall back to a rail-only layout
              // that keeps a thin draggable icon palette so users can still
              // drop nodes onto the tree.
              if (availableWidth < bothCollapsedMinWidth) {
                return _NarrowDesktopLayout(colors: colors);
              }

              // In the tight band both panels stay visible at their *min*
              // widths rather than one being yanked collapsed the instant a
              // node is selected; below bothCollapsedMinWidth the rail layout
              // above already takes over. Auto-collapse is DERIVED — never
              // written back to the user-pref providers — so widening the
              // window restores the saved expanded preference.
              final spaceTight = availableWidth < bothExpandedWidth;

              // Derived widths. The columns are the spec's 264 / 300 whenever
              // there is room for them; only a genuinely tight window packs
              // them down to their floor. A user-dragged width still overrides.
              final leftDerived = spaceTight ? dims.leftMin : dims.leftExpanded;
              final rightDerived =
                  spaceTight ? dims.rightMin : dims.rightExpanded;
              final leftWidth = (persistedLeftWidth ?? leftDerived).clamp(
                dims.leftMin,
                dims.leftMax,
              );
              final rightWidth = (persistedRightWidth ?? rightDerived).clamp(
                dims.rightMin,
                dims.rightMax,
              );

              // Honor the explicit user collapse prefs; tight space packs both
              // panels to *Min instead of collapsing one — until even that
              // leaves the document pane below [comfortableCenterWidth], at
              // which point the side panels give way (toolbox first, then
              // properties). Derived only: the user-pref providers are never
              // written, so widening the window restores their saved state.
              final centerWithBothOpen =
                  availableWidth - dims.leftMin - dims.rightMin;
              final autoCollapseToolbox =
                  centerWithBothOpen < comfortableCenterWidth;
              final centerWithToolboxCollapsed = availableWidth -
                  (autoCollapseToolbox ? collapsedPanelWidth : dims.leftMin) -
                  dims.rightMin;
              // At 700x900 the arithmetic above lands just the wrong side of
              // the line: 700 - 48 - 270 = 382, two pixels clear of the 380
              // comfortable width, so the properties column survived at its
              // floor and the operator got a 48 px strip, a 382 px canvas and
              // 270 px of "Select a node". An empty column is never worth a
              // column, so below the desktop breakpoint it collapses to the
              // side strip while nothing is selected and opens the moment a
              // node is. Derived only — the user-pref providers are never
              // written, so widening restores the saved state, and an explicit
              // force-open still wins.
              //
              // The same holds at any width where the open column would cut
              // the step names: an empty inspector is not worth a truncated
              // plan.
              final canvasWithPropertiesOpen = availableWidth -
                  (toolboxCollapsed || autoCollapseToolbox
                      ? collapsedPanelWidth
                      : leftWidth) -
                  rightWidth;
              final autoCollapseEmptyProperties = !hasSelection &&
                  (availableWidth < SkotiqTokens.breakpointDesktop ||
                      canvasWithPropertiesOpen < readableCanvasWidth);
              final autoCollapseProperties =
                  centerWithToolboxCollapsed < comfortableCenterWidth ||
                      autoCollapseEmptyProperties;

              // The derived collapse is the DEFAULT at this width, not a
              // verdict: an explicit "show me" always wins. Without the
              // override the effective state is `pref || derived`, which makes
              // the toggle icons inert at ~900px — flipping the pref changes
              // nothing on screen and the operator can neither add nor edit a
              // node. The operator's own collapse still wins over their own
              // force-open, which is what the toggle writes.
              final effectiveToolboxCollapsed = toolboxCollapsed ||
                  (autoCollapseToolbox && !toolboxForceOpen);
              final effectivePropertiesCollapsed = propertiesCollapsed ||
                  (autoCollapseProperties && !propertiesForceOpen);

              // On a touch screen below the desktop breakpoint (a tablet, an
              // unfolded phone) an open side panel slides OVER the plan instead of squeezing it:
              // docked, it left a canvas too narrow for the ledger, which fell
              // back to cards. Tapping the plan beside it closes it.
              final overlayPanels = SkotiqTouchTarget.isTouch(context) &&
                  availableWidth < SkotiqTokens.breakpointDesktop;

              void closeToolbox() {
                ref.read(sequencerToolboxForceOpenProvider.notifier).state =
                    false;
                // The overlay is opened per use; the docked preference stays
                // as the operator set it on a wide screen.
                if (!overlayPanels) {
                  ref.read(sequencerToolboxCollapsedProvider.notifier).state =
                      true;
                }
              }

              void closeProperties() {
                ref.read(sequencerPropertiesForceOpenProvider.notifier).state =
                    false;
                if (overlayPanels) {
                  // Closing the sheet ends the edit; the next step tapped
                  // opens it again.
                  ref.read(selectedNodeIdProvider.notifier).state = null;
                } else {
                  ref
                      .read(sequencerPropertiesCollapsedProvider.notifier)
                      .state = true;
                }
              }

              // Whether both docked panels can be open and still leave the
              // plan its comfortable width.
              final bothFit = availableWidth - leftWidth - rightWidth >=
                  comfortableCenterWidth;

              final docked = Row(
                children: [
                  _CollapsiblePanel(
                    colors: colors,
                    isCollapsed: overlayPanels || effectiveToolboxCollapsed,
                    collapsedWidth: collapsedPanelWidth,
                    expandedWidth: leftWidth,
                    minExpandedWidth: dims.leftMin,
                    maxExpandedWidth: dims.leftMax,
                    side: ResizeSide.right,
                    collapsedIcon: LucideIcons.layoutGrid,
                    collapsedTooltip: 'Show Toolbox',
                    // Toggle from what the operator SEES, not from the pref:
                    // when the pane is only collapsed because the layout
                    // derived it, reading the pref made "open it" a no-op.
                    onToggle: () {
                      final opening =
                          overlayPanels || effectiveToolboxCollapsed;
                      ref
                          .read(sequencerToolboxCollapsedProvider.notifier)
                          .state = !opening;
                      ref
                          .read(sequencerToolboxForceOpenProvider.notifier)
                          .state = opening;
                      // Docked panels share the width: opening one where both
                      // would crush the plan closes the other.
                      // Overlays take turns: one over the plan at a time.
                      if (opening && (overlayPanels || !bothFit)) {
                        closeProperties();
                      }
                    },
                    // Persist a drag so it survives the next layout pass
                    // instead of snapping back to the derived width.
                    onWidthChanged: (w) => ref
                        .read(sequencerLeftPanelWidthProvider.notifier)
                        .state = w.clamp(dims.leftMin, dims.leftMax),
                    child: _ToolboxPanel(
                      key: TourTarget.sequencerNodePalette.key,
                      colors: colors,
                      onCollapse: closeToolbox,
                    ),
                  ),
                  // Center - the canvas: its own 44 px bar, then the tree.
                  // A minWidth inside an Expanded is not enforced: while one
                  // panel slides shut and the other open, the plan was laid
                  // out at a few pixels and every row overflowed. It keeps its
                  // floor and is clipped for those frames instead.
                  Expanded(
                    child: ClipRect(
                      child: LayoutBuilder(
                        builder: (context, slot) {
                          final width = slot.maxWidth < minCenterWidth
                              ? minCenterWidth
                              : slot.maxWidth;
                          return OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: width,
                            maxWidth: width,
                            child: Column(
                              children: [
                                SequenceToolbar(
                                  key: TourTarget.sequencerToolbar.key,
                                  colors: colors,
                                ),
                                Expanded(
                                  child: SequenceTree(
                                    key: TourTarget.sequencerCanvas.key,
                                    colors: colors,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  // Right panel - Properties. The panel expands with an empty
                  // state, so the toggle is always live and the affordance is
                  // discoverable before a node is selected — the panel renders
                  // NodePropertiesPanel's own "select a node" empty state.
                  _CollapsiblePanel(
                    colors: colors,
                    isCollapsed: overlayPanels || effectivePropertiesCollapsed,
                    collapsedWidth: collapsedPanelWidth,
                    expandedWidth: rightWidth,
                    minExpandedWidth: dims.rightMin,
                    maxExpandedWidth: dims.rightMax,
                    side: ResizeSide.left,
                    collapsedIcon: LucideIcons.settings2,
                    collapsedTooltip: 'Show Properties',
                    onToggle: () {
                      final opening =
                          overlayPanels || effectivePropertiesCollapsed;
                      ref
                          .read(sequencerPropertiesCollapsedProvider.notifier)
                          .state = !opening;
                      ref
                          .read(sequencerPropertiesForceOpenProvider.notifier)
                          .state = opening;
                      if (opening && (overlayPanels || !bothFit)) {
                        closeToolbox();
                      }
                    },
                    onWidthChanged: (w) => ref
                        .read(sequencerRightPanelWidthProvider.notifier)
                        .state = w.clamp(dims.rightMin, dims.rightMax),
                    child: NodePropertiesPanel(
                      key: TourTarget.sequencerPropertiesPanel.key,
                      colors: colors,
                      onCollapse: closeProperties,
                    ),
                  ),
                ],
              );
              // As overlays the panels follow what the operator is doing, not
              // the docked preference: the toolbox while its rail was tapped,
              // the inspector while a step is selected (or its rail tapped).
              final propertiesOpen =
                  overlayPanels && (hasSelection || propertiesForceOpen);
              // One overlay at a time: a step selected (tapped, or just
              // added) shows its inspector in place of the toolbox.
              final toolboxOpen =
                  overlayPanels && toolboxForceOpen && !propertiesOpen;
              if (!toolboxOpen && !propertiesOpen) return docked;
              final sheetWidth = (availableWidth - collapsedPanelWidth * 2)
                  .clamp(dims.rightMin, 420.0);
              return Stack(
                children: [
                  docked,
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (toolboxOpen) closeToolbox();
                        if (propertiesOpen) closeProperties();
                      },
                      child: ColoredBox(
                        color: ImageOverlayColors.shadow.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  if (toolboxOpen)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: (availableWidth - collapsedPanelWidth * 2)
                          .clamp(dims.leftMin, 320.0),
                      child: Material(
                        elevation: 8,
                        color: colors.surface,
                        child: _ToolboxPanel(
                          key: TourTarget.sequencerNodePalette.key,
                          colors: colors,
                          onCollapse: closeToolbox,
                        ),
                      ),
                    ),
                  if (propertiesOpen)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: sheetWidth,
                      child: Material(
                        elevation: 8,
                        color: colors.surface,
                        child: NodePropertiesPanel(
                          key: TourTarget.sequencerPropertiesPanel.key,
                          colors: colors,
                          onCollapse: closeProperties,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
