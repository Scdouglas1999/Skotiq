part of '../sequence_tree.dart';

// Sticky ancestors (spec §5).
//
// Thirty rows into a night the operator can no longer tell which target and
// which loop the rows on screen belong to. The ancestors of the topmost
// visible row pin to the top of the viewport once their own row has scrolled
// out of it, so the answer is always on screen.
//
// The stack is an OVERLAY on the scroll view, not a row in it: it must not
// change the tree's layout, must not duplicate a row in the accessibility
// traversal order, and must not swallow the scroll gesture of a pointer that
// happens to be over it.

/// Identifies the pinned stack for tests and for tooling that has to tell a
/// pinned row from the real one (they carry the same name).
const Key sequenceStickyAncestorsKey = Key('sequence-tree-sticky-ancestors');

/// At most three ancestors pin. Deeper than that and the stack eats the
/// viewport it exists to explain.
const int _maxPinnedAncestors = 3;

/// How far a newly pinned row travels as it fades in (spec §9).
const double _pinSlideDistance = 6.0;

/// The hairline the stack draws along its bottom edge to separate itself from
/// the rows scrolling under it. It is painted INSIDE the box (a `Border` on a
/// `DecoratedBox` does not grow it), so it costs the reservation nothing.
const double _stickyStackBorderWidth = 1.0;

/// Height a stack of [count] pinned rows occupies, and therefore the height
/// the scroll viewport gives up to it so the stack covers nothing.
///
/// Computed, not measured: every pinned row is exactly one [_ledgerRowHeight]
/// in both densities the stack draws (the ledger row is fixed-height by
/// definition, and [_PinnedCompactRow] is built to match it), so the figure is
/// exact and — unlike a render-box measurement — available on the same frame
/// the pin appears.
double pinnedStackHeight(int count) => count * _ledgerRowHeight;

/// The ancestors of [anchorId] that are currently pinned, outermost first.
///
/// [hasRowTopPassed] answers "has this row's own TOP edge gone under the
/// stack?" — the caller owns it because only it can measure the live render
/// boxes. The looser test (the row is merely partly hidden) is deliberate: the
/// stricter one, which waited for the row to be GONE, left the operator
/// looking at a half-cut container name under the stack for the 28 px of
/// scrolling it took to finish leaving, with nothing at the top of the screen
/// saying which container the rows below belonged to. The row's remaining
/// sliver is clipped by the scroll view either way; the only thing the looser
/// test changes is that its identity is on screen the whole time.
///
/// The returned depth is the row's depth in the tree (the root container is
/// not drawn, so its children are depth 1), which is what a ledger row needs
/// to draw its guide columns.
List<VisibleNode> pinnedAncestorsOf(
  Sequence sequence,
  String anchorId,
  bool Function(String nodeId) hasRowTopPassed,
) {
  final chain = sequenceAncestorIds(sequence, anchorId);
  final pinned = <VisibleNode>[
    for (var i = 0; i < chain.length; i++)
      if (hasRowTopPassed(chain[i])) (id: chain[i], depth: i + 1),
  ];
  if (pinned.length <= _maxPinnedAncestors) return pinned;
  // Keep the NEAREST ancestors: "which loop am I in" is a more pressing
  // question than "which of the two targets", and the nearest ones are the
  // rows that just left the screen.
  return pinned.sublist(pinned.length - _maxPinnedAncestors);
}

/// The pinned ancestor rows, stacked in depth order over the tree's viewport.
///
/// Stateful only so a row that stops being pinned can leave rather than
/// disappear: it keeps departing entries in place, collapsing and fading them
/// over [SkotiqTokens.durationFast], and drops them when that is done.
/// Un-pinning is far more common than pinning — it happens on every upward
/// scroll — and a stack that loses a row between two frames reads as a glitch
/// at the top of the canvas.
class _StickyAncestorStack extends StatefulWidget {
  final SkotiqColors colors;
  final Sequence sequence;
  final SequenceProgress progress;
  final List<VisibleNode> pinned;
  final SequencerDensity density;

