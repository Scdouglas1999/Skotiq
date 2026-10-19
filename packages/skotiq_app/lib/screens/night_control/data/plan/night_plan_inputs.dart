// What every plan data provider (night-control plan section 3, P1a) reads:
// now, the operator's clock, the loaded plan flattened into execution order,
// one estimator run, and what this session's events recorded per node.
//
// Every DateTime a P1a view model carries is on the operator's clock, the
// same clock `tonightNightProvider` renders sunset and dawn on. A widget
// compares one against `clockProvider.now()`, never `DateTime.now()`; the two
// differ only when Settings picks a time zone other than the host's.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
// The typed bridge events, behind the prefix the run dashboard uses: their
// names collide with the wire event model the barrel keeps canonical.
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;

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

// ---------------------------------------------------------------------------
// P2 seams
// ---------------------------------------------------------------------------

/// The manual-action controller's state, for "Paused for autofocus".
///
/// Seam for P2: `nightActionStateProvider` does not exist yet, so this reads
/// idle and the run phase can only say [NightRunPhase.pausedByUser]. When P2
/// lands, integration makes this `ref.watch(nightActionStateProvider)`.
final nightPlanActionStateSeamProvider =
    Provider<ManualActionState>((ref) => ManualActionState.idle);

/// When an armed "Start at dark" fires, on the operator's clock; null when
/// nothing is armed.
///
/// Seam for P2: `NightActionApi.armedStartAt` lives behind
/// `nightActionApiProvider`, which does not exist yet, so this reads null and
/// the run phase never says [NightRunPhase.armed]. When P2 lands, integration
/// makes this watch P2's armed-start state.
final nightPlanArmedStartSeamProvider = Provider<DateTime?>((ref) => null);

// ---------------------------------------------------------------------------
// The plan, flattened
// ---------------------------------------------------------------------------

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

  /// Something a run can do: a target or an exposure. The same test the old
  /// Tonight hero used before it offered Start.
  bool get launchable =>
      sequence.targetHeaders.isNotEmpty || sequence.totalExposures > 0;

  /// Some loop runs until a time or a condition, so the plan has no fixed
  /// length.
  bool get openEnded => entries.any((e) => e.openEnded);

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

// ---------------------------------------------------------------------------
// The estimate
// ---------------------------------------------------------------------------

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

  final Map<String, NodeTiming> _firstByNode;

  DateTime get end => anchor.add(total);

  /// The node's first estimated pass, or null when the estimator gave it no
  /// time of its own.
  NodeTiming? of(String nodeId) => _firstByNode[nodeId];
}

/// The estimator run behind every planned time on Tonight.
///
/// Anchored at session start while a run is live (so the steps already done
/// keep their places), at the armed start time when "Start at dark" is
/// armed, and at now otherwise. Null with nothing loaded.
final nightPlanTimingProvider = Provider<NightPlanTiming?>((ref) {
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null || tree.entries.isEmpty) return null;

  final clock = ref.watch(clockProvider);
  final execution = ref.watch(sequenceExecutionStateProvider);
  final armedAt = ref.watch(nightPlanArmedStartSeamProvider);

  // Only the "now" anchor follows the tick; a live run's estimate stays put
  // instead of being recomputed every 30 s.
  final started = execution.isBusy
      ? ref.watch(sessionStateProvider.select((s) => s.startTime))
      : null;
  final DateTime anchor;
  if (started != null) {
    anchor = started.toUtc();
  } else if (armedAt != null && !execution.isBusy) {
    anchor = clock.toInstant(armedAt);
  } else {
    anchor = ref.watch(nightNowProvider);
  }

  final site = ref.watch(appObserverLocationProvider);
  final estimator = SequenceTimeEstimator(
    overhead: ref.watch(sequencerOverheadConfigProvider),
  );
  final timings = estimator.estimateSequenceTiming(
    tree.sequence,
    anchor,
    latitude: site?.latitude,
    longitude: site?.longitude,
  );
  final total = estimator.estimateTotalDuration(
    tree.sequence,
    anchor,
    latitude: site?.latitude,
    longitude: site?.longitude,
  );
  return NightPlanTiming(anchor: anchor, timings: timings, total: total);
});

// ---------------------------------------------------------------------------
// Recorded node times
// ---------------------------------------------------------------------------

/// When this session's nodes started and finished, from the in-memory event
/// history. Instants. Empty after an app restart, and limited to the events
/// the history still holds.
class NightNodeEventTimes {
  const NightNodeEventTimes({
    this.started = const <String, DateTime>{},
    this.completed = const <String, DateTime>{},
    this.completedStatus = const <String, String>{},
  });

  /// The latest NodeStarted per node.
  final Map<String, DateTime> started;

  /// The latest NodeCompleted per node, and its wire status ("success",
  /// "failed", "cancelled", "skipped").
  final Map<String, DateTime> completed;
  final Map<String, String> completedStatus;

  /// When [nodeId] finished successfully, if the history saw it.
  DateTime? succeededAt(String nodeId) =>
      completedStatus[nodeId] == 'success' ? completed[nodeId] : null;
}

final nightNodeEventTimesProvider = Provider<NightNodeEventTimes>((ref) {
  final history = ref.watch(eventHistoryProvider);
  if (history.isEmpty) return const NightNodeEventTimes();

  // Only this run's events: the same plan run twice reuses its node ids, and
  // the first run's finish times must not land on the second run's rows.
  final execution = ref.watch(sequenceExecutionStateProvider);
  final sessionStart = ref.watch(
    sessionStateProvider.select((s) => s.startTime),
  );
  final since =
      execution.isBusy || execution == SequenceExecutionState.completed
          ? sessionStart?.toUtc()
          : null;

  final started = <String, DateTime>{};
  final completed = <String, DateTime>{};
  final status = <String, String>{};
  // The history is newest first; walk it oldest first so the latest wins.
  for (final event in history.reversed) {
    final payload = event.payload;
    if (payload is! sk_events.EventPayload_Sequencer) continue;
    final at = DateTime.fromMillisecondsSinceEpoch(
      event.timestamp.toInt(),
      isUtc: true,
    );
    if (since != null && at.isBefore(since)) continue;
    final sequencerEvent = payload.field0;
    if (sequencerEvent is sk_events.SequencerEvent_NodeStarted) {
      started[sequencerEvent.nodeId] = at;
    } else if (sequencerEvent is sk_events.SequencerEvent_NodeCompleted) {
      completed[sequencerEvent.nodeId] = at;
      status[sequencerEvent.nodeId] = sequencerEvent.status;
    }
  }
  return NightNodeEventTimes(
    started: started,
    completed: completed,
    completedStatus: status,
  );
});

// ---------------------------------------------------------------------------
// Frame counts
// ---------------------------------------------------------------------------

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

/// How many frames a step plans per pass: an exposure's count, or null.
int? nightPlannedFrames(SequenceNode node) => switch (node) {
      ExposureNode() => node.count,
      SciencePhotometryNode() => node.count,
      SmartExposureNode() => node.plans.fold<int>(0, (s, p) => s + p.count),
      _ => null,
    };
