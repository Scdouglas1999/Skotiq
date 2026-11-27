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
        SequencerNightEnd,
        SequencerStop_Trigger,
        SequencerTriggerAction;

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

/// True when [message], read from a stored run's error list, is a stop
/// notice rather than a fault.
///
/// A run records no stop notice any more: the executor's cancellation arrives
/// as an `Error` of kind `cancelled`, which the run event handler turns into a
/// stop before anything is stored. Runs stored before that carry the notice
/// as text, in the native spelling ([isSequenceCancelledNotice]) or in one of
/// the operator phrasings the report has always dropped. The match is exact
/// for the same reason as [isSequenceCancelledNotice].
bool isStoredRunStopNotice(String message) {
  if (isSequenceCancelledNotice(message)) return true;
  final m = message.trim().toLowerCase();
  return m == 'stopped by user' ||
      m == 'stopped by the user' ||
      m == 'stopped by operator' ||
      m == 'stopped by the operator' ||
      m == 'stopped by request';
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

  /// Why the stop also ended the night, as the native trigger table says;
  /// null for a stop that ends only the run.
  final SequencerNightEnd? nightEnd;

  const SequenceStopDecision(
    this.author, {
    this.origin,
    this.originLabel,
    this.parked = false,
    this.nightEnd,
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
      SequencerStop_Trigger(
        :final triggerId,
        :final triggerName,
        :final nightEnd,
      ) =>
        _triggerStop(triggerId, triggerName, nightEnd),
    };

/// Read a `TriggerFired` event as stop authorship, or null when this fire did
/// not end the run with the mount parked (the one action that ends it so) or
/// names no trigger.
SequenceStopDecision? sequenceStopTriggerDecision({
  required String? triggerId,
  required String? triggerName,
  required SequencerTriggerAction? action,
  SequencerNightEnd? nightEnd,
}) {
  if (action != SequencerTriggerAction.parkAndAbort) return null;
  return _triggerStop(triggerId, triggerName, nightEnd);
}

/// A trigger is a subsystem, so its stop is a system stop with the trigger as
/// its origin. A trigger with neither an id nor a name names nobody.
SequenceStopDecision? _triggerStop(
  String? triggerId,
  String? triggerName,
  SequencerNightEnd? nightEnd,
) {
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
    nightEnd: nightEnd,
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

/// Who stopped a run, by the origin word the app sends the run engine with
/// the stop (the engine's `StopOrigin::from_wire` reads it back).
enum RunStopOrigin {
  /// A human.
  operator('operator'),

  /// The autopilot, on an unattended re-plan.
  scheduler('scheduler'),

  /// A launch that failed and was rolled back.
  rollback('rollback'),

  /// The disk-space watchdog.
  diskWatchdog('disk-watchdog'),

  /// The end-of-night calibration taking the rig.
  endOfNightCalibration('end-of-night calibration'),

  /// A native abort no stop commanded; never sent.
  safety('safety');

  const RunStopOrigin(this.wire);

  final String wire;

  /// The origin [wire] names; null for a word the app does not send.
  static RunStopOrigin? fromWire(String? wire) =>
      values.where((origin) => origin.wire == wire).firstOrNull;
}

/// The stop origin the native Weather Unsafe trigger stops a run with: the
/// trigger's id (`test_fixtures/wire_words/run_ids.json`).
const String kWeatherUnsafeTriggerId = 'weather_unsafe';

/// The operator-facing name of a system stop's `origin`. Unknown origins are
/// printed verbatim: naming the real caller is more useful than a generic
/// "the system", and it is what the log says too.
String sequenceStopOriginLabel(String origin) =>
    switch (RunStopOrigin.fromWire(origin)) {
      RunStopOrigin.rollback => 'the launch rollback',
      RunStopOrigin.diskWatchdog => 'the disk-space watchdog',
      _ => origin,
    };