  /// The scroll view's own horizontal padding, so a pinned row sits exactly
  /// over the column of the row it stands for.
  final EdgeInsets padding;

  final void Function(String nodeId) onTap;

  /// Called once the stack has nothing left to draw — its last pin has
  /// finished leaving — so the tree can stop building it.
  final VoidCallback onEmptied;

  const _StickyAncestorStack({
    super.key,
    required this.colors,
    required this.sequence,
    required this.progress,
    required this.pinned,
    required this.density,
    required this.padding,
    required this.onTap,
    required this.onEmptied,
  });

  @override
  State<_StickyAncestorStack> createState() => _StickyAncestorStackState();
}

class _StickyAncestorStackState extends State<_StickyAncestorStack> {
  /// Rows that have stopped being pinned and are still on their way out, in
  /// the position they held when they left.
  final List<VisibleNode> _departing = <VisibleNode>[];

  @override
  void didUpdateWidget(_StickyAncestorStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = {for (final entry in widget.pinned) entry.id};
    // A row that pinned again while it was still leaving goes straight back to
    // the live list; its `_PinTransition` is keyed by id, so the same widget
    // simply turns around.
    _departing.removeWhere((entry) => ids.contains(entry.id));
    for (final entry in oldWidget.pinned) {
      if (!ids.contains(entry.id) &&
          !_departing.any((other) => other.id == entry.id)) {
        _departing.add(entry);
      }
    }
  }

  void _dropDeparted(String nodeId) {
    if (!mounted) return;
    if (!_departing.any((entry) => entry.id == nodeId)) return;
    setState(() => _departing.removeWhere((entry) => entry.id == nodeId));
    // The LAST pin cannot fade out on its own: the tree stops building the
    // stack the moment nothing is pinned, so it has to be told when the stack
    // is finally empty rather than inferring it from the same set.
    if (_departing.isEmpty && widget.pinned.isEmpty) widget.onEmptied();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final sequence = widget.sequence;
    final progress = widget.progress;
    final density = widget.density;
    final onTap = widget.onTap;
    // Departing rows keep their place in the stack: a leaving row that jumped
    // to the bottom would travel across the pins that outlive it.
    final entries = <({VisibleNode row, bool visible})>[
      for (final entry in widget.pinned) (row: entry, visible: true),
      for (final entry in _departing) (row: entry, visible: false),
    ]..sort((a, b) => a.row.depth.compareTo(b.row.depth));

    final rows = <Widget>[
      for (final (:row, :visible) in entries)
        if (sequence.nodes[row.id] case final node?)
          _PinTransition(
            key: ValueKey<String>(row.id),
            visible: visible,
            onExited: () => _dropDeparted(row.id),
            child: GestureDetector(
              // Translucent, not opaque: the stack floats over the scroll
              // view, and an opaque hit box would kill the wheel and the drag
              // scroll of a pointer that happens to be in the top 84 px.
              behavior: HitTestBehavior.translucent,
              // The pin is a shortcut to a row that is already in the
              // traversal order, and its own contents are excluded from
              // semantics. Left to announce itself the detector would add an
              // anonymous tappable node per pin — three unlabelled "buttons"
              // ahead of the whole tree.
              excludeFromSemantics: true,
              onTap: () => onTap(row.id),
              // The row itself takes no pointer: the chevron, the kebab and
              // the drag handle belong to the real row, and a drag started
              // here must reach the scroll view under it.
              child: IgnorePointer(
                child: density == SequencerDensity.ledger
                    ? _LedgerRow(
                        colors: colors,
                        sequence: sequence,
                        node: node,
                        depth: row.depth,
                        isSelected: false,
                        isContainer: isSequenceContainer(node),
                        isCollapsed: false,
                        nodeStatus: progress.nodeStatuses[node.id],
                        progressPercent: progress.nodeProgressPercent[node.id],
                        pinned: true,
                      )
                    : _PinnedCompactRow(
                        colors: colors,
                        node: node,
                        depth: row.depth,
                      ),
              ),
            ),
          ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(
          left: widget.padding.left, right: widget.padding.right),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          border: Border(
            bottom: BorderSide(
              color: colors.border,
              width: _stickyStackBorderWidth,
            ),
          ),
          // The design system casts a shadow on exactly two things, and both
          // are surfaces genuinely floating above the page. The pinned stack
          // is the third: without the lift it reads as a row that refuses to
          // scroll.
          boxShadow: SkotiqDecorations.popover(colors).boxShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }
}

/// A pinned row's arrival and departure (spec §9).
///
/// Arriving, it slides down [_pinSlideDistance] and fades in over
/// [SkotiqTokens.durationQuick]; leaving, it fades and collapses out over
/// the shorter [SkotiqTokens.durationFast] — an exit that dawdles is an
/// exit the operator has to wait for, and this one happens on every upward
/// scroll. The HEIGHT is part of the exit so the stack shrinks with the
/// viewport inset that is opening back up underneath it, instead of hanging
/// over the first row of the tree while it fades.
///
/// [onExited] tells the stack the row has finished leaving and can be dropped.
class _PinTransition extends StatefulWidget {
  final bool visible;
  final VoidCallback onExited;
  final Widget child;

  const _PinTransition({
    super.key,
    required this.visible,
    required this.onExited,
    required this.child,
  });

  @override
  State<_PinTransition> createState() => _PinTransitionState();
}

class _PinTransitionState extends State<_PinTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _controller.addStatusListener(_onStatusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The entrance starts HERE and not in `initState`, because its duration
    // depends on `MediaQuery.disableAnimations` and an inherited widget cannot
    // be read before `initState` returns. A pin always arrives by animating
    // in: it is mounted the moment it pins.
    if (_entered) return;
    _entered = true;
    _syncDuration(entering: true);
    _controller.forward();
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.visible) {
      widget.onExited();
    }
  }

