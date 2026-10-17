/// Wave 5B — Phone-native sequencer authoring surface.
///
/// Renders the current sequence as a flat, depth-indented list of touch-
/// friendly rows with the desktop sequencer's status visuals, plus:
///
///   * long-press → reorder mode (Material `ReorderableListView`). Reorder
///     is **only** supported within the same parent — cross-parent moves
///     would require a target picker that doesn't fit one-handed on a
///     phone, so we fall back to "tap to edit" for that case (the desktop
///     editor exposes `moveNode` for cross-parent reparenting, which the
///     authoring surface here intentionally does not invoke).
///   * swipe-left → delete with 8s Undo SnackBar. We capture the entire
///     subtree before removal so the undo restores children, parent
///     position, and orderIndex.
///   * tap → opens the existing [NodePropertiesPanel] in a draggable
///     bottom sheet (same flow the desktop screen uses on narrow widths).
///   * FAB `+` → opens the [NodePalette] mobile sheet for adding nodes.
///     Tap adds to the currently selected parent, defaulting to the
///     sequence root.
///
/// Also exports [SequencerRecoveryActionsBanner] — the phone variant of
/// [RunDashboardRecoveryBanner]. Renders nothing when no recovery is in
/// flight; otherwise renders a single-row banner with the cause, attempt
/// counter, live countdown chip, and Try Now / Skip Node / Abort buttons
/// (Abort is wrapped in [HoldToConfirmButton] so a thumb-slip can't kill
/// an overnight run).
///
/// Both classes live in this single file because `sequencer_tab.dart`
/// references them via the deep import
/// `package:skotiq_app/screens/sequencer/mobile_sequence_editor.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'widgets/node_palette.dart';
import 'widgets/node_properties_panel.dart';
import 'widgets/run_dashboard/recovery_banner.dart';

// MOBILE SEQUENCE EDITOR

/// Touch-friendly sequence authoring surface for the mobile companion app.
///
/// Designed to live inside an `Expanded` slot — uses a `Column` with an
/// inner [ReorderableListView] so the FAB stays anchored above the bottom
/// edge regardless of list length.
class MobileSequenceEditor extends ConsumerStatefulWidget {
  const MobileSequenceEditor({super.key});

  @override
  ConsumerState<MobileSequenceEditor> createState() =>
      _MobileSequenceEditorState();
}

class _MobileSequenceEditorState extends ConsumerState<MobileSequenceEditor> {
  @override
  Widget build(BuildContext context) {
    final sequence = ref.watch(currentSequenceProvider);
    final progress = ref.watch(sequenceProgressProvider);
    final canEdit = ref.watch(canEditSequenceProvider);
    final colors = SkotiqColors.of(context);

    if (sequence == null) {
      return const EmptyState(
        icon: LucideIcons.play,
        title: 'Create or load a sequence',
        body: 'Tap "Load" in the header or create one on the desktop and '
            'it will appear here.',
      );
    }

    final rows = _flattenTree(sequence);
    if (rows.isEmpty) {
      // Even though we have a Sequence, the root has no children to edit.
      // Still show the FAB so the user can drop the first node.
      return Stack(
        children: [
          const Positioned.fill(
            child: EmptyState(
              icon: LucideIcons.fileWarning,
              title: 'Sequence is empty',
              body: 'Tap the + button to add your first node.',
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: _AddNodeFab(onPressed: () => _showAddNodeSheet(context)),
          ),
        ],
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: ReorderableListView.builder(
            // 80px gives the FAB room without clipping the last row.
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 80),
            itemCount: rows.length,
            // Material default long-press is the natural phone gesture for
            // "enter reorder mode"; we keep the standard 500ms hold instead
            // of a custom recogniser so users get the platform feedback.
            buildDefaultDragHandles: true,
            onReorderItem: (oldIndex, newIndex) =>
                _handleReorder(sequence, rows, oldIndex, newIndex),
            itemBuilder: (context, index) {
              final row = rows[index];
              final isCurrent = progress.currentNodeId == row.node.id;
              return _MobileNodeRow(
                key: ValueKey('mobile-seq-node-${row.node.id}'),
                row: row,
                status: progress.nodeStatuses[row.node.id],
                isCurrent: isCurrent,
                progressPct: progress.nodeProgressPercent[row.node.id],
                colors: colors,
                canEdit: canEdit,
                onTap: () => _openProperties(context, row.node),
                onDismissed: () => _deleteWithUndo(context, sequence, row.node),
              );
            },
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: _AddNodeFab(onPressed: () => _showAddNodeSheet(context)),
        ),
      ],
    );
  }

