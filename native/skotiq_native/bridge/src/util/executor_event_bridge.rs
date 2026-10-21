//! bridge ExecutorEvents from one-shot bridge-API instruction
//! sites (e.g. `api_autofocus`, `api_start_polar_alignment`) into the bridge's
//! shared SkotiqEvent bus.
//!
//! ## Why
//!
//! Several bridge-side APIs construct an `InstructionContext` directly to run
//! a single sequencer instruction outside the live `SequenceExecutor` —
//! examples include the standalone autofocus API and the polar-alignment
//! routine. With `event_tx: None` in the context, instruction-level emergencies
//! such as FITS-save failures reach the tracing log and nothing else, so the
//! user never sees them.
//!
//! The live sequencer already has its own broadcast channel (see
//! `SequenceExecutor::event_tx`). For the one-shot bridge sites we need an
//! adapter: a freshly-created `broadcast::Sender<ExecutorEvent>` whose
//! receiver pumps incoming events into `state.publish_event(...)` using the
//! existing `SequencerEvent::Error` payload so Dart subscribers see them on
//! the same SkotiqEvent stream as a live-sequence error.
//!
//! ## Lifetime
//!
//! `spawn_executor_event_bridge` returns a `broadcast::Sender<ExecutorEvent>`.
//! Hand it (cloned) into the `event_tx` field of the InstructionContext. The
//! background task lives as long as at least one sender clone exists; once the
//! caller drops the context and the original sender, the task exits cleanly.
//!
//! ## Error vs. info routing
//!
//! `ExecutorEvent::Error` -> `EventSeverity::Error` + `SequencerEvent::Error`.
//! Every other variant is currently re-emitted at `EventSeverity::Info` with a
//! `SequencerEvent::Error { message: "…" }` payload describing the event —
//! the one-shot sites don't have a richer payload mapping today and the
//! existing UI consumer (`SequenceExecutor._handleSequencerEvent`) treats the
//! `Error` SequencerEvent as the catch-all log line. This keeps the wiring
//! visible without inventing new typed payloads (which would require an FRB
//! regen and a separate UI handler).

use crate::event::{
    create_event_auto_id, EventCategory, EventPayload, EventSeverity, SequencerEvent,
};
use crate::state::SharedAppState;
use skotiq_sequencer::ExecutorEvent;
use tokio::sync::broadcast;

/// Buffer enough events to handle a short burst from a single instruction
/// (autofocus emits a handful of progress updates per V-curve frame). 32 is
/// the same order of magnitude as the per-supervisor task channels elsewhere
/// in the bridge.
const EVENT_BRIDGE_CAPACITY: usize = 32;

/// Spawn the bridge task and return a sender the caller can clone into an
/// `InstructionContext::event_tx`. The task exits when every sender clone is
/// dropped.
///
/// The returned sender is `clone`-able; pass `Some(sender.clone())` into the
/// `event_tx` field. The original `sender` must outlive the InstructionContext
/// (typically it's held in a local binding for the duration of the call).
pub fn spawn_executor_event_bridge(state: SharedAppState) -> broadcast::Sender<ExecutorEvent> {
    let (tx, mut rx) = broadcast::channel::<ExecutorEvent>(EVENT_BRIDGE_CAPACITY);

    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(event) => {
                    forward_event(&state, event);
                }
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    tracing::warn!(
                        "[ExecutorEventBridge] lagged behind; skipped {} events",
                        skipped
                    );
                }
                Err(broadcast::error::RecvError::Closed) => {
                    tracing::debug!("[ExecutorEventBridge] sender dropped; bridge exiting");
                    return;
                }
            }
        }
    });

    tx
}

fn forward_event(state: &SharedAppState, event: ExecutorEvent) {
    let (severity, message) = match event {
        ExecutorEvent::Error { message } => (EventSeverity::Error, message),
        ExecutorEvent::Warning { message } => (EventSeverity::Warning, message),
        ExecutorEvent::SequenceFailed { error } => (EventSeverity::Error, error),
        // The one-shot autofocus publishes its own points and returns its
        // result to the caller; forwarding these too would double the
        // V-curve and log a line per point.
        ExecutorEvent::AutofocusProgress { .. } | ExecutorEvent::AutofocusFinished { .. } => return,
        // Other variants currently surface as an informational error-tagged
        // payload because the one-shot bridge sites don't have a richer
        // mapping. If a future caller needs typed routing (e.g. exposure
        // progress for the standalone autofocus), extend this match.
        other => (
            EventSeverity::Info,
            format!("[ExecutorEvent] {:?}", std::mem::discriminant(&other)),
        ),
    };

    state.publish_event(create_event_auto_id(
        severity,
        EventCategory::Sequencer,
        EventPayload::Sequencer(SequencerEvent::Error { message }),
    ));
}
