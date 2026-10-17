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
              SequenceToolbar(
                  key: SequencerTutorialKeys.toolbar, colors: colors),

              // Compact playback controls.
              MobilePlaybackBar(colors: colors),

              // Live telemetry while executing — a wrapping stat strip so the
              // dense readout reflows instead of overflowing a phone column.
              if (isRunning) _MobileTelemetryStrip(colors: colors),

              // Progress bar (when running).
              if (isRunning)
                SequenceProgressBar(
                    key: SequencerTutorialKeys.progressBar, colors: colors),

              // Tree (portrait: full width; landscape: split with properties).
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wideLandscape =
                        constraints.maxWidth > constraints.maxHeight &&
                            constraints.maxWidth >= _kSequencerSplitMinWidth;
                    // Show the split whenever there's real width to
                    // spare, even with nothing selected — the properties pane
                    // renders its "Select a node to edit" hint, which teaches
                    // the affordance proactively instead of hiding it until a
                    // first selection.
                    if (wideLandscape) {
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
                // Add-node FAB.
                FloatingActionButton(
                  heroTag: 'add_node_fab',
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
/// split. Falls back to a hint when no node is selected.
class _LandscapePropertiesPane extends ConsumerWidget {
  final SkotiqColors colors;

  const _LandscapePropertiesPane({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedNodeId = ref.watch(selectedNodeIdProvider);
    final pane = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: selectedNodeId == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Select a node to edit',
                  textAlign: TextAlign.center,
                  style:
                      SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
                ),
              ),
            )
          : NodePropertiesPanel(
              key: SequencerTutorialKeys.propertiesPanel,
              colors: colors,
              // The landscape pane is narrow (~40% of a phone's long edge), so
              // use the mobile-sheet rendering, which is built to reflow/scroll
              // at small widths instead of the desktop sidebar's fixed rows.
              isMobileSheet: true,
            ),
    );
    return pane;
  }
}

/// Live equipment telemetry for the phone builder, rendered with
/// [ResponsiveStatStrip] so the dense readout wraps to two columns / one column
/// on narrow widths instead of overflowing the fixed-width horizontal strip the
/// desktop layout uses.
class _MobileTelemetryStrip extends ConsumerWidget {
  final SkotiqColors colors;

  const _MobileTelemetryStrip({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final camera = ref.watch(cameraStateProvider);
    final mount = ref.watch(mountStateProvider);
    final focuser = ref.watch(focuserStateProvider);
    final filterWheel = ref.watch(filterWheelStateProvider);
    final guider = ref.watch(guiderStateProvider);

    bool connected(DeviceConnectionState s) =>
        s == DeviceConnectionState.connected;

    final stats = <ResponsiveStat>[
      if (connected(camera.connectionState))
        ResponsiveStat(
          label: 'Cam',
          icon: LucideIcons.thermometer,
          value: camera.temperature != null
              ? '${camera.temperature!.toStringAsFixed(1)}°C'
              : '--',
        ),
      if (connected(focuser.connectionState))
        ResponsiveStat(
          label: 'Focus',
          icon: LucideIcons.focus,
          value: focuser.position?.toString() ?? '--',
          valueColor: focuser.isMoving ? colors.warning : null,
        ),
      if (connected(filterWheel.connectionState))
        ResponsiveStat(
          label: 'Filter',
          icon: LucideIcons.filter,
          value: filterWheel.currentFilterName ??
              'Pos ${filterWheel.currentPosition ?? '?'}',
          valueColor: filterWheel.isMoving ? colors.warning : null,
        ),
      if (connected(guider.connectionState))
        ResponsiveStat(
          label: 'RMS',
          icon: LucideIcons.crosshair,
          value: guider.isGuiding
              ? (guider.rmsTotal != null
                  ? '${guider.rmsTotal!.toStringAsFixed(2)}"'
                  : 'Guiding')
              : 'Idle',
          accent: guider.isGuiding
              ? (guider.rmsTotal != null && guider.rmsTotal! < 1.0
                  ? colors.success
                  : colors.warning)
              : colors.textMuted,
        ),
      if (connected(mount.connectionState))
        ResponsiveStat(
          label: 'Mount',
          icon: LucideIcons.locateFixed,
          value: mount.isSlewing
              ? 'Slewing'
              : mount.isTracking
                  ? 'Tracking'
                  : mount.isParked
                      ? 'Parked'
                      : 'Idle',
          accent: mount.isSlewing
              ? colors.warning
              : mount.isTracking
                  ? colors.success
                  : mount.isParked
                      ? colors.textMuted
                      : colors.error,
        ),
    ];

    if (stats.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: ResponsiveStatStrip(stats: stats, minCellWidth: 96),
    );
  }
}
