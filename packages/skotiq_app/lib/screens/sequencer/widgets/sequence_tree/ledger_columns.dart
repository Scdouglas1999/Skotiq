// The four right-aligned readout columns of a Ledger-mode tree row, and the
// node -> predicted-start-clock map they read their ETA from.
//
// Deliberately widget-free: the row paints what [ledgerColumnsFor] returns and
// decides nothing about the numbers, so the column semantics (which node type
// fills which column, and with what) are unit-testable in isolation.
//
// The values come from the models the rest of the sequencer already quotes —
// `plannedCaptureUnder` for frame totals, `nodeRollupDurationProvider` for the
// duration (passed in), and the pre-session simulation for the clock — so a
// ledger row cannot disagree with the target header card, the estimate chip or
// the pre-flight dialog about the same subtree.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The typed `SkotiqEvent` union collides by name with the wire/JSON event
// model the barrel above keeps canonical, so it is imported from the core's
// dedicated typed-event seam under the `sk_events` prefix — the convention the
// run dashboard providers already follow.
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;

import '../../ledger_seconds.dart';
import '../../plan_math.dart';
import '../visual_timeline.dart';

/// The text of one ledger row's four columns. An empty string means the column
/// is blank for this node — the ledger says nothing rather than inventing a
/// zero.
class LedgerColumns {
  /// **Filter / exp** — the capture spec, e.g. `Ha 300s`.
  final String filterExp;

  /// **Count** — frames this row will produce (its subtree, for a container).
  final String count;

  /// **Duration** — the row's rolled-up estimate, e.g. `~1h 4m`.
  final String duration;

  /// **ETA** — predicted start, local wall clock `HH:mm`.
  final String eta;

  const LedgerColumns({
    this.filterExp = '',
    this.count = '',
    this.duration = '',
    this.eta = '',
  });

  static const empty = LedgerColumns();

  /// The four values in column order. Used by the row to lay the cells out and
  /// to build its accessibility label.
  List<String> get values => <String>[filterExp, count, duration, eta];

  @override
  bool operator ==(Object other) =>
      other is LedgerColumns &&
      other.filterExp == filterExp &&
      other.count == count &&
      other.duration == duration &&
      other.eta == eta;

  @override
  int get hashCode => Object.hash(filterExp, count, duration, eta);

  @override
  String toString() =>
      'LedgerColumns(filterExp: "$filterExp", count: "$count", '
      'duration: "$duration", eta: "$eta")';
}

/// Build the column text for [node].
///
/// [rollup] is the node's rolled-up estimate from `nodeRollupDurationProvider`
/// and [eta] its predicted start from [ledgerEtaProvider]; both are passed in
/// rather than looked up so this stays a pure function of the sequence.
///
/// The dispatch is a deliberate `is`-chain rather than the exhaustive
/// `switch (node)` `nodeSummary` uses: a node type this function has never
/// heard of still has a name, a duration and a start time, so the honest
/// default (duration + ETA, no capture columns) is right for it. A new
/// instruction that captures frames adds a branch here; one that does not
/// needs no edit.
LedgerColumns ledgerColumnsFor(
  SequenceNode node,
  Sequence sequence, {
  required Duration rollup,
  DateTime? eta,
}) {
  final etaText = eta == null ? '' : formatLedgerClock(eta);
  // `<1s` is what `formatRollupDuration` returns for zero, which in a column
  // of estimates reads as a measurement rather than as "this step has no
  // length". A node with no duration leaves the column empty instead.
  final durationText =
      rollup.inSeconds <= 0 ? '' : formatRollupDuration(rollup);

  if (node is ExposureNode) {
    return LedgerColumns(
      filterExp: _filterExp(node.filter, node.durationSecs),
      count: '${node.count}',
      duration: durationText,
      eta: etaText,
    );
  }

  if (node is SciencePhotometryNode) {
    // A photometry burst runs the same TakeExposure pipeline, so it fills the
    // capture columns exactly as an exposure node does.
    return LedgerColumns(
      filterExp: _filterExp(node.filter, node.exposureSecs),
      count: '${node.count}',
      duration: durationText,
      eta: etaText,
    );
  }

  if (node is SmartExposureNode) {
    return LedgerColumns(
      filterExp: _smartFilters(node),
      count: _frameCount(plannedCaptureUnder(sequence, node.id)),
      duration: durationText,
      eta: etaText,
    );
  }

  if (node.childIds.isNotEmpty) {
    // A container: the Count column totals the subtree, and the Filter / exp
    // column stays blank — a container has no single capture spec, and the
    // filters it uses are named by its rollup summary when it is collapsed.
    return LedgerColumns(
      count: _frameCount(plannedCaptureUnder(sequence, node.id)),
      duration: durationText,
      eta: etaText,
    );
  }

  // Delay, Wait, Slew, Autofocus, Cool Camera, an empty container … anything
  // with a length but nothing to capture.
  return LedgerColumns(duration: durationText, eta: etaText);
}

