import 'package:skotiq_astro/format.dart';

import '../models/sequence/sequence_models.dart';
import 'sequence_time_estimator.dart';

/// What ends a node whose length the estimate cannot give: a "loop until
/// stopped" Smart Exposure with no budget, when there is no site to solve its
/// target's window from (or nothing in the window ends it), and every
/// container above one.
enum NodeOpenEnd {
  /// Its target's end condition stops it.
  targetWindow,

  /// Only the operator, or the dawn park, stops it.
  stopped,
}

/// Every node's rolled-up length, and why a node has none.
class NodeRollups {
  const NodeRollups(this.durations, this.openEnds);

  final Map<String, Duration> durations;
  final Map<String, NodeOpenEnd> openEnds;

  static const empty = NodeRollups(
    <String, Duration>{},
    <String, NodeOpenEnd>{},
  );
}

/// The plan walked tonight from now, at the site: what each leaf takes once
/// the targets' start and end conditions and the dawn park are applied.
class _TimedWalk {
  _TimedWalk(List<NodeTiming> timings) {
    for (final timing in timings) {
      leaf.putIfAbsent(timing.nodeId, () => timing);
    }
  }

  /// The first estimated pass of each node the walk reached. A node with a
  /// length of its own that is missing was skipped: its target's window had
  /// closed, or the target does not run tonight.
  final Map<String, NodeTiming> leaf = <String, NodeTiming>{};
}

/// Every node's rolled-up length in [sequence], in one memoized post-order
/// walk. With [tonight] (the sequence walked from now at the site), a node's
/// own cost is what that walk gives it; without it, a "loop until stopped"
/// block cannot be bounded and is marked open-ended.
NodeRollups computeNodeRollups(
  Sequence sequence,
  SequenceTimeEstimator estimator, {
  List<NodeTiming>? tonight,
}) {
  final walk = tonight == null ? null : _TimedWalk(tonight);
  final secsById = <String, double>{};
  final openEnds = <String, NodeOpenEnd>{};
  if (sequence.rootNodeId != null) {
    _computeRollupSecs(
      sequence,
      sequence.rootNodeId!,
      estimator,
      secsById,
      openEnds: openEnds,
      walk: walk,
    );
  }
  // Compute any node not reached from the root (detached subtrees, or the
  // no-root case) so every tree row still gets its own value — matching the
  // pre-memoization behaviour where the family computed each id on demand.
  // Already-computed nodes short-circuit via the cache inside the walk.
  for (final id in sequence.nodes.keys) {
    if (!secsById.containsKey(id)) {
      _computeRollupSecs(
        sequence,
        id,
        estimator,
        secsById,
        openEnds: openEnds,
        walk: walk,
      );
    }
  }
  return NodeRollups(
    secsById.map((id, secs) => MapEntry(id, Duration(seconds: secs.round()))),
    openEnds,
  );
}

/// A rolled-up length as a row shows it: "~2h 14m", or what ends it when it
/// has no length ("until target ends", "until stopped").
String formatNodeRollup(Duration duration, NodeOpenEnd? openEnd) =>
    switch (openEnd) {
      NodeOpenEnd.targetWindow => 'until target ends',
      NodeOpenEnd.stopped => 'until stopped',
      null => formatRollupDuration(duration),
    };

/// The whole plan's estimated length in seconds, by the same model the
/// Builder's rollup uses: the root's rollup, or every top-level node's when
/// the plan has no root. Zero for a plan with a block that loops until its
/// target's window closes: a saved plan's length cannot depend on one night's
/// sky, and one rotation (or the per-filter counts) is not its length.
double sequenceRollupSecs(
  Sequence sequence, {
  SequenceTimeEstimator estimator = const SequenceTimeEstimator(),
}) {
  final out = <String, double>{};
  final openEnds = <String, NodeOpenEnd>{};
  final rootId = sequence.rootNodeId;
  final roots = rootId != null && sequence.nodes.containsKey(rootId)
      ? [rootId]
      : [
          for (final node in sequence.nodes.values)
            if (node.parentId == null) node.id,
        ];
  var total = 0.0;
  for (final id in roots) {
    total += _computeRollupSecs(
      sequence,
      id,
      estimator,
      out,
      openEnds: openEnds,
    );
    if (openEnds.containsKey(id)) return 0;
  }
  return total;
}

/// Format helper used by the tree row + tests. Public so test code can
/// assert on the exact string the tree shows.
///
/// Output: "~2h 14m", "~14m 30s", "~30s", "<1s". Always prefixed with `~`
/// because these are estimates.
String formatRollupDuration(Duration d) => d.inSeconds <= 0
    ? '<1s'
    : '~${DurationFormat.of(d, style: DurationStyle.short)}';

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
  Map<String, double> out, {
  Map<String, NodeOpenEnd>? openEnds,
  _TimedWalk? walk,
}) {
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
  NodeOpenEnd? openEnd;
  for (final childId in node.childIds) {
    final s = _computeRollupSecs(
      sequence,
      childId,
      estimator,
      out,
      openEnds: openEnds,
      walk: walk,
    );
    childSecs.add(s);
    childSum += s;
    // "Until stopped" outranks "until target ends" on the way up.
    final childEnd = openEnds?[childId];
    if (childEnd != null && openEnd != NodeOpenEnd.stopped) openEnd = childEnd;
  }
  final childMax = childSecs.isEmpty
      ? 0.0
      : childSecs.reduce((a, b) => a > b ? a : b);

  // The node's own cost, children excluded. Exposure / SmartExposure /
  // SciencePhotometry leaves get their full capture cost here; containers get
  // zero and are carried entirely by [childSum] / [childMax] below.
  var selfOverhead = estimator.nodeDuration(node).inMilliseconds / 1000.0;
  if (walk != null && selfOverhead > 0 && node.childIds.isEmpty) {
    // Tonight's walk knows what the sky does to this step: a closed window
    // skips it, and a window cuts a Smart Exposure short.
    final timing = walk.leaf[node.id];
    selfOverhead = timing == null ? 0 : timing.duration.inMilliseconds / 1000.0;
    if (timing != null && timing.openEnded) {
      openEnd = _openEndOf(sequence, node);
    }
  } else if (walk == null &&
      node is SmartExposureNode &&
      node.loopUntilStopped &&
      node.integrationBudgetSecs <= 0) {
    openEnd = _openEndOf(sequence, node);
  }
  if (openEnd != null) openEnds?[nodeId] = openEnd;

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

/// What ends an open-ended [node]: the end condition of the target it runs
/// under, or nothing but a stop.
NodeOpenEnd _openEndOf(Sequence sequence, SequenceNode node) {
  String? parentId = node.parentId;
  while (parentId != null) {
    final parent = sequence.nodes[parentId];
    if (parent is TargetHeaderNode) {
      final ends =
          parent.endWhen != null ||
          parent.endBefore != null ||
          parent.maxAltitude != null;
      return ends ? NodeOpenEnd.targetWindow : NodeOpenEnd.stopped;
    }
    parentId = parent?.parentId;
  }
  return NodeOpenEnd.stopped;
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
