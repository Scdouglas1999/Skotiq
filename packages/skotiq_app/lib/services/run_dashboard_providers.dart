import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/backend.dart' show SkotiqBackend;
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
// The typed bridge event union (`SkotiqEvent` / `EventCategory` /
// `EventSeverity`) collides by name with the wire/JSON event model that the
// unprefixed barrel above keeps canonical, so the typed surface is imported
// from the core's dedicated typed-event seam under the `sk_events` prefix.
// (The non-colliding members — `EventPayload_*` variants, the display helpers,
// `isCriticalEvent` — are reachable unprefixed off the barrel, but we keep them
// behind the prefix here so every typed-event reference in this file reads from
// one place.)
import 'package:skotiq_core/bridge_events.dart' as sk_events;
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';

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
  final (altitude, azimuth) = AstronomyCalculations.objectAltAz(
    raDeg: target.raHours * 15.0,
    decDeg: target.decDegrees,
    dt: now,
    latitudeDeg: location.latitude,
    longitudeDeg: location.longitude,
  );

  final transit = AstronomyCalculations.transitOnUtcDate(
    raDeg: target.raHours * 15.0,
    decDeg: target.decDegrees,
    date: now.toUtc(),
    longitudeDeg: location.longitude,
  );
  Duration? timeToTransit;
  if (transit.isAfter(now)) {
    timeToTransit = transit.difference(now);
  }

  // The site's altitude floor, the one every time-to-set reads.
  final floor = ref.watch(altitudeFloorProvider);
  final horizonDeg = floor.atAzimuth(azimuth);
  final timeToSet = floor.timeUntilBelow(
    raDeg: target.raHours * 15.0,
    decDeg: target.decDegrees,
    now: now,
    latitudeDeg: location.latitude,
    longitudeDeg: location.longitude,
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

  bool get isEmpty => integrationSecs.isEmpty && goalSecs.isEmpty;
}

