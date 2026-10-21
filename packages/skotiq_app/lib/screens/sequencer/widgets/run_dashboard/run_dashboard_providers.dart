import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The typed bridge event union (`SkotiqEvent` / `EventCategory` /
// `EventSeverity`) collides by name with the wire/JSON event model that the
// unprefixed barrel above keeps canonical, so the typed surface is imported
// from the core's dedicated typed-event seam under the `sk_events` prefix.
// (The non-colliding members — `EventPayload_*` variants, the display helpers,
// `isCriticalEvent` — are reachable unprefixed off the barrel, but we keep them
// behind the prefix here so every typed-event reference in this file reads from
// one place.)
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;

/// The active target during execution.
///
/// Prefers the live `currentTarget` name from `sequenceProgressProvider`
/// (set by the executor) and falls back to the first `TargetHeaderNode`
/// in the loaded sequence. Returns null when nothing is loaded — the
/// dashboard shows an idle state in that case.
final runDashboardActiveTargetProvider = Provider<TargetHeaderNode?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;

  final progress = ref.watch(sequenceProgressProvider);
  final liveName = progress.currentTarget;

  if (liveName != null && liveName.isNotEmpty) {
    for (final t in sequence.targetHeaders) {
      if (t.targetName == liveName) return t;
    }
  }

  if (sequence.targetHeaders.isNotEmpty) {
    return sequence.targetHeaders.first;
  }
  return null;
});

/// Sky-derived stats for the active target evaluated against the observer
/// location stored in app settings. Returns null when location isn't set or
/// no target is active.
class RunDashboardSkyStats {
  /// Current altitude in degrees.
  final double altitudeDeg;

  /// Azimuth in degrees (0 = north, 90 = east).
  final double azimuthDeg;

  /// Time remaining until the target falls below the user-configured
  /// effective horizon. `null` when the target is circumpolar with
  /// respect to that horizon, [Duration.zero] when it's already below.
  final Duration? timeToSet;

  /// Time remaining until meridian transit, or null if already past.
  final Duration? timeToTransit;

  /// The horizon (in degrees) that [timeToSet] was computed against —
  /// kept here so the UI can label the stat correctly when the user
  /// changes the effective horizon between non-zero (e.g. 20°) values.
  final double horizonDeg;

  const RunDashboardSkyStats({
    required this.altitudeDeg,
    required this.azimuthDeg,
    required this.timeToSet,
    required this.timeToTransit,
    required this.horizonDeg,
  });
}

final runDashboardSkyStatsProvider = Provider<RunDashboardSkyStats?>((ref) {
  final target = ref.watch(runDashboardActiveTargetProvider);
  if (target == null) return null;

  final location = ref.watch(appObserverLocationProvider);
  if (location == null) return null;

  // Single shared 30s tick across the whole dashboard. Sky altitude only
  // moves at ~0.25°/min so a 30s cadence is plenty for the dashboard
  // header and avoids waking the executor.
  final tickAsync = ref.watch(tickerProvider(TickerCadence.thirtySeconds));
  final now = tickAsync.valueOrNull ?? DateTime.now();

  final scheduler = ref.read(schedulerServiceProvider);
  final (altitude, azimuth) = scheduler.calculateAltAz(
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    time: now,
    latitudeDegrees: location.latitude,
    longitudeDegrees: location.longitude,
  );

  final transit = scheduler.calculateTransitTime(
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    date: now.toUtc(),
    longitudeDegrees: location.longitude,
  );
  Duration? timeToTransit;
  if (transit.isAfter(now)) {
    timeToTransit = transit.difference(now);
  }

  // The same effectiveHorizonDeg is consumed by the planetarium altitude
  // card via `effectiveHorizonDegProvider`, so this stat matches the
  // planetarium's "Time to set" exactly.
  final horizonDeg = ref.watch(effectiveHorizonDegProvider);
  final timeToSet = scheduler.nextSetTime(
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    now: now,
    latitudeDegrees: location.latitude,
    longitudeDegrees: location.longitude,
    horizonDeg: horizonDeg,
  );

  return RunDashboardSkyStats(
    altitudeDeg: altitude,
    azimuthDeg: azimuth,
    timeToSet: timeToSet,
    timeToTransit: timeToTransit,
    horizonDeg: horizonDeg,
  );
});

/// Per-filter integration data for the active session, in seconds.
///
/// Combines:
///   * In-flight session progress (from `sequenceProgressProvider`,
///     which gives the *current* filter only) — kept zero for non-current
///     filters because the executor doesn't yet maintain a per-filter map.
///   * Persisted accepted-frame totals from the database for the active
///     `dbSessionId` (most-accurate "what's already on disk").
///
/// We sum the two so the bar reads as "total acquired so far this run."
class RunDashboardFilterTotals {
  /// Filter name -> seconds of *accepted* integration acquired this session.
  /// This is the integration that actually counts toward the goal — rejected
  /// subs are excluded so the bar never over-reports usable signal.
  final Map<String, double> integrationSecs;

  /// Filter name -> seconds of *total acquired* integration this session,
  /// i.e. accepted + rejected. Surfaced separately so the operator can see
  /// how much time was spent versus how much produced usable data (a large
  /// gap means a lot of subs are being thrown away — clouds, wind, focus).
  final Map<String, double> totalAcquiredSecs;

  /// Filter name -> goal seconds taken from each `ExposureNode` in the
  /// loaded sequence (count * durationSecs). When the same filter is
  /// reused across multiple exposure nodes the values accumulate.
  final Map<String, double> goalSecs;

  /// The filter the executor is currently exposing, or null when idle.
  final String? inFlightFilter;

  /// Elapsed seconds of the in-flight exposure (0 when idle). Kept separate
  /// from [integrationSecs] because the current sub hasn't been written to
  /// disk or accepted yet — folding it into the accepted total would lie.
  final double inFlightElapsedSecs;

  const RunDashboardFilterTotals({
    required this.integrationSecs,
    required this.totalAcquiredSecs,
    required this.goalSecs,
    this.inFlightFilter,
    this.inFlightElapsedSecs = 0.0,
  });

  static const empty = RunDashboardFilterTotals(
    integrationSecs: {},
    totalAcquiredSecs: {},
    goalSecs: {},
  );

  /// Returns true if no exposures are configured for any filter.
  bool get isEmpty => integrationSecs.isEmpty && goalSecs.isEmpty;