  // Tree flattening (DFS) — mirrors the legacy `_NodeList` walker in
  // `sequencer_tab.dart` so the rendered order matches the desktop sequencer
  // exactly. The root node is the implicit container; we surface only its
  // children and below.

  List<_NodeRow> _flattenTree(Sequence seq) {
    final out = <_NodeRow>[];
    final root = seq.rootNode;
    if (root == null) return out;
    for (final childId in root.childIds) {
      final child = seq.nodes[childId];
      if (child != null) {
        _walk(seq, child, root.id, 0, out);
      }
    }
    return out;
  }

  void _walk(
    Sequence seq,
    SequenceNode node,
    String parentId,
    int depth,
    List<_NodeRow> out,
  ) {
    out.add(_NodeRow(node: node, depth: depth, parentId: parentId));
    for (final childId in node.childIds) {
      final child = seq.nodes[childId];
      if (child != null) {
        _walk(seq, child, node.id, depth + 1, out);
      }
    }
  }

  // Reorder handler.
  //
  // Flutter's `ReorderableListView` reports indices over the flat visible
  // list, which spans multiple parents. A cross-parent move would silently
  // reparent the dragged node, so it is refused with a SnackBar.
  // Within the same parent we translate the flat indices into the
  // parent's child list and call the editor's `reorderNodes`.

  void _handleReorder(
    Sequence sequence,
    List<_NodeRow> rows,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= rows.length) return;

    // `onReorderItem` supplies the destination index after accounting for
    // removal of the source row. The deprecated `onReorder` callback did not,
    // which required a manual moving-down correction and made this easy to
    // double-adjust during Flutter upgrades.
    if (newIndex < 0 || newIndex >= rows.length) return;

    final src = rows[oldIndex];
    final dst = rows[newIndex];

    if (src.parentId != dst.parentId) {
      // Cross-parent moves require a destination picker. Surface the gap
      // instead of guessing — the desktop editor's `moveNode` API is
      // available, but invoking it from a drag-drop without confirmation
      // would change the tree shape silently.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Drag within the same group only. Cross-group moves are not '
            'supported on phone yet — tap to edit instead.',
          ),
        ),
      );
      return;
    }

    final parent = sequence.nodes[src.parentId];
    if (parent == null) return;
    final oldChildIndex = parent.childIds.indexOf(src.node.id);
    final newChildIndex = parent.childIds.indexOf(dst.node.id);
    if (oldChildIndex < 0 || newChildIndex < 0) return;

    try {
      ref
          .read(currentSequenceProvider.notifier)
          .reorderNodes(src.parentId, oldChildIndex, newChildIndex);
    } on SequenceLockedException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot reorder while running: ${e.message}')),
      );
    }
  }

  // Delete with Undo.
  //
  // We capture the full subtree of the doomed node BEFORE calling
  // `removeNode` so undo can restore not just the node itself but its
  // children, parent linkage, and original position within the parent's
  // child list. The undo window is 8 seconds — long enough for a phone
  // user to read the snackbar but short enough that it doesn't pin a
  // stale subtree in memory.

  void _deleteWithUndo(
      BuildContext context, Sequence sequence, SequenceNode node) {
    final snapshot = _captureSubtree(sequence, node.id);
    if (snapshot == null) return;

    try {
      ref.read(currentSequenceProvider.notifier).removeNode(node.id);
    } on SequenceLockedException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot delete while running: ${e.message}')),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Deleted "${node.name}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _restoreSubtree(snapshot),
        ),
      ),
    );
  }

  _SubtreeSnapshot? _captureSubtree(Sequence seq, String rootId) {
    final root = seq.nodes[rootId];
    if (root == null) return null;
    final parentId = root.parentId;
    if (parentId == null) return null;
    final parent = seq.nodes[parentId];
    if (parent == null) return null;
    final originalIndex = parent.childIds.indexOf(rootId);
    if (originalIndex < 0) return null;

    final subtree = <SequenceNode>[];
    void collect(String id) {
      final n = seq.nodes[id];
      if (n == null) return;
      subtree.add(n);
      for (final c in n.childIds) {
        collect(c);
      }
    }

    collect(rootId);

    return _SubtreeSnapshot(
      parentId: parentId,
      indexInParent: originalIndex,
      nodes: subtree,
    );
  }

  void _restoreSubtree(_SubtreeSnapshot snap) {
    final notifier = ref.read(currentSequenceProvider.notifier);
    // Re-add the root at the original parent + index, then re-add the
    // descendants in DFS order. Each node is re-added with its childIds
    // cleared: `addNode` appends the node to its parent's child list with no
    // dedup, so re-adding a node whose childIds still listed its descendants
    // would append each child a second time and duplicate the whole subtree.
    // The DFS re-add rebuilds every parent's childIds exactly once instead.
    final rootNode = snap.nodes.first.copyWith(childIds: const []);
    try {
      notifier.addNode(rootNode,
          parentId: snap.parentId, index: snap.indexInParent);
      for (var i = 1; i < snap.nodes.length; i++) {
        final child = snap.nodes[i].copyWith(childIds: const []);
        final parentId = child.parentId;
        if (parentId == null) continue;
        notifier.addNode(child, parentId: parentId);
      }
    } on SequenceLockedException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot undo while running: ${e.message}')),
      );
    }
  }

  // Properties dialog — opens the same NodePropertiesPanel the desktop
  // sequencer uses on narrow widths. We set selectedNodeIdProvider first
  // so the panel renders the tapped node (it reads `selectedNodeProvider`
  // internally, which derives from selectedNodeIdProvider).

  void _openProperties(BuildContext context, SequenceNode node) {
    ref.read(selectedNodeIdProvider.notifier).state = node.id;
    final colors = SkotiqColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusXl),
        ),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => NodePropertiesPanel(
          colors: colors,
          scrollController: scrollController,
          isMobileSheet: true,
          onClose: () => Navigator.of(sheetCtx).pop(),
        ),
      ),
    );
  }

  // Add-node sheet — reuses the desktop NodePalette in its mobile-sheet
  // mode so the palette stays the single source of truth for "what can be
  // added". Tapping a palette item there already calls
  // `currentSequenceProvider.notifier.addNode(...)` against
  // `selectedNodeIdProvider` (or the root when nothing is selected), then
  // fires `onNodeAdded` so we can close the sheet automatically.

  void _showAddNodeSheet(BuildContext context) {
    final colors = SkotiqColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusXl),
        ),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => NodePalette(
          colors: colors,
          scrollController: scrollController,
          isMobileSheet: true,
          onNodeAdded: () => Navigator.of(sheetCtx).pop(),
        ),
      ),
    );
  }
}

