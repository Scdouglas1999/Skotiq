//! LiveStacking instruction node.
//!
//! Arms the broadcast service for the EAA / outreach feature. The
//! instruction itself is **side-effect-only and non-blocking**: it
//! returns `Success` as soon as the broadcast session is registered, so
//! sibling exposure nodes inside the same `Loop` / `TargetHeader`
//! subtree continue to run normally. The actual frame ingestion happens
//! on the Dart side, which subscribes to `FrameAccepted` events,
//! re-reads the saved FITS, and feeds it into the existing
//! `live_stacking_service`.
//!
//! Why arm-only (vs. driving the capture loop itself):
//!
//!   * The stacker lives in `skotiq_imaging`, which the bridge
//!     already exposes via `apiStackingStart` / `apiStackingAddFrame`.
//!     Driving it from inside the sequencer would duplicate that
//!     plumbing and split the source of truth.
//!   * The brief mandates that broadcast piggy-backs on whatever
//!     exposures the parent subtree already produces; an active
//!     `BroadcastSession` plus a `FrameAccepted` event is enough for
//!     Dart to do the rest.
//!   * Returning `Success` immediately means a user who drops a
//!     `LiveStacking` node above an `Exposure` burst doesn't accidentally
//!     block the executor for the duration of the burst.
//!
//! The session is deactivated automatically when the next sequence
//! starts (the bridge resets the static slot on `api_sequencer_start`)
//! and explicitly by `api_broadcast_deactivate` when the user stops the
//! sequence.

use crate::broadcast::{self, BroadcastSession};
use crate::node::context::ExecutionContext;
use crate::node::progress::ProgressUpdate;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct LiveStackingInstruction;

// NOTE (OSC scope): this arm-only instruction intentionally carries no
// OSC / colour descriptor. The unattended broadcast path does not yet debayer —
// the Dart executor's `FrameAccepted` handler does not feed accepted frames
// into `LiveStackingBroadcastService.publishFrame`, so the broadcast renders
// mono regardless. The manual OSC / colour-stacking feature lives entirely in
// the bridge stacker (`stacking_api.rs`) and its Stack-and-Share / live-panel
// Dart surfaces. An earlier `color_descriptor` helper here logged CFA fields
// while claiming a Dart consumer read them back from the session; that consumer
// does not exist, so both the helper and the inert config fields were removed
// rather than advertise wiring that is not there.

#[async_trait]
impl InstructionNode for LiveStackingInstruction {
    fn type_name(&self) -> &'static str {
        "Live Stacking"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::LiveStacking(config) = node_type else {
            tracing::error!("LiveStackingInstruction received non-LiveStacking variant");
            return NodeStatus::Failure;
        };

        // Why not validate broadcast_port here: validation rules
        // (`LiveStackingPortClashRule`) run at sequence-edit time. The
        // runtime should fail-loud on a *runtime* port clash (e.g. the
        // headless server changed port after load), but the bridge's
        // broadcast activation handles that — we just hand off the
        // config.
        let session = BroadcastSession::from_config(node_id, config);

        // Activate the session. The function returns the previous
        // session (if any) so we can warn the operator about overlap;
        // two LiveStacking nodes in the same sequence is a configuration
        // smell rather than an outright error (the second one simply
        // wins).
        let previous = broadcast::activate(session.clone());
        if let Some(prev) = previous {
            tracing::warn!(
                "LiveStacking '{}' replaced active broadcast session from node '{}' \
                 (port {} → {})",
                node_id,
                prev.node_id,
                prev.config.broadcast_port,
                config.broadcast_port,
            );
        } else {
            tracing::info!(
                "LiveStacking '{}' armed: mode={}, stack={}, port={}, path='{}'",
                node_id,
                config.mode.as_str(),
                config.stack_method.as_str(),
                config.broadcast_port,
                config.broadcast_path,
            );
        }

        // Emit a structured Generic progress event so the run dashboard
        // can render the "Broadcasting" indicator without subscribing to
        // a separate event. Using `lifecycle` with `Success` here is
        // intentional — the instruction itself has completed; the
        // background broadcast carries on independently.
        let message = format!(
            "Broadcast armed on port {} ({})",
            config.broadcast_port,
            config.mode.as_str(),
        );
        context.send_progress(ProgressUpdate::lifecycle(
            node_id.to_string(),
            NodeStatus::Success,
            message,
        ));

        NodeStatus::Success
    }
}

#[cfg(test)]
// The broadcast service is process-global state; `broadcast::test_lock()`
// returns a std MutexGuard that each test deliberately holds across its
// awaits to serialise the whole test body against other broadcast tests.
// That is exactly what await_holding_lock warns about in production code,
// but here the hold IS the synchronisation strategy (single-threaded test
// runtime, no lock-ordering hazard).
#[allow(clippy::await_holding_lock)]
mod tests {
    use super::*;
    use crate::{LiveStackingConfig, LiveStackingMode, StackMethod};

    #[tokio::test]
    async fn live_stacking_arms_broadcast_session_and_returns_success() {
        // Sanity: a default-configured LiveStacking node arms the
        // broadcast service and returns Success without doing any I/O.
        let _broadcast_guard = crate::broadcast::test_lock();
        crate::broadcast::deactivate();
        let mut ctx = ExecutionContext::new_for_test("ls-1".to_string());
        let cfg = LiveStackingConfig {
            mode: LiveStackingMode::BroadcastOnly,
            stack_method: StackMethod::Sigma,
            broadcast_enabled: true,
            broadcast_port: 8081,
            broadcast_path: "/broadcast".to_string(),
            ..LiveStackingConfig::default()
        };
        let node_type = NodeType::LiveStacking(cfg.clone());

        let status = LiveStackingInstruction
            .execute("ls-1", &node_type, &mut ctx)
            .await;
        assert_eq!(status, NodeStatus::Success);

        let active = crate::broadcast::current().expect("expected active session");
        assert_eq!(active.node_id, "ls-1");
        assert_eq!(active.config.broadcast_port, 8081);
        assert_eq!(active.config.stack_method, StackMethod::Sigma);

        crate::broadcast::deactivate();
    }

    #[tokio::test]
    async fn live_stacking_replaces_previous_active_session() {
        // Two LiveStacking nodes in one sequence: the second wins.
        let _broadcast_guard = crate::broadcast::test_lock();
        crate::broadcast::deactivate();
        let mut ctx = ExecutionContext::new_for_test("ls-1".to_string());

        let cfg1 = LiveStackingConfig {
            broadcast_port: 8081,
            ..LiveStackingConfig::default()
        };
        let _ = LiveStackingInstruction
            .execute("ls-1", &NodeType::LiveStacking(cfg1), &mut ctx)
            .await;

        let cfg2 = LiveStackingConfig {
            broadcast_port: 9090,
            ..LiveStackingConfig::default()
        };
        let _ = LiveStackingInstruction
            .execute("ls-2", &NodeType::LiveStacking(cfg2), &mut ctx)
            .await;

        let active = crate::broadcast::current().expect("expected active session");
        assert_eq!(active.node_id, "ls-2");
        assert_eq!(active.config.broadcast_port, 9090);
        crate::broadcast::deactivate();
    }

    #[tokio::test]
    async fn live_stacking_rejects_wrong_variant() {
        let mut ctx = ExecutionContext::new_for_test("ls-1".to_string());
        let wrong = NodeType::Park;
        let status = LiveStackingInstruction
            .execute("ls-1", &wrong, &mut ctx)
            .await;
        assert_eq!(status, NodeStatus::Failure);
    }
}
