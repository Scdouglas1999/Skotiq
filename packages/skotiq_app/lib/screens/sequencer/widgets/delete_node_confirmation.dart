import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/sequence_mutator_helper.dart';
import '../sequence_fold_model.dart';

/// Canonical confirmation + delete helper for sequencer nodes.
///
/// Every user-initiated delete path in the sequencer MUST funnel through this
/// file so the confirmation policy stays consistent: it always prompts, even
/// on leaves, and the wording adapts to the count. Without it a misclick can
/// take an entire target subtree silently. A folded run of steps (spec §6) is
/// deleted as a unit through [confirmAndDeleteFoldGroup] below, which is the
/// same policy asked once for the whole run.
///
/// Returns `true` iff the user confirmed AND the underlying remove completed
/// without throwing.
///
/// IMPORTANT: this helper is for USER-INITIATED deletes only. Do not call it
/// from programmatic flows (import dialogs rejecting a node, undo/redo,
/// executor cleanup, …) — those should call
/// [CurrentSequenceNotifier.removeNode] directly so they don't bounce the user
/// through an irrelevant prompt.
Future<bool> confirmAndDeleteSequenceNode({
  required BuildContext context,
  required WidgetRef ref,
  required String nodeId,
  SkotiqColors? colors,
}) async {
  final sequence = ref.read(currentSequenceProvider);
  if (sequence == null) return false;
  final node = sequence.nodes[nodeId];
  if (node == null) return false;

  final descendants = sequence.countDescendants(nodeId);
  final resolvedColors = colors ?? SkotiqColors.of(context);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: resolvedColors.surface,
      title: Text(
        'Delete "${node.name}"?',
        style: TextStyle(color: resolvedColors.textPrimary),
      ),
      content: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          dialogContext,
          designMaxWidth: 440,
        ),
        child: Text(
          // Name the toolbar button first. Ctrl+Z is real but needs keyboard
          // focus inside the builder; the toolbar Undo always works, and a
          // recovery instruction that only sometimes applies is worse than
          // none.
          descendants == 0
              ? 'This node will be removed from the sequence. '
                  'Recover it with Undo in the toolbar (or Ctrl+Z).'
              : descendants == 1
                  ? 'This will also remove its 1 descendant. '
                      'Recover it with Undo in the toolbar (or Ctrl+Z).'
                  : 'This will also remove its $descendants descendants. '
                      'Recover it with Undo in the toolbar (or Ctrl+Z).',
          style: TextStyle(color: resolvedColors.textSecondary),
        ),
      ),
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          label: 'Delete',
          variant: ButtonVariant.destructive,
          size: ButtonSize.small,
        ),
      ],
    ),
  );

  if (confirmed != true) return false;

  try {
    ref.read(currentSequenceProvider.notifier).removeNode(nodeId);
  } catch (error) {
    // Surface the failure rather than swallowing it: the node stays in the
    // tree, so a silent catch leaves the user believing it was deleted.
    // SequenceLockedException is the expected case (the sequence started
    // running between dialog open and confirm).
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete "${node.name}": $error'),
          backgroundColor: resolvedColors.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
    return false;
  }

  // Clear stale selection so the Properties panel doesn't redraw on a
  // node that no longer exists.
  if (ref.read(selectedNodeIdProvider) == nodeId) {
    ref.read(selectedNodeIdProvider.notifier).state = null;
  }
  return true;
}

/// Confirm once, then delete every member of the run in one undo step.
///
/// The run-shaped half of this file's policy, beside the single-node half so
/// the two cannot drift: always prompt (even though every member is a leaf),
/// say how much is going, and name the toolbar's Undo as the way back. It is a
/// separate entry point rather than a loop over
/// [confirmAndDeleteSequenceNode] because that one asks PER NODE, and three
/// dialogs for one row is exactly the question spec §6 says to ask once.
///
/// Returns true iff the user confirmed AND the removal completed.
Future<bool> confirmAndDeleteFoldGroup({
  required BuildContext context,
  required WidgetRef ref,
  required FoldGroup group,
  SkotiqColors? colors,
}) async {
  final sequence = ref.read(currentSequenceProvider);
  if (sequence == null) return false;
  final resolvedColors = colors ?? SkotiqColors.of(context);
  final count = group.memberCount;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: resolvedColors.surface,
      title: Text(
        'Delete $count steps?',
        style: TextStyle(color: resolvedColors.textPrimary),
      ),
      content: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          dialogContext,
          designMaxWidth: 440,
        ),
        child: Text(
          // The member labels, not the group's title: "Ha · OIII · SII" is
          // what the row shows, and a delete prompt has to name the same
          // things the row named.
          '${group.memberLabels.join(' · ')} will be removed from the '
          'sequence. Recover them with Undo in the toolbar (or Ctrl+Z).',
          style: TextStyle(color: resolvedColors.textSecondary),
        ),
      ),
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          label: 'Delete',
          variant: ButtonVariant.destructive,
          size: ButtonSize.small,
        ),
      ],
    ),
  );

  if (confirmed != true) return false;
  if (!context.mounted) return false;

  final removed = await withSequenceMutation(
    context,
    ref,
    operationName: 'delete the folded steps',
    action: () async {
      final notifier = ref.read(currentSequenceProvider.notifier);
      notifier.withUndoGroup(() {
        for (final memberId in group.memberIds) {
          notifier.removeNode(memberId);
        }
      });
    },
  );
  if (!removed) return false;

  // The members are gone; a selection still pointing at one of them would
  // redraw the properties panel on a node that no longer exists.
  ref.read(multiSelectedNodeIdsProvider.notifier).clear();
  if (group.memberIds.contains(ref.read(selectedNodeIdProvider))) {
    ref.read(selectedNodeIdProvider.notifier).state = null;
  }
  return true;
}
