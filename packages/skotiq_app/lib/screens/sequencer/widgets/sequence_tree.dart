import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/sequence_mutator_helper.dart';
import '../../../widgets/tutorial_keys/sequencer_keys.dart';
import '../../accessible_dropdown.dart';
import '../ledger_seconds.dart';
import '../sequence_fold_model.dart';
import '../sequence_fold_state.dart';
import 'delete_node_confirmation.dart';
import 'exposure_node_thumbnail_strip.dart';
import 'node_duration_chip.dart';
import 'node_progress_panels.dart';
import 'node_summary.dart';
import 'node_summary_line.dart';
import 'sequence_minimap.dart';
import 'sequence_overview_prefs.dart';
import 'sequence_tree/fold_group_actions.dart';
import 'sequence_tree/ledger_columns.dart';
import 'sequence_tree/rollup_summary.dart';
import 'sequence_tree_context_menu.dart';
import 'sequence_tree_shortcuts.dart';
import 'sequencer_density.dart';
import 'target_coordinates.dart';
import 'target_header_card.dart';
import 'target_queue_panel.dart';
import 'visual_timeline.dart';

part 'sequence_tree/auto_collapse.dart';
part 'sequence_tree/gutter_map.dart';
part 'sequence_tree/sticky_ancestors.dart';
part 'sequence_tree/node_tree_view.dart';
part 'sequence_tree/node_item.dart';
part 'sequence_tree/ledger_row.dart';
part 'sequence_tree/ledger_fold_row.dart';
part 'sequence_tree/support_widgets.dart';
part 'sequence_tree/tree_controls.dart';
part 'sequence_tree/node_item_helpers.dart';

/// Live handle to the tree's GlobalKey registry (node id -> row key).
///
/// [SequenceTree] publishes its registry here so sibling widgets (notably
/// [SequenceMinimap]) can route "navigate to node" through the SAME
/// [revealSequenceRow] path the auto-follow uses, instead of
/// guessing a scroll offset. Null until the tree mounts. Not autoDispose:
/// the minimap may rebuild independently and must keep resolving keys.
final treeNodeKeyRegistryProvider =
    StateProvider<Map<String, GlobalKey>?>((ref) => null);

/// Scroll the TREE — and only the tree — so the row at [rowContext] lands
/// [alignment] of the way down its viewport.
///
/// Every "jump to this node" in the builder goes through here: the run's
/// auto-follow, the pinned-ancestor tap, the map/gutter jump, Find a step, and
/// the Targets panel's "In this sequence" rows. One helper because they are one
/// movement, and because the alternative is one bug repeated five times.
///
/// That bug was `Scrollable.ensureVisible`, which does not scroll *a*
/// scrollable — it walks EVERY ancestor `Scrollable` and scrolls each one so
/// the target is visible in it. The builder sits inside the sequencer screen's
/// `TabBarView` pager, so revealing a row also asked the pager to centre it:
/// the whole screen lurched sideways toward the next (lazily empty) page and
/// the page physics sprang it back. During a run the auto-follow fires on every
/// step, so the screen bounced at every node change.
///
/// Resolving the row's own [ScrollPosition] and calling
/// [ScrollPosition.ensureVisible] on it moves the tree and nothing else.
/// `Scrollable.maybeOf` finds the nearest enclosing scrollable, which for a row
/// key is always the tree's own viewport.
void revealSequenceRow(
  BuildContext rowContext, {
  required double alignment,
  required Duration duration,
}) {
  final position = Scrollable.maybeOf(rowContext)?.position;
  final target = rowContext.findRenderObject();
  if (position == null || target == null || !target.attached) return;
  position.ensureVisible(
    target,
    alignment: alignment,
    duration: animationDuration(rowContext, duration),
    // One curve for all five callers: the map's jump and the run's own scroll
    // are the same movement started by different hands (spec §9), and a jump
    // that eased differently would read as a different kind of navigation.
    curve: SkotiqTokens.curveStandard,
  );
}

/// Provider to track when a node is being dragged globally
/// This allows all drop zones to become visible when any drag starts
// autoDispose: drag state is transient UI — every drag begins from `false`
// and is reset by the matching onDragEnd/Cancel. Disposing on screen
// teardown ensures a stale `true` from an interrupted drag cannot leak
// into the next sequencer session.
final isDraggingNodeProvider = StateProvider.autoDispose<bool>((ref) => false);

/// Tree search query — filters the in-tree "jump to node" results popover in
/// the sequence header. autoDispose so it resets between sequencer visits.
final treeSearchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

/// Provider for "follow execution" toggle — auto-scrolls tree to current node
// autoDispose: tab/screen-scoped toggle; default (on) is the right initial
// state on each visit to the sequencer.
final followExecutionProvider = StateProvider.autoDispose<bool>((ref) => true);

// Note: confirm-then-delete now lives in `delete_node_confirmation.dart`
// as `confirmAndDeleteSequenceNode`. The tree's inline trash buttons and
// the TargetHeaderCard delete button below route through that helper so
// every user-initiated delete surface shares one policy.

