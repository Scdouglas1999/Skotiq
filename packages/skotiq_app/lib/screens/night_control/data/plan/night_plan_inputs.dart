// What every plan data provider (night-control plan section 3, P1a) reads:
// now, the operator's clock, the loaded plan flattened into execution order,
// and one estimator run. When nodes really started and finished is core's
// `runNodeTimesProvider`.
//
// Every DateTime a P1a view model carries is on the operator's clock, the
// same clock `tonightNightProvider` renders sunset and dawn on. A widget
// compares one against `clockProvider.now()`, never `DateTime.now()`; the two
// differ only when Settings picks a time zone other than the host's.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../actions/night_action_controller.dart';
import '../../night_control_contracts.dart';

/// Now, as a true instant (UTC), on Tonight's shared 30 s tick.
///
/// Tests override this with a fixed instant.
final nightNowProvider = Provider<DateTime>((ref) {
  final tick = ref.watch(tickerProvider(TickerCadence.thirtySeconds));
  final now = tick.valueOrNull ?? ref.watch(clockProvider).nowUtc();
  return now.toUtc();
});

/// Moves times between true instants and the operator's clock.
extension NightClockTimes on Clock {
  /// [instant] as the operator reads it.
  DateTime toNightClock(DateTime instant) => fromUtc(instant.toUtc());

  /// The true instant behind [onClock], a time already on this clock.
  ///
  /// [FixedOffsetClock] renders a zone by re-tagging shifted fields as host
  /// local, so the instant is those fields read as UTC, less the offset.
  DateTime toInstant(DateTime onClock) {
    final self = this;
    if (self is FixedOffsetClock) {
      return DateTime.utc(
        onClock.year,
        onClock.month,
        onClock.day,
        onClock.hour,
        onClock.minute,
        onClock.second,
        onClock.millisecond,
        onClock.microsecond,
      ).subtract(self.utcOffset);
    }
    return onClock.toUtc();
  }
}

/// The manual-action controller's state, for "Paused for autofocus".
final nightPlanActionStateSeamProvider = Provider<ManualActionState>(
  (ref) => ref.watch(nightActionStateProvider),
);

/// When an armed "Start at dark" fires, on the operator's clock; null when
/// nothing is armed.
///
/// [nightArmedStartProvider] holds the instant (UTC); the plan view models
/// carry operator-clock times.
final nightPlanArmedStartSeamProvider = Provider<DateTime?>((ref) {
  final armedAt = ref.watch(nightArmedStartProvider);
  if (armedAt == null) return null;
  return ref.watch(clockProvider).toNightClock(armedAt);
});

/// One enabled node of the plan, in execution order.
class NightPlanEntry {
  const NightPlanEntry({
    required this.node,
    required this.depth,
    required this.multiplier,
    required this.openEnded,
    this.targetId,
  });

  final SequenceNode node;

  /// Nesting below the root container.
  final int depth;

  /// The target header this node runs under, if any.
  final String? targetId;

  /// How many times a count loop above this node runs it.
  final int multiplier;

  /// A loop above this node runs until a time, an altitude or a condition,
  /// so how many times it runs is not known in advance.
  final bool openEnded;

  bool get isStep => node.category == NodeCategory.instruction;
}

/// The loaded plan walked once in execution order. Disabled nodes and
/// everything under them are left out, as the executor skips them.
class NightPlanTree {
  NightPlanTree(this.sequence, this.entries)
      : steps = List<NightPlanEntry>.unmodifiable(
          entries.where((e) => e.isStep),
        ),
        targets = List<TargetHeaderNode>.unmodifiable(
          entries.map((e) => e.node).whereType<TargetHeaderNode>(),
        );

  final Sequence sequence;
  final List<NightPlanEntry> entries;

  /// The instructions, the rows of the Steps list.
  final List<NightPlanEntry> steps;

  /// Target headers in the order the run reaches them.
  final List<TargetHeaderNode> targets;

  /// Something a run can do ([Sequence.launchable]).
  bool get launchable => sequence.launchable;

  /// Some loop runs until a time or a condition, so the plan has no fixed
  /// length.
  bool get openEnded => entries.any((e) => e.openEnded);

  /// A Smart Exposure loops until its target's window closes. Its length is
  /// the window's, which a frame count cannot give: the executor's
  /// per-frame remaining time counts the plans' per-filter counts.
  bool get loopsUntilWindowEnds =>
      entries.any((e) => e.node.capturesUntilStopped);

  int stepIndexOf(String nodeId) =>
      steps.indexWhere((entry) => entry.node.id == nodeId);
}

