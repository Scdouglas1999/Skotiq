import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../../utils/sequence_mutator_helper.dart';
import '../sequence_fold_model.dart';
import 'sequence_tree/fold_group_actions.dart';
import 'target_queue_panel.dart';

/// Whether the sequence tree takes [data] when it is dropped on it.
bool isTreeDropPayload(Object? data) =>
    data is NodePaletteItem ||
    data is TemplateSnippet ||
    data is TargetQueueDragPayload ||
    data is FoldDragPayload ||
    data is String;

/// Put [payload] into the tree at [parentId] / [index], the one path every
/// palette, drop zone and menu uses.
///
/// A palette item, a queued target or a snippet goes in as one undo step,
/// into a new sequence when none is open, and a new step becomes the
/// selection. A dragged step (its node id) or a folded run of steps moves;
/// a move needs both [parentId] and [index]. Nothing changes while a run owns
/// the tree. Returns whether a new step went in.
bool insertIntoTree(
  BuildContext context,
  WidgetRef ref,
  Object payload, {
  String? parentId,
  int? index,
}) {
  final editor = ref.read(currentSequenceProvider.notifier);

  bool insertNew(SequenceNode node, [List<SequenceNode> children = const []]) {
    final inserted = editor.insertNewNode(
      node,
      children: children,
      parentId: parentId,
      index: index,
    );
    if (inserted) ref.read(selectedNodeIdProvider.notifier).state = node.id;
    return inserted;
  }

  switch (payload) {
    case NodePaletteItem item:
      return insertNew(item.createNode(), item.createChildren?.call() ?? []);
    case TargetQueueDragPayload queued:
      return insertNew(queued.node);
    case TemplateSnippet snippet:
      insertSnippetGuarded(
        context,
        ref,
        snippet,
        parentId: parentId,
        index: index,
      );
    case FoldDragPayload fold when parentId != null && index != null:
      moveFoldGroup(
        context,
        ref,
        memberIds: fold.memberIds,
        parentId: parentId,
        index: index,
      );
    case String nodeId when parentId != null && index != null:
      editor.moveNode(nodeId, parentId, index);
  }
  return false;
}

/// Insert [snippet] through [withSequenceMutation], so a locked tree or a
/// node type this build does not know surfaces as a message instead of an
/// uncaught throw.
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
    operationName: 'insert snippet',
    action: () async {
      ref
          .read(currentSequenceProvider.notifier)
          .insertSnippet(
            snippet,
            parentId: parentId,
            index: index,
            profileFilterNames: profile?.filterNames,
          );
    },
  );
}
