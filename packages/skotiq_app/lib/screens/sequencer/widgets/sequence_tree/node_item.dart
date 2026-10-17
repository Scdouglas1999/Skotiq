part of '../sequence_tree.dart';

/// The kebab's own footprint on a card row.
///
/// `PopupMenuButton` renders an [IconButton], which enforces Material's
/// interactive minimum on itself whatever padding it is given — so this is the
/// width the menu takes, not a width chosen for it.
const double _cardKebabWidth = kMinInteractiveDimension;

/// Width a card row keeps for its hover-revealed actions on a pointer
/// platform: the eye / duplicate / delete trio (the same 28 px chip the ledger
/// row reserves) plus the kebab.
///
/// A MINIMUM, not a fixed width. `_cardKebabWidth` is the kebab's floor, not a
/// promise: a theme with denser or looser visual density, or a large text
/// scale, can make the real `IconButton` wider, and a tight box around it would
/// then overflow every comfortable row in the tree at once. The cluster is the
/// same widget hovered or not — only the chips swap for a spacer of their exact
/// width — so letting the slot size itself cannot introduce a hover shift.
const double _cardActionsWidth = 3 * _ledgerActionChipWidth + _cardKebabWidth;

class _NodeItem extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final SequenceNode node;
  final bool isSelected;
  final NodeStatus? nodeStatus;
  final bool hasChildren;
  final int depth;
  final VoidCallback? onSelect;
  final VoidCallback? onToggleEnabled;
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final bool isDragging;
  final double? progressPercent;
  final String? progressDetail;
  final InstructionProgressDetail? structuredProgressDetail;
  final bool isMobile;

  /// The filter the RUN is using, from `SequenceProgress.currentFilter`.
  ///
  /// An exposure node with no filter of its own still images through whatever
  /// is in the wheel, and the run names that filter everywhere else — the
  /// telemetry strip, the thumbnails, the FITS filenames and the session report
  /// all say `R`, so this card's header must not say "No Filter".
  final String? runFilter;

  /// Whether this node is collapsed in the tree (children hidden). Drives the
  /// chevron rotation; kept in sync with [collapsedNodeIdsProvider] which the
  /// chevron tap toggles. Computed by [_NodeTreeView] so the two stay
  /// consistent. Only meaningful for containers ([hasChildren] / target).
  final bool isCollapsed;

  /// Whether the row keeps the content that renders BELOW its title block —
  /// the live progress panel and the node's comment line.
  ///
  /// False in Compact density, where the row is the summary line and nothing
  /// else; that content moves to the node inspector. The panel's own
  /// persistence state machine still runs, so switching back to Comfortable
  /// mid-run reveals the panel the run is actually on rather than a blank.
  final bool showInlineExtras;

  const _NodeItem({
    required this.colors,
    required this.node,
    required this.isSelected,
    required this.nodeStatus,
    required this.hasChildren,
    required this.depth,
    this.onSelect,
    this.onToggleEnabled,
    this.onDelete,
    this.onDuplicate,
    this.onMoveUp,
    this.onMoveDown,
    this.isDragging = false,
    this.progressPercent,
    this.progressDetail,
    this.structuredProgressDetail,
    this.runFilter,
    this.isMobile = false,
    this.isCollapsed = false,
    this.showInlineExtras = true,
  });

  @override
  ConsumerState<_NodeItem> createState() => _NodeItemState();
}

class _NodeItemState extends ConsumerState<_NodeItem> {
  // Hover state lives in a ValueNotifier (not setState) so moving the mouse
  // over the row doesn't rebuild the whole _NodeItem subtree — only the two
  // hover-dependent islands (background color + action cluster) listen.
  final ValueNotifier<bool> _isHovered = ValueNotifier<bool>(false);

