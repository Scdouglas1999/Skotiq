// One walk that answers "what does this subtree actually plan to capture?" for
// every sequencer surface that quotes a frame count or an integration time.
//
// WHY THIS EXISTS: the target header card and the library card's preview each
// grew their own recursive walk. Both drifted from the model's own counting
// (`Sequence.totalExposures` / `Sequence._countExposures`) in the same
// direction — they ignored loop multipliers, so a Quick-Start-Wizard sequence
// (`Capture Loop ×10` wrapping one exposure node) was reported as "1 planned
// exposures · 2m" next to a toolbar reading "10 frames" — and the library
// preview ignored SmartExposure entirely, printing "No exposures" for a
// target whose only imager is a Smart Exposure node.
//
// The multiplier rules mirror `Sequence._countExposures` exactly:
//   * a `count` loop multiplies its whole subtree by `repeatCount`;
//   * every other loop kind keeps the single-pass multiplier (so a total is
//     never unbounded) and raises [PlannedCapture.hasUnboundedRepeat] so the
//     caller can say the figure is a per-pass floor rather than the plan;
//   * disabled nodes contribute nothing — they will not run.
//
// A `loopUntilStopped` SmartExposure has no fixed count at all: its per-plan
// counts are ignored by the executor, so its frames are NOT folded into
// [PlannedCapture.frames]; the budget (if any) is reported separately.

import 'package:skotiq_core/skotiq_core.dart';

/// What a subtree plans to capture.
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

    if (node is ExposureNode) {
      frames += node.count * mult;
      final secs = node.durationSecs * node.count * mult;
      integrationSecs += secs;
      addFilter(node.filter, secs);
    } else if (node is SciencePhotometryNode) {
      // A photometry burst captures `count` frames through the same
      // TakeExposure pipeline as an exposure node. Omitting it made a
      // photometry-only target read "No exposures" on its own header card and
      // in the library preview while the node's row said "60 frames".
      frames += node.count * mult;
      final secs = node.exposureSecs * node.count * mult;
      integrationSecs += secs;
      addFilter(node.filter, secs);
    } else if (node is SmartExposureNode) {
      if (node.loopUntilStopped) {
        // Counts are ignored by the executor in this mode — folding them in
        // would invent a total the run will never honour.
        hasOpenEndedLoop = true;
        openEndedBudgetSecs += node.integrationBudgetSecs * mult;
      } else {
        for (final plan in node.plans) {
          frames += plan.count * mult;
          final secs = plan.durationSecs * plan.count * mult;
          integrationSecs += secs;
          addFilter(plan.filterName, secs);
        }
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

/// Total planned capture for the whole [sequence], walking from its root.
PlannedCapture plannedCaptureForSequence(Sequence sequence) {
  final rootId = sequence.rootNodeId;
  if (rootId == null) return PlannedCapture.empty;
  return plannedCaptureUnder(sequence, rootId);
}
