part of '../sequence_tree.dart';

/// Inline badge that marks a node as a parallel safety watchdog.
///
/// Trigger-category nodes (currently [MeridianFlipNode], and any future
/// trigger node) do not execute in list order — they run in parallel and
/// fire when their condition is met (e.g. crossing the meridian) regardless
/// of where they sit in the sequence. The badge makes that non-obvious
/// behavior legible right in the tree so an operator reviewing a sequence
/// doesn't assume the flip "runs at this position".
/// Room the badge needs to draw its word: the chip's own padding, the glyph,
/// the gap and the `overline` measure of "Watchdog". Below it the badge keeps
/// the glyph and drops the word — the tooltip carries the meaning either way,
/// and a trigger row on a 500 px canvas (the ledger's column floor, where the
/// name has ~63 px left) overflowed by the width of the label.
const double _watchdogLabelMinWidth = 84.0;

class _WatchdogBadge extends StatelessWidget {
  final SkotiqColors colors;

  const _WatchdogBadge({required this.colors});

  @override
  Widget build(BuildContext context) {
    return SkotiqTooltip(
      message:
          'Runs in parallel as a safety watchdog — fires on meridian-crossing '
          'regardless of its position in the list',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showLabel = constraints.maxWidth >= _watchdogLabelMinWidth;
          return Container(
            padding: SkotiqTokens.paddingXs,
            decoration: SkotiqDecorations.statusChip(
              colors.warning,
              borderRadius: SkotiqTokens.borderRadiusSm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.shieldAlert,
                  size: SkotiqTokens.iconXs,
                  color: colors.warning,
                ),
                if (showLabel) ...[
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  Flexible(
                    child: Text(
                      'Watchdog',
                      style: SkotiqTypography.overline
                          .copyWith(color: colors.warning),
                      softWrap: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SpinningIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _SpinningIcon({
    required this.icon,
    required this.color,
    this.size = 16,
  });

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Started by the OnScreenAnimationGate in build(), not here: a repeat that
    // outlives visibility schedules a frame on every vsync and stops the whole
    // app from idling.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OnScreenAnimationGate(
      controller: _controller,
      repeating: true,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.rotate(
            angle: _controller.value * 2 * 3.14159,
            child: Icon(
              widget.icon,
              size: widget.size,
              color: widget.color,
            ),
          );
        },
      ),
    );
  }
}

class _NodeActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final SkotiqColors colors;
  final Color? color;
  final VoidCallback? onPressed;

  const _NodeActionButton({
    required this.icon,
    required this.tooltip,
    required this.colors,
    this.color,
    this.onPressed,
  });

  @override
  State<_NodeActionButton> createState() => _NodeActionButtonState();
}

class _NodeActionButtonState extends State<_NodeActionButton> {
  /// Edge of the visible chip. Three of these sit in every tree row, so it
  /// stays dense on desktop and is padded up to the touch minimum on a phone.
  static const double _chipExtent = 24.0;

  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? widget.colors.textSecondary;
    final disabled = widget.onPressed == null;
    final iconColor = disabled
        ? widget.colors.textMuted.withValues(alpha: 0.4)
        : (_isHovered ? color : widget.colors.textMuted);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: disabled ? null : (_) => setState(() => _isHovered = true),
        onExit: disabled ? null : (_) => setState(() => _isHovered = false),
        cursor:
            disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          // The 24x24 chip is right for a dense desktop tree row, but it is
          // also the whole hit area: a bare GestureDetector hit-tests its
          // child's box, so on a phone these measured 28x24 against Android's
          // 48. Padding the child (rather than wrapping the detector) grows the
          // real hit box, not just the semantics rect — and only on touch
          // platforms, so desktop density is untouched.
          child: Padding(
            padding: EdgeInsets.all(
              SkotiqTouchTarget.paddingToReach(context, _chipExtent),
            ),
            child: AnimatedContainer(
              duration: animationDuration(context, SkotiqTokens.durationFast),
              curve: SkotiqTokens.curveStandard,
              width: _chipExtent,
              height: _chipExtent,
              margin: const EdgeInsets.only(left: 4),
              decoration: BoxDecoration(
                color: !disabled && _isHovered
                    ? SkotiqDecorations.tintedBadge(
                        color,
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusInline4,
                        ),
                      ).color
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
              child: Icon(
                widget.icon,
                size: 12,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The eye / duplicate / delete chip trio, shared by the comfortable card row
/// (hover) and the ledger row's hover-revealed actions block.
///
/// Extracted for the same reason as [_NodeOverflowMenu]: two row densities
/// offering the same three mutations must not keep two hand-maintained copies
/// in step. Callers gate placement — the comfortable row hides the trio on
/// touch (the kebab carries the entries there), and the ledger row reserves
/// the block's width so the chips cannot shift the columns.
class _NodeActionChips extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceNode node;
  final VoidCallback? onToggleEnabled;
  final VoidCallback? onDuplicate;
  final VoidCallback? onDelete;

  const _NodeActionChips({
    required this.colors,
    required this.node,
    required this.onToggleEnabled,
    required this.onDuplicate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Per-row action icons mutate the tree (toggle enabled, duplicate, delete)
    // and must be disabled when a sequence is running. The kebab gates
    // move_up/move_down; this is the matching gate for the inline chips.
    final canEdit = ref.watch(canEditSequenceProvider);
    const lockedSuffix = ' (locked while sequence is running)';
    final lockedTail = canEdit ? '' : lockedSuffix;
    final toggleLabel = node.isEnabled ? 'Disable' : 'Enable';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NodeActionButton(
          icon: node.isEnabled ? LucideIcons.eye : LucideIcons.eyeOff,
          tooltip: '$toggleLabel$lockedTail',
          colors: colors,
          onPressed: canEdit ? onToggleEnabled : null,
        ),
        _NodeActionButton(
          icon: LucideIcons.copy,
          tooltip: 'Duplicate$lockedTail',
          colors: colors,
          onPressed: canEdit ? onDuplicate : null,
        ),
        _NodeActionButton(
          icon: LucideIcons.trash2,
          tooltip: 'Delete$lockedTail',
          colors: colors,
          color: colors.error,
          onPressed: canEdit ? onDelete : null,
        ),
      ],
    );
  }
}

/// The row's inline "more actions" kebab, shared by every density.
///
/// Reconciliation with the other action surfaces: the right-click /
/// long-press context menu ([SequenceTreeContextMenu]) is the comprehensive
/// tree-mutation surface (Insert, Move Up/Down, Duplicate, Group,
/// Enable/Disable, Delete). This kebab repeats:
///   * Move Up / Move Down — a visible, tappable re-order handle. Touch has no
///     right-click and drag-reordering a row inside a scrolling tree is
///     fiddly, so the affordance stays on-screen.
///     (`sequence_tree_shortcuts.dart` binds Shift+Up/Down to EXTEND the
///     selection, not to move a node — there is no keyboard reorder.)
///   * Save as Template — a "promote-this-subtree-to-the-library" action that
///     is not part of the per-node edit vocabulary the context menu covers.
///
/// Items respect [canEditSequenceProvider]: while a sequence is Running /
/// Paused / Stopping the kebab still opens but mutating entries are disabled
/// (Save as Template is read-only, so it stays enabled).
class _NodeOverflowMenu extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceNode node;
  final VoidCallback? onToggleEnabled;
  final VoidCallback? onDuplicate;
  final VoidCallback? onDelete;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  const _NodeOverflowMenu({
    required this.colors,
    required this.node,
    this.onToggleEnabled,
    this.onDuplicate,
    this.onDelete,
    this.onMoveUp,
    this.onMoveDown,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(canEditSequenceProvider);
    return _treeMenuSurface(
      context,
      colors,
      child: PopupMenuButton<String>(
        icon: Icon(LucideIcons.moreVertical, size: 14, color: colors.textMuted),
        tooltip: 'More Actions',
        padding: EdgeInsets.zero,
        itemBuilder: (context) => [
          // The inline eye / duplicate / delete chips are not rendered on
          // touch (three 24dp chips are not legal Android tap targets) — they
          // live here so the actions stay reachable through one compliant
          // target instead of three illegal ones.
          if (SkotiqTouchTarget.isTouch(context)) ...[
            PopupMenuItem<String>(
              value: 'toggle_enabled',
              height: 40,
              enabled: canEdit,
              child: Text(
                node.isEnabled ? 'Disable' : 'Enable',
                style: SkotiqTypography.bodySm.copyWith(
                  color: canEdit ? colors.textPrimary : colors.textMuted,
                ),
              ),
            ),
            PopupMenuItem<String>(
              value: 'duplicate',
              height: 40,
              enabled: canEdit,
              child: Text(
                'Duplicate',
                style: SkotiqTypography.bodySm.copyWith(
                  color: canEdit ? colors.textPrimary : colors.textMuted,
                ),
              ),
            ),
            PopupMenuItem<String>(
              value: 'delete',
              height: 40,
              enabled: canEdit,
              child: Text(
                'Delete',
                style: SkotiqTypography.bodySm.copyWith(
                  color: canEdit ? colors.error : colors.textMuted,
                ),
              ),
            ),
            const PopupMenuDivider(height: 8),
          ],
          if (onMoveUp != null)
            PopupMenuItem<String>(
              value: 'move_up',
              height: 32,
              enabled: canEdit,
              child: Text('Move Up',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: canEdit ? colors.textPrimary : colors.textMuted,
                  )),
            ),
          if (onMoveDown != null)
            PopupMenuItem<String>(
              value: 'move_down',
              height: 32,
              enabled: canEdit,
              child: Text('Move Down',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: canEdit ? colors.textPrimary : colors.textMuted,
                  )),
            ),
          if (onMoveUp != null || onMoveDown != null)
            const PopupMenuDivider(height: 8),
          // Save as Template is read-only (it copies the subtree to the
          // snippet library; it does not mutate the current sequence), so it
          // stays enabled even while the sequence is running.
          PopupMenuItem<String>(
            value: 'save_snippet',
            height: 32,
            child: Text('Save as Template',
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textPrimary)),
          ),
        ],
        onSelected: (value) {
          switch (value) {
            case 'toggle_enabled':
              onToggleEnabled?.call();
              break;
            case 'duplicate':
              onDuplicate?.call();
              break;
            case 'delete':
              onDelete?.call();
              break;
            case 'move_up':
              onMoveUp?.call();
              break;
            case 'move_down':
              onMoveDown?.call();
              break;
            case 'save_snippet':
              showSaveAsSnippetDialog(context, ref, node, colors);
              break;
          }
        },
      ),
    );
  }
}

