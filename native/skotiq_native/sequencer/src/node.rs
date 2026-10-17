//! Behaviour-tree node definitions and execution.
//!
//! ## Architecture
//!
//! This file is a small module entry that re-exports the structure:
//!
//! ```text
//! node/
//!   context.rs                  ExecutionContext (Clone-able)
//!   progress.rs                 ProgressUpdate + ProgressDetail (structured)
//!   registry.rs                 InstructionNode trait + static registry
//!   runtime.rs                  RuntimeNode + Node trait + dispatch
//!   instructions/               one file per instruction (29 leaf nodes)
//!   logic/                      target_header, loop, parallel, conditional,
//!                               recovery, sequential
//! ```
//!
//! See `docs/architecture/instruction-nodes.md` for the playbook for new
//! instruction authors.

// These are `pub(crate)` so submodules of `node` can address each other
// through `crate::node::*` paths (the cleanest way to write
// `use crate::node::context::ExecutionContext;` from a leaf instruction file).
// They are NOT re-exported to external crates — the public surface lives in
// the `pub use` block below.
pub(crate) mod context;
pub(crate) mod instructions;
pub(crate) mod logic;
pub(crate) mod progress;
pub(crate) mod registry;
pub(crate) mod runtime;

pub use context::{CloudMotionSnapshot, ExecutionContext};
pub use progress::{ProgressDetail, ProgressUpdate};
pub use runtime::{Node, RuntimeNode};

// Re-export the astronomical helpers the rest of the crate already addresses
// via `crate::node::julian_day` / `crate::node::local_sidereal_time`.
pub use crate::meridian::{julian_day, local_sidereal_time};

// The instruction registry is not part of the public API but is exposed for
// the unit tests in `registry.rs` and any future plugin authors who want to
// inspect available variants.
pub use registry::{node_type_discriminant, registry, InstructionNode, InstructionRegistry};