  // Selecting a row takes keyboard focus. The screen's Delete / Ctrl+D /
  // Ctrl+Z bindings are a `CallbackShortcuts` subtree, so they only fire
  // while primary focus is inside it — and the palette's search field, which
  // is where a user is typing moments before they click the node they want to
  // delete, holds focus and swallows those keys. Rows are click targets, not
  // tab stops (`skipTraversal`), so this changes what the keys act on without
  // inserting a stop per node into the tab order.
  final FocusNode _rowFocusNode = FocusNode(debugLabel: 'sequence-tree-row');

  // For progress panel persistence
  bool _showProgressPanel = false;
  DateTime? _lastRunningTime;
  Timer? _panelPersistTimer;
  static const _panelPersistDuration = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    if (widget.nodeStatus == NodeStatus.running) {
      _showProgressPanel = true;
      _lastRunningTime = DateTime.now();
    }
  }

  @override
  void didUpdateWidget(_NodeItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodeStatus == NodeStatus.running) {
      _showProgressPanel = true;
      _lastRunningTime = DateTime.now();
    } else {
      // Keep panel visible for 20 seconds after node stops running. Owned so
      // we can cancel on dispose — a teardown mid-delay would otherwise leak
      // a pending Timer past the widget tree.
      if (oldWidget.nodeStatus == NodeStatus.running && _showProgressPanel) {
        _panelPersistTimer?.cancel();
        _panelPersistTimer = Timer(_panelPersistDuration, () {
          if (mounted && widget.nodeStatus != NodeStatus.running) {
            setState(() => _showProgressPanel = false);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _panelPersistTimer?.cancel();
    _isHovered.dispose();
    _rowFocusNode.dispose();
    super.dispose();
  }

  bool get _shouldShowProgressPanel {
    // Show panel whenever node is running
    if (widget.nodeStatus == NodeStatus.running) {
      return true;
    }

    // Show panel during persistence period after node stops running
    if (_showProgressPanel && _lastRunningTime != null) {
      final elapsed = DateTime.now().difference(_lastRunningTime!);
      return elapsed < _panelPersistDuration;
    }

    return false;
  }

  /// Whether this node is being executed **right now**.
  ///
  /// `nodeStatus == running` is the node's own last-reported status. A PAUSED
  /// run has nothing executing in it — the node is where the run stopped, not
  /// work in progress — and an idle app has nothing executing at all.
  /// Measured: a paused run held two 16 px spinners at 61 fps and 46% of one
  /// core, and a spinning icon on a run that is not running is also a claim
  /// the app cannot back. Only the spin is gated on this: the running stripe,
  /// the highlight and the live progress panel still say "this is the node the
  /// run is on", which stays true while paused.
  bool get _isExecuting =>
      widget.nodeStatus == NodeStatus.running &&
      ref.watch(sequenceExecutionStateProvider) ==
          SequenceExecutionState.running;

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor();
    // An Autofocus node in defaults mode runs the AppSettings method, not its
    // own `method` field, so the row (and the screen-reader phrase built from
    // it) has to be told what that global method is.
    final node = widget.node;
    final globalAfMethod = node is AutofocusNode && node.useSettingsDefaults
        ? ref.watch(autofocusSettingsProvider).method
        : null;
    final summaryFragments =
        nodeSummary(node, globalAutofocusMethod: globalAfMethod);
    final summaryA11yText = _summaryA11yText(summaryFragments);
    // The collapsed-container rollup, shown on the title row only when the
    // density has stripped the inline extras (compact): an expanded container
    // has its children on screen and needs no summary, and comfortable mode
    // already spends the space on them.
    final rollupText =
        !widget.showInlineExtras && widget.isCollapsed && widget.hasChildren
            ? ref.watch(rollupSummaryMapProvider
                    .select((summaries) => summaries[widget.node.id])) ??
                ''
            : '';
    // The panel outlives the run by 20 s, and on the success path the per-node
    // progress entries are already gone by then — rendering it from the live
    // maps alone announced "0 / 4 frames" directly above the four thumbnails
    // the node had just captured. The session memory is a provider rather than
    // a field per row so the inspector's Activity tab and this panel cannot
    // disagree about what the node last did; watched only while the panel is
    // actually up, so an idle tree does not rebuild every row on every tick.
    final lastKnown = widget.showInlineExtras && _shouldShowProgressPanel
        ? ref.watch(lastKnownNodeActivityProvider
            .select((snapshots) => snapshots[widget.node.id]))
        : null;
    final isDisabled = !widget.node.isEnabled;
    final isRunning = widget.nodeStatus == NodeStatus.running;
    final isSuccess = widget.nodeStatus == NodeStatus.success;
    final isFailed = widget.nodeStatus == NodeStatus.failure;
    final isSkipped = widget.nodeStatus == NodeStatus.skipped;
    final isCancelled = widget.nodeStatus == NodeStatus.cancelled;
    final isTargetHeader = widget.node is TargetHeaderNode;
    final isMobile = widget.isMobile;

    // A step at the top of the canvas is a SkotiqPanel; a step nested
    // inside a container is a `well` row inside that panel (06 §Sequencer:
    // "its children as `well` rows"). That is the whole nesting rule —
    // panel -> well and no deeper.
    // depth 0 is the implicit root container, which the tree does not draw;
    // the steps the operator sees start at depth 1 and their children at 2.
    final isNested = widget.depth > 1;
    final verticalMargin = isMobile ? SkotiqTokens.spaceXs : 3.0;
    final horizontalPadding =
        isMobile ? SkotiqTokens.spaceMd + 2 : SkotiqTokens.spaceMd;
    final verticalPadding = isMobile
        ? SkotiqTokens.spaceMd + 2
        : (isNested ? SkotiqTokens.spaceSm : SkotiqTokens.spaceSm + 2);
    final iconBoxSize = isMobile ? 40.0 : 28.0;
    final iconSize = isMobile ? 20.0 : 14.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          onEnter: (_) => _isHovered.value = true,
          onExit: (_) => _isHovered.value = false,
          child: Semantics(
            button: true,
            selected: widget.isSelected,
            enabled: widget.node.isEnabled,
            label: widget.node.name,
            value: summaryA11yText.isNotEmpty ? summaryA11yText : null,
            hint:
                'Select node. More actions include reorder and wrap commands.',
            child: Focus(
              focusNode: _rowFocusNode,
              skipTraversal: true,
              child: GestureDetector(
                onTap: () {
                  // Take focus FIRST: the click that selects a node is also
                  // the moment the keyboard shortcuts must start applying to
                  // it. Without this the palette's search field keeps primary
                  // focus and Delete / Ctrl+D / Ctrl+Z silently do nothing.
                  _rowFocusNode.requestFocus();
                  widget.onSelect?.call();
                },
                child: ValueListenableBuilder<bool>(
                  valueListenable: _isHovered,
                  // The container's heavy child (icon / name / summary) is built
                  // ONCE and passed via `child`, so hover only recomputes the
                  // background color, not the whole row.
                  child: _buildRowBody(
                    context: context,
                    statusColor: statusColor,
                    summaryFragments: summaryFragments,
                    rollupText: rollupText,
                    isDisabled: isDisabled,
                    isRunning: isRunning,
                    isSuccess: isSuccess,
                    isFailed: isFailed,
                    isSkipped: isSkipped,
                    isCancelled: isCancelled,
                    isTargetHeader: isTargetHeader,
                    isNested: isNested,
                    isMobile: isMobile,
                    iconBoxSize: iconBoxSize,
                    iconSize: iconSize,
                  ),
                  builder: (context, hovered, child) => AnimatedContainer(
                    // Hover tint and the selection ring travel on the same
                    // token in every density (spec §9): the ledger row's
                    // `AnimatedContainer` is the same call with the same
                    // duration, so a step cannot light up at two speeds
                    // depending on how it is drawn.
                    duration: animationDuration(
                      context,
                      SkotiqTokens.durationFast,
                    ),
                    curve: SkotiqTokens.curveStandard,
                    margin: EdgeInsets.symmetric(vertical: verticalMargin),
                    padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                        vertical: verticalPadding),
                    decoration: _rowDecoration(
                      isNested: isNested,
                      isSelected: widget.isSelected || widget.isDragging,
                      hovered: hovered,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
        // Progress panel for expanded details
        if (widget.showInlineExtras && _shouldShowProgressPanel)
          getProgressPanelForNode(
            node: widget.node,
            colors: widget.colors,
            progressPercent: widget.progressPercent ?? lastKnown?.percent ?? 0,
            progressDetail: widget.progressDetail ?? lastKnown?.detail,
            structuredProgressDetail:
                widget.structuredProgressDetail ?? lastKnown?.structuredDetail,
            nodeStatus: widget.nodeStatus ?? lastKnown?.status,
            runFilter: widget.runFilter ?? lastKnown?.runFilter,
            // The frames this node actually captured, from the slot no
            // other instruction can overwrite. Watched here rather
            // than threaded down the tree so the count reaches the card by
            // the shortest path there is.
            exposureTally: ref.watch(nodeExposureTallyProvider)[widget.node.id],
          ),
      ],
    );
  }

  /// [child], breathing if this row is the one the run is on and the density
  /// has no spinner to say so.
  Widget _maybeBreathing({required bool breathing, required Widget child}) =>
      breathing ? _RunningMarkerBreath(child: child) : child;

  /// The eye / duplicate / delete trio and the kebab, as they sit on a card
  /// row.
  ///
  /// On touch the trio folds into the kebab instead of sitting inline. Three
  /// 24dp chips are not legal Android tap targets, and padding each one up to
  /// 48 adds 72dp to a row that then overflows a 360dp phone by 30 — measured,
  /// not guessed. Moving them behind the kebab gives the same three actions a
  /// single already-compliant 48dp target and hands 84dp back to the row.
  Widget _buildActionCluster(BuildContext context, {required bool chips}) {
    final showChips = chips && !SkotiqTouchTarget.isTouch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (!SkotiqTouchTarget.isTouch(context) && !chips)
          const SizedBox(width: 3 * _ledgerActionChipWidth),
        if (showChips)
          _NodeActionChips(
            colors: widget.colors,
            node: widget.node,
            onToggleEnabled: widget.onToggleEnabled,
            onDuplicate: widget.onDuplicate,
            onDelete: widget.onDelete,
          ),
        // Inline more-actions menu, shared with the ledger row.
        _NodeOverflowMenu(
          colors: widget.colors,
          node: widget.node,
          onToggleEnabled: widget.onToggleEnabled,
          onDuplicate: widget.onDuplicate,
          onDelete: widget.onDelete,
          onMoveUp: widget.onMoveUp,
          onMoveDown: widget.onMoveDown,
        ),
      ],
    );
  }

  /// The step's container.
  ///
  /// Tone, not lines (02 rule 2): a top-level step is a `SkotiqPanel`, a
  /// nested step is a `well` row inside it, and the ONE line either can carry
  /// is the selected ring. The old row painted a 2 px border in the node's
  /// category colour plus a tinted fill per run status — five colours of
  /// chrome competing with the sequence itself.
  BoxDecoration _rowDecoration({
    required bool isNested,
    required bool isSelected,
    required bool hovered,
  }) {
    final colors = widget.colors;
    if (isSelected) {
      final selected = SkotiqDecorations.panelSelected(colors);
      return isNested
          ? selected.copyWith(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
            )
          : selected;
    }
    if (isNested) {
      final well = SkotiqDecorations.well(colors);
      return hovered ? well.copyWith(color: colors.surfaceHover) : well;
    }
    final panel = SkotiqDecorations.panel(colors);
    return hovered ? panel.copyWith(color: colors.surfaceHover) : panel;
  }

  /// The static (hover-independent) body of the row: status bar, icon, name,
  /// summary, and the action cluster. Built once and handed to the
  /// background [ValueListenableBuilder] via its `child` slot.
  Widget _buildRowBody({
    required BuildContext context,
    required Color statusColor,
    required List<SummaryFragment> summaryFragments,
    required String rollupText,
    required bool isDisabled,
    required bool isRunning,
    required bool isSuccess,
    required bool isFailed,
    required bool isSkipped,
    required bool isCancelled,
    required bool isTargetHeader,
    required bool isNested,
    required bool isMobile,
    required double iconBoxSize,
    required double iconSize,
  }) {
    return Opacity(
      opacity: isDisabled
          ? 0.5
          : (isSkipped || isCancelled)
              ? 0.6
              : 1.0,
      child: Row(
        children: [
          // Status indicator. In Compact it is the row's only running marker —
          // the spinner is Comfortable's — so there it breathes (spec §9).
          if (widget.nodeStatus != null &&
              widget.nodeStatus != NodeStatus.pending)
            _maybeBreathing(
              breathing:
                  isRunning && !widget.showInlineExtras && !widget.isDragging,
              child: Container(
                width: 4,
                height: iconBoxSize,
                margin: EdgeInsets.only(right: isMobile ? 12 : 10),
                decoration: BoxDecoration(
                  color: statusColor,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline2),
                ),
              ),
            ),

          // Icon. A square in `well` at the top level; inside a container the
          // row IS a well, so the glyph stands alone rather than sitting in a
          // second inset (panel -> well is the deepest nesting there is).
          if (isNested)
            Icon(
              _getIcon(),
              size: iconSize,
              color: widget.isSelected
                  ? widget.colors.primary
                  : widget.colors.textMuted,
            )
          else
            Container(
              width: iconBoxSize,
              height: iconBoxSize,
              decoration: widget.isSelected
                  ? SkotiqDecorations.tintedBadge(
                      widget.colors.primary,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusSm),
                    )
                  : SkotiqDecorations.well(widget.colors),
              child: _isExecuting
                  ? _SpinningIcon(
                      icon: _getIcon(),
                      color: widget.isSelected
                          ? widget.colors.primary
                          : widget.colors.textSecondary,
                      size: iconSize,
                    )
                  : Icon(
                      _getIcon(),
                      size: iconSize,
                      color: widget.isSelected
                          ? widget.colors.primary
                          : widget.colors.textSecondary,
                    ),
            ),
          SizedBox(
              width: isMobile
                  ? SkotiqTokens.spaceMd + 2
                  : SkotiqTokens.spaceSm + 2),

          // Name and subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title row: the node name, followed inline by
                // the watchdog badge for trigger-category nodes
                // (e.g. Meridian Flip). The badge sits after the
                // title and before any trailing row-level status
                // indicator so it reads as a property of the
                // node, not of the run.
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.node.name,
                        // Step titles are 14/500 at the top level and 13 in a
                        // nested well row (06 §Sequencer). Run OUTCOME still
                        // colours the name — that is status, not decoration.
                        style: (isNested
                                ? SkotiqTypography.bodySm
                                : SkotiqTypography.button)
                            .copyWith(
                          color: isSuccess
                              ? widget.colors.success
                              : isFailed
                                  ? widget.colors.error
                                  : (isSkipped || isCancelled)
                                      ? widget.colors.textMuted
                                      : widget.colors.textPrimary,
                          decoration: isDisabled || isSkipped || isCancelled
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: isSkipped || isCancelled
                              ? widget.colors.textMuted
                              : null,
                        ),
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    if (widget.node.category == NodeCategory.trigger) ...[
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      _WatchdogBadge(colors: widget.colors),
                    ],
                    if (rollupText.isNotEmpty) ...[
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      Flexible(
                        child: Text(
                          rollupText,
                          style: SkotiqTypography.caption.copyWith(
                            color: widget.colors.textMuted,
                          ),
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ],
                ),
                if (summaryFragments.isNotEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.only(top: SkotiqTokens.spaceXs / 2),
                    child: NodeSummaryLine(
                      node: widget.node,
                      colors: widget.colors,
                      isMobile: isMobile,
                      mutedColorOverride: (isSkipped || isCancelled)
                          ? widget.colors.textMuted
                          : null,
                    ),
                  ),
                // Show node comment as gray italic text
                if (widget.showInlineExtras &&
                    widget.node.comment != null &&
                    widget.node.comment!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      widget.node.comment!,
                      style: SkotiqTypography.caption.copyWith(
                        color: widget.colors.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                // Show progress bar for running instructions
                if (isRunning &&
                    widget.progressPercent != null &&
                    widget.progressPercent! > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.progressDetail != null &&
                            widget.progressDetail!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              widget.progressDetail!,
                              style: SkotiqTypography.caption.copyWith(
                                color: widget.colors.brandWarm,
                              ),
                            ),
                          ),
                        ClipRRect(
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusXs),
                          child: LinearProgressIndicator(
                            value: widget.progressPercent! / 100.0,
                            minHeight: 4,
                            backgroundColor: widget.colors.surfaceHover,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                widget.colors.brandWarm),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Actions — visibility tracks hover (or always on
          // mobile). Scoped to its own ValueListenableBuilder so
          // hovering only rebuilds this cluster, not the whole row.
          //
          // The slot keeps its width on a pointer platform whether the actions
          // are drawn or not: actions that appear by INSERTING themselves push
          // the name and the summary sideways under the pointer, which is a
          // layout shift the operator caused by doing nothing but move the
          // mouse (spec §9, "no layout shift on hover"). Mobile draws them
          // unconditionally and so needs no reservation.
          ValueListenableBuilder<bool>(
            valueListenable: _isHovered,
            builder: (context, hovered, _) {
              if (widget.isDragging) return const SizedBox.shrink();
              if (isMobile) return _buildActionCluster(context, chips: true);
              final visible = hovered;
              final slotWidth = SkotiqTouchTarget.isTouch(context)
                  ? _cardKebabWidth
                  : _cardActionsWidth;
              return ConstrainedBox(
                constraints: BoxConstraints(minWidth: slotWidth),
                child: IgnorePointer(
                  ignoring: !visible,
                  // A hidden button must not be announced or focusable, or a
                  // screen-reader user lands on a control they cannot operate.
                  child: ExcludeSemantics(
                    excluding: !visible,
                    child: AnimatedOpacity(
                      opacity: visible ? 1 : 0,
                      duration: animationDuration(
                        context,
                        SkotiqTokens.durationFast,
                      ),
                      curve: SkotiqTokens.curveStandard,
                      // The trio is built only while the pointer is in the
                      // row; the kebab is not, for the same reason the ledger
                      // row keeps its own mounted — see [_LedgerActionsSlot].
                      child: _buildActionCluster(context, chips: visible),
                    ),
                  ),
                ),
              );
            },
          ),

          // Expand/collapse chevron for containers. Tapping it
          // toggles collapse via collapsedNodeIdsProvider; the
          // rotation follows widget.isCollapsed (kept in sync by
          // _NodeTreeView). Always shown for containers even when
          // empty to hint at nesting.
          if (widget.hasChildren || isTargetHeader)
            Tooltip(
              message: widget.isCollapsed ? 'Expand' : 'Collapse',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => ref
                    .read(collapsedNodeIdsProvider.notifier)
                    .toggle(widget.node.id),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: AnimatedRotation(
                    turns: widget.isCollapsed ? -0.25 : 0,
                    duration: animationDuration(
                      context,
                      SkotiqTokens.durationQuick,
                    ),
                    curve: SkotiqTokens.curveStandard,
                    child: Icon(
                      LucideIcons.chevronDown,
                      size: 14,
                      color: widget.colors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