  /// Rejected (accepted-vs-total gap) seconds for [filter].
  double rejectedSecsFor(String filter) {
    final total = totalAcquiredSecs[filter] ?? 0.0;
    final accepted = integrationSecs[filter] ?? 0.0;
    final gap = total - accepted;
    return gap > 0 ? gap : 0.0;
  }
}

/// Accepted + total-acquired per-filter integration for a session.
class RunDashboardSessionIntegration {
  /// Filter -> accepted (isAccepted == true) light-frame seconds.
  final Map<String, double> acceptedSecs;

  /// Filter -> all light-frame seconds (accepted + rejected).
  final Map<String, double> totalSecs;

  const RunDashboardSessionIntegration({
    required this.acceptedSecs,
    required this.totalSecs,
  });

  static const empty =
      RunDashboardSessionIntegration(acceptedSecs: {}, totalSecs: {});
}

/// Compute the goal totals from the loaded sequence's exposure nodes.
Map<String, double> _computeGoalSecs(Sequence? sequence) {
  if (sequence == null) return const {};
  final out = <String, double>{};
  for (final node in sequence.nodes.values.whereType<ExposureNode>()) {
    if (node.frameType != FrameType.light) continue;
    if (!node.isEnabled) continue;
    final filter = (node.filter == null || node.filter!.isEmpty)
        ? 'Unfiltered'
        : node.filter!;
    out[filter] = (out[filter] ?? 0.0) + node.totalDurationSecs;
  }
  return out;
}

/// Pulls light-frame integration totals from the database for the session id
/// provided, split into accepted-only and total-acquired (accepted +
/// rejected). A single DB scan produces both so the dashboard can show "usable
/// vs spent" without a second query.
final runDashboardSessionIntegrationProvider =
    FutureProvider.family<RunDashboardSessionIntegration, int>(
        (ref, sessionId) async {
  final backend = ref.watch(backendProvider);
  // On a remote-client slave the local captured_images table is never
  // populated, so the host's accruing per-filter totals are only reachable
  // over the wire. Pull the same session rows the host serialized
  // (`image.toJson()`) and run the identical accepted/total accumulation so
  // the Filter Integration panel ticks up live instead of stuck at zero.
  // Keep the FutureProvider re-evaluated on the dashboard's existing refresh
  // ticks (callers re-read it) so the slave's totals stay fresh.
  final List<DbCapturedImage> images;
  if (backend is NetworkBackend) {
    final rows = await backend.getSessionImageRows(sessionId);
    images = rows.map(DbCapturedImage.fromJson).toList();
  } else {
    final dao = ref.watch(imagesDaoProvider);
    images = await dao.getImagesForSession(sessionId);
  }
  final accepted = <String, double>{};
  final total = <String, double>{};
  for (final img in images) {
    if (img.frameType != 'light') continue;
    final filter = (img.filter == null || img.filter!.isEmpty)
        ? 'Unfiltered'
        : img.filter!;
    total[filter] = (total[filter] ?? 0.0) + img.exposureDuration;
    if (img.isAccepted) {
      accepted[filter] = (accepted[filter] ?? 0.0) + img.exposureDuration;
    }
  }
  return RunDashboardSessionIntegration(
    acceptedSecs: accepted,
    totalSecs: total,
  );
});

/// Pulls accepted light-frame integration totals from the database for the
/// session id provided. Derived from [runDashboardSessionIntegrationProvider]
/// so callers that only need the accepted map (e.g. the budget panel) don't
/// trigger a second DB scan.
final runDashboardSessionFilterTotalsProvider =
    Provider.family<AsyncValue<Map<String, double>>, int>((ref, sessionId) {
  return ref
      .watch(runDashboardSessionIntegrationProvider(sessionId))
      .whenData((integration) => integration.acceptedSecs);
});

/// Combined per-filter totals + goals for the active sequence/session.
///
/// Surfaces three honest quantities per filter:
///   * accepted integration (counts toward the goal),
///   * total acquired integration (accepted + rejected; what was spent),
///   * the in-flight exposure's elapsed seconds against the current filter,
///     so the operator sees integration tick up live rather than jumping a
///     whole sub at a time once a frame is written.
final runDashboardFilterTotalsProvider =
    Provider<RunDashboardFilterTotals>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  final goals = _computeGoalSecs(sequence);

  final progress = ref.watch(sequenceProgressProvider);
  final exposure = ref.watch(exposureProgressProvider);
  final executionState = ref.watch(sequenceExecutionStateProvider);
  final isActive = executionState == SequenceExecutionState.running ||
      executionState == SequenceExecutionState.paused ||
      executionState == SequenceExecutionState.stopping;
  // Only treat the current exposure's elapsed time as "in flight" while the
  // executor is actually running a frame — not during downloads or when idle.
  final inFlightFilter = isActive ? progress.currentFilter : null;
  final inFlightElapsed = (isActive &&
          !exposure.isDownloading &&
          exposure.frameNumber > 0 &&
          exposure.elapsed > 0)
      ? exposure.elapsed
      : 0.0;

  final sessionId = ref.watch(sessionStateProvider).dbSessionId;
  if (sessionId == null) {
    return RunDashboardFilterTotals(
      integrationSecs: const {},
      totalAcquiredSecs: const {},
      goalSecs: goals,
      inFlightFilter: inFlightFilter,
      inFlightElapsedSecs: inFlightElapsed,
    );
  }

  final integration = ref
          .watch(runDashboardSessionIntegrationProvider(sessionId))
          .valueOrNull ??
      RunDashboardSessionIntegration.empty;

  return RunDashboardFilterTotals(
    integrationSecs: integration.acceptedSecs,
    totalAcquiredSecs: integration.totalSecs,
    goalSecs: goals,
    inFlightFilter: inFlightFilter,
    inFlightElapsedSecs: inFlightElapsed,
  );
});

/// Per-target integration budget progress for the
/// active TargetHeader. `null` when the active target has no budget
/// configured (so the dashboard hides the panel).
class RunDashboardBudgetProgress {
  /// The TargetHeader node id this progress applies to.
  final String targetId;

  /// Resolved per-filter cap (seconds), keyed by filter name. Computed
  /// from the budget config — same math as
  /// `IntegrationBudget::resolved_filter_cap` on the Rust side.
  final Map<String, double> resolvedCapSecs;

  /// Total budget cap (seconds). `0.0` when no total cap is set.
  final double totalSecs;

  /// Completed per-filter integration (seconds), pulled from the
  /// database's accepted-frame totals for the active session.
  final Map<String, double> completedSecs;

