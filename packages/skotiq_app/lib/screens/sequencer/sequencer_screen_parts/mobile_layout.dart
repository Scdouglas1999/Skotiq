part of '../sequencer_screen.dart';

/// Minimum width at which the phone-landscape builder splits the tree and the
/// properties pane side-by-side. One named source instead of a literal 560
/// sprinkled through the layout.
const double _kSequencerSplitMinWidth = 560.0;

/// Shows the node palette as an adaptive modal. Single definition used by
/// both the phone builder and the narrow-desktop rail so the presentation
/// (design width / phone sheet) is defined once.
void showSequencerNodeSheet(BuildContext context, SkotiqColors colors) {
  showAdaptiveModal<void>(
    context: context,
    designWidth: 420,
    builder: (sheetContext) => NodePalette(
      colors: colors,
      isMobileSheet: true,
      onNodeAdded: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

/// Shows the selected node's properties as an adaptive modal. The
/// properties form is content-heavy, so it gets a full-screen route on a phone
/// and a centered dialog on tablet.
void showSequencerPropertiesSheet(BuildContext context, SkotiqColors colors) {
  showAdaptiveModal<void>(
    context: context,
    designWidth: 560,
    designHeight: 640,
    phoneMode: PhoneModalMode.fullScreen,
    builder: (sheetContext) => NodePropertiesPanel(
      colors: colors,
      isMobileSheet: true,
      showDragHandle: false,
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

/// Phone builder layout.
///
/// Phone-first reflow of the desktop 3-column builder:
///
///   * **Portrait** — the sequence tree is the single dominant, full-width
///     column. The node palette and the selected node's properties live in
///     adaptive modals (bottom sheet / full-screen route via
///     [showAdaptiveModal]), reached from the FABs / a tapped node.
///   * **Landscape** — the extra width is used for a fixed side-by-side split
///     (tree on the left, properties on the right) via [TwoPane] so editing a
///     node doesn't require opening a sheet. The palette still opens as a
///     sheet from the add FAB.
///
/// Everything sits inside a [SafeArea] and uses ≥ 48 px touch targets.
class _MobileBuilderLayout extends ConsumerWidget {
  final SkotiqColors colors;

  const _MobileBuilderLayout({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final selectedNodeId = ref.watch(selectedNodeIdProvider);
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final isRunning = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused;
    final transportLive =
        ref.watch(sequencerRunTransportProvider).phase.isRunLive;
    // Read orientation once for the build-time decisions (the FAB
    // visibility check below). The onNodeTap closure keeps its own tap-time
    // read so a rotation between build and tap still routes correctly.
    final landscape = Responsive.isLandscape(context);

    final tree = SequenceTree(
      colors: colors,
      isMobile: true,
      onNodeTap: (nodeId) {
        ref.read(selectedNodeIdProvider.notifier).state = nodeId;
        // In landscape the properties pane is already on-screen, so a tap
        // just selects. In portrait we surface the editor as a route.
        // Read orientation at tap time — it can change after this build.
        if (!Responsive.isLandscape(context)) {
          showSequencerPropertiesSheet(context, colors);
        }
      },
    );

    return SafeArea(
      top: false,
      child: Stack(
        children: [
          Column(
            children: [
              // File/edit actions (New, Open, Save, Undo) — mobile remote
              // clients need the same affordances as the desktop builder.
              // With no run live Start joins the toolbar; while a run is
              // live its pause, stop and skip do, instead of a row of their
              // own.
              SequenceToolbar(
                key: TourTarget.sequencerToolbar.key,
                colors: colors,
                showStart: !transportLive,
                transport:
                    transportLive ? MobilePlaybackBar(colors: colors) : null,
              ),

              // Live telemetry while executing: the one-line strip Imaging
              // shows, so a phone has one status bar and the plan keeps the
              // height a two-row stat grid took. On its side the height is
              // the plan's: the run's band above already says what runs.
              if (isRunning && !landscape) const ImagingStatusStrip(),

              // Tree (portrait: full width; landscape: split with properties).
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wideLandscape =
                        constraints.maxWidth > constraints.maxHeight &&
                            constraints.maxWidth >= _kSequencerSplitMinWidth;
                    // The split only while a step is selected, so the plan
                    // keeps the width for the ledger otherwise. Its close
                    // button (or tapping the step again) gives the width
                    // back.
                    if (wideLandscape && selectedNodeId != null) {
                      return TwoPane(
                        startFlex: 3,
                        endFlex: 2,
                        minSplitWidth: _kSequencerSplitMinWidth,
                        start: tree,
                        end: _LandscapePropertiesPane(colors: colors),
                      );
                    }
                    return tree;
                  },
                ),
              ),
            ],
          ),

          // Add / edit FABs, anchored above the safe-area inset.
          Positioned(
            bottom: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Properties FAB — only in portrait (landscape shows the
                // properties pane inline) and only with a node selected.
                if (selectedNodeId != null && !landscape) ...[
                  FloatingActionButton.small(
                    heroTag: 'properties_fab',
                    tooltip: 'Step properties',
                    backgroundColor: colors.accent,
                    onPressed: () =>
                        showSequencerPropertiesSheet(context, colors),
                    child: Icon(
                      LucideIcons.settings2,
                      color: onPrimary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // On its side with a step selected the properties pane sits
                // here, and the button covered its tabs. The plan's own
                // "Tap + to add a node" row stays.
                if (!(landscape && selectedNodeId != null))
                  FloatingActionButton(
                    heroTag: 'add_node_fab',
                    tooltip: 'Add a step',
                    backgroundColor: colors.primary,
                    onPressed: () => showSequencerNodeSheet(context, colors),
                    child: Icon(LucideIcons.plus, color: onPrimary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The inline properties pane shown in the right half of the phone-landscape
/// split, which is built only while a step is selected.
class _LandscapePropertiesPane extends ConsumerWidget {
  final SkotiqColors colors;

  const _LandscapePropertiesPane({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: NodePropertiesPanel(
        key: TourTarget.sequencerPropertiesPanel.key,
        colors: colors,
        // The landscape pane is narrow (~40% of a phone's long edge), so
        // use the mobile-sheet rendering, which is built to reflow/scroll
        // at small widths instead of the desktop sidebar's fixed rows.
        isMobileSheet: true,
        onClose: () => ref.read(selectedNodeIdProvider.notifier).state = null,
      ),
    );
  }
}
