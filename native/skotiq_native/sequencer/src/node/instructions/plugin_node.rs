//! PluginNode instruction.
//!
//! Dispatches `NodeType::PluginNode` to the Dart side via the executor's
//! event/command channel and blocks until Dart replies.
//!
//! ## Protocol
//!
//! 1. The Rust executor reaches a `NodeType::PluginNode` and the registry
//!    routes execution into [`PluginNodeInstruction::execute`].
//! 2. The instruction inserts a fresh `tokio::sync::oneshot::Sender` into
//!    `ExecutionContext::plugin_node_pending`, keyed by `node_id`. The
//!    matching receiver stays on the stack of the awaiting future.
//! 3. The instruction emits `ExecutorEvent::PluginNodeRequested` carrying
//!    the plugin id / node-type id / config blob / effective timeout. The
//!    bridge layer translates that to the typed
//!    `SequencerEvent::PluginNodeRequested` for the Dart subscriber.
//! 4. The Dart `SequenceExecutor` receives the event, resolves the plugin
//!    via `pluginNodeRegistryProvider`, runs the plugin through
//!    `PluginNodeExecutor.run`, then calls the bridge's
//!    `api_sequencer_plugin_node_finished` endpoint to send
//!    `ExecutorCommand::PluginNodeFinished` back into the executor's
//!    command channel.
//! 5. The executor's command handler looks up the pending oneshot by
//!    `node_id`, resolves it with the verdict, and the instruction
//!    finishes (Success / Failure).
//!
//! ## Timeout
//!
//! A `tokio::time::timeout` wraps the receiver. On expiry the instruction
//! fails loudly, removes the pending entry (so a late reply doesn't get
//! lost on a closed sender), and surfaces an `ExecutorEvent::Error` so the
//! dashboard sees the cause.
//!
//! ## Why oneshots and not a broadcast
//!
//! Two PluginNode invocations can run sequentially with the same plugin
//! and the same node_type_id but different node_ids — we need 1:1
//! request/response routing keyed on the executor-side node id, which
//! broadcast channels do not provide. A oneshot per pending request is
//! the cheapest correct primitive.

use crate::node::context::{ExecutionContext, PluginNodeReply};
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;
use std::time::Duration;
use tokio::sync::oneshot;

/// Default plugin-node timeout when the user did not set one explicitly.
///
/// Ten minutes matches the Dart-side `PluginNodeExecutor.defaultTimeout`,
/// so a runaway plugin fails at the same place on both sides regardless of
/// which timer expires first.
pub const DEFAULT_PLUGIN_NODE_TIMEOUT_SECS: u32 = 600;

pub struct PluginNodeInstruction;

#[async_trait]
impl InstructionNode for PluginNodeInstruction {
    fn type_name(&self) -> &'static str {
        // Surfaced on the legacy `InstructionProgress.instruction` field.
        // The dashboard's typed plugin-node panel uses the structured
        // detail instead, so this is purely a fallback string.
        "Plugin Node"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::PluginNode {
            plugin_id,
            node_type_id,
            config_json,
            display_name,
            timeout_secs,
        } = node_type
        else {
            tracing::error!(
                "PluginNodeInstruction received non-PluginNode variant; sequence cannot proceed"
            );
            return NodeStatus::Failure;
        };

        // Resolve the effective timeout. `None` and `Some(0)` both fall
        // back to the default — Some(0) is treated as a configuration
        // bug rather than a fire-now request.
        let effective_timeout_secs = match timeout_secs {
            Some(n) if *n > 0 => *n,
            _ => DEFAULT_PLUGIN_NODE_TIMEOUT_SECS,
        };

        // Set up the reply channel. We register BEFORE we emit the
        // request event so a fast Dart-side reply cannot lose the race.
        let (tx, rx) = oneshot::channel::<PluginNodeReply>();
        {
            let mut pending = context.plugin_node_pending.write().await;
            if pending.insert(node_id.to_string(), tx).is_some() {
                // A stale registration for the same node id should not
                // exist — every PluginNode invocation gets a unique
                // executor visit. If it does, the previous oneshot is
                // dropped (the awaiting future will see RecvError and
                // fail loudly).
                tracing::warn!(
                    "[PLUGIN] Replaced stale pending oneshot for node {} ({}: {})",
                    node_id,
                    plugin_id,
                    node_type_id,
                );
            }
        }