  /// True iff the budget is met (every per-filter cap reached OR
  /// total reached). Computed locally for UI; the Rust runtime is the
  /// authoritative source.
  final bool budgetMet;

  const RunDashboardBudgetProgress({
    required this.targetId,
    required this.resolvedCapSecs,
    required this.totalSecs,
    required this.completedSecs,
    required this.budgetMet,
  });

  double get completedTotalSecs =>
      completedSecs.values.fold(0.0, (a, b) => a + b);

  double get fraction {
    if (totalSecs > 0) {
      return (completedTotalSecs / totalSecs).clamp(0.0, 1.0);
    }
    final capSum = resolvedCapSecs.values.fold<double>(0, (a, b) => a + b);
    if (capSum <= 0) return 0;
    return (completedTotalSecs / capSum).clamp(0.0, 1.0);
  }
}

/// Surfaces the integration-budget progress for the
/// currently-active TargetHeader. Returns `null` when no target is
/// active or the active target has no budget configured.
///
/// Computes the resolved per-filter caps locally (cheap; the same math as the
/// Rust side) and asserts the "budget met" flag when every cap is reached. The
/// Rust runtime is the authoritative gate — this provider is render-only.
final runDashboardActiveBudgetProvider =
    Provider<RunDashboardBudgetProgress?>((ref) {
  final target = ref.watch(runDashboardActiveTargetProvider);
  if (target == null) return null;
  final budget = target.integrationBudget;
  if (budget == null || !budget.isActive) return null;

  final resolvedCaps = <String, double>{};
  for (final filter in budget.perFilter.keys) {
    final cap = budget.resolvedFilterCap(filter);
    if (cap != null) resolvedCaps[filter] = cap;
  }

  final sessionId = ref.watch(sessionStateProvider).dbSessionId;
  final completedSecs = sessionId == null
      ? const <String, double>{}
      : ref
              .watch(runDashboardSessionFilterTotalsProvider(sessionId))
              .valueOrNull ??
          const <String, double>{};

  // Budget-met check mirrors `BudgetState::evaluate` on the Rust side.
  final completedTotal = completedSecs.values.fold<double>(0, (a, b) => a + b);
  final totalMet = budget.totalSecs > 0 && completedTotal >= budget.totalSecs;
  final allFiltersMet = resolvedCaps.isNotEmpty &&
      resolvedCaps.entries.every(
        (e) => (completedSecs[e.key] ?? 0) >= e.value,
      );
  final budgetMet = totalMet || allFiltersMet;

  return RunDashboardBudgetProgress(
    targetId: target.id,
    resolvedCapSecs: resolvedCaps,
    totalSecs: budget.totalSecs,
    completedSecs: completedSecs,
    budgetMet: budgetMet,
  );
});

/// Severity classification used by the trigger feed.
enum RunDashboardEventSeverity { info, warning, error, critical }

/// A normalised event entry for the trigger feed.
class RunDashboardEvent {
  /// Stable identity for de-duplication / banner dismissal. Sourced from
  /// the bridge's monotonic `eventId`.
  final BigInt eventId;
  final DateTime time;
  final RunDashboardEventSeverity severity;
  final String category;
  final String title;
  final String message;

  /// True for events that the user must not miss — drives the persistent
  /// banner at the top of the dashboard.
  final bool isCritical;

  /// How many consecutive identical events this row stands for.
  ///
  /// 1 for a lone event. The feed only holds a handful of rows, so a condition
  /// that re-reports itself would otherwise evict everything else: a single
  /// mount unplug produced four identical "Guider disconnected" rows (one per
  /// reconnect attempt, on a 5/10/20s backoff) and filled 4 of the 5 slots,
  /// pushing the equipment error that actually named the cause off-panel.
  final int repeatCount;

  const RunDashboardEvent({
    required this.eventId,
    required this.time,
    required this.severity,
    required this.category,
    required this.title,
    required this.message,
    required this.isCritical,
    this.repeatCount = 1,
  });

  RunDashboardEvent withRepeatCount(int count) => RunDashboardEvent(
        eventId: eventId,
        time: time,
        severity: severity,
        category: category,
        title: title,
        message: message,
        isCritical: isCritical,
        repeatCount: count,
      );
}

/// Identical rows further apart than this are separate happenings, not a
/// repeat: two stops of two different runs read the same but were two
/// operator decisions twenty minutes apart, and folding them rewrites the
/// night. Live repeat storms (a flapping condition) land within seconds.
const _collapseWindow = Duration(minutes: 10);

/// Collapse runs of identical adjacent events into one row carrying a count.
///
/// Identity is the rendered content (category/title/message/severity), not
/// `eventId`: these are genuinely distinct events that happen to say the same
/// thing, which is exactly the case a reader gains nothing from seeing
/// repeated. Only ADJACENT events collapse, so an interleaved different event
/// still breaks the run and the ordering stays truthful. The retained row keeps
/// the NEWEST occurrence's identity and timestamp — "when did this last happen"
/// is the useful question.
List<RunDashboardEvent> collapseRepeatedEvents(
  Iterable<RunDashboardEvent> events,
) {
  final out = <RunDashboardEvent>[];
  // The window measures neighbour-to-neighbour, not first-to-latest: a storm
  // re-reporting every minute for half an hour is still ONE condition, and
  // anchoring on the retained (newest) row would split it and evict the rows
  // that name the cause. Rows arrive newest-first, so the chain's previous
  // occurrence is the one processed last.
  DateTime? chainPreviousTime;
  for (final event in events) {
    final last = out.isEmpty ? null : out.last;
    final isRepeat = last != null &&
        // A stop row is one press or one abort by construction of the fold
        // above; an xN badge would multiply the operator's action.
        event.title != 'Sequence stopped' &&
        // One completed run reaches the wire twice (the executor's explicit
        // SequenceCompleted AND the state-change arm), so completion rows
        // fold below WITHOUT a badge — "Sequence complete x2" reads as two
        // completions that never happened.
        event.title != 'Sequence complete' &&
        last.category == event.category &&
        last.title == event.title &&
        last.message == event.message &&
        last.severity == event.severity &&
        (chainPreviousTime ?? last.time).difference(event.time).abs() <=
            _collapseWindow;
    if (isRepeat) {
      out[out.length - 1] = last.withRepeatCount(last.repeatCount + 1);
      chainPreviousTime = event.time;
    } else {
      out.add(event);
      chainPreviousTime = event.time;
    }
  }
  return out;
}