/// `Ha 300s`, or `300s` for an unfiltered exposure.
String _filterExp(String? filter, double durationSecs) {
  final secs = formatLedgerSeconds(durationSecs);
  if (filter == null || filter.isEmpty) return '${secs}s';
  return '$filter ${secs}s';
}

/// The filter names a SmartExposure rotates through, e.g. `L R G B`. A plan
/// with no name is identified by its 1-based wheel position, matching
/// `nodeSummary`'s treatment of the same field.
String _smartFilters(SmartExposureNode node) {
  if (node.plans.isEmpty) return '';
  return node.plans
      .map((plan) => plan.filterName.isEmpty
          ? '#${(plan.filterIndex ?? 0) + 1}'
          : plan.filterName)
      .join(' ');
}

/// The Count column for a planned capture.
///
/// A `+` suffix marks a figure that is a floor rather than the plan: under a
/// non-`count` loop the walk deliberately counts one pass (the rest of the app
/// says "per pass"), and an open-ended SmartExposure contributes no fixed
/// frames at all. An em dash is the honest answer when the only imager is
/// open-ended — there is no number to print, and `0` would be a lie.
String _frameCount(PlannedCapture planned) {
  if (planned.isEmpty) return '';
  if (planned.frames == 0) return '—';
  final floor = planned.hasUnboundedRepeat || planned.hasOpenEndedLoop;
  return floor ? '${planned.frames}+' : '${planned.frames}';
}