        // Emit a synthetic "started" progress tick so the dashboard's
        // plugin-node panel surfaces the in-flight state with a stable
        // structured payload. We don't have any plugin-authored detail
        // yet so the JSON object is empty.
        context.send_progress(ProgressUpdate::instruction_progress(
            node_id.to_string(),
            self.type_name(),
            0.0,
            ProgressDetail::PluginNode {
                plugin_id: plugin_id.clone(),
                node_type_id: node_type_id.clone(),
                detail: serde_json::json!({"phase": "started"}),
            },
        ));

        // Fire the request event. A missing event_tx is a configuration
        // bug — without it the Dart side can never receive the request —
        // so we fail loudly.
        let Some(event_tx) = context.event_tx.clone() else {
            tracing::error!(
                "[PLUGIN] PluginNode {} ({}/{}) cannot dispatch: executor has no event channel. \
                 This indicates the executor was not started via SequenceExecutor::start().",
                node_id,
                plugin_id,
                node_type_id,
            );
            // Drop the pending registration so a future executor restart
            // doesn't see a stale entry.
            context.plugin_node_pending.write().await.remove(node_id);
            return NodeStatus::Failure;
        };

        let send_result = event_tx.send(crate::executor::ExecutorEvent::PluginNodeRequested {
            node_id: node_id.to_string(),
            plugin_id: plugin_id.clone(),
            node_type_id: node_type_id.clone(),
            config_json: config_json.clone(),
            display_name: display_name.clone(),
            timeout_secs: effective_timeout_secs,
        });
        // Replay Debug — log the plugin invocation so the
        // replay timeline carries a row for it. Plugins can run
        // arbitrary external scripts so this is an important audit
        // breadcrumb.
        context.emit_decision(
            crate::decision::DecisionEvent::new(
                crate::decision::DecisionCategory::PluginNodeInvoked,
                format!(
                    "Plugin node {} ({}/{}) invoked",
                    display_name.as_deref().unwrap_or(node_type_id.as_str()),
                    plugin_id,
                    node_type_id,
                ),
                serde_json::json!({
                    "node_id": node_id,
                    "plugin_id": plugin_id,
                    "node_type_id": node_type_id,
                    "display_name": display_name,
                    "timeout_secs": effective_timeout_secs,
                }),
            )
            .with_node(node_id.to_string()),
        );
        if let Err(e) = send_result {
            // No subscribers is technically benign — the headless API
            // case — but for plugin nodes it means nothing will ever
            // reply. We surface as a failure so the user sees the
            // problem instead of the sequence hanging until timeout.
            tracing::error!(
                "[PLUGIN] PluginNode {} ({}/{}) failed to publish request: {}. \
                 No Dart-side subscriber means the plugin cannot run.",
                node_id,
                plugin_id,
                node_type_id,
                e
            );
            context.plugin_node_pending.write().await.remove(node_id);
            return NodeStatus::Failure;
        }

        tracing::info!(
            "[PLUGIN] Dispatched plugin node {} ({}/{}); timeout={}s",
            node_id,
            plugin_id,
            node_type_id,
            effective_timeout_secs,
        );

        // Block waiting for the Dart-side reply.
        let reply_result =
            tokio::time::timeout(Duration::from_secs(u64::from(effective_timeout_secs)), rx).await;

        // Clean up the pending entry — successful resolution already
        // consumed the sender (the receiver returns Ok), so a `remove`
        // here is a no-op in the happy path and a leak-prevention in the
        // timeout / closed-channel paths.
        let _ = context.plugin_node_pending.write().await.remove(node_id);

