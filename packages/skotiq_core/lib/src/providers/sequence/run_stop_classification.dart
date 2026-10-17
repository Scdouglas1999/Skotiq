/// The ONE place that decides whether a sequencer `Error` event is really the
/// operator's Stop.
///
/// The native executor ends a cancelled run by emitting
/// `ExecutorEvent::Error { message: "Sequence cancelled" }`
/// (`native/skotiq_native/sequencer/src/executor/start.rs`, the
/// `NodeStatus::Cancelled` arm) *before* the `Stopped` state change. Every Dart
/// consumer that keys off the payload type therefore saw a run the operator had
/// deliberately ended as a fault, and each one said so in its own words:
///
///   * the notification classifier routed it to `sequenceFailed`
///     ("Sequence failed / Sequence aborted at …"),
///   * the run-dashboard bridge escalated it as a critical event
///     ("Critical · Sequencer", the red Dashboard banner, the RECENT EVENTS row),
///   * the executor's own event handler painted the target rollup
///     "Error: Sequence cancelled" and pushed the run into `recovering`.
///
/// Five surfaces, five producers, one wire event. They agree now because they
/// all ask this function.
///
/// ## Why the match is EXACT
///
/// A substring test on "cancelled" swallows real faults whose text happens to
/// contain the word — "Temperature compensation cancelled"
/// (`native/.../temperature_compensation.rs`), "Cancelled: Target"
/// (`executor/preflight.rs`), "focuser move was canceled by the driver",
/// "slew canceled by the mount (limit switch)" — leaving the operator with NO
/// error report at all. Those messages are the pinned counter-inputs of
/// `test/providers/sequence/run_stop_classification_test.dart`.
///
/// The notice is a fixed string the executor writes verbatim, so recognising it
/// exactly (trimmed, case-insensitive, both spellings) is both sufficient and
/// the only safe rule: anything else is a real fault and must survive.
library;

import 'dart:convert';

/// The verbatim notice the native executor emits for a cancelled run.
const String kSequenceCancelledNotice = 'Sequence cancelled';

/// The copy every surface uses instead of an error when [isSequenceCancelledNotice]
/// recognises the notice.
const String kSequenceStoppedByRequestMessage = 'Stopped by request';

/// Feed message for a stop the AUTOPILOT commanded (scheduler re-plan,
/// no-eligible-target tick). Distinct from the operator's message: an
/// unattended stop must never claim a human asked for it.
const String kSequenceStoppedByAutopilotMessage = 'Stopped by autopilot';

/// The cause-neutral terminal line: the run ended and nothing on the wire names
/// who ended it. Says THAT, claims no WHO.
const String kSequenceStoppedMessage = 'Stopped';

/// Log tag stamped by every producer that reclassifies a stop. Each call site
/// logs `[$kStopClassificationLogTag] <site>` when it reclassifies, so the run
/// log says WHICH producer acted.
const String kStopClassificationLogTag = 'stop-classification';

/// True when [message] is the run-cancelled NOTICE rather than a fault.
///
/// Exact match by design — see the library doc comment.
bool isSequenceCancelledNotice(String message) {
  final normalized = message.trim().toLowerCase();
  return normalized == 'sequence cancelled' ||
      normalized == 'sequence canceled';
}

// Who ended the run.
//
// Every cancellation path publishes the same cancel-notice pair, so the notice
// says only THAT a run ended. The one thing on the wire that says WHO is the
// decision row `SequencerExecutor::stop_with_origin` writes
// (`native/skotiq_native/sequencer/src/executor/lifecycle.rs`):
//
//   manual_intervention / "Operator: stop …"                    -> a human
//   system_event        / "Autopilot: stop"                     -> the scheduler
//   system_event        / "System: stop" + details.origin        -> a subsystem
//                          (`rollback`, `disk-watchdog`, …)
//   trigger_fired       / "Trigger X fired → ParkAndAbort"       -> the trigger
//                          monitor, which is a subsystem too
//
// The vocabulary is read HERE, once, so the surfaces that consume it (the Run
// Dashboard's stop row on bridge-typed events, the notification router on
// core-typed events) can never disagree about whose stop it was.