RunDashboardEventSeverity _mapSeverity(sk_events.EventSeverity sev) {
  switch (sev) {
    case sk_events.EventSeverity.info:
      return RunDashboardEventSeverity.info;
    case sk_events.EventSeverity.warning:
      return RunDashboardEventSeverity.warning;
    case sk_events.EventSeverity.error:
      return RunDashboardEventSeverity.error;
    case sk_events.EventSeverity.critical:
      return RunDashboardEventSeverity.critical;
  }
}

String _categoryLabel(sk_events.EventCategory cat) {
  switch (cat) {
    case sk_events.EventCategory.equipment:
      return 'Equipment';
    case sk_events.EventCategory.imaging:
      return 'Imaging';
    case sk_events.EventCategory.guiding:
      return 'Guiding';
    case sk_events.EventCategory.sequencer:
      return 'Sequencer';
    case sk_events.EventCategory.safety:
      return 'Safety';
    case sk_events.EventCategory.system:
      return 'System';
    case sk_events.EventCategory.polarAlignment:
      return 'Polar align';
  }
}

/// Whether [event] itself claims to be at least an error.
///
/// Guards against payload-type classification escalating an event above the
/// severity it declares.
bool _isAtLeastError(sk_events.SkotiqEvent event) =>
    event.severity == sk_events.EventSeverity.error ||
    event.severity == sk_events.EventSeverity.critical;

/// True when this bridge event is the operator's Stop wearing an error's
/// clothes.
///
/// PRODUCER 3 of the stop pipeline. The native executor ends a cancelled run
/// with `SequencerEvent.Error(message: "Sequence cancelled")`, and that payload
/// variant is on the `isCriticalEvent` allow-list — so a deliberate Stop
/// produced a red "Critical · Sequencer" toast, a full-width red Dashboard
/// banner titled "Sequencer error", and a RECENT EVENTS row saying the same,
/// all at the same second as a Session Report titled "Stopped (resumable)".
///
/// The predicate itself lives in the core so the notification classifier, the
/// executor's own handler and this bridge cannot disagree about what the notice
/// is; only the exact notice is reclassified (a fault whose text merely
/// contains "cancelled" is still an error).
bool isOperatorStopNotice(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return false;
  final sequencerEvent = payload.field0;
  if (sequencerEvent is! sk_events.SequencerEvent_Error) return false;
  return isSequenceCancelledNotice(sequencerEvent.message);
}

/// Whether this event is POSITIVE EVIDENCE that the operator ended the run:
/// ONLY the manual-intervention decision the executor logs from
/// SequencerExecutor::stop ("Operator: stop ..."). The cancel-notice Error
/// and the cancel-notice lifecycle decision are NOT evidence — every
/// cancellation path emits them, including a weather/dome ParkAndAbort with
/// nobody present (the trigger monitor cancels through the same
/// is_cancelled machinery), so claiming "Stopped by request" off them invents
/// an operator action nobody took.
bool _isOperatorStopEvidence(sk_events.SkotiqEvent event) =>
    _stopDecision(event)?.author == SequenceStopAuthor.operatorPress;

/// The stop-authorship decision this bridge event carries, read through the
/// SHARED vocabulary in `run_stop_classification.dart` — the same reader the
/// notification router uses on the core-typed stream, so the feed row and the
/// phone push can never disagree about whose stop it was.
SequenceStopDecision? _stopDecision(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return null;
  final sequencerEvent = payload.field0;
  if (sequencerEvent is! sk_events.SequencerEvent_DecisionLogged) return null;
  return sequenceStopDecision(
    category: sequencerEvent.category,
    summary: sequencerEvent.summary,
    detailsJson: sequencerEvent.detailsJson,
  );
}

/// The system decision the executor logs when the AUTOPILOT commanded the
/// stop (origin `scheduler` on the stop API). Evidence of a cause — just
/// not a human one.
bool _isAutopilotStopEvidence(sk_events.SkotiqEvent event) =>
    _stopDecision(event)?.author == SequenceStopAuthor.autopilot;

/// The run this stop-family event belongs to, when the wire carries it.
/// Episode identity: two events of DIFFERENT runs may never fold together,
/// and two of the SAME run always may, however far apart the safing
/// teardown stretched them.
int? _stopFamilyRunId(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return null;
  final sequencerEvent = payload.field0;
  if (sequencerEvent is sk_events.SequencerEvent_Stopped) {
    return sequencerEvent.sequenceRunId;
  }
  if (sequencerEvent is sk_events.SequencerEvent_DecisionLogged) {
    return sequencerEvent.sequenceRunId;
  }
  return null;
}

/// The rest of the stop family — cause-neutral members that mark THAT the
/// run ended, not WHY: the terminal `Stopped` pair, the cancel-notice Error,
/// and the cancel-notice lifecycle decision.
bool _isNeutralStopFamilyEvent(sk_events.SkotiqEvent event) {
  if (isOperatorStopNotice(event)) return true;
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return false;
  final sequencerEvent = payload.field0;
  if (sequencerEvent is sk_events.SequencerEvent_Stopped) return true;
  return sequencerEvent is sk_events.SequencerEvent_DecisionLogged &&
      isSequenceCancelledNotice(sequencerEvent.summary);
}

/// Which once-per-press producer this event is, or null for the neutral
/// `Stopped` pair (one press legitimately publishes two of those). Each of
/// these kinds fires exactly once per operator stop request, which makes
/// repetition of a kind the honest press counter: one press's producers span
/// seconds (the stop API publishes after the safing teardown) while a mashed
/// Stop repeats every couple of seconds — no time window can separate those,
/// but identity can.
String? _stopEvidenceKind(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return null;
  final sequencerEvent = payload.field0;
  if (sequencerEvent is sk_events.SequencerEvent_Error &&
      sequencerEvent.message == kSequenceCancelledNotice) {
    return 'error-notice';
  }
  if (sequencerEvent is! sk_events.SequencerEvent_DecisionLogged) return null;
  if (sequencerEvent.summary == kSequenceCancelledNotice) {
    return 'decision-notice';
  }
  switch (_stopDecision(event)?.author) {
    case SequenceStopAuthor.operatorPress:
      return 'manual-intervention';
    case SequenceStopAuthor.autopilot:
      return 'autopilot-decision';
    case SequenceStopAuthor.system:
    case null:
      return null;
  }
}

/// How far apart two members of ONE stop episode can plausibly land: the
/// api-published `Stopped` trails the press by the safing teardown
/// (exposure abort + park + dome), which is minutes at the very worst.
const _stopEpisodeSpan = Duration(minutes: 2);

