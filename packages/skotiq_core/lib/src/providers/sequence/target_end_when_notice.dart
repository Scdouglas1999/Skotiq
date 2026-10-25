/// The one place that recognises a target dropped by its own `end_when`, and
/// the one place that words it.
///
/// The native executor checks a TargetHeader's `end_when` before it images
/// anything: when the stop condition is ALREADY true at entry there is no
/// window left, so the whole target is skipped
/// (`native/skotiq_native/sequencer/src/node/logic/target_header.rs`,
/// `emit_end_when_skipped_at_entry`). That skip used to publish nothing at
/// all — a run that dropped an entire target answered `state: "completed"`,
/// `progress: 1.0`, `warningMessages: []` and a `targetBreakdown` the target
/// was absent from, and the only record anywhere was one `WARN` line in the
/// Rust log file.
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

/// Trigger id the native `end_when`-at-entry skip publishes under. Must stay
/// byte-identical to `TARGET_END_WHEN_TRIGGER_ID` in `target_header.rs`.
const String kTargetEndWhenTriggerId = 'target_end_when';

/// Action string that skip publishes. Kept next to the id so a future
/// `end_when` action (pause instead of skip, say) is a visible edit here
/// rather than a silently mis-worded warning.
const String kTargetEndWhenSkipAction = 'SkipTarget';

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
