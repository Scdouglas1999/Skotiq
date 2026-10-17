import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart';
import '../../services/sequence_time_estimator.dart';
import '../sequence_provider.dart' show currentSequenceProvider;
import 'sequencer_defaults.dart' show sequencerOverheadConfigProvider;

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
  return map[nodeId] ?? Duration.zero;
});

/// Single memoized post-order DFS over the current sequence producing every
/// node's rolled-up [Duration] in one pass. Each node is computed exactly
/// once and its child results are reused by its parent, so the whole map is
/// O(N) per edit instead of O(N) per node. Recomputes once whenever
/// [currentSequenceProvider] changes (sequence identity).
final _nodeRollupMapProvider = Provider<Map<String, Duration>>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return const <String, Duration>{};
  // ONE engine and ONE overhead model, shared with the timeline, the node
  // timing panel and the pre-flight simulation. A second per-node cost table
  // here would let the Builder's estimate chip and the Pre-Flight "Duration"
  // disagree about the same sequence.
  final estimator = SequenceTimeEstimator(
    overhead: ref.watch(sequencerOverheadConfigProvider),
  );
  final secsById = <String, double>{};
  if (sequence.rootNodeId != null) {
    _computeRollupSecs(sequence, sequence.rootNodeId!, estimator, secsById);
  }
  // Compute any node not reached from the root (detached subtrees, or the
  // no-root case) so every tree row still gets its own value — matching the
  // pre-memoization behaviour where the family computed each id on demand.
  // Already-computed nodes short-circuit via the cache inside the walk.
  for (final id in sequence.nodes.keys) {
    if (!secsById.containsKey(id)) {
      _computeRollupSecs(sequence, id, estimator, secsById);
    }
  }
  return secsById.map(
    (id, secs) => MapEntry(id, Duration(seconds: secs.round())),
  );
});

/// Format helper used by the tree row + tests. Public so test code can
/// assert on the exact string the tree shows.
///
/// Output: "~2h 14m", "~14m 30s", "~30s", "<1s". Always prefixed with `~`
/// because these are estimates.
String formatRollupDuration(Duration d) {
  final totalSecs = d.inSeconds;
  if (totalSecs <= 0) return '<1s';
  final hours = totalSecs ~/ 3600;
  final minutes = (totalSecs % 3600) ~/ 60;
  final seconds = totalSecs % 60;
  if (hours > 0) {
    return '~${hours}h ${minutes}m';
  }
  if (minutes > 0) {
    return '~${minutes}m ${seconds}s';
  }
  return '~${seconds}s';
}

/// Single memoizing post-order walk that returns the rolled-up duration *in
/// seconds* for [nodeId] AND records every node it visits into [out]. Each
/// node is computed once: the first time it is reached the result is stored
/// in [out]; subsequent reaches (shared ids are not expected in a tree, but
/// the guard makes the walk idempotent) reuse the cached value.
///
/// A tree-wide total is not enough here: every container row needs its own
/// value during a single render pass. The per-node cost itself comes from
/// [SequenceTimeEstimator.nodeDuration] — the same model the timeline and the
/// pre-flight simulation bill against — so the numbers agree by construction
/// rather than by two tables being kept in sync by hand.
double _computeRollupSecs(
  Sequence sequence,
  String nodeId,
  SequenceTimeEstimator estimator,
  Map<String, double> out,
) {
  final cached = out[nodeId];
  if (cached != null) return cached;

  final node = sequence.nodes[nodeId];
  if (node == null || !node.isEnabled) {
    out[nodeId] = 0;
    return 0;
  }

  // Compute child rollups first; we use them for every container shape.
  // Each child writes its own value into [out] as a side effect.
  final childSecs = <double>[];
  double childSum = 0;
  for (final childId in node.childIds) {
    final s = _computeRollupSecs(sequence, childId, estimator, out);
    childSecs.add(s);
    childSum += s;
  }
  final childMax = childSecs.isEmpty
      ? 0.0
      : childSecs.reduce((a, b) => a > b ? a : b);

  // The node's own cost, children excluded. Exposure / SmartExposure /
  // SciencePhotometry leaves get their full capture cost here; containers get
  // zero and are carried entirely by [childSum] / [childMax] below.
  final selfOverhead = estimator.nodeDuration(node).inMilliseconds / 1000.0;

  final double result;
  if (node is LoopNode) {
    result = switch (node.conditionType) {
      LoopConditionType.count =>
        selfOverhead + (childSum * (node.repeatCount ?? 1)),
      // We don't have a reference time here; reuse the Sequence-level
      // estimator's logic to get fittable iterations. Falling back to
      // single-iteration when the deadline is in the past matches
      // _estimateNodeIntegration().
      LoopConditionType.untilTime => _untilTimeRollup(
        node,
        childSum,
        selfOverhead,
      ),
      LoopConditionType.integrationTime => _integrationTimeRollup(
        sequence,
        node,
        childSum,
        selfOverhead,
      ),
      // Unbounded: report a single iteration. Marking this as "~∞" would be
      // more honest but the tree row already shows the loop condition; the
      // duration column reads as per-iteration cost.
      LoopConditionType.forever ||
      LoopConditionType.whileDark ||
      LoopConditionType.untilAltitude ||
      LoopConditionType.altitudeAbove => selfOverhead + childSum,
    };
  } else if (node is ParallelNode) {
    // Children run concurrently. Wall-clock cost is the slowest child
    // (plus any self-overhead, though Parallel has none today).
    result = selfOverhead + childMax;
  } else {
    // TargetHeaderNode, InstructionSetNode, ConditionalNode, RecoveryNode,
    // and any other container: sum.
    result = selfOverhead + childSum;
  }

  out[nodeId] = result;
  return result;
}

/// untilTime loop rollup: fit as many child iterations as the deadline
/// allows (single iteration when the deadline is in the past / unset).
double _untilTimeRollup(LoopNode node, double childSum, double selfOverhead) {
  if (node.repeatUntil != null && childSum > 0) {
    final availableSecs = node.repeatUntil!
        .difference(DateTime.now())
        .inSeconds
        .toDouble();
    if (availableSecs > 0) {
      final iters = (availableSecs / childSum).floor();
      return selfOverhead + (childSum * iters);
    }
  }
  return selfOverhead + childSum;
}

/// integrationTime loop rollup: iterate until the target integration time is
/// met, mirroring `_estimateNodeIntegration` so the numbers agree.
double _integrationTimeRollup(
  Sequence sequence,
  LoopNode node,
  double childSum,
  double selfOverhead,
) {
  if (node.integrationTimeTarget != null &&
      node.integrationTimeTarget! > 0 &&
      childSum > 0) {
    double exposurePerIteration = 0;
    for (final childId in node.childIds) {
      final c = sequence.nodes[childId];
      if (c is ExposureNode && c.isEnabled) {
        exposurePerIteration += c.totalDurationSecs;
      }
    }
    if (exposurePerIteration > 0) {
      final iters = (node.integrationTimeTarget! / exposurePerIteration).ceil();
      return selfOverhead + (childSum * iters);
    }
  }
  return selfOverhead + childSum;
}