/// The popup-menu surface every tree kebab opens on.
///
/// One helper rather than a copy per menu: the node row's kebab and the folded
/// row's sit a few pixels apart on the same line, so a menu that differed in
/// fill or border would read as two different controls.
Widget _treeMenuSurface(
  BuildContext context,
  SkotiqColors colors, {
  required Widget child,
}) {
  return Theme(
    data: Theme.of(context).copyWith(
      popupMenuTheme: PopupMenuThemeData(
        // ignore: deprecated_member_use
        color: colors.surfaceAlt,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          side: BorderSide(color: colors.border),
        ),
      ),
    ),
    child: child,
  );
}

/// Cross-fade between what one density draws and what the next one draws
/// (spec §9).
///
/// Keyed on the density, and applied per element rather than once around the
/// whole tree: the outgoing tree would stay mounted for the length of the fade
/// holding every scroll-key and tutorial `GlobalKey` the incoming tree also
/// wants, which is a hard framework error. Inside one element the outgoing
/// widget holds no key the incoming one needs.
///
/// Every piece of the canvas that belongs to one density goes through this —
/// the rows, the ledger's column header and the gutter map — so the switch is
/// ONE fade rather than a fade with two things blinking in the middle of it.
///
/// [animate] is false while the canvas is CLAMPING the density rather than
/// following the preference (a canvas too narrow for the ledger's columns
/// falls back to compact rows). A clamp is the canvas being resized, and the
/// outgoing density is laid out at the INCOMING width for the length of the
/// fade — ledger rows, whose columns are fixed-width, then overflow a canvas
/// that by definition no longer fits them. A resize is not a mode switch and
/// should not read as one: the rows the canvas can host appear at once.
Widget densityCrossfade({
  required BuildContext context,
  required SequencerDensity density,
  required Widget child,
  bool animate = true,
}) {
  // No switcher at all, rather than a zero-length one: an `AnimatedSwitcher`
  // that is already retiring a child keeps running THAT child's controller at
  // the duration it was created with, so shortening the duration mid-switch
  // leaves the outgoing rows on screen exactly as long as before.
  if (!animate) return child;
  return AnimatedSwitcher(
    duration: animationDuration(context, SkotiqTokens.durationSmooth),
    switchInCurve: SkotiqTokens.curveStandard,
    switchOutCurve: SkotiqTokens.curveStandard,
    child: KeyedSubtree(
      key: ValueKey<SequencerDensity>(density),
      child: child,
    ),
  );
}