/// Decision-row category for the executor's manual-intervention rows.
const String kManualInterventionDecisionCategory = 'manual_intervention';

/// Decision-row category for the executor's system-event rows.
const String kSystemEventDecisionCategory = 'system_event';

/// Decision-row category for the trigger monitor's fired-trigger rows.
const String kTriggerFiredDecisionCategory = 'trigger_fired';

/// The one fired-trigger action that ENDS the run, spelled as the trigger
/// monitor puts it on the wire (`format!("{:?}", action)` in
/// `native/skotiq_native/sequencer/src/executor/start/trigger_monitor.rs`).
///
/// Every other action leaves the run going — `Pause`, `NextTarget`, `Dither`,
/// `Recenter`, `Continue` — so a fire carrying one of those is NOT evidence of
/// who ended a cancellation that arrives later: reading it as the cause would
/// blame the dither trigger for the operator's Stop ten minutes on. The
/// autofocus- and flip-failure aborts do end a run, but their fired-trigger row
/// still names the action that was ATTEMPTED (`Autofocus`, `MeridianFlip(..)`),
/// so the wire does not say they ended it and this stays silent rather than
/// guessing.
const String kParkAndAbortTriggerAction = 'ParkAndAbort';

/// Summary PREFIX of the operator's stop decision. A prefix, not an equality:
/// both `Operator: stop` and `Operator: stop requested` occur on the wire.
const String kOperatorStopSummaryPrefix = 'Operator: stop';

/// Summary of the autopilot's stop decision.
const String kAutopilotStopSummary = 'Autopilot: stop';

/// Summary of a stop no one commanded but the system itself; the caller is in
/// `details.origin`.
const String kSystemStopSummary = 'System: stop';

/// WHO ended the run, as the executor's decision rows name them.
enum SequenceStopAuthor {
  /// A human pressed Stop (locally or from a paired phone).
  operatorPress,

  /// The scheduler stopped the run on an unattended re-plan.
  autopilot,

  /// A subsystem stopped the run: see [SequenceStopDecision.origin].
  system,
}

/// One stop decision read off the wire.
class SequenceStopDecision {
  final SequenceStopAuthor author;

  /// For [SequenceStopAuthor.system]: the caller the stop API was given
  /// (`rollback`, `disk-watchdog`, a trigger id). Null for the other authors.
  final String? origin;

  /// The operator-facing name of [origin] when the wire carried one beside the
  /// id — a trigger row ships `trigger_id: dawn_approaching` AND
  /// `trigger_name: Dawn Approaching`, and the operator knows the second.
  /// Null when only the id is on the wire, and [sequenceStopOriginLabel] then
  /// does the naming.
  final String? originLabel;

  /// True when the stop also PARKED the mount. The operator's next move
  /// differs for a parked rig, so the terminal line says so instead of only
  /// "stopped".
  final bool parked;

  const SequenceStopDecision(
    this.author, {
    this.origin,
    this.originLabel,
    this.parked = false,
  });
}

/// Read a `DecisionLogged` row as stop authorship, or `null` when the row is
/// not one of the executor's stop decisions (the cancel-notice lifecycle
/// decision every cancellation path emits included — it names no author).
SequenceStopDecision? sequenceStopDecision({
  required String category,
  required String summary,
  String? detailsJson,
}) {
  if (category == kManualInterventionDecisionCategory &&
      summary.startsWith(kOperatorStopSummaryPrefix)) {
    return const SequenceStopDecision(SequenceStopAuthor.operatorPress);
  }
  if (category == kTriggerFiredDecisionCategory) {
    final details = _decodeDetails(detailsJson);
    return sequenceStopTriggerDecision(
      triggerId: details['trigger_id'] as String?,
      triggerName: details['trigger_name'] as String?,
      action: details['action'] as String?,
    );
  }
  if (category != kSystemEventDecisionCategory) return null;
  if (summary == kAutopilotStopSummary) {
    return const SequenceStopDecision(SequenceStopAuthor.autopilot);
  }
  if (summary == kSystemStopSummary) {
    return SequenceStopDecision(
      SequenceStopAuthor.system,
      origin: _stopOrigin(detailsJson),
    );
  }
  return null;
}

