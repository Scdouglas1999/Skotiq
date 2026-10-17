import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../sequence_fold_model.dart';
import 'delete_node_confirmation.dart';
import 'node_palette_empty_state.dart';
import 'node_palette_search.dart';
import 'palette_icon_map.dart';
import 'sequence_tree/fold_group_actions.dart';

/// Right-click / long-press context menu for nodes in the sequencer tree.
///
/// This widget never *renders* the menu — it only wraps its [child] with a
/// gesture detector that opens a [showMenu] popup at the pointer position
/// when the user secondary-taps (desktop) or long-presses (mobile). The
/// menu visual style mirrors the existing inline `PopupMenuButton` usage
/// in `_NodeItem` so the two surfaces feel like the same control.
class SequenceTreeContextMenu extends ConsumerWidget {
  const SequenceTreeContextMenu({
    super.key,
    required this.nodeId,
    required this.colors,
    required this.child,
    this.foldGroup,
  });

  /// The node the menu acts on. For a folded row this is the run's first
  /// member — the id its scroll key and its inspector selection already use.
  final String nodeId;
  final SkotiqColors colors;
  final Widget child;

  /// Set when [child] is a folded row (spec §6). The menu then offers the
  /// run's vocabulary instead of the node's: every mutation applies to all
  /// members, Insert Above / Below anchor on the block's edges, and Move Up /
  /// Down shift the whole block.
  final FoldGroup? foldGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (details) =>
          _open(context, ref, details.globalPosition),
      onLongPressStart: (details) =>
          _open(context, ref, details.globalPosition),
      child: child,
    );
  }

  Future<void> _open(
      BuildContext context, WidgetRef ref, Offset position) async {
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;
    final node = sequence.nodes[nodeId];
    if (node == null) return;

    // Selecting the node *before* opening matches OS conventions (right-
    // click also focuses), and the menu actions all run against the
    // selected node so this keeps state consistent. A folded row selects the
    // way a click on it does — the whole run, inspector on the first member —
    // because "Group into …" reads the multi-selection.
    final group = foldGroup;
    if (group == null) {
      ref.read(selectedNodeIdProvider.notifier).state = nodeId;
    } else {
      ref
          .read(multiSelectedNodeIdsProvider.notifier)
          .selectAll(group.memberIds);
      ref.read(selectedNodeIdProvider.notifier).state = group.memberIds.first;
    }

    final canEdit = ref.read(canEditSequenceProvider);
    // "Skip to here" is only meaningful while the sequence
    // is running/paused. canEdit is FALSE in those states — the inverse of
    // what we need — so we read the live execution state directly.
    final executionState = ref.read(sequenceExecutionStateProvider);
    final isRunning = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused;

    if (group != null) {
      await _openFoldMenu(
        context,
        ref,
        sequence: sequence,
        group: group,
        position: position,
        canEdit: canEdit,
        isRunning: isRunning,
      );
      return;
    }

    final selected = await showMenu<_TreeMenuAction>(
      context: context,
      // [position] is the GLOBAL pointer position and `showMenu` measures its
      // insets against the nested Navigator's overlay, which starts at the
      // shell's content edge. It has to be converted, or the overlay's origin
      // is counted twice: this used to claim it opened "exactly under the
      // cursor" while landing a nav-rail plus a title-bar away from it —
      // measured live, 147 px right and 32 px down of the cursor with the rail
      // expanded, and 43 px right with it collapsed.
      position: menuPositionFromPoint(context, position),
      color: colors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      // Wider min-width: the default 112px clips "Group into Sequential
      // Container" and triggers Flex overflow warnings in tests on
      // narrow surfaces.
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 320),
      items: _buildMenuItems(
        node,
        sequence: sequence,
        selectedIds: ref.read(multiSelectedNodeIdsProvider),
        canEdit: canEdit,
        isRunning: isRunning,
      ),
    );

    if (selected == null) return;
    if (!context.mounted) return;
    await _handleSelection(context, ref, sequence, node, selected);
  }

  List<PopupMenuEntry<_TreeMenuAction>> _buildMenuItems(
    SequenceNode node, {
    required Sequence sequence,
    required Set<String> selectedIds,
    required bool canEdit,
    required bool isRunning,
  }) {
    // Same compact style as the existing more-actions menu in _NodeItem.
    // When `canEdit` is false (sequence is running/paused/stopping) we
    // gray out every mutating entry so the user sees them but can't fire
    // them — matches `canEditSequenceProvider` semantics. The notifier
    // still throws SequenceLockedException as a last line of defense.

    // Insert Above / Insert Below require a parent slot. The root
    // sequence node has no parent, so those entries are permanently
    // disabled on the root with a tooltip explaining why — avoids the
    // earlier behaviour where clicking them on the root silently
    // returned without any feedback.
    final isRoot = node.parentId == null;
    const rootDisabledReason =
        'Cannot insert above/below the root sequence node.';

    // Group into ...: forbid grouping the root node itself, same reason.
    // For non-root nodes, the multi-select grouping helper validates that
    // the selection shares a parent; we don't need to pre-check that
    // here because the menu item is being opened on a single node.
    final groupDisabledReason =
        isRoot ? 'Cannot group the root sequence node into a container.' : null;

    // "Group into Parallel" only makes sense for 2+ adjacent siblings —
    // wrapping a single node in a Parallel container is a no-op semantically
    // (a parallel branch of one). Sequential grouping stays meaningful for a
    // single node (it's still a labelled container), so it is not gated.
    final parallelGroupDisabledReason = groupDisabledReason ??
        (_contiguousSiblingSelectionCount(sequence, node, selectedIds) >= 2
            ? null
            : 'Select 2+ adjacent nodes to group in parallel.');

    // Duplicate / Delete also don't make sense for the root — the editor
    // ignores `removeNode(root)` silently which is the same audit
    // complaint. Surface the same way.
    final rootOnlyDisabledReason = isRoot
        ? 'This action is not available on the root sequence node.'
        : null;

    // Reorder. Node order is load-bearing in a sequence (unpark must precede
    // slew), and drag-and-drop inside a long scrolling tree is a poor way to
    // move one row. The kebab menu carries the same two entries; having them
    // here as well means a right-click — the reflex for "move this" — finds
    // them.
    final parent = isRoot ? null : sequence.nodes[node.parentId];
    final siblingIndex = parent?.childIds.indexOf(node.id) ?? -1;
    final moveUpDisabledReason = rootOnlyDisabledReason ??
        (siblingIndex <= 0 ? 'Already the first node in its container.' : null);
    final moveDownDisabledReason = rootOnlyDisabledReason ??
        (siblingIndex < 0 || siblingIndex >= (parent!.childIds.length - 1)
            ? 'Already the last node in its container.'
            : null);

    return [
      // "Skip to here" — only enabled while a sequence is
      // running. Mutating: false because skipping does not edit the
      // sequence definition; the disabledReason teaches the user the entry
      // requires a live run when the executor is idle.
      _entry(
        _TreeMenuAction.skipToHere,
        LucideIcons.skipForward,
        'Skip to here',
        mutating: false,
        disabledReason: isRunning
            ? (isRoot ? 'Cannot skip to the root sequence node.' : null)
            : 'Start the sequence to skip ahead to a specific node.',
        canEdit: canEdit,
      ),
      const PopupMenuDivider(height: 8),
      _entry(
        _TreeMenuAction.insertAbove,
        LucideIcons.arrowUpToLine,
        'Insert Above',
        disabledReason: isRoot ? rootDisabledReason : null,
        canEdit: canEdit,
      ),
      _entry(
        _TreeMenuAction.insertBelow,
        LucideIcons.arrowDownToLine,
        'Insert Below',
        disabledReason: isRoot ? rootDisabledReason : null,
        canEdit: canEdit,
      ),
      const PopupMenuDivider(height: 8),
      _entry(
        _TreeMenuAction.moveUp,
        LucideIcons.arrowUp,
        'Move Up',
        disabledReason: moveUpDisabledReason,
        canEdit: canEdit,
      ),
      _entry(
        _TreeMenuAction.moveDown,
        LucideIcons.arrowDown,
        'Move Down',
        disabledReason: moveDownDisabledReason,
        canEdit: canEdit,
      ),
      const PopupMenuDivider(height: 8),
      _entry(
        _TreeMenuAction.duplicate,
        LucideIcons.copy,
        'Duplicate',
        disabledReason: rootOnlyDisabledReason,
        canEdit: canEdit,
      ),
      _entry(
        _TreeMenuAction.groupSequential,
        LucideIcons.listOrdered,
        'Group into Sequential Container',
        disabledReason: groupDisabledReason,
        canEdit: canEdit,
      ),
      _entry(
        _TreeMenuAction.groupParallel,
        LucideIcons.gitBranch,
        'Group into Parallel Container',
        disabledReason: parallelGroupDisabledReason,
        canEdit: canEdit,
      ),
      const PopupMenuDivider(height: 8),
      _entry(
        node.isEnabled ? _TreeMenuAction.disable : _TreeMenuAction.enable,
        node.isEnabled ? LucideIcons.eyeOff : LucideIcons.eye,
        node.isEnabled ? 'Disable' : 'Enable',
        canEdit: canEdit,
      ),
      const PopupMenuDivider(height: 8),
      _entry(
        _TreeMenuAction.delete,
        LucideIcons.trash2,
        'Delete',
        labelColor: colors.error,
        disabledReason: rootOnlyDisabledReason,
        canEdit: canEdit,
      ),
    ];
  }

  /// One menu row, shared by the node menu and the folded-run menu so the two
  /// can never disagree about how a disabled entry looks or why.
  ///
  /// [disabledReason] overrides [canEdit]: it carries the cases that are
  /// permanent for the target (a root node has no sibling slot, a block is
  /// already at the end of its container) rather than gated by execution
  /// state.
  PopupMenuItem<T> _entry<T>(
    T action,
    IconData icon,
    String label, {
    required bool canEdit,
    Color? labelColor,
    bool mutating = true,
    String? disabledReason,
  }) {
    final structurallyDisabled = disabledReason != null;
    final lockedByExecution = mutating && !canEdit;
    final disabled = structurallyDisabled || lockedByExecution;

    final effectiveColor =
        disabled ? colors.textMuted : (labelColor ?? colors.textSecondary);
    final effectiveLabel =
        disabled ? colors.textMuted : (labelColor ?? colors.textPrimary);

    // Tooltip wins for the structural case (more informative than
    // "sequence is running"); falls back to the execution-state hint
    // otherwise.
    final tooltip = structurallyDisabled
        ? disabledReason
        : (lockedByExecution ? 'Sequence is running — stop it first.' : null);

    final row = Row(
      children: [
        Icon(icon, size: 14, color: effectiveColor),
        const SizedBox(width: 10),
        // Flexible+ellipsis so the wider entries ("Group into Sequential
        // Container") do not overflow the menu's default 256px width on
        // narrow surfaces.
        Flexible(
          child: Text(
            label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: effectiveLabel),
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          ),
        ),
      ],
    );

    return PopupMenuItem<T>(
      value: action,
      height: 36,
      enabled: !disabled,
      child: tooltip == null
          ? row
          // Wrap with a Tooltip so the user discovers *why* the entry is
          // grayed out instead of silently no-op-ing on click.
          : Tooltip(message: tooltip, child: row),
    );
  }

  /// The folded-run menu (spec §6): the node menu's vocabulary, restated for a
  /// block of steps.
  ///
  /// What changes: every mutation applies to all members and says so, Insert
  /// Above / Below anchor on the block's first and last member instead of on
  /// one row, Move Up / Down shift the whole block, and Delete asks about the
  /// run. What is absent: nothing a run cannot answer for — the node menu has
  /// no per-node Rename or Save as Template to hide, and "Group into …" works
  /// unchanged because opening this menu selects every member.
  Future<void> _openFoldMenu(
    BuildContext context,
    WidgetRef ref, {
    required Sequence sequence,
    required FoldGroup group,
    required Offset position,
    required bool canEdit,
    required bool isRunning,
  }) async {
    final parent = sequence.nodes[group.parentId];
    final siblingCount = parent?.childIds.length ?? 0;
    final atTop = group.firstIndex <= 0;
    final atBottom = group.firstIndex + group.memberCount >= siblingCount;

    final selected = await showMenu<_FoldMenuAction>(
      context: context,
      // Global pointer position, converted — see the node menu above.
      position: menuPositionFromPoint(context, position),
      color: colors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 320),
      items: [
        _entry(
          _FoldMenuAction.skipToHere,
          LucideIcons.skipForward,
          'Skip to here',
          mutating: false,
          canEdit: canEdit,
          disabledReason: isRunning
              ? null
              : 'Start the sequence to skip ahead to a specific node.',
        ),
        const PopupMenuDivider(height: 8),
        _entry(
          _FoldMenuAction.insertAbove,
          LucideIcons.arrowUpToLine,
          'Insert Above',
          canEdit: canEdit,
        ),
        _entry(
          _FoldMenuAction.insertBelow,
          LucideIcons.arrowDownToLine,
          'Insert Below',
          canEdit: canEdit,
        ),
        const PopupMenuDivider(height: 8),
        _entry(
          _FoldMenuAction.moveUp,
          LucideIcons.arrowUp,
          'Move Up',
          canEdit: canEdit,
          disabledReason:
              atTop ? 'Already the first steps in their container.' : null,
        ),
        _entry(
          _FoldMenuAction.moveDown,
          LucideIcons.arrowDown,
          'Move Down',
          canEdit: canEdit,
          disabledReason:
              atBottom ? 'Already the last steps in their container.' : null,
        ),
        const PopupMenuDivider(height: 8),
        _entry(
          _FoldMenuAction.duplicate,
          LucideIcons.copy,
          'Duplicate all',
          canEdit: canEdit,
        ),
        _entry(
          _FoldMenuAction.groupSequential,
          LucideIcons.listOrdered,
          'Group into Sequential Container',
          canEdit: canEdit,
        ),
        _entry(
          _FoldMenuAction.groupParallel,
          LucideIcons.gitBranch,
          'Group into Parallel Container',
          canEdit: canEdit,
        ),
        const PopupMenuDivider(height: 8),
        // A run is enabled by construction — a disabled step is not part of
        // one — so this is the only direction the entry ever offers.
        _entry(
          _FoldMenuAction.disableAll,
          LucideIcons.eyeOff,
          'Disable all',
          canEdit: canEdit,
        ),
        const PopupMenuDivider(height: 8),
        _entry(
          _FoldMenuAction.delete,
          LucideIcons.trash2,
          'Delete ${group.memberCount} steps',
          labelColor: colors.error,
          canEdit: canEdit,
        ),
      ],
    );

    if (selected == null) return;
    if (!context.mounted) return;

    final first = sequence.nodes[group.memberIds.first];
    final last = sequence.nodes[group.memberIds.last];
    if (first == null || last == null) return;

    switch (selected) {
      case _FoldMenuAction.insertAbove:
        _insertSibling(context, ref, sequence, first, offset: 0);
      case _FoldMenuAction.insertBelow:
        _insertSibling(context, ref, sequence, last, offset: 1);
      case _FoldMenuAction.moveUp:
        await moveFoldGroup(
          context,
          ref,
          memberIds: group.memberIds,
          parentId: group.parentId,
          index: group.firstIndex - 1,
        );
      case _FoldMenuAction.moveDown:
        await moveFoldGroup(
          context,
          ref,
          memberIds: group.memberIds,
          parentId: group.parentId,
          // The slot the step after the run holds today: removing the run's
          // leader shifts it left by one, so inserting there lands the block
          // one step further down.
          index: group.firstIndex + group.memberCount,
        );
      case _FoldMenuAction.duplicate:
        await duplicateFoldGroup(context, ref, group: group);
      case _FoldMenuAction.groupSequential:
        await _groupSelection(
          context,
          ref,
          sequence,
          first,
          () => InstructionSetNode(name: 'Sequential'),
        );
      case _FoldMenuAction.groupParallel:
        await _groupSelection(context, ref, sequence, first, ParallelNode.new);
      case _FoldMenuAction.disableAll:
        await disableFoldGroup(context, ref, memberIds: group.memberIds);
      case _FoldMenuAction.delete:
        await confirmAndDeleteFoldGroup(
          context: context,
          ref: ref,
          group: group,
        );
      case _FoldMenuAction.skipToHere:
        // A run starts at its first member, so that is what "here" means.
        try {
          await ref.read(sequenceExecutorProvider).skipToNode(first.id);
        } catch (e) {
          if (!context.mounted) return;
          _showSnackBar(context, 'Failed to skip to "${first.name}": $e');
        }
    }
  }

  /// Count of selected nodes that form a contiguous run of siblings sharing
  /// the right-clicked node's parent (and including that node). Returns 0
  /// when the selection doesn't include [node], spans multiple parents, or
  /// is not contiguous — i.e. the conditions under which `wrapChildrenSubset`
  /// would refuse. Used to gate "Group into Parallel" (requires >= 2).
  int _contiguousSiblingSelectionCount(
    Sequence sequence,
    SequenceNode node,
    Set<String> selectedIds,
  ) {
    final parentId = node.parentId;
    if (parentId == null) return 0;
    if (!selectedIds.contains(node.id)) return 0;

    final parent = sequence.nodes[parentId];
    if (parent == null) return 0;

    final indices = <int>[];
    for (final id in selectedIds) {
      final n = sequence.nodes[id];
      if (n == null) return 0;
      if (n.parentId != parentId) return 0; // spans parents
      final idx = parent.childIds.indexOf(id);
      if (idx < 0) return 0;
      indices.add(idx);
    }
    indices.sort();
    for (int i = 1; i < indices.length; i++) {
      if (indices[i] != indices[i - 1] + 1) return 0; // not contiguous
    }
    return indices.length;
  }

  Future<void> _handleSelection(
    BuildContext context,
    WidgetRef ref,
    Sequence sequence,
    SequenceNode node,
    _TreeMenuAction action,
  ) async {
    final notifier = ref.read(currentSequenceProvider.notifier);

    switch (action) {
      case _TreeMenuAction.insertAbove:
        _insertSibling(context, ref, sequence, node, offset: 0);
        break;
      case _TreeMenuAction.insertBelow:
        _insertSibling(context, ref, sequence, node, offset: 1);
        break;
      case _TreeMenuAction.moveUp:
        _moveSibling(ref, sequence, node, delta: -1);
        break;
      case _TreeMenuAction.moveDown:
        _moveSibling(ref, sequence, node, delta: 1);
        break;
      case _TreeMenuAction.duplicate:
        notifier.duplicateNode(node.id);
        break;
      case _TreeMenuAction.groupSequential:
        await _groupSelection(
          context,
          ref,
          sequence,
          node,
          () => InstructionSetNode(name: 'Sequential'),
        );
        break;
      case _TreeMenuAction.groupParallel:
        await _groupSelection(
          context,
          ref,
          sequence,
          node,
          () => ParallelNode(),
        );
        break;
      case _TreeMenuAction.disable:
      case _TreeMenuAction.enable:
        notifier.toggleNodeEnabled(node.id);
        break;
      case _TreeMenuAction.delete:
        await _confirmAndDelete(context, ref, sequence, node);
        break;
      case _TreeMenuAction.skipToHere:
        // Route through SequenceExecutor.skipToNode which
        // proxies to the backend `sequencerSkipToNode` method (the Rust side
        // maps to the new api_sequencer_skip_to_node FRB binding). Errors
        // surface as a snackbar so the user sees when the jump was rejected
        // (e.g. executor not running, or backend not connected).
        try {
          await ref.read(sequenceExecutorProvider).skipToNode(node.id);
        } catch (e) {
          if (!context.mounted) return;
          _showSnackBar(context, 'Failed to skip to "${node.name}": $e');
        }
        break;
    }
  }

  /// Resolve "group into X" against the current multi-selection.
  ///
  /// Behavior:
  ///   * Selection size 0 or 1 (or the right-clicked node is not part of
  ///     the selection): wrap only the right-clicked [node]. This matches
  ///     pre-multi-select intuition for the single-click case.
  ///   * Selection size > 1, all sharing a parent: wrap the whole
  ///     selection via [CurrentSequenceNotifier.wrapChildrenSubset] so
  ///     every selected sibling lands inside the same container in their
  ///     original tree order.
  ///   * Selection size > 1, spanning multiple parents: refuse with a
  ///     snackbar (no silent partial-wrap). The user must collapse the
  ///     selection or move siblings under one parent first.
  ///   * Selection contiguity is enforced by the notifier, which throws
  ///     [StateError]; we translate that into a snackbar too.
  Future<void> _groupSelection(
    BuildContext context,
    WidgetRef ref,
    Sequence sequence,
    SequenceNode node,
    SequenceNode Function() makeWrapper,
  ) async {
    final notifier = ref.read(currentSequenceProvider.notifier);
    final selected = ref.read(multiSelectedNodeIdsProvider);

    // Trivial cases: 0 or 1 selection, or right-click outside the multi-
    // selection → fall back to single-node wrap of the clicked node.
    if (selected.length < 2 || !selected.contains(node.id)) {
      notifier.wrapNode(node.id, makeWrapper());
      return;
    }

    // All selected nodes must share the same parent.
    String? sharedParent;
    for (final id in selected) {
      final n = sequence.nodes[id];
      if (n == null) continue;
      final p = n.parentId;
      if (p == null) {
        // The root node has no parent — wrapping the root is not a thing
        // we expose. Defensive: surface this rather than no-op.
        _showSnackBar(
            context, "Can't group the root sequence node into a container.");
        return;
      }
      sharedParent ??= p;
      if (sharedParent != p) {
        _showSnackBar(
            context,
            'Selection spans multiple parents — move the selected nodes '
            'under one container before grouping.');
        return;
      }
    }
    if (sharedParent == null) return;

    try {
      notifier.wrapChildrenSubset(
        sharedParent,
        selected.toList(),
        makeWrapper(),
      );
      // Move selection focus onto the new wrapper so subsequent edits
      // (rename it, drag more into it) act on the new container.
      final current = ref.read(currentSequenceProvider);
      if (current != null) {
        // The new wrapper is the only child of `sharedParent` that wasn't
        // in the original selection set — recover it by diffing.
        final newParent = current.nodes[sharedParent];
        if (newParent != null) {
          for (final childId in newParent.childIds) {
            if (!selected.contains(childId)) {
              ref.read(selectedNodeIdProvider.notifier).state = childId;
              break;
            }
          }
        }
      }
      ref.read(multiSelectedNodeIdsProvider.notifier).clear();
    } on StateError catch (e) {
      // wrapChildrenSubset throws on non-contiguous selection — surface
      // with the message verbatim so the user understands the constraint.
      _showSnackBar(context, e.message);
    }
  }

  /// Shift [node] one slot within its own parent. Uses the same
  /// `moveNode(id, parentId, index)` call the tree's drag-drop and kebab
  /// Move Up / Move Down go through, so the three surfaces produce one
  /// undo entry shape and one reindex path.
  void _moveSibling(
    WidgetRef ref,
    Sequence sequence,
    SequenceNode node, {
    required int delta,
  }) {
    final parentId = node.parentId;
    if (parentId == null) return;
    final parent = sequence.nodes[parentId];
    if (parent == null) return;
    final index = parent.childIds.indexOf(node.id);
    final target = index + delta;
    // The menu entries are pre-disabled at the ends; this guard only covers
    // a programmatic call.
    if (index < 0 || target < 0 || target >= parent.childIds.length) return;
    ref.read(currentSequenceProvider.notifier).moveNode(
          node.id,
          parentId,
          target,
        );
  }

  void _showSnackBar(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: colors.error,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Open the node-palette sheet rooted at this node's parent so the new
  /// node lands at the requested sibling slot. We piggy-back on the
  /// existing palette UX rather than inventing a "pick a node type"
  /// dialog inline — that's what `_showNodePaletteSheet` already gives
  /// us in the narrow-desktop / mobile layouts. For Insert Above /
  /// Insert Below we just compute the target index and open the palette
  /// preloaded with an insert callback.
  void _insertSibling(
    BuildContext context,
    WidgetRef ref,
    Sequence sequence,
    SequenceNode node, {
    required int offset,
  }) {
    final parentId = node.parentId;
    // The Insert Above / Insert Below menu items are pre-disabled for
    // root nodes (`_buildMenuItems` sets `disabledReason`), so reaching
    // this method with parentId == null indicates a programmatic call —
    // e.g. a future keyboard shortcut. Bail safely; the menu surface
    // already informs the user this isn't supported.
    if (parentId == null) return;
    final parent = sequence.nodes[parentId];
    if (parent == null) return;
    final targetIndex = parent.childIds.indexOf(node.id) + offset;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: colors.background.withValues(alpha: 0.72),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusMd),
        ),
      ),
      builder: (sheetContext) {
        return _InsertNodePicker(
          colors: colors,
          parentId: parentId,
          index: targetIndex,
          onDismiss: () => Navigator.of(sheetContext).pop(),
        );
      },
    );
  }

  Future<void> _confirmAndDelete(
    BuildContext context,
    WidgetRef ref,
    Sequence sequence,
    SequenceNode node,
  ) async {
    await confirmAndDeleteSequenceNode(
      context: context,
      ref: ref,
      nodeId: node.id,
      colors: colors,
    );
  }
}