/// How far above its resting place a container's children start as they fade
/// in (spec §9).
const double _childrenSlideDistance = 6.0;

/// Where the children's fade-and-slide finishes inside the block's own height
/// animation.
///
/// Derived from the tokens, not chosen: the rows travel on
/// [SkotiqTokens.durationQuick] and the space they occupy opens on
/// [SkotiqTokens.durationSmooth], so the rows have arrived by the time the
/// block stops growing. Reversed, the rows leave before the gap closes, which
/// is what stops a collapse reading as a row being crushed.
final double _childrenFadeFraction = SkotiqTokens.durationQuick.inMilliseconds /
    SkotiqTokens.durationSmooth.inMilliseconds;

/// The expand / collapse motion of a container's children block (spec §9).
///
/// [builder] is called only while the block is on screen (or on its way off),
/// so a collapsed container costs what it has always cost: nothing. That is
/// also why this is not an `AnimatedSize` around a conditional child —
/// `AnimatedSize` can only animate the gap AFTER its child has already
/// vanished, so a collapse read as the rows blinking out and an empty space
/// then closing. [SizeTransition] keeps the departing rows mounted and clips
/// them away instead, which is the motion the spec describes and the one
/// `ExpansionTile` uses. It also cannot flash an overflow: the child is always
/// laid out at its full height and clipped, never asked to lay out at an
/// intermediate one.
///
/// A top-centre `alignment` keeps the block pinned to its top edge, so
/// everything ABOVE a collapsing container stays exactly where it is and the
/// scroll position does not jump.
class _ChildrenReveal extends StatefulWidget {
  final bool isCollapsed;
  final WidgetBuilder builder;