// ROW MODEL + WIDGET

class _NodeRow {
  final SequenceNode node;
  final int depth;
  final String parentId;
  const _NodeRow({
    required this.node,
    required this.depth,
    required this.parentId,
  });
}

class _SubtreeSnapshot {
  final String parentId;
  final int indexInParent;

  /// DFS-ordered list; element 0 is the subtree root.
  final List<SequenceNode> nodes;
  const _SubtreeSnapshot({
    required this.parentId,
    required this.indexInParent,
    required this.nodes,
  });
}

/// Row widget. Wraps a [Dismissible] over a container styled like the
/// desktop `_NodeTile`. The drag handle for reorder is provided by the
/// outer `ReorderableListView` via `buildDefaultDragHandles: true`.
class _MobileNodeRow extends StatelessWidget {
  final _NodeRow row;
  final NodeStatus? status;
  final bool isCurrent;
  final double? progressPct;
  final SkotiqColors colors;
  final bool canEdit;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  const _MobileNodeRow({
    super.key,
    required this.row,
    required this.status,
    required this.isCurrent,
    required this.progressPct,
    required this.colors,
    required this.canEdit,
    required this.onTap,
    required this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _statusVisual(status, isCurrent, colors);

    return Dismissible(
      key: ValueKey('mobile-seq-dismiss-${row.node.id}'),
      direction: DismissDirection.endToStart,
      // While the executor owns the tree, `removeNode` throws and the row
      // must not dismiss — returning false keeps the Dismissible in the tree
      // (a dismissed-but-still-present widget red-screens on the next rebuild).
      confirmDismiss: canEdit
          ? null
          : (_) async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Cannot delete while running')),
              );
              return false;
            },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        margin: EdgeInsets.fromLTRB(16 + row.depth * 16.0, 4, 16, 4),
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        child: Icon(
          LucideIcons.trash2,
          color: Theme.of(context).colorScheme.onError,
          size: 22,
        ),
      ),
      onDismissed: (_) => onDismissed(),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        child: Container(
          margin: EdgeInsets.fromLTRB(16 + row.depth * 16.0, 4, 16, 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: isCurrent
              ? SkotiqDecorations.emphasisSurface(
                  colors.primary,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                )
              : BoxDecoration(
                  color: colors.surface,
                  border: Border.all(color: colors.border),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.node.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: colors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (progressPct != null &&
                        isCurrent &&
                        progressPct! > 0) ...[
                      const SizedBox(height: 4),
                      SkotiqProgressBar(
                        value: (progressPct! / 100.0).clamp(0.0, 1.0),
                        height: 4,
                      ),
                    ],
                  ],
                ),
              ),
              if (!row.node.isEnabled)
                Icon(LucideIcons.eyeOff, size: 14, color: colors.textMuted),
              // Status badge — short text chip mirroring desktop sequencer.
              if (status != null) ...[
                const SizedBox(width: 6),
                _StatusBadge(status: status!, colors: colors),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Mirrors the desktop `_statusVisual` in `sequencer_tab.dart` so the
  /// icon/colour pairing stays in lockstep between phone and desktop.
  (IconData, Color) _statusVisual(
    NodeStatus? s,
    bool isCurrent,
    SkotiqColors c,
  ) {
    if (isCurrent) {
      return (LucideIcons.loader, c.primary);
    }
    return switch (s) {
      NodeStatus.success => (LucideIcons.checkCircle2, c.success),
      NodeStatus.failure => (LucideIcons.xCircle, c.error),
      NodeStatus.running => (LucideIcons.loader, c.primary),
      NodeStatus.skipped => (LucideIcons.skipForward, c.textMuted),
      NodeStatus.cancelled => (LucideIcons.ban, c.warning),
      NodeStatus.pending => (LucideIcons.circle, c.textMuted),
      null => (LucideIcons.circle, c.textMuted),
    };
  }
}

class _StatusBadge extends StatelessWidget {
  final NodeStatus status;
  final SkotiqColors colors;
  const _StatusBadge({required this.status, required this.colors});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      NodeStatus.success => ('Done', colors.success),
      NodeStatus.failure => ('Failed', colors.error),
      NodeStatus.running => ('Running', colors.primary),
      NodeStatus.skipped => ('Skipped', colors.textMuted),
      NodeStatus.cancelled => ('Cancelled', colors.warning),
      NodeStatus.pending => ('Pending', colors.textMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: SkotiqDecorations.tintedBadge(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AddNodeFab extends StatelessWidget {
  final VoidCallback onPressed;
  const _AddNodeFab({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return FloatingActionButton(
      onPressed: onPressed,
      backgroundColor: colors.primary,
      foregroundColor: Theme.of(context).colorScheme.onPrimary,
      tooltip: 'Add node',
      child: const Icon(LucideIcons.plus),
    );
  }
}

// SEQUENCER RECOVERY ACTIONS BANNER (phone variant)

/// Compact phone variant of [RunDashboardRecoveryBanner].
///
/// Behaviour mirrors the desktop banner:
///   * `SizedBox.shrink()` when `currentRecoveryProvider` is `null`.
///   * A `Ticker` rebuilds every ~500ms while in the Waiting phase so the
///     countdown chip stays live without the executor having to publish
///     ProgressUpdated events for the timer alone.
///   * All three operator actions (Try Now / Skip Node / Abort) route
///     through [recoveryControlProvider] so the FFI and network backends
///     stay on the same code path. The Abort button is wrapped in
///     [HoldToConfirmButton] (1500ms) so a stray tap on a phone in the
///     dark can't terminate an overnight run.
class SequencerRecoveryActionsBanner extends ConsumerStatefulWidget {
  const SequencerRecoveryActionsBanner({super.key});

  @override
  ConsumerState<SequencerRecoveryActionsBanner> createState() =>
      _SequencerRecoveryActionsBannerState();
}

class _SequencerRecoveryActionsBannerState
    extends ConsumerState<SequencerRecoveryActionsBanner>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      if ((d - _lastTick).inMilliseconds < 500) return;
      _lastTick = d;
      if (mounted) setState(() {});
    });
    // Not started here — driven from build() by _syncTicker, so the 500 ms
    // rebuild loop is idle whenever there is nothing counting down. An
    // active Ticker schedules a frame on every vsync even when build()
    // returns SizedBox.shrink(), which is exactly the state this banner is
    // in whenever no recovery is running. Matches the desktop twin,
    // run_dashboard/recovery_banner.dart.
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// Start/stop the countdown ticker to match whether a recovery is actually
  /// waiting for its next retry.
  void _syncTicker({required bool needsCountdown}) {
    if (needsCountdown) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
      _lastTick = Duration.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = ref.watch(currentRecoveryProvider);
    _syncTicker(needsCountdown: ctx != null && ctx.isWaiting);
    if (ctx == null) return const SizedBox.shrink();

    final colors = SkotiqColors.of(context);
    final control = ref.read(recoveryControlProvider);
    final now = DateTime.now().toUtc();
    final nextAttemptSecs = ctx.nextAttemptInSecs(now);

    return Container(
      constraints: const BoxConstraints(maxHeight: 80),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.20),
        border: Border(
          top: BorderSide(color: colors.error, width: 1.5),
          bottom: BorderSide(color: colors.error.withValues(alpha: 0.6)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        // SingleChildScrollView on overflow keeps the row usable on the
        // narrowest phones: the cause string can be long, so the row scrolls
        // rather than truncating the recovery actions.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 16, color: colors.error),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  ctx.cause.displayLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _RecoveryChip(
                label: '${ctx.attemptCount}/${ctx.maxAttempts}',
                color: colors.error,
              ),
              const SizedBox(width: 6),
              _RecoveryChip(
                label: ctx.isWaiting
                    ? 'Retry in ${_formatSecs(nextAttemptSecs)}'
                    : ctx.isAttempting
                        ? 'Attempting…'
                        : ctx.isRecovered
                            ? 'Recovered'
                            : 'Gave up',
                color: colors.warning,
              ),
              const SizedBox(width: 8),
              _RecoveryActions(control: control, errorColor: colors.error),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSecs(double s) {
    if (s.isNaN || s.isInfinite || s <= 0) return '0s';
    if (s < 60) return '${s.round()}s';
    final mins = (s / 60).floor();
    final secs = (s - mins * 60).round();
    return secs == 0 ? '${mins}m' : '${mins}m ${secs}s';
  }
}

class _RecoveryChip extends StatelessWidget {
  final String label;
  final Color color;
  const _RecoveryChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: SkotiqDecorations.tintedBadge(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          // Tabular figures keep the countdown from jittering as digits change.
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _RecoveryActions extends StatefulWidget {
  final RecoveryControl control;
  final Color errorColor;

  const _RecoveryActions({required this.control, required this.errorColor});

  @override
  State<_RecoveryActions> createState() => _RecoveryActionsState();
}

class _RecoveryActionsState extends State<_RecoveryActions> {
  bool _tryNowBusy = false;
  bool _skipBusy = false;
  bool _abortBusy = false;

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _tryNow() async {
    if (_tryNowBusy) return;
    setState(() => _tryNowBusy = true);
    try {
      await widget.control.tryNow();
    } catch (e) {
      _showError(extractRecoveryActionError('Retry failed', e));
    } finally {
      if (mounted) setState(() => _tryNowBusy = false);
    }
  }

  Future<void> _skipNode() async {
    if (_skipBusy) return;
    setState(() => _skipBusy = true);
    try {
      await widget.control.skipNode();
    } catch (e) {
      _showError(extractRecoveryActionError('Skip failed', e));
    } finally {
      if (mounted) setState(() => _skipBusy = false);
    }
  }

  Future<void> _abort() async {
    if (_abortBusy) return;
    setState(() => _abortBusy = true);
    try {
      await widget.control.abort();
    } catch (e) {
      _showError(extractRecoveryActionError('Abort failed', e));
    } finally {
      if (mounted) setState(() => _abortBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqButton(
          key: const Key('mobile_recovery_try_now'),
          label: 'Try now',
          icon: LucideIcons.rotateCw,
          size: ButtonSize.small,
          isLoading: _tryNowBusy,
          onPressed: _tryNowBusy ? null : _tryNow,
        ),
        const SizedBox(width: 6),
        SkotiqButton(
          key: const Key('mobile_recovery_skip_node'),
          label: 'Skip',
          icon: LucideIcons.skipForward,
          size: ButtonSize.small,
          variant: ButtonVariant.outline,
          isLoading: _skipBusy,
          onPressed: _skipBusy ? null : _skipNode,
        ),
        const SizedBox(width: 6),
        // Abort: hold-to-confirm so a stray tap can't terminate an
        // overnight run. Inner button stays keyed `mobile_recovery_abort`
        // for parity with the desktop banner's widget-test patterns.
        HoldToConfirmButton(
          key: const Key('mobile_recovery_abort_hold'),
          enabled: !_abortBusy,
          holdColor: widget.errorColor,
          confirmText: 'Hold to abort',
          semanticsLabel: 'Press and hold to abort recovery',
          onConfirmed: _abort,
          child: IgnorePointer(
            child: SkotiqButton(
              key: const Key('mobile_recovery_abort'),
              label: 'Abort',
              icon: LucideIcons.xOctagon,
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              isLoading: _abortBusy,
              onPressed: _abort,
            ),
          ),
        ),
      ],
    );
  }
}
