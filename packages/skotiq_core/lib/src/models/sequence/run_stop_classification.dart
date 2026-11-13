/// How a stopped run is told: that it stopped, and who stopped it.
///
/// Every way a run is stopped ends it the same way: a sequencer `Error` of
/// kind `cancelled`, a cancellation decision row, then `Stopped`. None of
/// those says who stopped it. Only the stop decision rows do, through their
/// typed `stop` ([sequenceStopDecisionOf]), and a parking trigger's
/// `TriggerFired` ([sequenceStopTriggerDecision]). Every surface that names a
/// stop's author reads it here, so the feed, the run header and the phone say
/// the same thing about the same stop.
library;

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        SequencerStop,
        SequencerStop_Autopilot,
        SequencerStop_Cancelled,
        SequencerStop_Operator,
        SequencerStop_System,
        SequencerStop_Trigger;

/// The notice the native executor sends with a cancelled run's `Error`.
const String kSequenceCancelledNotice = 'Sequence cancelled';

/// What a run the operator stopped shows instead of an error.
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

/// True when [message] is the cancellation notice, as a run's stored error
/// text can carry it, rather than a fault.
///
/// The match is exact: real faults contain the word too ("Temperature
/// compensation cancelled", "slew canceled by the mount (limit switch)") and
/// must stay errors.
bool isSequenceCancelledNotice(String message) {
  final normalized = message.trim().toLowerCase();
  return normalized == 'sequence cancelled' ||
      normalized == 'sequence canceled';
}

/// True when [message] is a failed run's reason that names no reason: the
/// native executor's bare "Sequence failed" when it found no cause, or the
/// "Unknown error" a reader puts in for a missing field.
bool isUnexplainedRunFailure(String message) {
  final normalized = message.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == 'sequence failed' ||
      normalized == 'unknown error';
}

/// The one fired-trigger action that ends the run with the mount parked,
/// spelled as the trigger monitor names it on `TriggerFired`. Every other
/// action leaves the run going, or ends it without saying it parked.
const String kParkAndAbortTriggerAction = 'ParkAndAbort';

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

/// The stop authorship a stop decision row records, or null when it names
/// nobody: no stop, or the cancellation row every stop writes.
SequenceStopDecision? sequenceStopDecisionOf(SequencerStop? stop) =>
    switch (stop) {
      null || SequencerStop_Cancelled() => null,
      SequencerStop_Operator() => const SequenceStopDecision(
        SequenceStopAuthor.operatorPress,
      ),
      SequencerStop_Autopilot() => const SequenceStopDecision(
        SequenceStopAuthor.autopilot,
      ),
      SequencerStop_System(:final origin) => SequenceStopDecision(
        SequenceStopAuthor.system,
        origin: _nonEmpty(origin),
      ),
      SequencerStop_Trigger(:final triggerId, :final triggerName) =>
        _triggerStop(triggerId, triggerName),
    };

/// Read a `TriggerFired` event as stop authorship, or null when this fire did
/// not end the run with the mount parked or names no trigger.
SequenceStopDecision? sequenceStopTriggerDecision({
  required String? triggerId,
  required String? triggerName,
  required String? action,
}) {
  if (action?.trim() != kParkAndAbortTriggerAction) return null;
  return _triggerStop(triggerId, triggerName);
}

/// A trigger is a subsystem, so its stop is a system stop with the trigger as
/// its origin. A trigger with neither an id nor a name names nobody.
SequenceStopDecision? _triggerStop(String? triggerId, String? triggerName) {
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