/// Insert a dragged [snippet] into the tree through [withSequenceMutation]
/// so a locked-state or unknown-node-type failure surfaces a snackbar/dialog
/// instead of an uncaught throw. Shared by every drag-drop TemplateSnippet
/// branch (root target, per-container target, inter-row drop zone) so the
/// drop path matches the tap path's error handling.
void insertSnippetGuarded(
  BuildContext context,
  WidgetRef ref,
  TemplateSnippet snippet, {
  String? parentId,
  int? index,
}) {
  final profile = ref.read(activeEquipmentProfileProvider);
  withSequenceMutation(
    context,
    ref,
    operationName: 'insert template',
    action: () async {
      ref.read(currentSequenceProvider.notifier).insertSnippet(
            snippet,
            parentId: parentId,
            index: index,
            profileFilterNames: profile?.filterNames,
          );
    },
  );
}

/// Handle node selection with modifier key support for multi-select.
/// Ctrl+Click: toggle individual node in multi-selection.
/// Shift+Click: range-select siblings between anchor and clicked node.
/// Plain click: single-select (clears multi-selection).
void _handleNodeSelect(WidgetRef ref, String nodeId) {
  final isCtrlPressed = HardwareKeyboard.instance.logicalKeysPressed.any(
      (key) =>
          key == LogicalKeyboardKey.controlLeft ||
          key == LogicalKeyboardKey.controlRight ||
          key == LogicalKeyboardKey.metaLeft ||
          key == LogicalKeyboardKey.metaRight);

  final isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed.any(
      (key) =>
          key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight);

  if (isCtrlPressed) {
    // Ctrl+Click: toggle in multi-select.
    //
    // The FIRST Ctrl+click also folds the existing primary selection into the
    // set. A tree row paints as selected when it is either the primary
    // selection or in the multi-select set (node_tree_view.dart:133
    // `isSelected || isMultiSelected`), so without this the user saw three
    // identically-outlined rows while the batch bar said "2 selected" and
    // every batch operation — including Delete — silently skipped the row
    // they clicked first.
    final multi = ref.read(multiSelectedNodeIdsProvider.notifier);
    final primaryId = ref.read(selectedNodeIdProvider);
    if (ref.read(multiSelectedNodeIdsProvider).isEmpty &&
        primaryId != null &&
        primaryId != nodeId) {
      multi.toggle(primaryId);
    }
    multi.toggle(nodeId);
  } else if (isShiftPressed) {
    // Shift+Click: range select
    ref.read(multiSelectedNodeIdsProvider.notifier).rangeSelect(nodeId);
  } else {
    // Plain click: single select, clear multi-select
    ref.read(multiSelectedNodeIdsProvider.notifier).clear();
    ref.read(selectedNodeIdProvider.notifier).state = nodeId;
  }
}

class SequenceTree extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final bool isMobile;
  final void Function(String nodeId)? onNodeTap;

  const SequenceTree({
    super.key,
    required this.colors,
    this.isMobile = false,
    this.onNodeTap,
  });

  @override
  ConsumerState<SequenceTree> createState() => _SequenceTreeState();
}

class _SequenceTreeState extends ConsumerState<SequenceTree> {
  final ScrollController _scrollController = ScrollController();
  String? _lastScrolledToNodeId;
  bool _userScrolledManually = false;

  /// GlobalKey registry for auto-scroll: maps node IDs to their GlobalKeys.
  /// Scoped to this state so it is torn down with the screen: a module-level
  /// map leaks GlobalKeys across hot reload and screen transitions.
  final Map<String, GlobalKey> _nodeKeyRegistry = <String, GlobalKey>{};

  /// Marks the tree's scroll viewport so the sticky-ancestor pass can measure
  /// row boxes against its top edge.
  final GlobalKey _viewportKey =
      GlobalKey(debugLabel: 'sequence-tree-viewport');

  /// The ancestor rows currently pinned over the top of the viewport, and the
  /// depth each draws at (spec §5). Recomputed once per frame at most.
  List<VisibleNode> _pinnedAncestors = const <VisibleNode>[];
  bool _stickyPassScheduled = false;

  /// True while the stack has rows still fading out after the last of them
  /// stopped being pinned. Without it the final pin would vanish between two
  /// frames — the tree stops building the stack the moment [_pinnedAncestors]
  /// empties, and an exit needs something to run inside.
  bool _pinStackDraining = false;

  /// The density the canvas resolved on the last layout pass — the preference
  /// clamped by what the canvas can actually host. Reconciled AFTER the frame
  /// that computed it (never during build), and the one thing that says
  /// whether ancestors pin at all: Comfortable keeps its cards and pins
  /// nothing, and measuring render boxes every scroll frame for a stack that
  /// will not be drawn is pure cost.
  SequencerDensity? _canvasDensity;