/// What the folded-row menu can do. A separate enum from [_TreeMenuAction]
/// because a run answers to a different set: there is no Enable (a run has no
/// disabled members) and every entry is plural.
enum _FoldMenuAction {
  skipToHere,
  insertAbove,
  insertBelow,
  moveUp,
  moveDown,
  duplicate,
  groupSequential,
  groupParallel,
  disableAll,
  delete,
}

enum _TreeMenuAction {
  insertAbove,
  insertBelow,
  moveUp,
  moveDown,
  duplicate,
  groupSequential,
  groupParallel,
  disable,
  enable,
  delete,
  skipToHere,
}

/// Lightweight palette wrapper used by Insert Above / Insert Below.
///
/// Implemented inline (not a separate widget file) because it only exists
/// to delegate into the existing palette + carry an "insert at index"
/// callback. We reuse [nodePaletteProvider] as the data source so any
/// node type the user can drag is also reachable from this menu.
class _InsertNodePicker extends ConsumerStatefulWidget {
  const _InsertNodePicker({
    required this.colors,
    required this.parentId,
    required this.index,
    required this.onDismiss,
  });

  final SkotiqColors colors;
  final String parentId;
  final int index;
  final VoidCallback onDismiss;

  @override
  ConsumerState<_InsertNodePicker> createState() => _InsertNodePickerState();
}