/// Read a fired-trigger row as stop authorship, or null when this fire did not
/// end the run (see [kParkAndAbortTriggerAction]) or names no trigger.
///
/// The trigger monitor is a subsystem, so the authorship is
/// [SequenceStopAuthor.system] with the trigger as its origin — the same shape
/// the `System: stop` rows already use, which is why every surface that reads
/// the vocabulary gets the trigger's name for free.
///
/// A row carrying neither an id nor a name names nobody: it is a fired-trigger
/// row this build cannot read, not a stop to attribute to something.
SequenceStopDecision? sequenceStopTriggerDecision({
  required String? triggerId,
  required String? triggerName,
  required String? action,
}) {
  if (action?.trim() != kParkAndAbortTriggerAction) return null;
  final id = _nonEmpty(triggerId);
  final name = _nonEmpty(triggerName);
  // The operator knows the trigger by its display name; the id is the fallback
  // so a row that carries only the id still names the real caller.
  final named = name ?? id;
  if (named == null) return null;
  return SequenceStopDecision(
    SequenceStopAuthor.system,
    origin: id ?? named,
    originLabel: 'the $named trigger',
    parked: true,
  );
}

/// [value] trimmed, or null when it is absent or blank — "" is not a name.
String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

String? _stopOrigin(String? detailsJson) {
  final origin = _decodeDetails(detailsJson)['origin'];
  if (origin is String && origin.isNotEmpty) return origin;
  return null;
}

/// The decision row's `details` payload, or an empty map when there is none to
/// read. A payload we cannot parse names nothing, and the stop stays
/// cause-neutral — the honest direction.
Map<String, dynamic> _decodeDetails(String? detailsJson) {
  if (detailsJson == null || detailsJson.isEmpty) return const {};
  try {
    final decoded = jsonDecode(detailsJson);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // Fall through: an unreadable payload names nothing.
  }
  return const {};
}

/// The clause naming who ended the run — `by request`, `by autopilot`,
/// `by the disk-space watchdog` — or the empty string when nothing on the wire
/// names an author (a safety abort with nobody at the keyboard).
///
/// Every surface composes its own sentence around this one clause:
/// [kSequenceStoppedByRequestMessage] is `'Stopped ${clause}'` for the
/// operator, and the notification body is `'Sequence stopped ${clause} at …'`.
String sequenceStopCauseClause(SequenceStopDecision? decision) {
  switch (decision?.author) {
    case SequenceStopAuthor.operatorPress:
      return 'by request';
    case SequenceStopAuthor.autopilot:
      return 'by autopilot';
    case SequenceStopAuthor.system:
      final label = decision?.originLabel;
      if (label != null && label.isNotEmpty) return 'by $label';
      final origin = decision?.origin;
      return origin == null ? '' : 'by ${sequenceStopOriginLabel(origin)}';
    case null:
      return '';
  }
}

/// The terminal line a cancelled run shows — the sentence stating the cause the
/// run's own decision rows carried, or [kSequenceStoppedMessage] when they
/// carried none.
///
/// Every cancellation path emits the same cancel notice, so the notice cannot
/// tell an operator's Stop from a weather/dawn ParkAndAbort; only the
/// authorship row can. Composed around [sequenceStopCauseClause] so the run
/// header and the phone push say the same thing about the same stop.
String sequenceStoppedMessage(SequenceStopDecision? decision) {
  switch (decision?.author) {
    case SequenceStopAuthor.operatorPress:
      return kSequenceStoppedByRequestMessage;
    case SequenceStopAuthor.autopilot:
      return kSequenceStoppedByAutopilotMessage;
    case SequenceStopAuthor.system:
    case null:
      final clause = sequenceStopCauseClause(decision);
      if (clause.isEmpty) return kSequenceStoppedMessage;
      return '${decision!.parked ? 'Parked' : 'Stopped'} $clause';
  }
}

/// The operator-facing name of a system stop's `origin`. Unknown origins are
/// printed verbatim: naming the real caller is more useful than a generic
/// "the system", and it is what the log says too.
String sequenceStopOriginLabel(String origin) {
  switch (origin) {
    case 'rollback':
      return 'the launch rollback';
    case 'disk-watchdog':
      return 'the disk-space watchdog';
    default:
      return origin;
  }
}
