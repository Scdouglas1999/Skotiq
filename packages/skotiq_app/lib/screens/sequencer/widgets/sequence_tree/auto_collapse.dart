part of '../sequence_tree.dart';

// Auto-collapse to the running branch (spec §4).
//
// The planner is pure: given the sequence, where the run was, where it is now
// and what the user has opened by hand, it says which containers to expand and
// which to fold away. `_SequenceTreeState` owns the two inputs that are not in
// the sequence — the user-expanded set and the follow-execution toggle — and
// applies the plan to `collapsedNodeIdsProvider`.

/// How many containers deep the run's branch is re-opened, and which finished
/// ones are folded away, in one step of the run.
@immutable
class AutoCollapsePlan {
  /// Containers to open because the executing node is inside them.
  final Set<String> toExpand;

  /// Containers to fold away because the run is finished with them.
  final Set<String> toCollapse;

  const AutoCollapsePlan({required this.toExpand, required this.toCollapse});

  static const AutoCollapsePlan empty =
      AutoCollapsePlan(toExpand: <String>{}, toCollapse: <String>{});

  bool get isEmpty => toExpand.isEmpty && toCollapse.isEmpty;
}

/// The ancestors of [nodeId], outermost first.
///
/// The sequence's root container is excluded: it is not a drawn row, so it can
/// neither be pinned nor collapsed. Guards against a malformed parent cycle
/// rather than hanging the UI thread on one.
List<String> sequenceAncestorIds(Sequence sequence, String nodeId) {
  final chain = <String>[];
  final seen = <String>{nodeId};
  var parentId = sequence.nodes[nodeId]?.parentId;
  while (parentId != null && parentId != sequence.rootNodeId) {
    if (!seen.add(parentId)) break;
    chain.add(parentId);
    parentId = sequence.nodes[parentId]?.parentId;
  }
  return chain.reversed.toList(growable: false);
}

/// The moves the tree should make now that the run has reached
/// [currentNodeId].
///
/// [previousNodeId] null means "the run just started": every finished
/// container in the sequence folds away at once. Non-null means the run moved
/// on, and only the containers the run has just LEFT are candidates.
///
/// [userExpanded] is the set of containers the operator opened by hand and
/// that have not run since; nothing in it is ever folded away. [statuses] is
/// `SequenceProgress.nodeStatuses`.
///
/// [followExecution] false returns [AutoCollapsePlan.empty]: the toggle is the
/// operator saying they are driving the canvas, and nothing may move under
/// them while it is off.
AutoCollapsePlan planAutoCollapse({
  required Sequence sequence,
  required String? previousNodeId,
  required String? currentNodeId,
  required Map<String, NodeStatus> statuses,
  required Set<String> collapsed,
  required Set<String> userExpanded,
  required bool followExecution,
}) {
  if (!followExecution) return AutoCollapsePlan.empty;
  if (currentNodeId == null) return AutoCollapsePlan.empty;
  if (!sequence.nodes.containsKey(currentNodeId)) return AutoCollapsePlan.empty;

  final ancestors = sequenceAncestorIds(sequence, currentNodeId);
  final onBranch = <String>{...ancestors, currentNodeId};

  final completeCache = <String, bool>{};
  bool isComplete(String id) => _isSubtreeComplete(
        sequence,
        statuses,
        id,
        completeCache,
        <String>{},
      );

  final Iterable<String> candidates;
  if (previousNodeId == null) {
    candidates = sequence.nodes.keys;
  } else {
    candidates = <String>[
      ...sequenceAncestorIds(sequence, previousNodeId),
      previousNodeId,
    ];
  }

  // A container is shielded when it — or anything it sits inside — is already
  // collapsed (there is nothing on screen left to fold) or was opened by the
  // operator (they asked to see what is in there, and gutting it one level
  // down answers a question they did not ask).
  bool isShielded(String id) {
    if (collapsed.contains(id) || userExpanded.contains(id)) return true;
    return sequenceAncestorIds(sequence, id).any(
      (ancestorId) =>
          collapsed.contains(ancestorId) || userExpanded.contains(ancestorId),
    );
  }

  final folding = <String>{};
  for (final id in candidates) {
    if (id == sequence.rootNodeId) continue;
    if (onBranch.contains(id)) continue;
    if (isShielded(id)) continue;
    final node = sequence.nodes[id];
    if (node == null || !isSequenceContainer(node)) continue;
    if (!isComplete(id)) continue;
    folding.add(id);
  }

  return AutoCollapsePlan(
    toExpand: <String>{
      for (final id in ancestors)
        if (collapsed.contains(id)) id,
    },
    // Folding a container that sits INSIDE another container we are folding
    // changes nothing on screen now, and surprises the operator later: they
    // open the outer one and find its contents collapsed for no reason they
    // took part in.
    toCollapse: <String>{
      for (final id in folding)
        if (!sequenceAncestorIds(sequence, id).any(folding.contains)) id,
    },
  );
}

/// Whether the run is finished with [nodeId] — the same question
/// [planAutoCollapse] asks before folding a container away, answered for one
/// node so callers outside the planner can ask it too.
///
/// `_SequenceTreeState` uses it to decide whether a manual expansion is worth
/// remembering: a container the operator opens AFTER it has finished is being
/// read, not held open for the run, and recording it would shield a finished
/// branch from every later fold.
bool isSubtreeComplete(
  Sequence sequence,
  Map<String, NodeStatus> statuses,
  String nodeId,
) =>
    _isSubtreeComplete(
        sequence, statuses, nodeId, <String, bool>{}, <String>{});

/// Whether the run is finished with [nodeId].
///
/// A node is finished when its own status says so. A container is ALSO
/// finished when every child of it is: the executor reports container
/// completion through the same `NodeCompleted` events as leaves, but a
/// container whose last child finished is done whether or not its own event
/// has landed yet, and the branch it holds should not stay open waiting for a
/// message that adds nothing.
bool _isSubtreeComplete(
  Sequence sequence,
  Map<String, NodeStatus> statuses,
  String nodeId,
  Map<String, bool> cache,
  Set<String> visiting,
) {
  final cached = cache[nodeId];
  if (cached != null) return cached;
  // A parent cycle would otherwise recurse forever; treat the revisit as
  // "not finished" so a malformed sequence collapses nothing.
  if (!visiting.add(nodeId)) return false;

  final status = statuses[nodeId];
  final result = switch (status) {
    NodeStatus.success || NodeStatus.skipped || NodeStatus.cancelled => true,
    // A FAILED branch stays open — it is the one outcome the operator has to
    // look at — and a RUNNING one is by definition not finished.
    NodeStatus.failure || NodeStatus.running => false,
    NodeStatus.pending || null => _allChildrenComplete(
        sequence,
        statuses,
        nodeId,
        cache,
        visiting,
      ),
  };

  visiting.remove(nodeId);
  cache[nodeId] = result;
  return result;
}

/// Whether [nodeId] holds children and the run is finished with every one.
bool _allChildrenComplete(
  Sequence sequence,
  Map<String, NodeStatus> statuses,
  String nodeId,
  Map<String, bool> cache,
  Set<String> visiting,
) {
  final childIds = sequence.nodes[nodeId]?.childIds ?? const <String>[];
  if (childIds.isEmpty) return false;
  return childIds.every(
    (childId) =>
        _isSubtreeComplete(sequence, statuses, childId, cache, visiting),
  );
}