class _StopGroup {
  final int outIndex;
  final Set<String> kinds = <String>{};

  /// The episode's SPINE: the first-seen member plus every member that
  /// carried a run id. Id-less members measure their join distance to the
  /// spine only — never to fellow id-less members — because letting each
  /// id-less join extend the reach turns the bound into a stepping-stone
  /// chain that can absorb (and delete) a stop arbitrarily far away.
  final List<DateTime> spineTimes;
  int? runId;
  _StopGroup(DateTime anchor, this.outIndex) : spineTimes = [anchor];

  Duration nearestSpineDistance(DateTime time) => spineTimes
      .map((t) => t.difference(time).abs())
      .reduce((a, b) => a < b ? a : b);
}

/// Fold each press (or abort) of the stop family into ONE row, regardless of
/// what landed between its producers: park/dome/device rows routinely
/// interleave them, and the api-published `Stopped` can trail the executor's
/// notices by however long the safing teardown takes, so NO time window is
/// used. Identity comes from the stream instead:
///
/// - A run stops at most once, so every family member between two
///   `Started` boundaries belongs to one stop episode; a `Started` closes
///   all open groups (two runs' stops can never merge).
/// - Within the episode, a group accepts at most one member of each
///   once-per-press kind, so a repeated kind — the fingerprint of a second
///   press — starts a new group and mashing Stop stays one row per press.
/// - Members join the NEAREST eligible group by time.
///
/// A group claims "Stopped by request" only when a member is operator
/// evidence (the manual-intervention decision); a safety abort keeps a
/// cause-neutral message. The emitted row keeps its OWN time and eventId —
/// only the message is copied in, so the feed stays newest-first and row
/// identity is stable. Groups never wear an xN badge — that would say it
/// happened N times.
/// One run's completion arrives twice on the wire (explicit terminal +
/// state-change echo). Keep ONE row, badge-free: a x2 would claim two
/// completions, and two rows would too.
List<RunDashboardEvent> _foldDuplicateCompletions(
  List<RunDashboardEvent> rows,
) {
  final out = <RunDashboardEvent>[];
  for (final row in rows) {
    if (row.title == 'Sequence complete' &&
        out.isNotEmpty &&
        out.last.title == 'Sequence complete' &&
        out.last.time.difference(row.time).abs() <=
            const Duration(seconds: 10)) {
      continue;
    }
    out.add(row);
  }
  return out;
}

List<RunDashboardEvent> _foldStopFamilyRows(
  Iterable<sk_events.SkotiqEvent> events,
) {
  final out = <RunDashboardEvent>[];
  final groups = <_StopGroup>[];
  for (final event in events) {
    final evidence =
        _isOperatorStopEvidence(event) || _isAutopilotStopEvidence(event);
    final family = evidence || _isNeutralStopFamilyEvent(event);
    final row = _toDashboardEvent(event);
    if (!family && row.title != 'Sequence stopped') {
      final payload = event.payload;
      if (payload is sk_events.EventPayload_Sequencer &&
          payload.field0 is sk_events.SequencerEvent_Started) {
        // Run boundary: anything older belongs to a previous run's episode.
        groups.clear();
      }
      out.add(row);
      continue;
    }
    final kind = _stopEvidenceKind(event);
    final runId = _stopFamilyRunId(event);
    _StopGroup? group;
    Duration? bestDistance;
    for (final candidate in groups) {
      if (kind != null && candidate.kinds.contains(kind)) continue;
      // Run identity outranks time: same run always joins (the safing
      // teardown can stretch one episode's producers arbitrarily far),
      // different runs never do.
      if (runId != null && candidate.runId != null) {
        if (candidate.runId != runId) continue;
        group = candidate;
        break;
      }
      final distance = candidate.nearestSpineDistance(row.time);
      // For id-less members the Started boundary is the primary separator,
      // but it is published by exactly one producer — anywhere it is
      // missing (an attached session, a truncated stream) an unbounded
      // join would absorb an arbitrarily old stop row and DELETE it from
      // the night's record. Past the bound the fold degrades to two rows,
      // which is the honest direction.
      if (distance > _stopEpisodeSpan) continue;
      if (bestDistance == null || distance < bestDistance) {
        group = candidate;
        bestDistance = distance;
      }
    }
    if (group == null) {
      final started = _StopGroup(row.time, out.length);
      if (kind != null) started.kinds.add(kind);
      started.runId = runId;
      groups.add(started);
      out.add(row);
      continue;
    }
    if (kind != null) group.kinds.add(kind);
    group.runId ??= runId;
    if (runId != null) group.spineTimes.add(row.time);
    // If this member knows the cause and the emitted row does not, the row
    // learns the MESSAGE only — time, eventId, and position stay the
    // emitted row's own.
    final at = group.outIndex;
    if (out[at].message.isEmpty && row.message.isNotEmpty) {
      final kept = out[at];
      out[at] = RunDashboardEvent(
        eventId: kept.eventId,
        time: kept.time,
        severity: kept.severity,
        category: kept.category,
        title: kept.title,
        message: row.message,
        isCritical: kept.isCritical,
        repeatCount: kept.repeatCount,
      );
    }
  }
  return out;
}

/// Convert a freezed bridge event into the dashboard's compact model.
///
/// Uses the exhaustive switch helpers in `event_display.dart` so a new
/// payload variant becomes a compile error here instead of a silent
/// "Unknown event" row on the live rig.
RunDashboardEvent _toDashboardEvent(sk_events.SkotiqEvent event) {
  final ms = event.timestamp.toInt();
  // A stop is still worth a row in the feed — it is how the operator
  // reconstructs the night — but it is an INFO row that says what happened,
  // not a critical "Sequencer error".
  if (_isOperatorStopEvidence(event) ||
      _isAutopilotStopEvidence(event) ||
      _isNeutralStopFamilyEvent(event)) {
    return RunDashboardEvent(
      eventId: event.eventId,
      time: DateTime.fromMillisecondsSinceEpoch(ms),
      severity: RunDashboardEventSeverity.info,
      category: _categoryLabel(event.category),
      title: 'Sequence stopped',
      // Only evidence may claim a cause — and it names WHOSE: the
      // operator's decision or the autopilot's. A bare Stopped may be a
      // safety abort with nobody at the keyboard and stays neutral.
      message: _isOperatorStopEvidence(event)
          ? kSequenceStoppedByRequestMessage
          : _isAutopilotStopEvidence(event)
              ? kSequenceStoppedByAutopilotMessage
              : '',
      isCritical: false,
    );
  }
  final severity = _mapSeverity(event.severity);
  // `isCriticalEvent` classifies by PAYLOAD type, so on its own it will promote
  // a benign event to critical whenever a payload is reused for something
  // routine. An event's declared severity is the authoritative statement about
  // how bad it is, and nothing should silently escalate past it — the alerting
  // path below already refuses to treat an Info event as critical, and the two
  // must not disagree about the same event.
  final isCritical = sk_events.isCriticalEvent(event) && _isAtLeastError(event);
  return RunDashboardEvent(
    eventId: event.eventId,
    time: DateTime.fromMillisecondsSinceEpoch(ms),
    severity: isCritical ? RunDashboardEventSeverity.critical : severity,
    category: _categoryLabel(event.category),
    title: sk_events.skotiqEventDisplayTitle(event),
    message: _nameDepthGoal(
      _humanizeDeviceIds(sk_events.skotiqEventDisplayDetail(event), event),
      event,
    ),
    isCritical: isCritical,
  );
}