/// Format [time] as a local 24-hour `HH:mm` wall clock.
///
/// Hand-formatted rather than via `DateFormat` so the ETA column is the same
/// string in every locale the sequencer runs under — the column is 62 px wide
/// and a 12-hour `10:14 PM` does not fit it.
String formatLedgerClock(DateTime time) {
  final local = time.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// One ETA cell's provenance: [start] is the clock the column prints and
/// [isActual] marks whether that time was observed (the node really began
/// then) or projected (the estimator's plan shifted onto the current anchor).
/// The row needs the distinction — a projected time for a node that already
/// started is stale, and the column mutes it rather than present it as fact.
class LedgerEta {
  final DateTime start;
  final bool isActual;

  const LedgerEta(this.start, {required this.isActual});

  @override
  bool operator ==(Object other) =>
      other is LedgerEta && other.start == start && other.isActual == isActual;

  @override
  int get hashCode => Object.hash(start, isActual);

  @override
  String toString() => 'LedgerEta($start, actual: $isActual)';
}

/// Predicted start time per node id, derived from the pre-session simulation.
///
/// [PreSessionSimulationResult.segments] only carries the nodes the estimator
/// bills time to (`_processNode` emits an entry solely when the node's own
/// duration is non-zero), so a target header, a loop or an instruction set has
/// no segment of its own. Those take the earliest start in their subtree —
/// spec §2, "Container: ETA = subtree start".
///
/// A node the simulation cannot place is absent from the map, and its ETA
/// column stays blank. That is the case whenever there is no observer location
/// or the sequence has not been simulated at all.
Map<String, DateTime> ledgerNodeStarts(
  Sequence sequence,
  PreSessionSimulationResult? simulation,
) {
  if (simulation == null || simulation.segments.isEmpty) {
    return const <String, DateTime>{};
  }

  final starts = <String, DateTime>{};
  for (final segment in simulation.segments) {
    final existing = starts[segment.nodeId];
    if (existing == null || segment.start.isBefore(existing)) {
      starts[segment.nodeId] = segment.start;
    }
  }
  return _foldStarts(sequence, starts);
}

/// Fold any seed map of per-node start times into subtree-earliest times: the
/// same post-order walk [ledgerNodeStarts] uses, reused so the predicted and
/// the observed-start maps cannot disagree about how containers inherit.
Map<String, DateTime> _foldStarts(
  Sequence sequence,
  Map<String, DateTime> seeds,
) {
  final starts = Map<String, DateTime>.of(seeds);
  final visited = <String>{};
  final rootId = sequence.rootNodeId;
  if (rootId != null) {
    _foldSubtreeStart(sequence, rootId, starts, visited);
  }
  // Detached subtrees (a sequence with no root, or nodes the root does not
  // reach) still render rows, so they get their container starts folded too.
  for (final id in sequence.nodes.keys) {
    _foldSubtreeStart(sequence, id, starts, visited);
  }
  return Map<String, DateTime>.unmodifiable(starts);
}

/// Post-order walk: give every node with children the earliest start found
/// under it, and return that start so the parent can fold it in turn.
DateTime? _foldSubtreeStart(
  Sequence sequence,
  String nodeId,
  Map<String, DateTime> starts,
  Set<String> visited,
) {
  if (!visited.add(nodeId)) return starts[nodeId];
  final node = sequence.nodes[nodeId];
  if (node == null) return null;

  var earliest = starts[nodeId];
  for (final childId in node.childIds) {
    final childStart = _foldSubtreeStart(sequence, childId, starts, visited);
    if (childStart == null) continue;
    if (earliest == null || childStart.isBefore(earliest)) {
      earliest = childStart;
    }
  }
  if (earliest != null) starts[nodeId] = earliest;
  return earliest;
}

/// How far behind its own plan the run is, measured at the node it is on.
///
/// Two quantities, and they are a MAX rather than a sum:
///
///  * **Lateness** — how much later the node began than the plan (shifted onto
///    the run's anchor) said it would. Everything after it inherits that.
///  * **Overrun** — how long the node has been going past the moment the plan
///    said it would END. This already contains the lateness once the node is
///    past its expected finish, which is why adding the two would count the
///    same minutes twice.
///
/// Measuring `now - predictedStart` instead — as this did before review — is
/// not lateness at all but time ELAPSED IN the node, most of which the plan
/// asked for. A 30-minute exposure running exactly on plan would have pushed
/// every pending ETA by a minute every minute for half an hour and then snapped
/// back when the node ended.
///
/// Zero, never negative: a run that is AHEAD of plan is not talked back down to
/// it, because the estimator and not the clock says how long the rest takes.
/// Zero as well when the executing node carries no segment of its own (a
/// container is not billed), where there is nothing to measure against and
/// inventing a delay would be worse than quoting the plan.
Duration _behindSchedule(
  PreSessionSimulationResult? simulation, {
  required String? currentNodeId,
  required DateTime? predictedStart,
  required DateTime? actualStart,
  required Duration runShift,
  required DateTime now,
}) {
  if (simulation == null || currentNodeId == null || predictedStart == null) {
    return Duration.zero;
  }
  final anchoredStart = predictedStart.add(runShift);
  final lateness = actualStart == null
      ? Duration.zero
      : _atLeastZero(actualStart.difference(anchoredStart));

  final billed = _billedDuration(simulation, currentNodeId);
  if (billed == null) return lateness;
  final overrun = _atLeastZero(now.difference(anchoredStart.add(billed)));

  return overrun > lateness ? overrun : lateness;
}

Duration _atLeastZero(Duration value) =>
    value.isNegative ? Duration.zero : value;

/// How long the estimator billed [nodeId] for, on the pass whose start
/// [ledgerNodeStarts] kept — the earliest, so the two agree about which
/// segment they are talking about.
Duration? _billedDuration(
  PreSessionSimulationResult simulation,
  String nodeId,
) {
  PreSessionSimulationSegment? earliest;
  for (final segment in simulation.segments) {
    if (segment.nodeId != nodeId) continue;
    if (earliest == null || segment.start.isBefore(earliest.start)) {
      earliest = segment;
    }
  }
  return earliest?.duration;
}

/// The ETA map's pure core, parameterised on the clocks so tests drive it with
/// fake times.
///
/// The simulation is anchored once at [PreSessionSimulationResult.start] —
/// whenever the estimator last ran — and the column re-anchors it rather than
/// re-simulating, so a plan opened at 21:00 and run at 23:00 reads correctly
/// at both. [actualStarts] (observed `NodeStarted` events, folded to
/// subtree-earliest) always wins over a projection — a node that demonstrably
/// began at 22:41 is not "predicted" for anything.
Map<String, LedgerEta> ledgerEtasFor(
  Sequence sequence,
  PreSessionSimulationResult? simulation, {
  required DateTime now,
  required bool runActive,
  DateTime? runStart,
  String? currentNodeId,
  Map<String, DateTime> actualStarts = const <String, DateTime>{},
}) {
  if (actualStarts.isEmpty &&
      (simulation == null || simulation.segments.isEmpty)) {
    return const <String, LedgerEta>{};
  }

  final actuals = _foldStarts(sequence, actualStarts);
  final predicted = ledgerNodeStarts(sequence, simulation);
  // Before a run the plan is projected from `now`; once the executor is
  // driving, the remaining plan hangs off the run's recorded start (falling
  // back to the simulation's own anchor while `startSession` is still
  // resolving).
  final runShift = simulation == null
      ? Duration.zero
      : (runActive ? (runStart ?? simulation.start) : now)
          .difference(simulation.start);

  // …but the RUN's start is the wrong anchor for the part of the plan that has
  // not happened yet. A night that is forty minutes behind at 01:00 still had
  // the same start time, so anchoring on it alone printed every remaining ETA
  // forty minutes optimistic — all night, and by more as the night went on.
  //
  // The executing node is the join between what happened and what is still
  // predicted, and there are exactly two ways it can put the rest of the night
  // back: it started late, or it is still going after it should have finished.
  final pendingShift = runShift +
      _behindSchedule(
        simulation,
        currentNodeId: runActive ? currentNodeId : null,
        predictedStart: currentNodeId == null ? null : predicted[currentNodeId],
        actualStart: currentNodeId == null ? null : actualStarts[currentNodeId],
        runShift: runShift,
        now: now,
      );

  final etas = <String, LedgerEta>{};
  for (final id in sequence.nodes.keys) {
    final actual = actuals[id];
    if (actual != null) {
      etas[id] = LedgerEta(actual, isActual: true);
      continue;
    }
    final start = predicted[id];
    if (start != null) {
      etas[id] = LedgerEta(start.add(pendingShift), isActual: false);
    }
  }
  return Map<String, LedgerEta>.unmodifiable(etas);
}

/// The wall clock the ETA column anchors against.
///
/// A stream rather than a `Timer` held by a notifier: Riverpod cancels the
/// subscription on rebuild and dispose, which kills the periodic timer with
/// it. `autoDispose` so the subscription — and the timer inside it — dies with
/// the last listener instead of outliving a widget test's tree.
///
/// It ticks DURING a run as well as before one. It used to stop while the
/// executor was driving, on the reasoning that the anchor had moved to the
/// run's recorded start and a tick would only rebuild identical predictions.
/// That was true of the predictions and wrong about the night: the pending
/// tail is anchored on `max(now, the executing node's predicted start)`
/// ([ledgerEtasFor]), so a run falling behind only shows in the ETA column
/// when the clock moves. One minute is also the column's own resolution — it
/// prints `HH:mm` — so this is the slowest tick that can still be right.
///
/// Nothing but [ledgerEtaProvider] reads it, which is what keeps a timer
/// running through a night from costing anything else a rebuild.
final ledgerClockProvider = StreamProvider.autoDispose<DateTime>((ref) {
  Stream<DateTime> tick() async* {
    yield DateTime.now();
    yield* Stream.periodic(const Duration(minutes: 1), (_) => DateTime.now());
  }

  return tick();
});

/// Observed node-start times for the current run, folded out of the typed
/// event stream the executor already publishes (`NodeStarted` carries the
/// node id; the event envelope carries the timestamp).
///
/// `Started` clears the map so a rerun does not show last night's times. The
/// same `ref.listen` fold `eventHistoryProvider` uses — kept as a map provider
/// rather than read inside the row so every event does not rebuild the tree.
///
/// `autoDispose`, and held alive from the moment a run starts.
///
/// The fold subscribes to `skotiqEventsProvider`, and as a plain provider
/// it kept that subscription — and the observed starts of whatever ran last —
/// for the lifetime of the process whether or not a sequencer had ever been
/// opened. `autoDispose` means an app that never runs a sequence never
/// subscribes.
///
/// The keep-alive is NOT released when the run settles, which is the mistake
/// the first version of this made. A finished run's observed starts are the
/// record of the night: spec §2 has finished nodes showing the time they
/// really began, so disposing the map when the executor went idle meant an
/// operator who left the sequencer and came back after the run found every row
/// re-anchored on `now` — finished nodes claiming a fresh start time. The only
/// thing that should erase the record is the next run, and that arrives as
/// `SequencerEvent_Started`, which clears the map in place.
final ledgerActualStartsProvider = StateNotifierProvider.autoDispose<
    _LedgerActualStartsNotifier, Map<String, DateTime>>((ref) {
  final notifier = _LedgerActualStartsNotifier();
  ref.listen(skotiqEventsProvider, (previous, next) {
    next.whenData(notifier._onEvent);
  });
  KeepAliveLink? sessionLink;
  void holdForTheSession() => sessionLink ??= ref.keepAlive();
  notifier._onRunObserved = holdForTheSession;
  // The execution state covers the case where the tree is opened onto a run
  // that is already going and whose `Started` event has long been delivered.
  ref.listen<SequenceExecutionState>(
    sequenceExecutionStateProvider,
    (previous, next) {
      if (!next.canStart) holdForTheSession();
    },
    fireImmediately: true,
  );
  ref.onDispose(() => sessionLink?.close());
  return notifier;
});

class _LedgerActualStartsNotifier extends StateNotifier<Map<String, DateTime>> {
  _LedgerActualStartsNotifier() : super(const <String, DateTime>{});

  /// Told the provider that this session has a run in it, so the record must
  /// outlive the sequencer screen being closed.
  void Function()? _onRunObserved;

  void _onEvent(sk_events.SkotiqEvent event) {
    if (!mounted) return;
    final payload = event.payload;
    if (payload is! sk_events.EventPayload_Sequencer) return;
    switch (payload.field0) {
      case sk_events.SequencerEvent_Started():
        _onRunObserved?.call();
        state = const <String, DateTime>{};
      case sk_events.SequencerEvent_NodeStarted(nodeId: final nodeId):
        _onRunObserved?.call();
        state = <String, DateTime>{
          ...state,
          nodeId: DateTime.fromMillisecondsSinceEpoch(event.timestamp.toInt()),
        };
      default:
        break;
    }
  }
}

/// ETA per node id for every node in the open sequence — observed starts where
/// the run has already produced them, anchored predictions elsewhere.
///
/// A single map rather than a family: the fold is one walk over the whole
/// sequence, so computing it per node would re-run it per row. Rows read their
/// own entry with `.select`, which keeps a row out of the rebuild when another
/// row's ETA is the only thing that moved. `autoDispose` so a closed tree
/// stops the clock watch inside it (see [ledgerClockProvider]).
final ledgerEtaProvider = Provider.autoDispose<Map<String, LedgerEta>>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return const <String, LedgerEta>{};
  final simulation = ref.watch(sequenceTimelineProvider);
  final runActive = !ref.watch(sequenceExecutionStateProvider).canStart;
  return ledgerEtasFor(
    sequence,
    simulation,
    // `now` is the wall clock, idle or running (running, it is what pushes the
    // pending tail when a node overruns). The stream's own first event is a
    // `DateTime.now()`, so this reads the same clock one moment earlier on the
    // build that precedes it — not a stand-in for a time nobody measured.
    now: ref.watch(ledgerClockProvider).valueOrNull ?? DateTime.now(),
    runActive: runActive,
    runStart: ref.watch(sessionStateProvider).startTime,
    // The join between what has happened and what is still predicted. Watched
    // as a slice so a progress tick that does not move the run to a new node
    // leaves the whole ETA map alone.
    currentNodeId: ref.watch(
      sequenceProgressProvider.select((progress) => progress.currentNodeId),
    ),
    actualStarts: ref.watch(ledgerActualStartsProvider),
  );
});

/// The [LedgerColumns] for every node in the open sequence, computed once per
/// sequence (or rollup) change rather than once per row build: each
/// `ledgerColumnsFor` call can walk a subtree via `plannedCaptureUnder`, so
/// running it inside every row's `build` repeats that walk on every progress
/// tick. Rows read their own entry with `.select`.
///
/// ETAs deliberately stay out of this map — they move with the clock and the
/// event stream, and mixing them in would invalidate every column on every
/// tick. The row merges its own entry from [ledgerEtaProvider].
final ledgerColumnsMapProvider =
    Provider.autoDispose<Map<String, LedgerColumns>>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return const <String, LedgerColumns>{};
  final columns = <String, LedgerColumns>{};
  for (final node in sequence.nodes.values) {
    columns[node.id] = ledgerColumnsFor(
      node,
      sequence,
      rollup: ref.watch(nodeRollupDurationProvider(node.id)),
    );
  }
  return Map<String, LedgerColumns>.unmodifiable(columns);
});