// Re-export the sequential helper so external callers (tests, the executor's
// resume path) can poke at execute_children_sequential without having to
// reach into the logic submodule directly.
pub use logic::sequential::{execute_children_sequential, wait_until_timestamp_or_cancel};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        AutofocusConfig, DelayConfig, NodeDefinition, NodeId, NodeStatus, NodeType, RecoveryAction,
        RecoveryConfig, TargetHeaderConfig,
    };
    use std::sync::atomic::Ordering;

    #[test]
    fn test_execution_context_creation() {
        let ctx = ExecutionContext::new_for_test("test_node".to_string());
        assert_eq!(ctx.node_id, "test_node");
        assert!(ctx.target_ra.is_none());
        assert!(ctx.target_dec.is_none());
        assert!(ctx.camera_id.is_none());
    }

    /// ExecutionContext exposes SkipToNode plumbing via
    /// `set_skip_to_node_request` / `skip_to_node_target` /
    /// `clear_skip_to_node_request`. The slot must round-trip and the
    /// clear must take effect.
    #[test]
    fn trust_patch_7_skip_to_node_request_roundtrip() {
        let ctx = ExecutionContext::new_for_test("root".to_string());
        assert!(ctx.skip_to_node_target().is_none());
        ctx.set_skip_to_node_request("target_node".to_string());
        assert_eq!(ctx.skip_to_node_target().as_deref(), Some("target_node"));
        ctx.clear_skip_to_node_request();
        assert!(ctx.skip_to_node_target().is_none());
    }

    /// `Node::contains_node` (default impl on the trait)
    /// reports whether the subtree rooted at `self` contains `node_id`.
    #[test]
    fn trust_patch_7_contains_node_walks_subtree() {
        let leaf = NodeDefinition {
            id: "leaf".to_string(),
            name: "Leaf".to_string(),
            node_type: NodeType::Delay(DelayConfig::default()),
            enabled: true,
            children: vec![],
        };
        let root = NodeDefinition {
            id: "root".to_string(),
            name: "Root".to_string(),
            node_type: NodeType::Delay(DelayConfig::default()),
            enabled: true,
            children: vec![],
        };

        let mut root_node = RuntimeNode::from_definition(root);
        root_node.add_child(Box::new(RuntimeNode::from_definition(leaf)));

        let leaf_id: NodeId = "leaf".to_string();
        let root_id: NodeId = "root".to_string();
        let missing_id: NodeId = "missing".to_string();

        assert!(root_node.contains_node(&root_id));
        assert!(root_node.contains_node(&leaf_id));
        assert!(!root_node.contains_node(&missing_id));
    }

    #[test]
    fn test_execution_context_with_target() {
        let ctx = ExecutionContext::new_for_test("test_node".to_string()).with_target(
            "M31".to_string(),
            10.68,
            41.27,
            Some(45.0),
        );

        assert_eq!(ctx.target_name, Some("M31".to_string()));
        assert_eq!(ctx.target_ra, Some(10.68));
        assert_eq!(ctx.target_dec, Some(41.27));
        assert_eq!(ctx.target_rotation, Some(45.0));
    }

    #[test]
    fn test_execution_context_cancellation() {
        let ctx = ExecutionContext::new_for_test("test_node".to_string());
        assert!(!ctx.is_cancelled.load(Ordering::Relaxed));
        ctx.is_cancelled.store(true, Ordering::Relaxed);
        assert!(ctx.is_cancelled.load(Ordering::Relaxed));
    }

    #[test]
    fn test_execution_context_pause() {
        let ctx = ExecutionContext::new_for_test("test_node".to_string());
        assert!(!ctx.is_paused.load(Ordering::Relaxed));
        ctx.is_paused.store(true, Ordering::Relaxed);
        assert!(ctx.is_paused.load(Ordering::Relaxed));
    }

    fn count_loop_def(id: &str, iterations: u32) -> NodeDefinition {
        use crate::{LoopCondition, LoopConfig};
        NodeDefinition {
            id: id.to_string(),
            name: "Loop".to_string(),
            node_type: NodeType::Loop(LoopConfig {
                iterations: Some(iterations),
                condition: LoopCondition::Count,
                condition_value: None,
                horizon_profile: None,
            }),
            enabled: true,
            children: vec![],
        }
    }

    /// a node restored as Success from a checkpoint (via mark_completed)
    /// must short-circuit on the next execute() instead of re-running. A
    /// childless Count loop is a clean observable: if it re-runs it advances
    /// current_iteration to the count; if it short-circuits it stays 0.
    #[tokio::test]
    async fn p1_7_resume_short_circuits_completed_node() {
        // Baseline: an un-marked loop DOES run (advances to the count).
        let mut fresh = RuntimeNode::from_definition(count_loop_def("loop1", 3));
        let mut ctx = ExecutionContext::new_for_test("loop1".to_string());
        assert_eq!(fresh.execute(&mut ctx).await, NodeStatus::Success);
        assert_eq!(
            fresh.current_iteration, 3,
            "a fresh Count loop must run all iterations"
        );

        // Resume: the checkpoint marked this node completed.
        let mut resumed = RuntimeNode::from_definition(count_loop_def("loop1", 3));
        resumed.mark_completed(&"loop1".to_string());
        assert_eq!(resumed.status, NodeStatus::Success);
        let mut ctx2 = ExecutionContext::new_for_test("loop1".to_string());
        assert_eq!(resumed.execute(&mut ctx2).await, NodeStatus::Success);
        assert_eq!(
            resumed.current_iteration, 0,
            "a completed node must NOT re-run its body on resume"
        );
    }

    /// a Loop's current_iteration must survive a checkpoint round-trip
    /// so a resumed Count loop continues from where it stopped rather than
    /// restarting at iteration 1.
    #[test]
    fn p1_8_loop_iteration_snapshot_and_restore_roundtrip() {
        let mut node = RuntimeNode::from_definition(count_loop_def("loop1", 60));
        node.current_iteration = 30;

        let mut snap = std::collections::HashMap::new();
        node.snapshot_loop_iterations(&mut snap);
        assert_eq!(snap.get("loop1"), Some(&30));

        // A freshly built tree starts at 0 and is restored to the snapshot.
        let mut fresh = RuntimeNode::from_definition(count_loop_def("loop1", 60));
        assert_eq!(fresh.current_iteration, 0);
        fresh.restore_loop_iterations(&snap);
        assert_eq!(
            fresh.current_iteration, 30,
            "restore must continue the loop from the persisted iteration"
        );
    }

    #[test]
    fn test_progress_update_creation() {
        let mut update =
            ProgressUpdate::lifecycle("node1".to_string(), NodeStatus::Running, "Capturing frame");
        update.current_frame = Some(5);
        update.total_frames = Some(10);
        update.completed_exposure_secs = Some(60.0);
        assert_eq!(update.node_id, "node1");
        assert_eq!(update.status, NodeStatus::Running);
        assert_eq!(update.current_frame, Some(5));
        assert_eq!(update.total_frames, Some(10));
        assert_eq!(update.completed_exposure_secs, Some(60.0));
    }

    #[test]
    fn test_julian_day_calculation() {
        use chrono::{TimeZone, Utc};
        let dt = Utc.with_ymd_and_hms(2000, 1, 1, 12, 0, 0).unwrap();
        let jd = julian_day(&dt);
        assert!((jd - 2451545.0).abs() < 0.001);
    }

    #[test]
    fn test_julian_day_another_epoch() {
        use chrono::{TimeZone, Utc};
        let dt = Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap();
        let jd = julian_day(&dt);
        assert!((jd - 2460310.5).abs() < 0.1);
    }

    #[test]
    fn test_local_sidereal_time() {
        let jd = 2451545.0;
        let lst = local_sidereal_time(jd, 0.0);
        assert!(lst > 18.0 && lst < 19.0);
    }

    #[test]
    fn test_local_sidereal_time_with_longitude() {
        let jd = 2451545.0;
        let lst_greenwich = local_sidereal_time(jd, 0.0);
        let lst_east = local_sidereal_time(jd, 15.0); // 15 deg east = 1h
        let diff = lst_east - lst_greenwich;
        assert!((diff - 1.0).abs() < 0.1 || (diff + 23.0).abs() < 0.1);
    }

    #[test]
    fn recovery_autofocus_uses_configured_child() {
        let mut recovery_node = RuntimeNode::from_definition(NodeDefinition {
            id: "recovery".to_string(),
            name: "Recovery".to_string(),
            node_type: NodeType::Recovery(RecoveryConfig {
                recovery_action: RecoveryAction::Autofocus,
                ..RecoveryConfig::default()
            }),
            enabled: true,
            children: vec![],
        });
        recovery_node.add_child(Box::new(RuntimeNode::from_definition(NodeDefinition {
            id: "autofocus".to_string(),
            name: "Autofocus".to_string(),
            node_type: NodeType::Autofocus(AutofocusConfig {
                step_size: 321,
                exposure_duration: 7.5,
                ..AutofocusConfig::default()
            }),
            enabled: true,
            children: vec![],
        })));

        let autofocus = logic::recovery::configured_recovery_autofocus(&recovery_node)
            .expect("recovery node should find autofocus child");

        assert_eq!(autofocus.step_size, 321);
        assert_eq!(autofocus.exposure_duration, 7.5);
    }

    #[test]
    fn custom_branch_executes_enabled_children() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        rt.block_on(async {
            let mut recovery_node = RuntimeNode::from_definition(NodeDefinition {
                id: "recovery".to_string(),
                name: "Recovery".to_string(),
                node_type: NodeType::Recovery(RecoveryConfig {
                    recovery_action: RecoveryAction::CustomBranch,
                    ..RecoveryConfig::default()
                }),
                enabled: true,
                children: vec![],
            });
            recovery_node.add_child(Box::new(RuntimeNode::from_definition(NodeDefinition {
                id: "delay".to_string(),
                name: "Delay".to_string(),
                node_type: NodeType::Delay(DelayConfig { seconds: 0.0 }),
                enabled: true,
                children: vec![],
            })));

            let mut ctx = ExecutionContext::new_for_test("recovery".to_string());
            let result =
                logic::recovery::execute_custom_branch_children(&mut recovery_node, &mut ctx).await;

            assert_eq!(result, NodeStatus::Success);
        });
    }

    #[test]
    fn custom_branch_empty_children_fails_loudly() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        rt.block_on(async {
            let mut recovery_node = RuntimeNode::from_definition(NodeDefinition {
                id: "recovery".to_string(),
                name: "Recovery".to_string(),
                node_type: NodeType::Recovery(RecoveryConfig {
                    recovery_action: RecoveryAction::CustomBranch,
                    ..RecoveryConfig::default()
                }),
                enabled: true,
                children: vec![],
            });

            let mut ctx = ExecutionContext::new_for_test("recovery".to_string());
            let result =
                logic::recovery::execute_custom_branch_children(&mut recovery_node, &mut ctx).await;

            assert_eq!(result, NodeStatus::Failure);
        });
    }

    #[test]
    fn wait_until_timestamp_or_cancel_stops_on_skip_request() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        rt.block_on(async {
            let ctx = ExecutionContext::new_for_test("test_node".to_string());
            ctx.request_skip_to_next_target();

            let result =
                wait_until_timestamp_or_cancel(&ctx, chrono::Utc::now().timestamp() + 60).await;

            assert_eq!(result, NodeStatus::Skipped);
        });
    }

    #[test]
    fn target_header_wait_is_cancellable() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        rt.block_on(async {
            let mut node = RuntimeNode::from_definition(NodeDefinition {
                id: "target".to_string(),
                name: "Target".to_string(),
                node_type: NodeType::TargetHeader(TargetHeaderConfig {
                    target_name: "M31".to_string(),
                    ra_hours: 1.0,
                    dec_degrees: 2.0,
                    start_after: Some(chrono::Utc::now().timestamp() + 60),
                    ..TargetHeaderConfig::default()
                }),
                enabled: true,
                children: vec![],
            });
            let mut ctx = ExecutionContext::new_for_test("target".to_string());
            ctx.is_cancelled.store(true, Ordering::Relaxed);

            let result = node.execute(&mut ctx).await;
            assert_eq!(result, NodeStatus::Cancelled);
        });
    }

    // Concurrent writes to trigger state must never drop on contention with a
    // reading monitor: the write goes through `write().await`, so the contract
    // holds whichever file owns the progress callback.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn trigger_state_writes_are_never_dropped_under_monitor_contention() {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering as AtomicOrdering};
        use std::sync::Arc;
        use tokio::sync::RwLock as TokioRwLock;
        use tokio::time::{sleep, Duration};

        let trigger_state = Arc::new(TokioRwLock::new(crate::triggers::TriggerState::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let monitor_reads = Arc::new(AtomicUsize::new(0));

        let monitor_state = trigger_state.clone();
        let monitor_stop = stop.clone();
        let monitor_count = monitor_reads.clone();
        let monitor = tokio::spawn(async move {
            while !monitor_stop.load(AtomicOrdering::Relaxed) {
                {
                    let guard = monitor_state.read().await;
                    let _ = guard.current_target_name.clone();
                    let _ = guard.completed_exposures;
                }
                monitor_count.fetch_add(1, AtomicOrdering::Relaxed);
                sleep(Duration::from_millis(10)).await;
            }
        });

        const WRITERS: usize = 32;
        let mut writers = Vec::with_capacity(WRITERS);
        for i in 0..WRITERS {
            let state = trigger_state.clone();
            writers.push(tokio::spawn(async move {
                let name = format!("Target-{i:02}");
                let mut guard = state.write().await;
                guard.set_meridian_target(name);
                guard.increment_exposure_count();
            }));
        }

        for handle in writers {
            handle.await.expect("writer task must not panic");
        }

        stop.store(true, AtomicOrdering::Relaxed);
        monitor.await.expect("monitor task must not panic");

        let reads = monitor_reads.load(AtomicOrdering::Relaxed);
        assert!(
            reads > 0,
            "monitor must have observed at least one read iteration; got {reads}"
        );

        let final_state = trigger_state.read().await;
        let writers_u32 = u32::try_from(WRITERS).expect("WRITERS fits in u32");
        assert_eq!(
            final_state.completed_exposures,
            writers_u32,
            "every concurrent writer's increment must be observed; missing {} writes",
            writers_u32 - final_state.completed_exposures
        );
        let name = final_state
            .current_target_name
            .as_ref()
            .expect("current_target_name must be set by at least one writer");
        assert!(
            name.starts_with("Target-"),
            "expected a Target-NN name, got {name:?}"
        );
    }
}
