/// The one place that recognises a target dropped by its own `end_when`, and
/// the one place that words it.
///
/// The native executor checks a TargetHeader's `end_when` before it images
/// anything: when the stop condition is ALREADY true at entry there is no
/// window left, so the whole target is skipped
/// (`native/skotiq_native/sequencer/src/node/logic/target_header.rs`,
/// `emit_end_when_skipped_at_entry`).
///
/// ## Why it rides `TriggerFired`
///
/// Nothing failed: a target trigger fired and the executor did exactly what
/// the sequence configured. The sibling refusal for an unevaluable `start_when`
/// publishes `InstructionFailed`, which reaches Dart as a sequencer `Error` —
/// that one IS a failure. Reusing it here would paint the node red, push a
/// running sequence into `recovering`, and send the operator's phone a
/// "Sequence failed" notification for a target that was skipped on purpose.
///
/// ## The split
///
/// Rust supplies the typed facts (which trigger, guarding which target,
/// testing what, and what the executor did); this file composes the operator's
/// sentence — the same division of labour the meridian-flip outcome uses.
library;

/// Trigger id the native `end_when`-at-entry skip publishes under
/// (`test_fixtures/wire_words/run_ids.json`).
const String kTargetEndWhenTriggerId = 'target_end_when';

/// True when this `TriggerFired` event is a target dropped by its `end_when`.
///
/// Matched on the machine id, never on the human name: the name carries the
/// target's own title and the condition's label, both operator-authored.
bool isTargetEndWhenSkip(String triggerId) =>
    triggerId == kTargetEndWhenTriggerId;

/// The run-record sentence for a target skipped by its `end_when`.
///
/// [triggerName] arrives already naming the target and the condition — e.g.
/// `The end condition on "Dusk Field" (time ≥ 2026-08-17 12:38 UTC)` — so this
/// only has to state the consequence, which is the half the operator was never
/// told: that a whole target went by with nothing captured.
String targetEndWhenSkipWarning(String triggerName) =>
    '$triggerName was already met when the run reached the target, so the '
    'target was skipped without imaging and no frames were captured for it.';

/// The run error for a run that skipped its targets at entry and captured
/// nothing.
const kNothingImagedRunError =
    'Nothing was imaged: every target this run reached had already met its '
    'end condition, so no frames were captured.';

/// Trigger id the native run publishes under when it skips a target that
/// stays below the site's altitude floor until dawn
/// (`test_fixtures/wire_words/run_ids.json`).
const String kTargetBelowFloorTriggerId = 'target_below_floor';

/// True when this `TriggerFired` event is a target skipped for staying below
/// the altitude floor.
bool isTargetBelowFloorSkip(String triggerId) =>
    triggerId == kTargetBelowFloorTriggerId;

/// The run-record sentence for a target skipped for staying below the floor.
/// [triggerName] arrives naming the target and what it stays below.
String targetBelowFloorSkipWarning(String triggerName) =>
    '$triggerName, so the target was skipped without imaging and no frames '
    'were captured for it. The floor is your horizon when one is set in '
    'Settings > Location, otherwise the minimum altitude.';

/// What a one-line header shows while the run holds a frame for a flip. Short
/// enough to fit a phone's header after "target 1 of 2 ·".
const String kFlipWaitShort = 'Waiting for the flip';
