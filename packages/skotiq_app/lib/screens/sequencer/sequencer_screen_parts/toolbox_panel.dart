part of '../sequencer_screen.dart';

class _ToolboxPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final VoidCallback? onCollapse;

  const _ToolboxPanel({
    super.key,
    required this.colors,
    this.onCollapse,
  });

  @override
  ConsumerState<_ToolboxPanel> createState() => _ToolboxPanelState();
}

class _ToolboxPanelState extends ConsumerState<_ToolboxPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: SequencerToolboxTab.values.length,
      vsync: this,
    );
    // Seed initial tab from the enum provider once. After this, sync flows
    // via the ref.listenManual hook below, which keeps animateTo out of
    // build(). The 3-tab controller and the 3-value enum share one domain, so
    // there is no lossy bool→3-tab mapping.
    _tabController.index = ref.read(sequencerToolboxTabProvider).index;
    _tabController.addListener(_onTabChanged);

    ref.listenManual<SequencerToolboxTab>(sequencerToolboxTabProvider,
        (prev, next) {
      if (!mounted) return;
      if (_tabController.index != next.index) {
        _tabController.animateTo(next.index);
      }
    });

    // One-way bridge for the `snippetPaletteVisibleProvider` intent flag: a
    // cross-area caller (Templates → "Go to Builder") flips it true to surface
    // snippets. Act on the rising edge by switching the enum, then reset the
    // flag so it stays a one-shot trigger with no bidirectional coupling.
    ref.listenManual<bool>(snippetPaletteVisibleProvider, (prev, next) {
      if (!mounted || !next) return;
      ref.read(sequencerToolboxTabProvider.notifier).state =
          SequencerToolboxTab.snippets;
      ref.read(snippetPaletteVisibleProvider.notifier).state = false;
    });
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      // Mirror every tab (including Targets) back to the enum provider so
      // the provider is the single source of truth for the active toolbox
      // tab and persists the user's last choice.
      final tab = SequencerToolboxTab.values[_tabController.index];
      if (ref.read(sequencerToolboxTabProvider) != tab) {
        ref.read(sequencerToolboxTabProvider.notifier).state = tab;
      }
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watched (not read off the controller) so the tabs' selected-state
    // announcement rebuilds with the pane it describes.
    final activeIndex = ref.watch(sequencerToolboxTabProvider).index;
    return Container(
      decoration: BoxDecoration(
        color: widget.colors.surface,
        border: Border(right: BorderSide(color: widget.colors.border)),
      ),
      child: Column(
        children: [
          // A second-level switch INSIDE a panel is a SegmentedControl, never
          // a tab strip: the page header owns the only tab style in the app
          // (05 §4). The control sizes itself, so the old shrink-the-labels
          // LayoutBuilder is gone with the pills it was compensating for.
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            child: Row(
              children: [
                Expanded(
                  // SegmentedControl publishes button / enabled / selected /
                  // label per segment, so the palette switch has a role and a
                  // state in the tree without a wrapper of its own. The Ctrl+T
                  // accelerator is not repeated here: shortcuts live in the top
                  // bar's help popover (05 §11).
                  // Scrolls rather than shrinks: the palette can be dragged
                  // down to 220 px, where three labels do not fit, and the old
                  // strip answered that by cutting "Nodes" to "\odes" and
                  // "Targets" to "Target". 07: "Do not scale fonts down to
                  // make something fit. Reduce content or let it scroll."
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedControl(
                      segments: const ['Nodes', 'Snippets', 'Targets'],
                      selectedIndex: activeIndex,
                      onSelected: _tabController.animateTo,
                    ),
                  ),
                ),
                if (widget.onCollapse != null)
                  SkotiqIconButton(
                    icon: LucideIcons.panelLeftClose,
                    tooltip: 'Collapse panel',
                    size: IconButtonSize.sm,
                    onPressed: widget.onCollapse,
                  ),
              ],
            ),
          ),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Node Palette (without its own header since we have tabs)
                _NodePaletteContent(colors: widget.colors),
                // Snippet Palette
                _SnippetPaletteContent(colors: widget.colors),
                // Targets: the sequence's own target headers above the
                // planetarium's saved-for-later wishlist, which is still
                // draggable onto the sequence tree.
                TargetQueuePanel(colors: widget.colors),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Node palette content without header (used in toolbox tabs)