NightPlanTree buildNightPlanTree(Sequence sequence) {
  final entries = <NightPlanEntry>[];

  void visit(
    SequenceNode node, {
    required int depth,
    required String? targetId,
    required int multiplier,
    required bool openEnded,
  }) {
    if (!node.isEnabled) return;
    final ownTarget = node is TargetHeaderNode ? node.id : targetId;
    entries.add(
      NightPlanEntry(
        node: node,
        depth: depth,
        targetId: ownTarget,
        multiplier: multiplier,
        openEnded: openEnded,
      ),
    );
    var childMultiplier = multiplier;
    var childOpenEnded = openEnded;
    if (node is LoopNode) {
      if (node.conditionType == LoopConditionType.count) {
        childMultiplier = multiplier * (node.repeatCount ?? 1);
      } else {
        childOpenEnded = true;
      }
    }
    for (final child in sequence.childrenOf(node.id)) {
      visit(
        child,
        depth: depth + 1,
        targetId: ownTarget,
        multiplier: childMultiplier,
        openEnded: childOpenEnded,
      );
    }
  }

  final root = sequence.rootNode;
  if (root != null) {
    // The root is the run's container; its children sit at depth 0.
    if (root.isEnabled) {
      for (final child in sequence.childrenOf(root.id)) {
        visit(
          child,
          depth: 0,
          targetId: null,
          multiplier: 1,
          openEnded: false,
        );
      }
    }
  } else {
    // No root: every target header is its own root, as the estimator and
    // the executor treat it.
    for (final target in sequence.targetHeaders) {
      visit(target, depth: 0, targetId: null, multiplier: 1, openEnded: false);
    }
  }
  return NightPlanTree(sequence, entries);
}

/// The loaded plan flattened; null when nothing is loaded.
final nightPlanTreeProvider = Provider<NightPlanTree?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;
  return buildNightPlanTree(sequence);
});

/// One run of [SequenceTimeEstimator] over the loaded plan. Instants, not
/// operator-clock times. Everything here is an estimate.
class NightPlanTiming {
  NightPlanTiming({
    required this.anchor,
    required this.timings,
    required this.total,
  }) : _firstByNode = <String, NodeTiming>{} {
    for (final timing in timings) {
      _firstByNode.putIfAbsent(timing.nodeId, () => timing);
    }
  }

  /// When the estimate starts the plan.
  final DateTime anchor;

  /// In execution order. A loop body appears once, for its first pass.
  final List<NodeTiming> timings;

  /// The whole plan, loops included.
  final Duration total;

  /// A step runs until it is stopped and nothing bounds it (no site to solve
  /// its target's window from), so [total] and [end] are not the plan's
  /// length.
  bool get openEnded => timings.any((timing) => timing.openEnded);

  final Map<String, NodeTiming> _firstByNode;

  DateTime get end => anchor.add(total);

  /// The node's first estimated pass, or null when the estimator gave it no
  /// time of its own.
  NodeTiming? of(String nodeId) => _firstByNode[nodeId];
}

/// When the loaded plan's estimate starts, where something fixes it: the
/// session's start while a run is live (so the steps already done keep their
/// places), the armed time when "Start at dark" is armed. Instant (UTC). Null
/// otherwise, when the plan starts now.
///
/// Tonight's plan and the Sequencer's timeline and ETA column all time the
/// plan from here, so they give the same times.
final planStartProvider = Provider<DateTime?>((ref) {
  if (ref.watch(sequenceExecutionStateProvider).isBusy) {
    return ref.watch(sessionStateProvider.select((s) => s.startTime))?.toUtc();
  }
  final armedAt = ref.watch(nightPlanArmedStartSeamProvider);
  if (armedAt == null) return null;
  return ref.watch(clockProvider).toInstant(armedAt);
});

/// The estimator run behind every planned time on Tonight, from
/// [planStartProvider], or from now on Tonight's tick (a plan that has not
/// started is re-timed every 30 s). Null with nothing loaded.
final nightPlanTimingProvider = Provider<NightPlanTiming?>((ref) {
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null || tree.entries.isEmpty) return null;

  final DateTime anchor =
      ref.watch(planStartProvider) ?? ref.watch<DateTime>(nightNowProvider);
  final plan = ref.watch(planTimerProvider).time(tree.sequence, anchor);
  return NightPlanTiming(
      anchor: anchor, timings: plan.timings, total: plan.total);
});

/// Frames an exposure node has captured in its current pass, and planned.
///
/// Same precedence as the Sequencer's progress panel: the per-node tally,
/// then the structured detail, then the progress string. Null when the node
/// has reported no frames at all.
({int captured, int? planned})? nightNodeFrames(
  String nodeId, {
  required Map<String, NodeExposureTally> tally,
  required SequenceProgress progress,
}) {
  final counted = tally[nodeId];
  if (counted != null) {
    return (captured: counted.captured, planned: counted.planned);
  }
  final structured = progress.nodeProgressStructuredDetail[nodeId];
  if (structured is ExposureInstructionProgressDetail && structured.total > 0) {
    return (
      captured: structured.frame.clamp(0, structured.total),
      planned: structured.total,
    );
  }
  final detail = progress.nodeProgressDetail[nodeId];
  final parsed = detail == null ? null : parseExposureProgressDetail(detail);
  if (parsed != null) {
    final captured = parsed.frameCompleted ? parsed.frame : parsed.frame - 1;
    final planned = parsed.total > 0 ? parsed.total : null;
    return (
      captured: planned == null ? captured : captured.clamp(0, planned),
      planned: planned,
    );
  }
  return null;
}

/// The frames [node] takes per pass, or null when it has no count of its own:
/// it captures nothing, or it loops until stopped.
int? nightPlannedFrames(SequenceNode node) {
  final frames = node.framesPerPass;
  return frames > 0 ? frames : null;
}