class _InsertNodePickerState extends ConsumerState<_InsertNodePicker> {
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _insert(NodePaletteItem item) {
    final newNode = item.createNode();
    final notifier = ref.read(currentSequenceProvider.notifier);
    notifier.addNode(
      newNode,
      parentId: widget.parentId,
      index: widget.index,
    );
    final children = item.createChildren?.call();
    if (children != null) {
      for (final c in children) {
        notifier.addNode(c, parentId: newNode.id);
      }
    }
    ref.read(selectedNodeIdProvider.notifier).state = newNode.id;
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final categories = ref.watch(nodePaletteProvider);

    // Same relevance ranking as the two main palettes (see
    // node_palette_search.dart), so a NAME hit outranks a DESCRIPTION hit here
    // too.
    final filtered = rankNodePaletteMatches(categories, _query);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.surfaceElevated,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(SkotiqTokens.radiusMd),
            ),
            border: Border(top: BorderSide(color: colors.border)),
            boxShadow: SkotiqTokens.shadowLg,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Row(
                    children: [
                      Icon(LucideIcons.plus, size: 16, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Insert node',
                        style: SkotiqTypography.h5
                            .copyWith(color: colors.textPrimary),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: colors.surfaceAlt,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline8),
                      border: Border.all(color: colors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(LucideIcons.search,
                            size: 15, color: colors.textMuted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: (value) =>
                                setState(() => _query = value),
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize13,
                              color: colors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Search nodes...',
                              hintStyle: TextStyle(
                                fontSize: SkotiqTypography.fontSize13,
                                color: colors.textMuted,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                        if (_query.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            child: Icon(LucideIcons.x,
                                size: 15, color: colors.textMuted),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? NodePaletteEmptyState(
                          colors: colors,
                          query: _query,
                          onClear: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        )
                      : ListView(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          children: [
                            for (final category in filtered) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                                child: Text(
                                  category.name,
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize11,
                                    fontWeight: FontWeight.w600,
                                    color: colors.textMuted,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                              for (final item in category.items)
                                Builder(builder: (context) {
                                  final categoryColor =
                                      nodePaletteCategoryColor(
                                          category.name, colors);
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(
                                        SkotiqTokens.radiusInline8),
                                    onTap: () => _insert(item),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 10),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 28,
                                            height: 28,
                                            decoration: SkotiqDecorations
                                                .tintedBadge(
                                              categoryColor,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      SkotiqTokens
                                                          .radiusMd),
                                            ),
                                            child: Icon(
                                              nodePaletteIconFor(item.icon),
                                              size: 14,
                                              color: categoryColor,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item.name,
                                                  style: SkotiqTypography
                                                      .label
                                                      .copyWith(
                                                          color: colors
                                                              .textPrimary),
                                                ),
                                                Text(
                                                  item.description,
                                                  style: TextStyle(
                                                    fontSize:
                                                        SkotiqTypography
                                                            .fontSize11,
                                                    color: colors.textMuted,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }),
                            ],
                            const SizedBox(height: 16),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