/// Name the goal behind a "depth goal reached" row.
///
/// The shared sentence in `event_display.dart` is about the FILTER, because
/// that is what the operator watched stop early, and every surface renders it
/// identically. The run history is also where they come back days later to
/// find the goal itself — and a goal is addressed by its id and the revision
/// the verdict was reached on — so the identity is appended here rather than
/// pushed into the sentence the other surfaces share.
String _nameDepthGoal(String message, sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return message;
  final sequencer = payload.field0;
  if (sequencer is! sk_events.SequencerEvent_DepthGoalCompleted) {
    return message;
  }
  return '$message · goal ${sequencer.goalId} revision ${sequencer.revision}';
}

/// Swap an internal device id out of a feed row for the name the rest of the
/// app shows.
///
/// The bridge's display helper subtitles every equipment row with
/// `<type> · <device_id>` — live, that reads `Camera · sim_camera_1`, and on
/// the built-in guider `Guider · native:builtin_guider:multi_star`. A device id
/// is a routing key, not something an astrophotographer recognises, and the
/// same feed is what an operator scans to reconstruct their night.
String _humanizeDeviceIds(String message, sk_events.SkotiqEvent event) {
  final deviceId = event.deviceId;
  if (deviceId == null || deviceId.isEmpty) return message;
  if (!message.contains(deviceId)) return message;
  final friendly = friendlyNameFromDeviceId(deviceId);
  if (friendly.isEmpty || friendly == deviceId) return message;
  return message.replaceAll(deviceId, friendly);
}

/// Whether [event] is something a user reads their night from.
///
/// The feed is meant to summarise the night, and on a fresh profile its only
/// entry was `System EventStreamReady — Event stream subscription is active
/// (debug)`. One connect then filled it with `Heartbeat started · Heartbeat
/// stopped · Heartbeat started · Heartbeat stopped · Connected`: five rows for
/// one action, four of them monitor plumbing that means nothing to an
/// astrophotographer and that evicted the events that do. Both still reach the
/// diagnostics log, which is where they belong.
bool isUserFacingRunEvent(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is sk_events.EventPayload_Equipment) {
    final equipment = payload.field0;
    return equipment is! sk_events.EquipmentEvent_HeartbeatStarted &&
        equipment is! sk_events.EquipmentEvent_HeartbeatStopped;
  }
  if (payload is sk_events.EventPayload_System) {
    final system = payload.field0;
    return !(system is sk_events.SystemEvent_Notification &&
        system.level.toLowerCase() == 'debug');
  }
  return true;
}

/// [events], newest first, as the trigger feed's rows: user-facing events
/// only, a stop episode folded to one row, a doubled completion to one, and
/// repeats of one condition collapsed with a count.
List<RunDashboardEvent> runDashboardFeedRows(
  Iterable<sk_events.SkotiqEvent> events,
) =>
    collapseRepeatedEvents(
      _foldDuplicateCompletions(
        _foldStopFamilyRows(events.where(isUserFacingRunEvent)),
      ),
    );

/// Last N events (default 5) classified for the trigger feed.
///
/// Built off the existing `eventHistoryProvider` so we don't run a second
/// subscription. The rendering layer can configure how many to show.
final runDashboardRecentEventsProvider =
    Provider.family<List<RunDashboardEvent>, int>((ref, limit) {
  final history = ref.watch(eventHistoryProvider);
  // Collapse BEFORE taking `limit`, so squashing a repeated condition actually
  // frees slots for the different events behind it. Taking first would leave
  // the panel showing one collapsed row and four blanks' worth of lost history.
  return runDashboardFeedRows(history).take(limit).toList(growable: false);
});

// Critical event escalation

/// State of critical events that the user has *not* dismissed yet.
///
/// A user who walks away from the laptop for an hour and comes back needs
/// to be able to see at-a-glance whether anything critical happened. The
/// trigger feed alone is not enough — it only holds 5 rows and they
/// scroll off. Critical events are escalated by:
///
///   * Holding them in this notifier indefinitely (until the user
///     dismisses them or clears via "Mark all seen").
///   * Rendering a persistent banner above the Run Dashboard
///     (`run_dashboard_critical_banner.dart`).
///   * Forwarding them to [uiNotificationProvider] as toast / center
///     notifications so the global app notification queue surfaces them
///     consistently with other in-app alerts.
///   * Optionally firing an audible alert (system bell) when the user has
///     enabled `audibleAlertsOnCritical` in settings.
class RunDashboardCriticalEventsNotifier
    extends StateNotifier<List<RunDashboardEvent>> {
  RunDashboardCriticalEventsNotifier(this._ref) : super(const []);

  final Ref _ref;

  /// Maximum number of unsigned events to retain. If the user is
  /// genuinely racking up dozens of unresolved critical events something
  /// is very wrong, but we still want to bound memory.
  static const int _maxRetained = 50;

  void add(RunDashboardEvent event) {
    if (!mounted) return;
    // Skip exact duplicates (same eventId) — the bridge emits the same
    // event to multiple subscribers and we may receive it twice.
    if (state.any((e) => e.eventId == event.eventId)) return;
    final next = [event, ...state];
    if (next.length > _maxRetained) {
      // Truncating drops the oldest unresolved critical events. Surface the
      // overflow count so the banner can render a "+N earlier critical
      // events not shown" marker instead of silently losing them.
      final dropped = next.length - _maxRetained;
      next.removeRange(_maxRetained, next.length);
      _ref.read(runDashboardDroppedCriticalCountProvider.notifier).state +=
          dropped;
    }
    state = next;
  }

  void dismiss(BigInt eventId) {
    if (!mounted) return;
    state = state.where((e) => e.eventId != eventId).toList();
  }

  void clearAll() {
    if (!mounted) return;
    state = const [];
    // A full clear also resets the overflow marker — there is nothing left
    // for the dropped count to refer to.
    _ref.read(runDashboardDroppedCriticalCountProvider.notifier).state = 0;
  }
}

