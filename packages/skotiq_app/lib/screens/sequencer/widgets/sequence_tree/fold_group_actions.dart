// Every mutation a folded row offers (spec §6): move the run as a block,
// duplicate it, disable it, delete it.
//
// Move, duplicate and disable live here; DELETE lives with the single-node
// delete in `delete_node_confirmation.dart`, because the one thing a delete
// has to be consistent about is how it asks.
//
// A separate library rather than a `part` of `sequence_tree.dart` because
// `sequence_tree_context_menu.dart` is its own library and has to reach the
// same operations — the right-click menu on a folded row must not be able to
// drift from the kebab on the same row.
//
// Every entry point shares one shape: `withSequenceMutation` so a locked
// sequence surfaces a snackbar instead of an uncaught throw, and
// `withUndoGroup` INSIDE it so the N `moveNode` / `duplicateNode` /
// `toggleNodeEnabled` calls a group needs collapse into a single undo entry.
// Without the group, undoing a three-member move would take three Ctrl+Z and
// pass through two states the user never asked for.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../../utils/sequence_mutator_helper.dart';
import '../../sequence_fold_model.dart';

/// Move [memberIds] under [parentId] so the run lands as one contiguous block
/// starting at [index], in one undo step.
///
/// [index] is interpreted exactly as the single-node drop interprets it: the
/// FIRST member goes where a lone `moveNode` of that member would have put it,
/// and every following member is then re-inserted directly after the one
/// before it. `index + k` is only correct when the block changes parent —
/// inside its own parent, removing a member shifts every later slot left, and
/// the run would end up reversed or scattered.
Future<bool> moveFoldGroup(
  BuildContext context,
  WidgetRef ref, {
  required List<String> memberIds,
  required String parentId,
  required int index,
}) {
  return withSequenceMutation(
    context,
    ref,
    operationName: 'move the folded steps',
    action: () async {
      ref.read(currentSequenceProvider.notifier).withUndoGroup(() {
        _relocateBlock(ref,
            memberIds: memberIds, parentId: parentId, index: index);
      });
    },
  );
}

/// Copy every member of the run and leave the copies as a second contiguous
/// block immediately after the original, in one undo step.
///
/// `duplicateNode` inserts each copy directly after ITS original, so calling
/// it member by member interleaves the two runs (`Ha Ha' OIII OIII' …`) —
/// which folds back into one six-member group and reads as a single run with
/// every filter doubled. The copies are collected and relocated as a block so
/// the result is what the user asked for: the same run, twice.
Future<bool> duplicateFoldGroup(
  BuildContext context,
  WidgetRef ref, {
  required FoldGroup group,
}) {
  return withSequenceMutation(
    context,
    ref,
    operationName: 'duplicate the folded steps',
    action: () async {
      final notifier = ref.read(currentSequenceProvider.notifier);
      notifier.withUndoGroup(() {
        final copies = <String>[];
        for (final memberId in group.memberIds) {
          notifier.duplicateNode(memberId);
          final siblings = ref
              .read(currentSequenceProvider)!
              .nodes[group.parentId]!
              .childIds;
          copies.add(siblings[siblings.indexOf(memberId) + 1]);
        }
        final siblings =
            ref.read(currentSequenceProvider)!.nodes[group.parentId]!.childIds;
        _relocateBlock(
          ref,
          memberIds: copies,
          parentId: group.parentId,
          index: siblings.indexOf(group.memberIds.last) + 1,
        );
      });
    },
  );
}

/// Disable every member of the run in one undo step.
///
/// A folded group is all-enabled by construction — `foldChildren` refuses a
/// disabled node as a run member — so a toggle over the members is a disable,
/// and the row only ever offers that direction. Once disabled the members stop
/// qualifying as a run, so the fold row is replaced by its (struck-through)
/// member rows on the next build.
Future<bool> disableFoldGroup(
  BuildContext context,
  WidgetRef ref, {
  required List<String> memberIds,
}) {
  return withSequenceMutation(
    context,
    ref,
    operationName: 'disable the folded steps',
    action: () async {
      final notifier = ref.read(currentSequenceProvider.notifier);
      notifier.withUndoGroup(() {
        for (final memberId in memberIds) {
          notifier.toggleNodeEnabled(memberId);
        }
      });
    },
  );
}

/// Re-seat [memberIds] as a contiguous, ordered block starting at [index].
/// See [moveFoldGroup] for why the followers chase their predecessor instead
/// of taking `index + k`.
void _relocateBlock(
  WidgetRef ref, {
  required List<String> memberIds,
  required String parentId,
  required int index,
}) {
  final notifier = ref.read(currentSequenceProvider.notifier);
  notifier.moveNode(memberIds.first, parentId, index);
  for (var k = 1; k < memberIds.length; k++) {
    final siblings =
        ref.read(currentSequenceProvider)!.nodes[parentId]!.childIds;
    final target = siblings.indexOf(memberIds[k - 1]);
    final here = siblings.indexOf(memberIds[k]);
    // `moveNode` REMOVES before it inserts, so the index it takes is an index
    // into the list without this member in it. A member still sitting above
    // its predecessor vacates a slot above it, pulling the predecessor down to
    // `target - 1` — so "directly after the predecessor" is `target`, not
    // `target + 1`. Adding one anyway overshoots by a slot per follower, which
    // is how a three-member block moved down one place came out as
    // `Y · A · C · B` instead of `Y · A · B · C`.
    final alreadyAbove = here >= 0 && here < target;
    notifier.moveNode(
        memberIds[k], parentId, alreadyAbove ? target : target + 1);
  }
}