  void _syncDuration({required bool entering}) {
    _controller.duration = animationDuration(
      context,
      entering ? SkotiqTokens.durationQuick : SkotiqTokens.durationFast,
    );
  }

  @override
  void didUpdateWidget(_PinTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    _syncDuration(entering: widget.visible);
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncDuration(entering: widget.visible);
    return SizeTransition(
      sizeFactor: _controller,
      alignment: Alignment.topCenter,
      // An aligned child is laid out loose; without this a pinned row would
      // shrink-wrap to its own content instead of spanning the stack the way
      // the column's `stretch` hands it, and stop lining up with the row it
      // stands for.
      child: SizedBox(
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _controller,
          child: widget.child,
          builder: (context, child) {
            final t = SkotiqTokens.curveStandard.transform(_controller.value);
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, -_pinSlideDistance * (1 - t)),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The pinned form of a Compact row.
///
/// Compact keeps today's cards, which are far too tall to stack three deep
/// over the viewport, so a pinned ancestor there is a single line: the same
/// height, glyph and name treatment a ledger row gives it, minus the readout
/// columns Compact does not draw anywhere.
class _PinnedCompactRow extends StatelessWidget {
  final SkotiqColors colors;
  final SequenceNode node;
  final int depth;

  const _PinnedCompactRow({
    required this.colors,
    required this.node,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    final node = this.node;
    // A target card titles itself with its target, not with the node's own
    // name; the pin must name the row it stands for.
    final label = node is TargetHeaderNode ? node.displayName : node.name;
    return ExcludeSemantics(
      child: SizedBox(
        height: _ledgerRowHeight,
        child: Row(
          children: [
            SizedBox(width: (depth - 1) * _ledgerGuideWidth),
            Icon(
              sequenceNodeIcon(node.iconName),
              size: _ledgerIconSize,
              color: nodeCategoryTint(node.category, colors),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                label,
                style: SkotiqTypography.bodySm.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
                softWrap: false,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