Map<String, double> _computeGoalSecs(Sequence? sequence) {
  if (sequence == null) return const {};
  final out = <String, double>{};
  for (final node in sequence.nodes.values.whereType<ExposureNode>()) {
    if (node.frameType != FrameType.light) continue;
    if (!node.isEnabled) continue;
    final filter = (node.filter == null || node.filter!.isEmpty)
        ? IntegrationByFilter.unfiltered
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
    FutureProvider.family<IntegrationByFilter, int>((ref, sessionId) async {
  // A linked client's session rows are the host's; the dashboard's refresh
  // ticks re-read this provider so the totals stay current.
  return IntegrationByFilter.of(
      await ref.watch(imagingRecordsProvider).getImagesForSession(sessionId));
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
      IntegrationByFilter.empty;

  return RunDashboardFilterTotals(
    integrationSecs: integration.acceptedSecs,
    totalAcquiredSecs: integration.totalSecs,
    goalSecs: goals,
    inFlightFilter: inFlightFilter,
    inFlightElapsedSecs: inFlightElapsed,
  );
});

enum RunDashboardEventSeverity { info, warning, error, critical }

/// What a feed row stands for, as the feed's folds read it: one stop of a
/// run, one run's completion, a cooler set-point, or any other event.
enum RunDashboardRowKind { stop, completion, coolerSetpoint, other }

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
  /// that re-reports itself would otherwise evict everything else.
  final int repeatCount;

  /// What this critical event is about when a newer event about the same
  /// thing supersedes it: a second meridian flip failure replaces the first
  /// in the banner rather than queueing behind it. Null for events that stand
  /// on their own.
  final String? faultKey;

  /// True for a fault of the run itself (a flip failure, a sequencer error,
  /// a failed run). The banner drops it once the run goes on: resumed after
  /// the pause it caused, or a new run started.
  final bool isRunFault;

  final RunDashboardRowKind kind;

  const RunDashboardEvent({
    required this.eventId,
    required this.time,
    required this.severity,
    required this.category,
    required this.title,
    required this.message,
    required this.isCritical,
    this.repeatCount = 1,
    this.faultKey,
    this.isRunFault = false,
    this.kind = RunDashboardRowKind.other,
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
        faultKey: faultKey,
        isRunFault: isRunFault,
        kind: kind,
      );

  /// Same event, same words: what the banner treats as one entry. The id
  /// alone is not enough on a linked client, where it is the host's
  /// millisecond timestamp and two events of one millisecond share it.
  bool sameAs(RunDashboardEvent other) =>
      other.eventId == eventId &&
      other.title == title &&
      other.message == message &&
      other.category == category;
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
        event.kind != RunDashboardRowKind.stop &&
        // One completed run reaches the wire twice (the executor's explicit
        // SequenceCompleted AND the state-change arm), so completion rows
        // fold below WITHOUT a badge — "Sequence complete x2" reads as two
        // completions that never happened.
        event.kind != RunDashboardRowKind.completion &&
        last.category == event.category &&
        last.title == event.title &&
        last.message == event.message &&
        last.severity == event.severity &&
        (chainPreviousTime ?? last.time).difference(event.time).abs() <=
            _collapseWindow;
    // A warm-up ramp moves the set-point a third of a degree every ten
    // seconds, about ninety rows that buried everything else in the log.
    // Adjacent set-points fold into the newest, without a count: only the
    // set-point now in force matters.
    final isSetpointStep = last != null &&
        event.kind == RunDashboardRowKind.coolerSetpoint &&
        last.kind == RunDashboardRowKind.coolerSetpoint &&
        (chainPreviousTime ?? last.time).difference(event.time).abs() <=
            _collapseWindow;
    if (isSetpointStep) {
      chainPreviousTime = event.time;
    } else if (isRepeat) {
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

/// True when this bridge event is a stopped run's cancellation `Error`. It
/// names nobody: every way a run is stopped sends it.
bool _isRunCancellation(sk_events.SkotiqEvent event) =>
    switch (_sequencerEvent(event)) {
      sk_events.SequencerEvent_Error(
        kind: sk_events.SequencerErrorKind.cancelled,
      ) =>
        true,
      _ => false,
    };

/// True when this bridge event is a stopped run's cancellation decision row.
bool _isCancellationRow(sk_events.SkotiqEvent event) =>
    switch (_sequencerEvent(event)) {
      sk_events.SequencerEvent_DecisionLogged(
        stop: sk_events.SequencerStop_Cancelled(),
      ) =>
        true,
      _ => false,
    };

sk_events.SequencerEvent? _sequencerEvent(sk_events.SkotiqEvent event) =>
    switch (event.payload) {
      sk_events.EventPayload_Sequencer(:final field0) => field0,
      _ => null,
    };

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
SequenceStopDecision? _stopDecision(sk_events.SkotiqEvent event) =>
    switch (_sequencerEvent(event)) {
      sk_events.SequencerEvent_DecisionLogged(:final stop) =>
        sequenceStopDecisionOf(stop),
      _ => null,
    };

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
bool _isNeutralStopFamilyEvent(sk_events.SkotiqEvent event) =>
    _isRunCancellation(event) ||
    _isCancellationRow(event) ||
    _sequencerEvent(event) is sk_events.SequencerEvent_Stopped;

/// Which once-per-press producer this event is, or null for the neutral
/// `Stopped` pair (one press legitimately publishes two of those). Each of
/// these kinds fires exactly once per operator stop request, which makes
/// repetition of a kind the honest press counter: one press's producers span
/// seconds (the stop API publishes after the safing teardown) while a mashed
/// Stop repeats every couple of seconds — no time window can separate those,
/// but identity can.
String? _stopEvidenceKind(sk_events.SkotiqEvent event) {
  if (_isRunCancellation(event)) return 'error-notice';
  if (_isCancellationRow(event)) return 'decision-notice';
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
    if (row.kind == RunDashboardRowKind.completion &&
        out.isNotEmpty &&
        out.last.kind == RunDashboardRowKind.completion &&
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
    if (!family && row.kind != RunDashboardRowKind.stop) {
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
        kind: kept.kind,
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
      kind: RunDashboardRowKind.stop,
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
  final stopWords = _guidingStopWords(event);
  return RunDashboardEvent(
    eventId: event.eventId,
    time: DateTime.fromMillisecondsSinceEpoch(ms),
    severity: isCritical ? RunDashboardEventSeverity.critical : severity,
    category: _categoryLabel(event.category),
    // A guiding stop's reason is a whole sentence ("Guiding stopped because
    // the run was stopped"), so it is the row.
    title: stopWords ?? sk_events.skotiqEventDisplayTitle(event),
    message: stopWords != null
        ? ''
        : _nameDepthGoal(
            humanizeDeviceIds(sk_events.skotiqEventDisplayDetail(event), event),
            event,
          ),
    isCritical: isCritical,
    faultKey: _faultKey(event),
    isRunFault: _isRunFault(event),
    kind: _rowKind(event),
  );
}

/// Why guiding stopped, in words: the event carries the wire code
/// (`run_stopped`), and the log printed it as it came.
String? _guidingStopWords(sk_events.SkotiqEvent event) =>
    switch (event.payload) {
      sk_events.EventPayload_Guiding(
        field0: sk_events.GuidingEvent_StopReason(:final reason?)
      ) =>
        GuidingStopReason.fromWire(reason)?.text,
      _ => null,
    };

RunDashboardRowKind _rowKind(sk_events.SkotiqEvent event) =>
    switch (event.payload) {
      sk_events.EventPayload_Sequencer(
        field0: sk_events.SequencerEvent_Completed()
      ) =>
        RunDashboardRowKind.completion,
      sk_events.EventPayload_Equipment(
        field0: sk_events.EquipmentEvent_CameraCoolingStarted()
      ) =>
        RunDashboardRowKind.coolerSetpoint,
      _ => RunDashboardRowKind.other,
    };

/// The banner key of a meridian flip outcome. One flip is one thing to know
/// about: its newest failure replaces the older one, and a flip that
/// succeeds clears it.
const String _meridianFlipFaultKey = 'meridian_flip';

/// The banner key of a camera's failed exposures. A camera that reopens
/// fails a frame or two and then images on; its newest failure replaces the
/// older ones, and its next good frame clears them.
const String _exposureFaultPrefix = 'exposure_failed:';

/// A failure no camera was named on has the bare prefix as its key.
String _exposureFaultKey(String? deviceId) =>
    deviceId == null ? _exposureFaultPrefix : '$_exposureFaultPrefix$deviceId';

String? _faultKey(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is sk_events.EventPayload_Imaging) {
    return switch (payload.field0) {
      sk_events.ImagingEvent_ExposureFailed() ||
      sk_events.ImagingEvent_ExposureFailedOld() =>
        _exposureFaultKey(event.deviceId),
      _ => null,
    };
  }
  if (payload is! sk_events.EventPayload_Sequencer) return null;
  return payload.field0 is sk_events.SequencerEvent_MeridianFlipOutcome
      ? _meridianFlipFaultKey
      : null;
}

/// True for an event that says a frame came off the camera: the camera
/// images again, whatever failed before.
bool _isGoodFrame(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  return switch (payload) {
    sk_events.EventPayload_Imaging(field0: final v) => switch (v) {
        sk_events.ImagingEvent_ExposureCompleted() ||
        sk_events.ImagingEvent_ExposureCompletedWithFrame() ||
        sk_events.ImagingEvent_ImageSaved() =>
          true,
        sk_events.ImagingEvent_ExposureComplete(success: final ok) => ok,
        _ => false,
      },
    sk_events.EventPayload_Sequencer(field0: final v) =>
      v is sk_events.SequencerEvent_ExposureCompleted,
    _ => false,
  };
}

bool _isRunFault(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return false;
  return switch (payload.field0) {
    sk_events.SequencerEvent_MeridianFlipOutcome() ||
    sk_events.SequencerEvent_Error() ||
    sk_events.SequencerEvent_Failed() =>
      true,
    _ => false,
  };
}

bool _isSuccessfulFlip(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return false;
  final sequencerEvent = payload.field0;
  return sequencerEvent is sk_events.SequencerEvent_MeridianFlipOutcome &&
      sequencerEvent.outcome == sk_events.FlipOutcome.success;
}

/// True for the events that say the run goes on: a resume, or a new run.
bool _isRunContinuing(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is! sk_events.EventPayload_Sequencer) return false;
  return payload.field0 is sk_events.SequencerEvent_Resumed ||
      payload.field0 is sk_events.SequencerEvent_Started;
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
String humanizeDeviceIds(String message, sk_events.SkotiqEvent event) {
  final deviceId = event.deviceId;
  if (deviceId == null || deviceId.isEmpty) return message;
  if (!message.contains(deviceId)) return message;
  final friendly = friendlyNameFromDeviceId(deviceId);
  if (friendly.isEmpty || friendly == deviceId) return message;
  return message.replaceAll(deviceId, friendly);
}

/// Whether [event] is something a user reads their night from.
///
/// The feed is meant to summarise the night; connection and heartbeat
/// plumbing means nothing to an astrophotographer and would evict the events
/// that do. Both still reach the diagnostics log, which is where they belong.
bool isUserFacingRunEvent(sk_events.SkotiqEvent event) {
  final payload = event.payload;
  if (payload is sk_events.EventPayload_Equipment) {
    final equipment = payload.field0;
    // A property change is how a device's state reaches the screens that
    // show it (filter names, a camera setting, autofocus progress); the
    // feed read "Property changed · Filter Wheel · FilterNames".
    return equipment is! sk_events.EquipmentEvent_HeartbeatStarted &&
        equipment is! sk_events.EquipmentEvent_HeartbeatStopped &&
        equipment is! sk_events.EquipmentEvent_PropertyChanged;
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

/// State of critical events that the user has *not* dismissed yet.
///
/// A user who walks away from the laptop for an hour and comes back needs
/// to be able to see at-a-glance whether anything critical happened. The
/// trigger feed alone is not enough — it only holds 5 rows and they
/// scroll off. This notifier holds them until the user dismisses them or
/// clears them all; Tonight's banner (`critical_event_banner.dart`) shows
/// them. [runCriticalAlertsProvider] fills it.
class RunDashboardCriticalEventsNotifier
    extends StateNotifier<List<RunDashboardEvent>> {
  RunDashboardCriticalEventsNotifier(this._ref) : super(const []) {
    // One rig's faults say nothing about another: linking to a different
    // host (or back to this computer) clears them. A phone that moved to a
    // fresh rig kept "Run paused - the mount is parked" from the last one.
    _ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      scheduleMicrotask(() {
        if (!mounted) return;
        state = const [];
        _ref.read(runDashboardDroppedCriticalCountProvider.notifier).state = 0;
      });
    });
  }

  final Ref _ref;

  /// Maximum number of unsigned events to retain. If the user is
  /// genuinely racking up dozens of unresolved critical events something
  /// is very wrong, but we still want to bound memory.
  static const int _maxRetained = 50;

  void add(RunDashboardEvent event) {
    if (!mounted) return;
    // Skip exact duplicates — the bridge emits the same event to multiple
    // subscribers and we may receive it twice.
    if (state.any(event.sameAs)) return;
    // A newer event about the same thing replaces the older one.
    final key = event.faultKey;
    final next = [
      event,
      for (final e in state)
        if (key == null || e.faultKey != key) e,
    ];
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

  void dismiss(RunDashboardEvent event) {
    if (!mounted) return;
    state = state.where((e) => !e.sameAs(event)).toList();
  }

  /// Drop the faults of the run once it goes on (resumed, or a new run
  /// started). What paused it has been dealt with; a red banner that still
  /// says "FAILED" over a Running header reads as a run in trouble.
  void clearRunFaults() {
    if (!mounted) return;
    if (!state.any((e) => e.isRunFault)) return;
    state = [
      for (final e in state)
        if (!e.isRunFault) e,
    ];
  }

  /// Drop the exposure failures a good frame answers: that camera's, and
  /// those no camera was named on. A good frame named on no camera answers
  /// them all.
  void clearExposureFaults(String? deviceId) {
    if (!mounted) return;
    bool answered(RunDashboardEvent e) {
      final key = e.faultKey;
      if (key == null || !key.startsWith(_exposureFaultPrefix)) return false;
      return deviceId == null ||
          key == _exposureFaultKey(null) ||
          key == _exposureFaultKey(deviceId);
    }

    if (!state.any(answered)) return;
    state = [
      for (final e in state)
        if (!answered(e)) e,
    ];
  }

  /// Drop the entries about [faultKey], once that condition recovered.
  void clearFault(String faultKey) {
    if (!mounted) return;
    if (!state.any((e) => e.faultKey == faultKey)) return;
    state = [
      for (final e in state)
        if (e.faultKey != faultKey) e,
    ];
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
/// through `bridge_events.dart`); `skotiq_core` also has its
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

/// The category under which the notification router tells [event] on its
/// own from the event stream, for the critical events it tells; null for the
/// ones it has no notice for (a generic system error, a FITS save failure),
/// which this bridge pages itself.
///
/// A failed step is told by the router as the run's failure, if the run
/// fails.
NotificationCategory? _routerCategoryOf(sk_events.SkotiqEvent event) =>
    switch (event.payload) {
      sk_events.EventPayload_Imaging(field0: final v) => switch (v) {
          sk_events.ImagingEvent_ExposureFailed() ||
          sk_events.ImagingEvent_ExposureFailedOld() =>
            NotificationCategory.exposureFailed,
          _ => null,
        },
      sk_events.EventPayload_Safety(field0: final v) => switch (v) {
          sk_events.SafetyEvent_WeatherUnsafe() ||
          sk_events.SafetyEvent_EmergencyStop() =>
            NotificationCategory.weatherUnsafe,
          sk_events.SafetyEvent_MountMotionFault() ||
          sk_events.SafetyEvent_MountPositionUnknown() =>
            NotificationCategory.mountFault,
          _ => null,
        },
      sk_events.EventPayload_System(field0: final v) => switch (v) {
          sk_events.SystemEvent_DiskSpaceLow() =>
            NotificationCategory.diskSpaceLow,
          _ => null,
        },
      sk_events.EventPayload_Sequencer(field0: final v) => switch (v) {
          sk_events.SequencerEvent_Error(kind: final kind)
              when kind == sk_events.SequencerErrorKind.stepFailed =>
            NotificationCategory.sequenceFailed,
          sk_events.SequencerEvent_Failed() =>
            NotificationCategory.sequenceFailed,
          sk_events.SequencerEvent_Stopped() =>
            NotificationCategory.sequenceStopped,
          sk_events.SequencerEvent_RecoveryGaveUp() =>
            NotificationCategory.recoveryGaveUp,
          _ => null,
        },
      // A critical guiding or equipment event the router tells only for some
      // event types; the bridge pages it and the router's content dedup
      // folds a matching copy, since a duplicate page is safer than none.
      _ => null,
    };

/// True when the router pages [event] itself, so this bridge must not page
/// it a second time. The router is asked with the operator's own rules: with
/// the phone push turned off for the category, the bridge pages instead, so
/// a critical event is paged by someone.
///
/// A stop is always left to the router: only its stop arbiter knows who
/// stopped the run, and the operator's own stop pages nobody.
bool _routerPagesItself(
  NotificationRouter router,
  sk_events.SkotiqEvent event,
) {
  final category = _routerCategoryOf(event);
  if (category == null) return false;
  if (category == NotificationCategory.sequenceStopped) return true;
  // A failed step is told by the run's failure, at that notice's own level.
  final told = event.payload is sk_events.EventPayload_Sequencer &&
      (event.payload as sk_events.EventPayload_Sequencer).field0
          is sk_events.SequencerEvent_Error;
  return router.wouldPush(
    category,
    severity: told
        ? category.defaultSeverity
        : EventSeverity.values.byName(event.severity.name),
  );
}

/// True for the mount motion guard's faults, which the mount guard banner
/// shows.
bool _isMountGuardFault(sk_events.SkotiqEvent event) => switch (event.payload) {
      sk_events.EventPayload_Safety(field0: final v) =>
        v is sk_events.SafetyEvent_MountMotionFault ||
            v is sk_events.SafetyEvent_MountPositionUnknown,
      _ => false,
    };

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
/// `SequencerEvent.Error`, and both payload variants are on the
/// `isCriticalEvent` allow-list. Matching on the reason text (rather than a
/// time window) is what
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

/// One critical event the operator must not miss, escalated once.
class RunCriticalAlert {
  const RunCriticalAlert({required this.event, required this.row});

  final sk_events.SkotiqEvent event;

  final RunDashboardEvent row;

  String get detail => row.message.isNotEmpty ? row.message : row.title;

  String get title => 'Critical · ${row.category}';
}

/// The critical events of the run, each once, as they arrive.
///
/// Reads the event history, decides which events are critical alerts (not
/// the operator's own Stop, not a terminal failure restating a reason the
/// run already raised) and keeps Tonight's banner
/// ([runDashboardCriticalEventsProvider]) up to date, including clearing a
/// run's faults once the run goes on. The alert sound
/// ([runCriticalAlertSoundProvider]) and the phone push
/// ([runCriticalAlertPushProvider]) listen to the stream it returns. Toasts
/// are not raised here: the error toast bridge already shows every backend
/// error on every screen.
///
/// An always-on service (`startup/always_on_services.dart`), so an alert
/// reaches the operator whichever screen is open.
final runCriticalAlertsProvider = Provider<Stream<RunCriticalAlert>>((ref) {
  final alerts = StreamController<RunCriticalAlert>.broadcast(sync: true);
  ref.onDispose(alerts.close);
  // Use ref.listen on the history so we react to new entries without
  // depending on the order or count of rebuilds.
  //
  // New entries are the ones at the front of the history that the previous
  // list did not hold, by identity. An id watermark would drop events on a
  // linked client, where the id is the host's millisecond timestamp.
  List<sk_events.SkotiqEvent> seen = const [];
  // Mid-run failure reasons this run has already escalated, so the terminal
  // event that restates one is not escalated a second time. See
  // [_isRestatedFailureReason].
  final escalatedSequencerFailureReasons = <String>{};

  ref.listen<List<sk_events.SkotiqEvent>>(
    eventHistoryProvider,
    (previous, next) {
      final known = Set<sk_events.SkotiqEvent>.identity()..addAll(seen);
      seen = next;
      if (next.isEmpty) return;
      // The history list is newest-first and only gains events at its front.
      final fresh = next.takeWhile((event) => !known.contains(event)).toList();
      if (fresh.isEmpty) return;

      // Process oldest-first so the most recent ends up at the head of
      // the notifier's state list.
      for (final event in fresh.reversed) {
        // An Info-severity event is never a critical alert, regardless of its
        // payload type. The Rust executor deliberately surfaces benign
        // runtime-config updates (e.g. `conditions_score`) with Info severity
        // but reuses the `SequencerEvent::Error` payload to avoid an FRB regen
        // (see native `RuntimeConfigUpdated`); isCriticalEvent keys off that
        // Error payload, so without this guard every 30s config tick would
        // raise a false "Sequencer error" banner and alerts.
        // A fresh run starts a fresh ledger of reasons. Checked ahead of the
        // severity/criticality gates because a run start is Info-severity and
        // is not itself a critical event.
        if (_isSequencerRunStart(event)) {
          escalatedSequencerFailureReasons.clear();
        }
        if (_isRunContinuing(event)) {
          ref
              .read(runDashboardCriticalEventsProvider.notifier)
              .clearRunFaults();
        }
        if (_isGoodFrame(event)) {
          ref
              .read(runDashboardCriticalEventsProvider.notifier)
              .clearExposureFaults(event.deviceId);
        }
        if (_isSuccessfulFlip(event)) {
          ref
              .read(runDashboardCriticalEventsProvider.notifier)
              .clearFault(_meridianFlipFaultKey);
        }
        if (event.severity == sk_events.EventSeverity.info) continue;
        if (!sk_events.isCriticalEvent(event)) continue;
        if (_isRestatedFailureReason(event, escalatedSequencerFailureReasons)) {
          continue;
        }
        final row = _toDashboardEvent(event);
        // A mount guard fault has its own banner above this one, with the
        // operator's actions, until the mount is checked: listed here as
        // well it read twice (mobile rework P2-14). It still sounds below.
        if (!_isMountGuardFault(event)) {
          ref.read(runDashboardCriticalEventsProvider.notifier).add(row);
        }
        // An alert the host raised before this window linked to it is shown
        // with the night so far. It has already sounded and paged where it
        // was raised.
        if (ref.read(eventHistoryProvider.notifier).happenedEarlier(event)) {
          continue;
        }
        alerts.add(RunCriticalAlert(event: event, row: row));
      }
    },
    fireImmediately: true,
  );

  // A run seen to go from paused to running has been resumed, whether or not
  // this window saw the Resumed event: a linked client that joined while the
  // run was paused learns of the resume from the host's status.
  ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider,
      (previous, next) {
    if (previous == SequenceExecutionState.paused &&
        next == SequenceExecutionState.running) {
      ref.read(runDashboardCriticalEventsProvider.notifier).clearRunFaults();
    }
  });
  return alerts.stream;
});

/// Plays the alert sound for each critical alert (Settings: audible alerts),
/// at most once per [_audibleAlertCooldown].
final runCriticalAlertSoundProvider = Provider<void>((ref) {
  DateTime? lastAlertAt;
  final subscription = ref.watch(runCriticalAlertsProvider).listen((alert) {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (!(settings?.audibleAlertsOnCritical ?? false)) return;
    final sound = settings?.criticalAlertSound ?? 'systemBell';
    if (sound == 'none') return;
    final now = DateTime.now();
    final last = lastAlertAt;
    if (last != null && now.difference(last) < _audibleAlertCooldown) return;
    lastAlertAt = now;
    ref.read(loggingServiceProvider).info(
      'Critical alert sounded',
      source: 'RunCriticalAlerts',
      fields: {'sound': sound, 'alert': alert.row.title},
    );
    unawaited(
      ref.read(criticalAlertPlayerProvider).play(sound: sound).catchError(
            (Object error) => Log.debug(
              'Critical alert sound failed: $error',
              source: 'RunCriticalAlertSound',
            ),
          ),
    );
  });
  ref.onDispose(subscription.cancel);
});

/// Pages paired phones for each critical alert (Settings: push critical
/// alerts) that the notification router does not already push from the
/// event stream on its own; see [_routerPagesItself].
final runCriticalAlertPushProvider = Provider<void>((ref) {
  final subscription = ref.watch(runCriticalAlertsProvider).listen((alert) {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (!(settings?.pushCriticalAlerts ?? true)) return;
    final router = ref.read(notificationRouterProvider);
    if (_routerPagesItself(router, alert.event)) return;
    router.routeCriticalPush(
      title: alert.title,
      body: alert.detail,
      eventType: sk_events.skotiqEventDisplayTitle(alert.event),
      eventCategory: _bridgeCategoryToCore(alert.event.category),
    );
    ref.read(loggingServiceProvider).info(
      'Critical alert sent to the phone push',
      source: 'RunCriticalAlerts',
      fields: {'title': alert.title, 'body': alert.detail},
    );
  });
  ref.onDispose(subscription.cancel);
});