  bool get _stickyEnabled =>
      _canvasDensity != null && _canvasDensity != SequencerDensity.comfortable;

  /// The visible-row order as of the last build.
  ///
  /// Watched in [build] rather than read inside the post-frame pass:
  /// `visibleNodeOrderProvider` is autoDispose, and a bare `ref.read` from a
  /// state with no subscription rebuilds and disposes the whole order on every
  /// scroll frame.
  List<VisibleNode> _visibleOrder = const <VisibleNode>[];

  /// Containers the operator opened by hand that have not run since. Nothing
  /// in here is ever folded away by [planAutoCollapse]; an entry leaves when
  /// the run reaches that container, or when the operator collapses it again.
  final Set<String> _userExpandedIds = <String>{};

  /// Expansions this widget is about to apply itself, so the diff of
  /// [collapsedNodeIdsProvider] can tell the run's own bookkeeping from the
  /// operator reaching for a chevron. Every manual path — the chevron in both
  /// row densities, the Left/Right arrows, Expand all — lands in that diff, so
  /// subtracting our own writes is the one place that covers all of them.
  final Set<String> _pendingAutoExpansions = <String>{};

  /// The sequence id we last reconciled the key registry against. Used by
  /// [didUpdateWidget] / [_pruneKeyRegistry] to detect "the user opened a
  /// different sequence" and clear the registry.
  String? _registryOwnerSequenceId;

  /// FocusNode for the tree-keyboard-shortcut wiring. Owned so the tree
  /// keeps focus across rebuilds — without this, every selection change
  /// reshuffles focus and arrow keys stop working after the first press.
  late final FocusNode _treeFocusNode;

  /// Captured during [initState] so [dispose] can clear the published
  /// registry handle without touching `ref` — Riverpod forbids `ref.read`
  /// after the widget is disposed. The provider is not autoDispose, so the
  /// notifier outlives this widget and is safe to hold.
  late final StateController<Map<String, GlobalKey>?> _registryController;

