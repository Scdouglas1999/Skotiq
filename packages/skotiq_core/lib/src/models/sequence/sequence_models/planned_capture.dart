part of '../sequence_models.dart';

/// How many frames a step takes each time it runs, and how long they expose.
/// Every surface that quotes a frame count reads these (through
/// [plannedCaptureUnder] when loops are involved), so the tree, the totals,
/// pre-flight and progress agree.
///
/// A Smart Exposure looping until stopped has no count: the run ignores its
/// per-filter counts and reports no total, so it contributes nothing here
/// and says so through [capturesUntilStopped].
extension NodeFrames on SequenceNode {
  int get framesPerPass =>
      kind.captures(this).fold(0, (sum, run) => sum + run.count);

  double get integrationSecsPerPass => kind
      .captures(this)
      .fold(0, (sum, run) => sum + run.exposureSecs * run.count);

  bool get capturesUntilStopped {
    final node = this;
    return node is SmartExposureNode && node.loopUntilStopped;
  }
}

/// What a subtree plans to capture.
///
/// A `count` loop multiplies its subtree by its repeat count. Every other
/// loop keeps the single-pass figure (a total is never unbounded) and sets
/// [hasUnboundedRepeat], so a caller can say the figure is a per-pass floor.
/// Disabled steps contribute nothing.
class PlannedCapture {
  /// Frames with a known, bounded count (loop multipliers applied).
  final int frames;

  /// Integration seconds for those frames (loop multipliers applied).
  final double integrationSecs;

  /// Integration seconds per filter name, for surfaces that break the plan
  /// down by band. `'No filter'` collects unfiltered exposures.
  final Map<String, double> integrationSecsByFilter;

  /// True when a `loopUntilStopped` SmartExposure is in the subtree — its
  /// frame count is open-ended, so [frames] excludes it entirely.
  final bool hasOpenEndedLoop;

  /// Integration budget of those open-ended nodes, in seconds (0 = uncapped).
  final double openEndedBudgetSecs;

  /// True when a non-`count` loop (until-time / altitude / forever / while
  /// dark / integration-time) wraps part of the subtree, which makes
  /// [frames] a single-pass floor rather than the total.
  final bool hasUnboundedRepeat;

  const PlannedCapture({
    required this.frames,
    required this.integrationSecs,
    required this.integrationSecsByFilter,
    required this.hasOpenEndedLoop,
    required this.openEndedBudgetSecs,
    required this.hasUnboundedRepeat,
  });

  static const empty = PlannedCapture(
    frames: 0,
    integrationSecs: 0,
    integrationSecsByFilter: {},
    hasOpenEndedLoop: false,
    openEndedBudgetSecs: 0,
    hasUnboundedRepeat: false,
  );

  /// True when the subtree plans no capture at all — no bounded frames and no
  /// open-ended loop. Only then is "no exposures" an honest label.
  bool get isEmpty => frames == 0 && !hasOpenEndedLoop;
}

/// Walk [sequence] from [rootId] (inclusive) and total up what it will
/// capture. Returns [PlannedCapture.empty] when [rootId] is not in the
/// sequence.
PlannedCapture plannedCaptureUnder(Sequence sequence, String rootId) {
  if (!sequence.nodes.containsKey(rootId)) return PlannedCapture.empty;

  var frames = 0;
  var integrationSecs = 0.0;
  final byFilter = <String, double>{};
  var hasOpenEndedLoop = false;
  var openEndedBudgetSecs = 0.0;
  var hasUnboundedRepeat = false;
  final visited = <String>{};

  void addFilter(String? name, double secs) {
    final key = (name == null || name.isEmpty) ? 'No filter' : name;
    byFilter.update(key, (value) => value + secs, ifAbsent: () => secs);
  }

  void visit(String nodeId, int mult) {
    if (!visited.add(nodeId)) return;
    final node = sequence.nodes[nodeId];
    if (node == null || !node.isEnabled) return;

    for (final run in node.kind.captures(node)) {
      frames += run.count * mult;
      final secs = run.exposureSecs * run.count * mult;
      integrationSecs += secs;
      addFilter(run.filter, secs);
    }
    if (node.capturesUntilStopped) {
      hasOpenEndedLoop = true;
      if (node is SmartExposureNode) {
        openEndedBudgetSecs += node.integrationBudgetSecs * mult;
      }
    }

    var childMult = mult;
    if (node is LoopNode) {
      if (node.conditionType == LoopConditionType.count) {
        childMult = mult * (node.repeatCount ?? 1);
      } else if (node.childIds.isNotEmpty) {
        hasUnboundedRepeat = true;
      }
    }

    for (final childId in node.childIds) {
      visit(childId, childMult);
    }
  }

  visit(rootId, 1);

  return PlannedCapture(
    frames: frames,
    integrationSecs: integrationSecs,
    integrationSecsByFilter: byFilter,
    hasOpenEndedLoop: hasOpenEndedLoop,
    openEndedBudgetSecs: openEndedBudgetSecs,
    hasUnboundedRepeat: hasUnboundedRepeat,
  );
}

PlannedCapture plannedCaptureForSequence(Sequence sequence) {
  final rootId = sequence.rootNodeId;
  if (rootId == null) return PlannedCapture.empty;
  return plannedCaptureUnder(sequence, rootId);
}
