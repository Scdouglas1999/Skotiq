import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart';
import '../../services/sequence_rollup.dart';
import '../sequence_provider.dart' show currentSequenceProvider;
import 'plan_timer_provider.dart';

/// Per-node estimated *integration + overhead* roll-up.
///
/// The sequencer tree shows a "~2h 14m" hint next to container rows
/// (Loop, Target, Parallel, Sequential / generic container). This file
/// produces those rolled-up [Duration] values without recomputing the
/// whole tree on every widget rebuild.
///
/// Semantics by node type:
///
///   * [TargetHeaderNode]      — sum of children durations.
///   * [LoopNode] (count)      — sum(children) * repeatCount.
///   * [LoopNode] (untilTime)  — sum(children) * fittable_iterations
///                               (uses the [Sequence] estimator output).
///   * [LoopNode] (unbounded)  — single-iteration duration (best we can do
///                               without a future end-time anchor).
///   * [ParallelNode]          — max(children).
///   * [InstructionSetNode]    — sum(children).
///   * any other container     — sum(children).
///   * leaf [ExposureNode]     — totalDurationSecs + per-exposure download
///                               overhead.
///   * other leaves            — per-node overhead from [SequenceOverheadConfig].
///
/// Disabled nodes contribute 0 — matching the executor's behaviour.
///
/// The family reads its id out of [_nodeRollupMapProvider], which computes the
/// WHOLE tree's rollup in one cached post-order DFS, so painting an N-node tree
/// is O(N) rather than O(N^2). A change to [currentSequenceProvider]
/// invalidates the whole family: every node's cached value must clear together,
/// because a stale roll-up deeper in the tree is a silent wrong answer.
final nodeRollupDurationProvider = Provider.family<Duration, String>((
  ref,
  nodeId,
) {
  final map = ref.watch(_nodeRollupMapProvider);
  return map.durations[nodeId] ?? Duration.zero;
});

/// Why [nodeId]'s rolled-up length is not a number, or null when it is.
/// A row shows [formatNodeRollup] rather than a count of one rotation.
final nodeRollupOpenEndProvider = Provider.family<NodeOpenEnd?, String>((
  ref,
  nodeId,
) {
  return ref.watch(_nodeRollupMapProvider).openEnds[nodeId];
});

/// Single memoized post-order DFS over the current sequence producing every
/// node's rolled-up [Duration] in one pass. Each node is computed exactly
/// once and its child results are reused by its parent, so the whole map is
/// O(N) per edit instead of O(N) per node. Recomputes once whenever
/// [currentSequenceProvider] changes (sequence identity).
///
/// With a site, a node's own cost is what tonight's timed walk gives it, so a
/// "loop until stopped" block lasts until its target's window closes (or the
/// dawn park), and the steps a closed window skips cost nothing. Without one,
/// such a block cannot be bounded and is marked open-ended instead of billed
/// as its per-filter counts.
final _nodeRollupMapProvider = Provider<NodeRollups>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return NodeRollups.empty;
  final timer = ref.watch(planTimerProvider);
  return computeNodeRollups(
    sequence,
    timer.estimator,
    tonight: timer.site == null
        ? null
        : ref.watch(currentPlanTimingProvider)?.timings,
  );
});