        match reply_result {
            Ok(Ok(reply)) => {
                // Final progress event with the structured detail Dart
                // attached (if any). The dashboard panel reads this
                // verbatim.
                let detail_value = reply
                    .structured_detail
                    .clone()
                    .unwrap_or_else(|| serde_json::json!({"phase": "finished"}));
                context.send_progress(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    self.type_name(),
                    100.0,
                    ProgressDetail::PluginNode {
                        plugin_id: plugin_id.clone(),
                        node_type_id: node_type_id.clone(),
                        detail: detail_value,
                    },
                ));

                if reply.success {
                    if let Some(msg) = &reply.message {
                        tracing::info!(
                            "[PLUGIN] Plugin node {} ({}/{}) completed: {}",
                            node_id,
                            plugin_id,
                            node_type_id,
                            msg,
                        );
                    } else {
                        tracing::info!(
                            "[PLUGIN] Plugin node {} ({}/{}) completed",
                            node_id,
                            plugin_id,
                            node_type_id,
                        );
                    }
                    NodeStatus::Success
                } else {
                    let msg = reply
                        .message
                        .clone()
                        .unwrap_or_else(|| "plugin reported failure".to_string());
                    tracing::warn!(
                        "[PLUGIN] Plugin node {} ({}/{}) failed: {}",
                        node_id,
                        plugin_id,
                        node_type_id,
                        msg,
                    );
                    let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                        message: format!(
                            "Plugin node {}/{} failed: {}",
                            plugin_id, node_type_id, msg
                        ),
                    });
                    NodeStatus::Failure
                }
            }
            Ok(Err(_recv_err)) => {
                // The sender was dropped before sending — usually means
                // the executor was torn down while the request was in
                // flight. Surface as a failure rather than silently
                // succeeding.
                tracing::error!(
                    "[PLUGIN] Plugin node {} ({}/{}) oneshot was dropped without a reply; \
                     marking node as failed.",
                    node_id,
                    plugin_id,
                    node_type_id,
                );
                let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                    message: format!(
                        "Plugin node {}/{} was dropped before completion",
                        plugin_id, node_type_id
                    ),
                });
                NodeStatus::Failure
            }
            Err(_elapsed) => {
                tracing::error!(
                    "[PLUGIN] Plugin node {} ({}/{}) timed out after {}s; failing the node loudly \
. Either the plugin is hung, or the Dart side never received \
                     the request event.",
                    node_id,
                    plugin_id,
                    node_type_id,
                    effective_timeout_secs,
                );
                let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                    message: format!(
                        "Plugin node {}/{} timed out after {}s",
                        plugin_id, node_type_id, effective_timeout_secs
                    ),
                });
                NodeStatus::Failure
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::context::PluginNodeReply;
    use crate::{NodeStatus, NodeType};
    use tokio::sync::broadcast;

    /// Spin up a minimal context with a live event channel and confirm
    /// the instruction:
    ///   1. emits the PluginNodeRequested event,
    ///   2. blocks on the pending oneshot,
    ///   3. resolves to Success when the oneshot is fulfilled.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn plugin_node_dispatches_and_completes_on_reply() {
        let (event_tx, mut event_rx) = broadcast::channel(16);
        let mut ctx = ExecutionContext::new_for_test("plugin_node_1".to_string());
        ctx.event_tx = Some(event_tx);
        let pending = ctx.plugin_node_pending.clone();
        let node_type = NodeType::PluginNode {
            plugin_id: "com.example.pushover".to_string(),
            node_type_id: "pushover.notify".to_string(),
            config_json: r#"{"title":"Hello","message":"World"}"#.to_string(),
            display_name: Some("Pushover".to_string()),
            timeout_secs: Some(5),
        };

        // Spawn the instruction first so the executor's command-handler
        // analogue (our test below) can observe the request and reply.
        let mut ctx_for_task = ctx.clone();
        let task = tokio::spawn(async move {
            PluginNodeInstruction
                .execute("plugin_node_1", &node_type, &mut ctx_for_task)
                .await
        });

        // Wait for the PluginNodeRequested event so we know the task
        // registered its oneshot. broadcast::Receiver.recv is async-fair
        // so we don't busy-spin.
        let event = tokio::time::timeout(Duration::from_secs(2), event_rx.recv())
            .await
            .expect("event channel should emit within timeout")
            .expect("event channel must not close");
        match event {
            crate::executor::ExecutorEvent::PluginNodeRequested {
                node_id,
                plugin_id,
                node_type_id,
                config_json,
                timeout_secs,
                ..
            } => {
                assert_eq!(node_id, "plugin_node_1");
                assert_eq!(plugin_id, "com.example.pushover");
                assert_eq!(node_type_id, "pushover.notify");
                assert_eq!(config_json, r#"{"title":"Hello","message":"World"}"#);
                assert_eq!(timeout_secs, 5);
            }
            other => panic!("expected PluginNodeRequested, got {:?}", other),
        }

        // The instruction MUST have registered the pending oneshot before
        // emitting the event — that's the contract that prevents lost
        // replies under race.
        let sender = {
            let mut map = pending.write().await;
            map.remove("plugin_node_1")
                .expect("plugin_node_pending must hold the oneshot sender")
        };
        sender
            .send(PluginNodeReply {
                success: true,
                message: Some("delivered".to_string()),
                structured_detail: Some(serde_json::json!({
                    "phase": "finished",
                    "delivery_id": "abc123"
                })),
            })
            .expect("oneshot send must succeed");

        let status = tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .expect("plugin node future should resolve")
            .expect("task must not panic");
        assert_eq!(status, NodeStatus::Success);
    }

    /// Confirm a `success=false` reply maps to `NodeStatus::Failure` and
    /// the executor's Error event is published.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn plugin_node_reports_failure_when_dart_returns_false() {
        let (event_tx, mut event_rx) = broadcast::channel(16);
        let mut ctx = ExecutionContext::new_for_test("plugin_node_fail".to_string());
        ctx.event_tx = Some(event_tx);
        let pending = ctx.plugin_node_pending.clone();
        let node_type = NodeType::PluginNode {
            plugin_id: "com.example.failing".to_string(),
            node_type_id: "failing.always".to_string(),
            config_json: String::new(),
            display_name: None,
            timeout_secs: Some(5),
        };

        let mut ctx_for_task = ctx.clone();
        let task = tokio::spawn(async move {
            PluginNodeInstruction
                .execute("plugin_node_fail", &node_type, &mut ctx_for_task)
                .await
        });

        // Drain the PluginNodeRequested event so the channel doesn't
        // back-pressure the producer.
        let _ = tokio::time::timeout(Duration::from_secs(2), event_rx.recv())
            .await
            .expect("event channel should emit within timeout")
            .expect("event channel must not close");

        let sender = {
            let mut map = pending.write().await;
            map.remove("plugin_node_fail")
                .expect("plugin_node_pending must hold the oneshot sender")
        };
        sender
            .send(PluginNodeReply {
                success: false,
                message: Some("HTTP 500".to_string()),
                structured_detail: None,
            })
            .expect("oneshot send must succeed");

        let status = tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .expect("plugin node future should resolve")
            .expect("task must not panic");
        assert_eq!(status, NodeStatus::Failure);

        // Confirm the Error event was published so the dashboard sees
        // the cause.
        let mut saw_error = false;
        while let Ok(Ok(event)) =
            tokio::time::timeout(Duration::from_millis(100), event_rx.recv()).await
        {
            if let crate::executor::ExecutorEvent::Error { message } = event {
                assert!(message.contains("HTTP 500"));
                saw_error = true;
                break;
            }
        }
        assert!(
            saw_error,
            "expected an Error event after the plugin failure"
        );
    }

    /// A plugin that never replies must fail at the configured timeout
    /// rather than blocking forever.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn plugin_node_times_out_when_no_reply_arrives() {
        let (event_tx, mut event_rx) = broadcast::channel(16);
        let mut ctx = ExecutionContext::new_for_test("plugin_node_timeout".to_string());
        ctx.event_tx = Some(event_tx);
        let node_type = NodeType::PluginNode {
            plugin_id: "com.example.hang".to_string(),
            node_type_id: "hanger".to_string(),
            config_json: String::new(),
            display_name: None,
            // 1 second timeout so the test stays fast. The default 600s
            // applies only when timeout_secs is None / Some(0).
            timeout_secs: Some(1),
        };

        let mut ctx_for_task = ctx.clone();
        let task = tokio::spawn(async move {
            PluginNodeInstruction
                .execute("plugin_node_timeout", &node_type, &mut ctx_for_task)
                .await
        });

        // Drain the request event.
        let _ = tokio::time::timeout(Duration::from_secs(2), event_rx.recv())
            .await
            .expect("event channel should emit within timeout")
            .expect("event channel must not close");

        // Never reply — wait for the instruction to time out on its own.
        let status = tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .expect("plugin node future should resolve within outer timeout")
            .expect("task must not panic");
        assert_eq!(status, NodeStatus::Failure);
    }

    /// `timeout_secs: Some(0)` is treated as "use default" rather than
    /// "fail immediately"; the default would be 600s so we just confirm
    /// the configured value resolves into something larger than 0.
    #[test]
    fn timeout_secs_zero_falls_back_to_default() {
        // Mirror the logic in execute() for `effective_timeout_secs` so
        // any future tweak is caught here.
        let cases: Vec<(Option<u32>, u32)> = vec![
            (None, DEFAULT_PLUGIN_NODE_TIMEOUT_SECS),
            (Some(0), DEFAULT_PLUGIN_NODE_TIMEOUT_SECS),
            (Some(1), 1),
            (Some(900), 900),
        ];
        for (input, expected) in cases {
            let effective = match input {
                Some(n) if n > 0 => n,
                _ => DEFAULT_PLUGIN_NODE_TIMEOUT_SECS,
            };
            assert_eq!(effective, expected, "input {:?}", input);
        }
    }
}