  const _ChildrenReveal({required this.isCollapsed, required this.builder});

  @override
  State<_ChildrenReveal> createState() => _ChildrenRevealState();
}

class _ChildrenRevealState extends State<_ChildrenReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _size;
  late final Animation<double> _content;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationSmooth,
      value: widget.isCollapsed ? 0.0 : 1.0,
    );
    _size = CurvedAnimation(
      parent: _controller,
      curve: SkotiqTokens.curveStandard,
    );
    _content = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        0.0,
        _childrenFadeFraction,
        curve: SkotiqTokens.curveStandard,
      ),
    );
    // The block is only unmounted once it has finished leaving; nothing else
    // rebuilds this widget at that moment.
    _controller.addStatusListener(_onStatusChanged);
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(_ChildrenReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCollapsed == widget.isCollapsed) return;
    if (widget.isCollapsed) {
      _controller.reverse();
    } else {
      _controller.forward();
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
    _controller.duration =
        animationDuration(context, SkotiqTokens.durationSmooth);
    // Collapsed and settled: nothing to draw and, more to the point, nothing
    // to BUILD. A collapsed container's subtree is the cost collapsing exists
    // to avoid.
    if (widget.isCollapsed && _controller.value == 0) {
      return const SizedBox.shrink();
    }
    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      // `SizeTransition` aligns its child, and an aligned child is laid out
      // LOOSE. Without this the children column would shrink-wrap to its
      // widest row instead of filling the canvas the way the tree's
      // `crossAxisAlignment: stretch` hands it, and every row would size to
      // its own content and overflow a narrow canvas.
      child: SizedBox(
        width: double.infinity,
        child: FadeTransition(
          opacity: _content,
          child: AnimatedBuilder(
            animation: _content,
            child: widget.builder(context),
            builder: (context, child) => Transform.translate(
              offset: Offset(0, -_childrenSlideDistance * (1 - _content.value)),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// How far the running marker's breath dims between beats (spec §9).
const double _runningBreathLowOpacity = 0.55;

/// The slow breath the running row's left marker takes (spec §9).
///
/// It is the ONE looping animation in the tree, and it earns the loop by being
/// the only thing on screen that says "this is happening right now" in a
/// density that has no spinner: Ledger and Compact rows mark the running step
/// with a 2 px bar, and a still bar is indistinguishable from a decoration.
/// The cadence is [SkotiqTokens.durationPulse] with `reverse`, which is
/// exactly what `StatusDot`'s urgent pulse breathes at — one app, one heartbeat.
///
/// Two structural rules, both load-bearing:
///
///  * The loop runs inside an [OnScreenAnimationGate]. A repeating controller
///    schedules a frame on every vsync for as long as it runs, whether or not
///    anything is drawn for it; forty rows of un-gated breath would stop the
///    application idling for the length of a night.
///  * The [RepaintBoundary] is OUTSIDE the gate. The gate decides whether to
///    keep running by observing whether its child actually PAINTS. A boundary
///    placed inside the gate makes the marker its own compositing layer, so a
///    repaint of the marker never reaches the gate's observer — the gate then
///    concludes it is invisible and stops the animation two ticks in, silently.
///    Outside, the boundary keeps the repaints local AND lets the observer see
///    every one of them.
class _RunningMarkerBreath extends StatefulWidget {
  final Widget child;

  const _RunningMarkerBreath({required this.child});

  @override
  State<_RunningMarkerBreath> createState() => _RunningMarkerBreathState();
}

class _RunningMarkerBreathState extends State<_RunningMarkerBreath>
    with SingleTickerProviderStateMixin {
  // Eagerly, not `late`: with animations disabled the build below never
  // touches the controller, and a lazy field would then be CONSTRUCTED by
  // `dispose` — which reads `TickerMode` off an element that is already
  // deactivated, and throws.
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationPulse,
    );
    // `Curves.easeInOut` rather than the design system's one curve: a breath
    // reverses, and `curveStandard` decelerates into its end only, so a
    // reversing loop on it would snap at one extreme and drift at the other.
    // The one-curve rule governs state transitions, which this is not.
    _opacity = Tween<double>(
      begin: _runningBreathLowOpacity,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A repeat cannot be shortened to zero — a zero-length loop is an
    // infinitely fast one — so with animations disabled the marker simply
    // holds at full strength. The row still says it is running; it says it in
    // a still image.
    if (animationsDisabled(context)) return widget.child;
    return RepaintBoundary(
      child: OnScreenAnimationGate(
        controller: _controller,
        repeating: true,
        reverse: true,
        child: AnimatedBuilder(
          animation: _opacity,
          child: widget.child,
          builder: (context, child) => Opacity(
            opacity: _opacity.value,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The height an inter-row drop zone takes while a drag is in flight, and the
/// larger height of the one the payload is actually over.
///
/// At rest a zone has no height at all: forty of them at four pixels each put
/// 160 px of dead space into a tree whose whole point is that a night fits on
/// one screen. The gap between rows is [_dropZoneGap] either side, which is
/// spacing the rows want regardless of whether anything is being dragged.
const double _dropZoneActiveHeight = 28.0;
const double _dropZoneHoverHeight = 48.0;
const double _dropZoneGap = 2.0;

class _DropZone extends ConsumerWidget {
  final SkotiqColors colors;
  final String parentId;
  final int index;

  /// Whether the *enclosing* container's DragTarget currently has a candidate
  /// hovering (plumbed down from `_NodeTreeView`). Drives the dashed-zone
  /// reveal per-container rather than off the global drag provider, so a drag
  /// over one container doesn't repaint every sibling subtree.
  final bool isActive;

  const _DropZone({
    required this.colors,
    required this.parentId,
    required this.index,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<Object>(
      onWillAcceptWithDetails: (data) =>
          data.data is String ||
          data.data is FoldDragPayload ||
          data.data is NodePaletteItem ||
          data.data is TemplateSnippet ||
          data.data is TargetQueueDragPayload,
      onAcceptWithDetails: (details) {
        final data = details.data;
        if (data is String) {
          ref.read(currentSequenceProvider.notifier).moveNode(
                data,
                parentId,
                index,
              );
        } else if (data is FoldDragPayload) {
          // A folded run lands here as one contiguous block, in one undo step
          // — see [moveFoldGroup] for why the members chase each other rather
          // than take index + k.
          moveFoldGroup(
            context,
            ref,
            memberIds: data.memberIds,
            parentId: parentId,
            index: index,
          );
        } else if (data is NodePaletteItem) {
          final node = data.createNode();
          final notifier = ref.read(currentSequenceProvider.notifier);
          notifier.addNode(
            node,
            parentId: parentId,
            index: index,
          );
          final children = data.createChildren?.call();
          if (children != null) {
            for (final child in children) {
              notifier.addNode(child, parentId: node.id);
            }
          }
          ref.read(selectedNodeIdProvider.notifier).state = node.id;
        } else if (data is TemplateSnippet) {
          // Route through the guarded helper so a locked-state /
          // unknown-node-type insert surfaces a snackbar, matching the
          // tap path.
          insertSnippetGuarded(context, ref, data,
              parentId: parentId, index: index);
        } else if (data is TargetQueueDragPayload) {
          // Precise-position drop: insert the prebuilt
          // TargetHeaderNode at the exact index where the dashed
          // drop-zone lives. Mirrors the NodePaletteItem branch above
          // so the queue payload feels like any other dragged
          // toolbox item.
          final notifier = ref.read(currentSequenceProvider.notifier);
          notifier.addNode(data.node, parentId: parentId, index: index);
          ref.read(selectedNodeIdProvider.notifier).state = data.node.id;
        }
        // Reset drag state after drop
        ref.read(isDraggingNodeProvider.notifier).state = false;
      },
      builder: (context, candidateData, rejectedData) {
        final isOver = candidateData.isNotEmpty;
        // RepaintBoundary isolates this zone's animation so the global
        // drag-state rebuild (read inside the Consumer below) doesn't
        // repaint sibling subtrees.
        return RepaintBoundary(
          child: Consumer(
            builder: (context, ref, _) {
              // Watch global drag state ONLY here so the rest of the row
              // doesn't rebuild when a drag starts elsewhere.
              final isDragging = ref.watch(isDraggingNodeProvider);
              final showDropZone = isDragging || isActive || isOver;
              return _buildZone(
                context,
                isOver: isOver,
                showDropZone: showDropZone,
              );
            },
          ),
        );
      },
    );
  }

  /// The zone's three sizes, and the motion between them (spec §9).
  ///
  /// At rest a zone is nothing at all: it grows to [_dropZoneActiveHeight] and
  /// fades its dashed line in when a drag starts, and to
  /// [_dropZoneHoverHeight] when the payload is over this particular zone.
  /// Entering the hovered state is the faster of the two — it answers a
  /// pointer, where the reveal answers the drag as a whole.
  Widget _buildZone(
    BuildContext context, {
    required bool isOver,
    required bool showDropZone,
  }) {
    return AnimatedContainer(
      duration: animationDuration(
        context,
        isOver ? SkotiqTokens.durationFast : SkotiqTokens.durationQuick,
      ),
      curve: SkotiqTokens.curveStandard,
      height: isOver
          ? _dropZoneHoverHeight
          : (showDropZone ? _dropZoneActiveHeight : 0.0),
      margin: const EdgeInsets.symmetric(vertical: _dropZoneGap),
      decoration: isOver
          ? SkotiqDecorations.selectedSurface(
              colors.primary,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              fillAlpha: 0.2,
            ).copyWith(
              border: Border.all(color: colors.primary, width: 2),
            )
          : showDropZone
              ? _dashedDropDecoration(colors)
              : const BoxDecoration(),
      // The dashed line and the "Insert here" label cross-fade rather than
      // swap: a line that pops in at full strength reads as a click, and the
      // zone it belongs to is still growing underneath it.
      child: AnimatedSwitcher(
        duration: animationDuration(context, SkotiqTokens.durationQuick),
        switchInCurve: SkotiqTokens.curveStandard,
        switchOutCurve: SkotiqTokens.curveStandard,
        child: isOver
            ? Center(
                key: const ValueKey<String>('drop-zone-insert'),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.arrowDown,
                      size: 12,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Insert here',
                      style: SkotiqTypography.labelStrongSm
                          .copyWith(color: colors.primary),
                    ),
                  ],
                ),
              )
            : showDropZone
                ? CustomPaint(
                    key: const ValueKey<String>('drop-zone-dashes'),
                    painter: _DashedLinePainter(
                        color: colors.primary.withValues(alpha: 0.5)),
                    child: Center(
                      child: Icon(
                        LucideIcons.plusCircle,
                        size: 12,
                        color: colors.primary.withValues(alpha: 0.5),
                      ),
                    ),
                  )
                : const SizedBox.shrink(
                    key: ValueKey<String>('drop-zone-idle'),
                  ),
      ),
    );
  }
}

/// Creates a dashed-border-style decoration for drop zone indicators.
BoxDecoration _dashedDropDecoration(SkotiqColors colors) {
  return SkotiqDecorations.tintedBadge(
    colors.primary,
    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
  );
}

/// Paints a horizontal dashed line across the center of the widget,
/// acting as an insertion point indicator during drag operations.
class _DashedLinePainter extends CustomPainter {
  final Color color;
  _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    const dashWidth = 6.0;
    const dashSpace = 4.0;
    final y = size.height / 2;

    // Draw left dashes (up to center minus icon space)
    final leftEnd = size.width / 2 - 12;
    var x = 4.0;
    while (x < leftEnd) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + dashWidth).clamp(0, leftEnd), y),
        paint,
      );
      x += dashWidth + dashSpace;
    }

    // Draw right dashes (from center plus icon space)
    final rightStart = size.width / 2 + 12;
    x = rightStart;
    while (x < size.width - 4) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + dashWidth).clamp(0, size.width - 4), y),
        paint,
      );
      x += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