  /// Captured for the same reason as [_registryController]: the resolved
  /// density is published from a post-frame callback and cleared after this
  /// widget is gone, both of which are illegal through `ref`.
  late final StateController<SequencerDensity?> _densityController;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onManualScroll);
    _treeFocusNode = FocusNode(debugLabel: 'sequence-tree');
    _registryController = ref.read(treeNodeKeyRegistryProvider.notifier);
    _densityController = ref.read(resolvedSequencerDensityProvider.notifier);
    // Publish the registry handle so the minimap can route navigation
    // through the same ensureVisible path. Done post-frame because provider
    // writes are illegal during the initial build pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _registryController.state = _nodeKeyRegistry;
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onManualScroll);
    _scrollController.dispose();
    _treeFocusNode.dispose();
    // Clear the published handle after the current teardown pass. Riverpod
    // forbids provider writes while the widget tree is building/disposing, and
    // this mirrors the post-frame publish in initState.
    final registry = _nodeKeyRegistry;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The owning ProviderScope may be torn down before this deferred
      // callback runs (for example when the app/test root is replaced).
      // StateController throws even on a read after disposal, so gate the
      // compare-and-clear operation on the controller's lifetime.
      if (!_registryController.mounted) return;
      if (_registryController.state == registry) {
        _registryController.state = null;
      }
      // With no tree on screen there is no resolved density; the consumers
      // fall back to the stored preference rather than to this tree's last
      // width decision.
      if (_densityController.mounted) _densityController.state = null;
    });
    _nodeKeyRegistry.clear();
    super.dispose();
  }

  /// Drop stale entries from the key registry. Called from build() once the
  /// current set of node ids is known. Without this, replacing a node
  /// (e.g. via wrap/group) leaves its GlobalKey in the map forever; the
  /// next node sharing that id would steal the key and crash with a
  /// "duplicate GlobalKey in widget tree" error.
  void _pruneKeyRegistry(Sequence sequence) {
    // If the active sequence changed entirely, the registry is rebuilt
    // from scratch in the next render — no need to keep any keys.
    if (_registryOwnerSequenceId != sequence.id) {
      _nodeKeyRegistry.clear();
      _registryOwnerSequenceId = sequence.id;
      // Both expansion sets are keyed by node id, and node ids do not repeat
      // across sequences: carried into the next sequence they are dead weight
      // that can only shield a container the operator never opened (the ids
      // would have to collide) or, worse, mask a real auto-expansion.
      _clearExpansionBookkeeping();
      return;
    }
    final liveIds = sequence.nodes.keys.toSet();
    _nodeKeyRegistry.removeWhere((id, _) => !liveIds.contains(id));
  }

  void _onManualScroll() {
    // If the user scrolls manually, temporarily suppress auto-scroll
    // until the current node changes again
    if (_scrollController.position.isScrollingNotifier.value) {
      _userScrolledManually = true;
    }
    _scheduleStickyPass();
  }

  void _scrollToCurrentNode(String? currentNodeId) {
    if (currentNodeId == null) return;
    if (!ref.read(followExecutionProvider)) return;

    // Don't re-scroll to the same node unless user scrolled away
    if (currentNodeId == _lastScrolledToNodeId && !_userScrolledManually) {
      return;
    }

    final key = _nodeKeyRegistry[currentNodeId];
    if (key == null || key.currentContext == null) return;

    _userScrolledManually = false;
    _lastScrolledToNodeId = currentNodeId;

    revealSequenceRow(
      key.currentContext!,
      duration: SkotiqTokens.durationSlow,
      alignment: 0.3, // show node ~30% from the top
    );
  }

  /// Bring a pinned ancestor's REAL row back to the top of the viewport.
  ///
  /// Alignment 0, and it means something different now that the viewport is
  /// inset by the stack: position zero is the stack's bottom edge, not the
  /// canvas's top. The row therefore arrives exactly where the pin the
  /// operator clicked was — and stays there when the stack shrinks, because
  /// the viewport grows from the same edge the row is measured against.
  void _scrollToPinnedRow(String nodeId) {
    final rowContext = _nodeKeyRegistry[nodeId]?.currentContext;
    if (rowContext == null) return;
    revealSequenceRow(
      rowContext,
      duration: SkotiqTokens.durationSlow,
      alignment: 0,
    );
  }

  /// Height the pinned stack occupies over the top of the tree, and therefore
  /// the height the scroll viewport gives up to it.
  double get _reservedPinHeight => pinnedStackHeight(_pinnedAncestors.length);

  /// Record the density the layout pass just resolved, once it has finished.
  ///
  /// A no-op in the steady state. When it does change it is the third of the
  /// three things that can move the pins — the other two being a scroll and a
  /// rebuild — so it is also where the next measurement is scheduled from.
  void _syncCanvasDensity(SequencerDensity resolved) {
    if (_canvasDensity == resolved) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _canvasDensity == resolved) return;
      setState(() => _canvasDensity = resolved);
      if (_densityController.mounted) _densityController.state = resolved;
      _scheduleStickyPass();
    });
  }

  @override
  void didUpdateWidget(SequenceTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rebuild can add, remove or resize rows under a stack that is still
    // pointing at the old ones.
    _scheduleStickyPass();
  }

  /// Re-measure the pinned ancestors after the current frame.
  ///
  /// Guarded to one pass per frame: a fling fires the scroll listener far more
  /// often than the tree paints, and every pass walks live render boxes.
  void _scheduleStickyPass() {
    if (_stickyPassScheduled) return;
    _stickyPassScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickyPassScheduled = false;
      if (!mounted) return;
      final next =
          _stickyEnabled ? _computePinnedAncestors() : const <VisibleNode>[];
      if (listEquals(next, _pinnedAncestors)) return;
      final draining = next.isEmpty && _pinnedAncestors.isNotEmpty;
      setState(() {
        _pinnedAncestors = next;
        if (draining) _pinStackDraining = true;
      });
    });
  }

  /// Which ancestors of the topmost visible row have scrolled out of view.
  List<VisibleNode> _computePinnedAncestors() {
    final metrics = sequenceMapMetrics(_scrollController);
    // A tree shorter than its viewport has every ancestor row on screen
    // already; there is nothing a pin could add.
    if (metrics == null || metrics.maxScrollExtent <= 0) {
      return const <VisibleNode>[];
    }
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) {
      return const <VisibleNode>[];
    }
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return const <VisibleNode>[];

    // The scroll viewport is inset by the stack's height while the pins are
    // up, so its own top edge IS the first pixel the operator can see — no row
    // is ever behind the stack, and this one comparison serves both the anchor
    // and the pin test. It is also what keeps the set stable: the inset moves
    // the rows and the edge by the same amount, so which ancestors are pinned
    // stays a function of the scroll offset alone instead of feeding back into
    // itself once a frame.
    final occludedTop = viewport.localToGlobal(Offset.zero).dy;

    // The anchor is the first row the operator can see WHOLE. A row that is
    // only half out from under the stack is not the row the pins are
    // explaining — it is itself one of the things that needs explaining — so
    // the ancestors of the first complete row are the honest set, and the
    // half-hidden container ends up pinned rather than left unlabelled for the
    // 28 px it takes to finish leaving. The fallback covers a viewport too
    // short to hold one whole row: there the first partly visible row anchors,
    // exactly as it always did.
    String? anchorId;
    String? partialId;
    for (final row in _visibleOrder) {
      final bounds = _rowBounds(row.id);
      if (bounds == null) continue;
      if (bounds.top >= occludedTop) {
        anchorId = row.id;
        break;
      }
      partialId ??= bounds.bottom > occludedTop ? row.id : null;
    }
    anchorId ??= partialId;
    if (anchorId == null) return const <VisibleNode>[];

    // Measured against the viewport's own top edge, which the stack's
    // reservation has ALREADY moved: the rows and that edge are both inset by
    // the stack's height, so `row.top - occludedTop` is the scroll offset and
    // nothing else. That is what keeps the set from feeding back into itself —
    // a pin grows the stack, which moves the edge and the rows by the same
    // amount, so it can never push the row that caused it back over the line.
    return pinnedAncestorsOf(sequence, anchorId, (nodeId) {
      final bounds = _rowBounds(nodeId);
      return bounds != null && bounds.top < occludedTop;
    });
  }

  /// Index into [_visibleOrder] of the row that covers [contentOffset] pixels
  /// down the scroll content, or null while no row's box is mounted.
  ///
  /// The gutter's blocks are evenly spaced and the tree's rows are not (a
  /// container's children area, the ledger's column header and the scroll
  /// padding all take content pixels that no block stands for), so a gutter
  /// position can only be turned into a row by asking the rows themselves
  /// where they are. Same mapping the viewport rectangle uses — content
  /// pixels — which is what makes a tap on the rectangle's top edge select the
  /// row at the top of the viewport.
  int? _rowAtContentOffset(double contentOffset) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    if (!_scrollController.hasClients) return null;
    final contentTop =
        viewport.localToGlobal(Offset.zero).dy - _scrollController.offset;

    int? found;
    int? first;
    for (var i = 0; i < _visibleOrder.length; i++) {
      final bounds = _rowBounds(_visibleOrder[i].id);
      if (bounds == null) continue;
      first ??= i;
      // Rows are walked in draw order, so the first one that starts below the
      // target ends the search — everything after it starts lower still.
      if (bounds.top - contentTop > contentOffset) break;
      found = i;
    }
    // An offset ABOVE the first row is still a place in the tree: the ledger's
    // column header and the scroll view's top padding take content pixels that
    // no row starts in, and a gutter tap in that band is unmistakably a tap at
    // the top of the night. Returning null there sent it to the block-grid
    // estimate instead, which names a different row.
    return found ?? first;
  }

  /// A row's global top and bottom edge, or null while its box is not mounted.
  ({double top, double bottom})? _rowBounds(String nodeId) {
    final rowContext = _nodeKeyRegistry[nodeId]?.currentContext;
    final box = rowContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final top = box.localToGlobal(Offset.zero).dy;
    return (top: top, bottom: top + box.size.height);
  }

  /// Keep [_userExpandedIds] honest against every path that opens or closes a
  /// container, by diffing the collapsed set rather than hooking each of them.
  void _onCollapsedSetChanged(Set<String>? previous, Set<String> next) {
    final before = previous ?? const <String>{};
    // A container the operator closed again is no longer one they are holding
    // open.
    _userExpandedIds.removeAll(next.difference(before));

    final expanded = before.difference(next);
    if (expanded.isEmpty) return;
    final byUser = expanded.difference(_pendingAutoExpansions);
    _pendingAutoExpansions.removeAll(expanded);
    if (byUser.isEmpty) return;

    // Only containers the run has NOT finished with are worth remembering.
    // The set exists to stop the tree folding a branch away while the operator
    // is working in it — and a branch the run is done with is not one they can
    // still be working in. Expand-all is the case that proved it: one press
    // recorded every finished target in the night, and from then on nothing
    // the run did folded anything away again.
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;
    final statuses = ref.read(sequenceProgressProvider).nodeStatuses;
    _userExpandedIds.addAll(byUser.where(
      (id) => !isSubtreeComplete(sequence, statuses, id),
    ));
  }

  /// Drop the manual expansions the run has now finished with.
  ///
  /// A container can complete while the operator is holding it open; from that
  /// moment it is a finished branch like any other and the next node change
  /// may fold it away.
  void _dropCompletedUserExpansions() {
    if (_userExpandedIds.isEmpty) return;
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;
    final statuses = ref.read(sequenceProgressProvider).nodeStatuses;
    _userExpandedIds.removeWhere(
      (id) => isSubtreeComplete(sequence, statuses, id),
    );
  }

  /// Forget everything the tree knows about who opened what.
  ///
  /// Both sets describe ONE run over ONE sequence: carried past the end of
  /// either they can only shield containers from a fold the operator never
  /// asked to shield.
  void _clearExpansionBookkeeping() {
    _userExpandedIds.clear();
    _pendingAutoExpansions.clear();
  }

  void _onExecutingNodeChanged(String? previous, String? current) {
    if (previous == current) return;
    // Reset manual-scroll suppression: the run moved, so auto-follow gets
    // another turn.
    _userScrolledManually = false;

    if (current != null) {
      final sequence = ref.read(currentSequenceProvider);
      if (sequence != null) {
        // The branch the run just entered HAS now run, so the operator's
        // manual expansion of it stops protecting it from folding away once it
        // finishes.
        _userExpandedIds.remove(current);
        _userExpandedIds.removeAll(sequenceAncestorIds(sequence, current));
      }
    }
    _dropCompletedUserExpansions();
    _applyAutoCollapse(previousNodeId: previous, currentNodeId: current);
  }

  void _onExecutionStateChanged(
    SequenceExecutionState? previous,
    SequenceExecutionState next,
  ) {
    // Back to idle is the run RESET: statuses are cleared, so nothing in the
    // sequence is "finished" any more and every id the last run recorded
    // describes a container the next run has not reached. Keeping them would
    // shield those containers through a whole second night.
    if (next == SequenceExecutionState.idle) {
      _clearExpansionBookkeeping();
      return;
    }
    if (next != SequenceExecutionState.running) return;
    // Resuming from a pause is not a fresh start: the tree is already folded
    // to where the run left off.
    if (previous == SequenceExecutionState.running ||
        previous == SequenceExecutionState.paused) {
      return;
    }
    _applyAutoCollapse(
      previousNodeId: null,
      currentNodeId: ref.read(sequenceProgressProvider).currentNodeId,
    );
  }

  /// Fold the tree to the running branch (spec §4).
  void _applyAutoCollapse({
    required String? previousNodeId,
    required String? currentNodeId,
  }) {
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;
    final plan = planAutoCollapse(
      sequence: sequence,
      previousNodeId: previousNodeId,
      currentNodeId: currentNodeId,
      statuses: ref.read(sequenceProgressProvider).nodeStatuses,
      collapsed: ref.read(collapsedNodeIdsProvider),
      userExpanded: _userExpandedIds,
      followExecution: ref.read(followExecutionProvider),
    );
    if (plan.isEmpty) return;

    final notifier = ref.read(collapsedNodeIdsProvider.notifier);
    _pendingAutoExpansions.addAll(plan.toExpand);
    for (final id in plan.toExpand) {
      notifier.expand(id);
    }
    for (final id in plan.toCollapse) {
      notifier.collapse(id);
    }
  }

  /// Add a starter Target Header from the empty state.
  ///
  /// [addTargetHeader] throws [NoActiveSequenceException] when no sequence is
  /// loaded, so we create one first when [currentSequenceProvider] is null,
  /// then add the target. Routed through [withSequenceMutation] so any editor
  /// failure surfaces as a snackbar rather than an uncaught throw.
  void _addStarterTargetHeader() {
    withSequenceMutation(
      context,
      ref,
      operationName: 'add target header',
      action: () async {
        final notifier = ref.read(currentSequenceProvider.notifier);
        if (ref.read(currentSequenceProvider) == null) {
          notifier.createSequence();
        }
        final target = TargetHeaderNode(
          name: 'New Target',
          targetName: 'New Target',
          raHours: 0.0,
          decDegrees: 0.0,
        );
        notifier.addTargetHeader(target);
        ref.read(selectedNodeIdProvider.notifier).state = target.id;
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    // One empty-state pattern, one button, and that button is `secondary`:
    // the page's single primary is Start, in the header.
    return EmptyState(
      icon: LucideIcons.workflow,
      title: 'Build your sequence',
      body: isMobile
          ? 'Tap + to add a node.'
          : 'Drag a node from the palette, or double-click one.',
      action: SkotiqButton(
        onPressed: _addStarterTargetHeader,
        label: 'Add a target',
        icon: LucideIcons.target,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sequence = ref.watch(currentSequenceProvider);
    final progress = ref.watch(sequenceProgressProvider);
    final validation = ref.watch(liveValidationProvider);
    final density = effectiveSequencerDensity(
      ref.watch(sequencerDensityProvider),
      isMobile: widget.isMobile,
    );
    // Cached for the post-frame sticky pass and for the gutter's row mapping.
    // See [_visibleOrder]: watching here is what keeps the autoDispose order
    // alive between scroll frames.
    _visibleOrder = ref.watch(visibleNodeOrderProvider);

    // Auto-scroll whenever the executing node changes
    final followExecution = ref.watch(followExecutionProvider);
    if (followExecution && progress.currentNodeId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToCurrentNode(progress.currentNodeId);
        }
      });
    }

    // Auto-collapse to the running branch, and the manual-scroll reset that
    // rides on the same signal (spec §4).
    // Adding, removing, folding or collapsing rows moves every row under the
    // change, so the stack has to be re-measured against the new layout.
    ref.listen<List<VisibleNode>>(
      visibleNodeOrderProvider,
      (_, __) => _scheduleStickyPass(),
    );
    ref.listen(collapsedNodeIdsProvider, _onCollapsedSetChanged);
    ref.listen<String?>(sequenceProgressProvider.select((p) => p.currentNodeId),
        _onExecutingNodeChanged);
    ref.listen(sequenceExecutionStateProvider, _onExecutionStateChanged);

    if (sequence == null) {
      return _buildEmptyState(context);
    }

    final rootNode = sequence.rootNode;
    if (rootNode == null) {
      return _buildEmptyState(context);
    }

    // Reconcile the key registry against the current sequence before we
    // hand the registry to the recursive view. Pruning here (instead of
    // in didUpdateWidget) keeps it driven by the same provider snapshot
    // the view will render, so deletions can't race a re-add.
    _pruneKeyRegistry(sequence);

    // Tree-only keyboard shortcuts (arrow navigation, Enter -> properties,
    // Left/Right collapse/expand). Scoped to the tree FocusScope so they
    // don't fight Ctrl+Z/Y, Delete, etc. wired at the screen level. Text
    // fields inside property editors don't see these because Flutter
    // routes keystrokes to the nearest descendant Focus first.
    return Shortcuts(
      shortcuts: kSequenceTreeShortcuts,
      child: Actions(
        actions: buildSequenceTreeActions(ref),
        child: Focus(
          focusNode: _treeFocusNode,
          // The tree panel is the user's primary surface in the Builder
          // tab; auto-focus so arrows work right after switching tabs.
          autofocus: !widget.isMobile,
          child: _buildDragTarget(
              context, sequence, rootNode, progress, validation, density),
        ),
      ),
    );
  }

  Widget _buildDragTarget(
    BuildContext context,
    Sequence sequence,
    SequenceNode rootNode,
    SequenceProgress progress,
    LiveValidationState validation,
    SequencerDensity density,
  ) {
    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) =>
          details.data is NodePaletteItem ||
          details.data is TemplateSnippet ||
          details.data is TargetQueueDragPayload,
      onAcceptWithDetails: (details) {
        if (!ref.read(canEditSequenceProvider)) return;
        final data = details.data;
        if (data is NodePaletteItem) {
          final node = data.createNode();
          final notifier = ref.read(currentSequenceProvider.notifier);
          notifier.addNode(node);
          final children = data.createChildren?.call();
          if (children != null) {
            for (final child in children) {
              notifier.addNode(child, parentId: node.id);
            }
          }
          ref.read(selectedNodeIdProvider.notifier).state = node.id;
        } else if (data is TemplateSnippet) {
          insertSnippetGuarded(context, ref, data);
        } else if (data is TargetQueueDragPayload) {
          // Drag-drop a queued target → append the prebuilt
          // TargetHeaderNode under the root. Selection follows the
          // drop so the properties panel reveals the new target.
          final notifier = ref.read(currentSequenceProvider.notifier);
          notifier.addNode(data.node);
          ref.read(selectedNodeIdProvider.notifier).state = data.node.id;
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isAccepting = candidateData.isNotEmpty;

        return Container(
          decoration: BoxDecoration(
            color: widget.colors.background,
            border: isAccepting
                ? Border.all(color: widget.colors.primary, width: 2)
                : null,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A modal IME can reduce the already-covered backing route to a
              // few pixels after the shared shell consumes its inset. The
              // fixed sequence header cannot be useful there and would paint an
              // overflow stripe through the dialog scrim.
              if (constraints.hasBoundedHeight && constraints.maxHeight < 80) {
                return const SizedBox.expand();
              }
              // The one width decision the ledger rows rely on: below
              // `_ledgerColumnsMinWidth` the four columns cannot leave the
              // step names any room, so the whole tree falls back to compact
              // rows — the preference says which density is wanted, this says
              // which the canvas can actually host. Rows read the resolved
              // density, so a ledger row never has to wonder whether it can
              // afford its own columns.
              final contentWidth = constraints.maxWidth -
                  (widget.isMobile
                      ? SkotiqTokens.spaceMd * 2
                      : SkotiqTokens.spaceXl * 2);
              // The gutter comes out of the same width as the columns, so it
              // is part of the affordability test: a canvas that fits the
              // columns only by taking the gutter's 34 px cannot host Ledger.
              final canvasDensity = density == SequencerDensity.ledger &&
                      contentWidth - _gutterMapWidth < _ledgerColumnsMinWidth
                  ? SequencerDensity.compact
                  : density;
              // Whether the canvas is overruling the preference. A clamp is a
              // resize, and a resize must not cross-fade: see
              // [densityCrossfade].
              final densityClamped = canvasDensity != density;
              // 16 / 20 (06 §Sequencer): the canvas breathes at the sides
              // and packs vertically. The pinned ancestor stack takes the same
              // horizontal padding so a pin sits over the row it stands for.
              final scrollPadding = widget.isMobile
                  ? const EdgeInsets.all(SkotiqTokens.spaceMd)
                  : const EdgeInsets.symmetric(
                      horizontal: SkotiqTokens.spaceXl,
                      vertical: SkotiqTokens.spaceLg,
                    );
              // Reconciled after this frame, never during it: publishing the
              // resolved density and re-measuring the pins are both writes,
              // and a write from inside a build is either illegal (the
              // provider) or a frame late (the measurement).
              _syncCanvasDensity(canvasDensity);

              // Straight from the preference against the density THIS frame
              // resolved, not through `sequenceOverviewVisibleProvider`: that
              // provider reads the resolved density the tree only publishes
              // after the frame, so on the frame a narrow canvas clamps Ledger
              // to compact rows it would still be answering with Ledger's
              // choice and flash the strip on for one frame.
              final overviewPrefs =
                  ref.watch(sequenceOverviewPrefsProvider).valueOrNull ??
                      SequenceOverviewPrefs.defaults;
              final showOverview = overviewPrefs.visibleIn(canvasDensity);

              // The pinned stack floats over the top of the tree, so the
              // scroll viewport gives up exactly its height while it is up.
              // Padding the scroll CONTENT instead would only change which
              // rows end up behind the stack, never that two of them are: the
              // feature that exists to say where you are would be hiding the
              // first two rows of where you are.
              final reservedTop = _reservedPinHeight;

              return Column(
                children: [
                  // No header row: the canvas bar above the tree carries the
                  // sequence's name, its issue counts and its view toggles.
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Stack(
                            // Tight constraints for the scroll view, exactly
                            // as the Expanded it replaced gave it: a loose
                            // Stack would let a short tree shrink the viewport
                            // and break the scroll maths under it.
                            fit: StackFit.expand,
                            children: [
                              // Animated on the same token as the pins'
                              // entrance, so the rows travel down WITH the
                              // stack sliding in over them.
                              AnimatedPadding(
                                padding: EdgeInsets.only(top: reservedTop),
                                duration: animationDuration(
                                  context,
                                  SkotiqTokens.durationQuick,
                                ),
                                curve: SkotiqTokens.curveStandard,
                                child: SingleChildScrollView(
                                  key: _viewportKey,
                                  controller: _scrollController,
                                  padding: scrollPadding,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      // The ledger's column headings ride
                                      // inside the scroll view so they take
                                      // the same horizontal padding the rows
                                      // do and sit over the columns they name.
                                      // Through the SAME cross-fade the rows
                                      // take, so the header does not blink out
                                      // ahead of the tree it labels (spec §9).
                                      // An empty sequence has no columns to
                                      // name: the header would sit over the
                                      // lone drop line and read as a table
                                      // with its rows missing.
                                      densityCrossfade(
                                        context: context,
                                        density: canvasDensity,
                                        animate: !densityClamped,
                                        child: canvasDensity ==
                                                    SequencerDensity.ledger &&
                                                sequence
                                                    .getChildren(rootNode.id)
                                                    .isNotEmpty
                                            ? _LedgerColumnHeader(
                                                colors: widget.colors)
                                            : const SizedBox.shrink(),
                                      ),
                                      _NodeTreeView(
                                        colors: widget.colors,
                                        sequence: sequence,
                                        nodeId: rootNode.id,
                                        progress: progress,
                                        validation: validation,
                                        depth: 0,
                                        density: canvasDensity,
                                        densityClamped: densityClamped,
                                        isMobile: widget.isMobile,
                                        onNodeTap: widget.onNodeTap,
                                        keyRegistry: _nodeKeyRegistry,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_stickyEnabled &&
                                  (_pinnedAncestors.isNotEmpty ||
                                      _pinStackDraining))
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: _StickyAncestorStack(
                                    key: sequenceStickyAncestorsKey,
                                    colors: widget.colors,
                                    sequence: sequence,
                                    progress: progress,
                                    pinned: _pinnedAncestors,
                                    density: canvasDensity,
                                    padding: scrollPadding,
                                    onTap: _scrollToPinnedRow,
                                    onEmptied: () {
                                      if (!mounted || !_pinStackDraining) {
                                        return;
                                      }
                                      setState(() => _pinStackDraining = false);
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // Ledger's overview lives beside the rows it maps
                        // (spec §7); the other two densities put the same map
                        // in the strip below. It fades with the rows rather
                        // than snapping away from beside them (spec §9), and
                        // the rows take back its width when it is off.
                        densityCrossfade(
                          context: context,
                          density: canvasDensity,
                          animate: !densityClamped,
                          child: canvasDensity == SequencerDensity.ledger
                              ? _GutterMapSlot(
                                  visible: showOverview,
                                  colors: widget.colors,
                                  scrollController: _scrollController,
                                  rowAtContentOffset: _rowAtContentOffset,
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),

                  // Visual timeline (toggled via timelineVisibleProvider)
                  Consumer(
                    builder: (context, ref, child) {
                      final showTimeline = ref.watch(timelineVisibleProvider);
                      if (!showTimeline || widget.isMobile) {
                        return const SizedBox.shrink();
                      }
                      return VisualTimeline(colors: widget.colors);
                    },
                  ),

                  // The overview's strip shape, toggled by the same canvas-bar
                  // control the gutter answers to. Ledger has the gutter
                  // instead, so the strip would be a second copy of the map
                  // already beside the rows.
                  if (showOverview &&
                      !widget.isMobile &&
                      canvasDensity != SequencerDensity.ledger)
                    SequenceMinimap(
                      colors: widget.colors,
                      scrollController: _scrollController,
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