final runDashboardCriticalEventsProvider = StateNotifierProvider<
    RunDashboardCriticalEventsNotifier, List<RunDashboardEvent>>((ref) {
  return RunDashboardCriticalEventsNotifier(ref);
});

/// Count of oldest critical events dropped from
/// [runDashboardCriticalEventsProvider] once the retention cap is exceeded.
/// The banner renders a "+N earlier critical events not shown" marker so the
/// truncation is honest rather than silent. Reset on "Dismiss all".
final runDashboardDroppedCriticalCountProvider = StateProvider<int>((ref) => 0);

/// Cooldown between consecutive audible alerts so a storm of critical
/// events (e.g. a power loss that cascades into mount + camera + guider
/// disconnects in the same second) doesn't machine-gun-beep at the user.
const Duration _audibleAlertCooldown = Duration(seconds: 5);

/// Map the typed event category (`sk_events.EventCategory`) to the
/// `EventCategory` enum that [PushNotificationService] expects on its
/// synthetic-injection API.
/// Why two enums: the typed event category is generated from FRB (surfaced
/// through the `skotiq_core_events` seam); `skotiq_core` also has its
/// own wire/JSON copy used by services (`PushNotification.category` is the
/// unprefixed core enum).
EventCategory _bridgeCategoryToCore(sk_events.EventCategory cat) {
  switch (cat) {
    case sk_events.EventCategory.equipment:
      return EventCategory.equipment;
    case sk_events.EventCategory.imaging:
      return EventCategory.imaging;
    case sk_events.EventCategory.guiding:
      return EventCategory.guiding;
    case sk_events.EventCategory.sequencer:
      return EventCategory.sequencer;
    case sk_events.EventCategory.safety:
      return EventCategory.safety;
    case sk_events.EventCategory.system:
      return EventCategory.system;
    case sk_events.EventCategory.polarAlignment:
      return EventCategory.polarAlignment;
  }
}

/// True when the router's own backend event-stream classifier already routes
/// this event to systemPush — i.e. the eager-mounted [NotificationRouter] will
/// push it on its own from the core stream. The dashboard bridge must NOT also
/// push those, or the operator's phone pages twice for one alert.
///
/// This mirrors exactly the `isCriticalEvent` payload variants that the shared
/// [NotificationEventClassifier] maps to a systemPush-by-default category:
/// exposure-failed, weather-unsafe / emergency-stop, disk-low, sequencer
/// error / stop, and recovery-gave-up. The remaining critical events the
/// dashboard escalates (notably generic system errors / FITS save failures,
/// which the classifier returns null for) are NOT covered by the router, so
/// the bridge still forwards those — that is the gap this bridge exists to
/// fill. The router's content-signature dedup is a backstop; this predicate is
/// the primary, intent-level guard so the two paths never both page.
bool _routerClassifierAlreadyPushes(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  return switch (payload) {
    sk_events.EventPayload_Imaging(field0: final v) => switch (v) {
        sk_events.ImagingEvent_ExposureFailed() => true,
        sk_events.ImagingEvent_ExposureFailedOld() => true,
        _ => false,
      },
    sk_events.EventPayload_Safety(field0: final v) => switch (v) {
        sk_events.SafetyEvent_WeatherUnsafe() => true,
        sk_events.SafetyEvent_EmergencyStop() => true,
        _ => false,
      },
    sk_events.EventPayload_System(field0: final v) => switch (v) {
        // The classifier maps only "disk*" system events to a category; a
        // generic SystemEvent.error classifies to null, so the bridge must
        // still push it (that is the gap below).
        sk_events.SystemEvent_DiskSpaceLow() => true,
        _ => false,
      },
    sk_events.EventPayload_Sequencer(field0: final v) => switch (v) {
        sk_events.SequencerEvent_Error() => true,
        sk_events.SequencerEvent_Stopped() => true,
        sk_events.SequencerEvent_RecoveryGaveUp() => true,
        _ => false,
      },
    // Guiding / equipment events only reach this bridge as critical when they
    // carry critical severity (their normal error-severity StarLost /
    // Disconnected are NOT `isCriticalEvent`, so the classifier alone pushes
    // those). At critical severity the classifier only pushes the specific
    // StarLost/Disconnected/Error eventTypes; any OTHER critical guiding/
    // equipment event would classify to null and get no push. Rather than risk
    // MISSING such a page (errors-are-a-feature: never drop an operator
    // alert), we let the bridge forward these and rely on the router's
    // content-signature dedup to collapse the rare matching-copy overlap. A
    // possible duplicate is strictly safer than a missed critical page.
    _ => false,
  };
}

/// True for the event that opens a run, which resets the per-run ledger of
/// already-escalated failure reasons.
bool _isSequencerRunStart(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  return payload is sk_events.EventPayload_Sequencer &&
      payload.field0 is sk_events.SequencerEvent_Started;
}

/// True when [event] is the terminal `SequenceFailed` merely RESTATING a
/// reason this run already escalated, in which case the caller must not
/// escalate it a second time.
///
/// The native executor derives `SequenceFailed.error` by draining the
/// broadcast buffer for the last `InstructionFailed` and re-formatting it as
/// `"<node>: <message>"` (`executor/mod.rs: last_instruction_failure`) — the
/// byte-identical string the bridge already delivered as a mid-run
/// `SequencerEvent.Error`. Both payload variants are on the `isCriticalEvent`
/// allow-list, so one failed Open Cover node raised TWO identical
/// "Critical · Sequencer" toasts and left two identical rows in the critical
/// banner. Matching on the reason text (rather than a time window) is what
/// keeps this from swallowing a genuinely new failure: a terminal error the
/// run never announced mid-flight is still escalated, and the ledger is
/// per-run.
///
/// Recording happens here too, so the mid-run Error that IS escalated is
/// remembered for its own terminal restatement.
bool _isRestatedFailureReason(
  sk_events.SkotiqEvent event,
  Set<String> escalatedReasons,
) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return false;
  final sequencerEvent = payload.field0;
  final reason = sk_events.skotiqEventDisplayDetail(event);
  if (reason.isEmpty) return false;

  if (sequencerEvent is sk_events.SequencerEvent_Error) {
    escalatedReasons.add(reason);
    return false;
  }
  if (sequencerEvent is sk_events.SequencerEvent_Failed) {
    return escalatedReasons.contains(reason);
  }
  return false;
}

