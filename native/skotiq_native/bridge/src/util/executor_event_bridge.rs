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
//! Every payload published here has kind `Standalone`: there is no run, so
//! nothing downstream may read it as a run failing or carrying on.
//! Every other variant is currently re-emitted at `EventSeverity::Info` with a
//! `SequencerEvent::Error { message: "…" }` payload describing the event —
//! the one-shot sites don't have a richer payload mapping today and the
//! existing UI consumer (`SequenceExecutor._handleSequencerEvent`) treats the
//! `Error` SequencerEvent as the catch-all log line.

use crate::event::bus::EventPayload;
use crate::event::correlation::create_event_auto_id;
use crate::event::equipment::{EventCategory, EventSeverity};
use crate::event::sequencer::{SequencerErrorKind, SequencerEvent};
use crate::state::SharedAppState;
use skotiq_sequencer::ExecutorEvent;
use tokio::sync::broadcast;

/// Buffer enough events to handle a short burst from a single instruction
/// (autofocus emits a handful of progress updates per V-curve frame). 32 is
/// the same order of magnitude as the per-supervisor task channels elsewhere
/// in the bridge.
const EVENT_BRIDGE_CAPACITY: usize = 32;

/// Spawn the bridge task and return a sender the caller can clone into an
/// `RunShared::event_tx`. The task exits when every sender clone is
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

/// Publish an autofocus sweep's outcome as the focuser's `AutofocusFinished`
/// property, the one shape every window settles its focus panel from,
/// whoever started the sweep.
pub(crate) fn publish_autofocus_finished(
    state: &SharedAppState,
    focuser_id: &str,
    status: skotiq_sequencer::NodeStatus,
    message: Option<&str>,
    result_json: Option<&str>,
) {
    let result = result_json.and_then(|json| serde_json::from_str::<serde_json::Value>(json).ok());
    let value = serde_json::json!({
        "status": status,
        "message": message,
        "result": result,
    });
    state.publish_equipment_event(
        crate::event::equipment::EquipmentEvent::PropertyChanged {
            device_type: "focuser".to_string(),
            device_id: focuser_id.to_string(),
            property: "AutofocusFinished".to_string(),
            value: value.to_string(),
        },
        EventSeverity::Info,
    );
}

fn forward_event(state: &SharedAppState, event: ExecutorEvent) {
    let (severity, message) = match event {
        ExecutorEvent::Error { message } => (EventSeverity::Error, message),
        ExecutorEvent::Warning { message }
        | ExecutorEvent::NoticedWarning { message, .. }
        | ExecutorEvent::StepProblem { message }
        | ExecutorEvent::RunHeld { message } => (EventSeverity::Warning, message),
        ExecutorEvent::SequenceFailed { error } => (EventSeverity::Error, error),
        // The one-shot autofocus publishes its own points; forwarding these
        // too would double the V-curve and log a line per point.
        ExecutorEvent::AutofocusProgress { .. } => return,
        // Its outcome does go out: only the caller that started the sweep gets
        // the result back, and every other window, which drew the sweep from
        // the events, needs it to stop showing the sweep as running.
        ExecutorEvent::AutofocusFinished {
            focuser_id,
            status,
            message,
            result_json,
        } => {
            publish_autofocus_finished(
                state,
                &focuser_id,
                status,
                message.as_deref(),
                result_json.as_deref(),
            );
            return;
        }
        // A one-shot dither is not a run's dither; there is no run to count it.
        ExecutorEvent::DitherPerformed { .. } => return,
        // Frame measurements belong to a run's frame record.
        ExecutorEvent::FrameWatch(_) => return,
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
        // No decision row goes out from a one-shot operation, so nothing here
        // is announced elsewhere.
        EventPayload::Sequencer(SequencerEvent::Error {
            message,
            kind: SequencerErrorKind::Standalone,
            notice: None,
        }),
    ));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::equipment::EquipmentEvent;
    use skotiq_sequencer::NodeStatus;

    /// On 2026-11-07 an autofocus started through the REST API succeeded and
    /// the host's focus panel read "point 13 of 13" all night: the one-shot
    /// bridge dropped the sweep's end, so only the API caller learned of it.
    #[tokio::test]
    async fn a_one_shot_autofocus_end_reaches_every_window() {
        let state = crate::state::AppState::new();
        let mut events = state.event_bus.subscribe();
        let tx = spawn_executor_event_bridge(state.clone());

        tx.send(ExecutorEvent::AutofocusFinished {
            focuser_id: "native:zwo_eaf:0".to_string(),
            status: NodeStatus::Success,
            message: None,
            result_json: Some(r#"{"best_position":45416,"best_hfr":2.35}"#.to_string()),
        })
        .unwrap();
        drop(tx);

        let event = tokio::time::timeout(std::time::Duration::from_secs(5), events.recv())
            .await
            .expect("the outcome was published")
            .unwrap();
        let EventPayload::Equipment(EquipmentEvent::PropertyChanged {
            device_id,
            property,
            value,
            ..
        }) = event.payload
        else {
            panic!("unexpected event {:?}", event.payload);
        };
        assert_eq!(device_id, "native:zwo_eaf:0");
        assert_eq!(property, "AutofocusFinished");
        let value: serde_json::Value = serde_json::from_str(&value).unwrap();
        assert_eq!(value["status"], "Success");
        assert_eq!(value["result"]["best_position"], 45416);
    }
}