/// Side-effect provider: subscribes to the event history and routes
/// critical events through the dashboard notifier, the in-app
/// notification queue, the audible alert player, and the mobile push
/// notification stream.
///
/// This provider must be `ref.watch`-ed somewhere in the widget tree for
/// the side effects to run. The Run Dashboard scaffolding watches it in
/// its build method.
final runDashboardCriticalEventsBridgeProvider = Provider<void>((ref) {
  // Use ref.listen on the history so we react to new entries without
  // depending on the order or count of rebuilds.
  BigInt? lastSeenId;
  // Last time we played the audible alert. We hold this in the provider
  // closure scope so the cooldown survives provider rebuilds.
  DateTime? lastAlertAt;
  // Mid-run failure reasons this run has already escalated, so the terminal
  // event that restates one is not escalated a second time. See
  // [_isRestatedFailureReason].
  final escalatedSequencerFailureReasons = <String>{};

  ref.listen<List<sk_events.SkotiqEvent>>(
    eventHistoryProvider,
    (previous, next) {
      if (next.isEmpty) return;
      // Iterate from oldest-to-newest among entries the bridge hasn't
      // seen before. The history list is newest-first.
      final fresh = <sk_events.SkotiqEvent>[];
      for (final event in next) {
        if (lastSeenId != null && event.eventId <= lastSeenId!) break;
        fresh.add(event);
      }
      if (fresh.isEmpty) return;
      lastSeenId = fresh.first.eventId;

      // Read settings once per batch; the user can't toggle these mid-batch
      // and re-reading per event would race the AsyncNotifier update.
      final settings = ref.read(appSettingsProvider).valueOrNull;
      final audibleEnabled = settings?.audibleAlertsOnCritical ?? false;
      final soundChoice = settings?.criticalAlertSound ?? 'systemBell';
      final pushEnabled = settings?.pushCriticalAlerts ?? true;

      // Process oldest-first so the most recent ends up at the head of
      // the notifier's state list.
      for (final event in fresh.reversed) {
        // An Info-severity event is never a critical alert, regardless of its
        // payload type. The Rust executor deliberately surfaces benign
        // runtime-config updates (e.g. `conditions_score`) with Info severity
        // but reuses the `SequencerEvent::Error` payload to avoid an FRB regen
        // (see native `RuntimeConfigUpdated`); isCriticalEvent keys off that
        // Error payload, so without this guard every 30s config tick flooded
        // the run dashboard with false "Sequencer error" banners + audible /
        // push alerts.
        // A fresh run starts a fresh ledger of reasons. Checked ahead of the
        // severity/criticality gates because a run start is Info-severity and
        // is not itself a critical event.
        if (_isSequencerRunStart(event)) {
          escalatedSequencerFailureReasons.clear();
        }
        if (event.severity == sk_events.EventSeverity.info) continue;
        if (!sk_events.isCriticalEvent(event)) continue;
        // The operator's own Stop arrives here as a critical sequencer Error
        // (see [isOperatorStopNotice]). It is not an alert: no red banner, no
        // "Critical · Sequencer" toast, no audible alarm, no phone page for a
        // button the operator just pressed. It still reaches the feed as an
        // info row via [_toDashboardEvent].
        if (isOperatorStopNotice(event)) {
          developer.log(
            '[$kStopClassificationLogTag] run_dashboard bridge: cancellation '
            'notice not escalated',
            name: 'RunDashboardCriticalEventsBridge',
          );
          continue;
        }
        if (_isRestatedFailureReason(event, escalatedSequencerFailureReasons)) {
          continue;
        }
        final dashboardEvent = _toDashboardEvent(event);
        ref
            .read(runDashboardCriticalEventsProvider.notifier)
            .add(dashboardEvent);

        // Forward to the in-app notification queue. Title is the
        // category, message is the event detail (or title if there is
        // no detail). Long duration so the toast doesn't time out while
        // the user is reading.
        final notif = ref.read(uiNotificationProvider.notifier);
        final detail = dashboardEvent.message.isNotEmpty
            ? dashboardEvent.message
            : dashboardEvent.title;
        notif.showError(
          detail,
          title: 'Critical · ${dashboardEvent.category}',
          duration: const Duration(seconds: 30),
        );

        // Audible alert: respects the user setting + the 5-second cooldown
        // so a storm of critical events doesn't make the laptop sound like
        // a slot machine.
        if (audibleEnabled && soundChoice != 'none') {
          final now = DateTime.now();
          if (lastAlertAt == null ||
              now.difference(lastAlertAt!) >= _audibleAlertCooldown) {
            lastAlertAt = now;
            // Fire-and-forget: SystemSound.play returns Future<void> and we
            // don't gate further work on it. Errors from the platform
            // channel are surfaced via developer.log inside the player
            // rather than thrown — a failed audio cue must not crash the
            // event dispatch path.
            final player = ref.read(criticalAlertPlayerProvider);
            player.play(sound: soundChoice);
          }
        }

        // Mobile push notification: forwarded through the NotificationRouter
        // — the single systemPush producer after the architecture-unification
        // collapse. The router's SystemPushTransport broadcasts to paired
        // phones as a critical WebSocket message. This path covers criticality
        // classifications the router's core-stream classifier does not push on
        // its own (e.g. generic system errors / FITS save failures); for
        // events the classifier DOES recognise, the router's systemPush
        // content-signature dedup collapses this push and the classifier's
        // into exactly one page. The router honours the master push gate, so
        // the `pushEnabled` check here mirrors the user's `pushCriticalAlerts`
        // preference (an extra, cheap short-circuit).
        if (pushEnabled && !_routerClassifierAlreadyPushes(event)) {
          final router = ref.read(notificationRouterProvider);
          router.routeBridgeCriticalPush(
            title: 'Critical · ${dashboardEvent.category}',
            body: detail,
            eventType: sk_events.skotiqEventDisplayTitle(event),
            eventCategory: _bridgeCategoryToCore(event.category),
          );
        }
      }
    },
    fireImmediately: true,
  );
});
