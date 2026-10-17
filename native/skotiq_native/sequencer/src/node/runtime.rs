//! RuntimeNode — the live behaviour-tree node built from a NodeDefinition.
//!
//! The top-level execute() dispatch is intentionally small: container/logic
//! variants are routed to `node::logic::*` (which need `&mut self.children`
//! access) and every other variant goes through the `InstructionRegistry`
//! trait dispatch.

use crate::expressions::{interpolate, EvaluationFrame};
use crate::node::context::ExecutionContext;
use crate::node::logic;
use crate::node::progress::ProgressUpdate;
use crate::node::registry::registry;
use crate::{NodeDefinition, NodeId, NodeStatus, NodeType};
use async_trait::async_trait;
use std::sync::atomic::Ordering;

/// render a node's display name through the interpolation engine.
///
/// Display strings are non-load-bearing: when interpolation fails we log
/// at debug! (a user-visible label that won't render is annoying but not
/// dangerous) and return the raw template. Errors that are load-bearing
/// (script arguments, save paths, notification text) use a fail-closed
/// path elsewhere — this helper exists specifically for the cosmetic
/// label channel.
fn render_node_display_name(raw: &str, context: &ExecutionContext) -> String {
    // Fast path: no `${` anywhere → skip the parser entirely.
    if !raw.contains("${") {
        return raw.to_string();
    }
    let frame = EvaluationFrame::empty();
    match interpolate(raw, context, &frame) {
        Ok(rendered) => rendered,
        Err(e) => {
            tracing::debug!("Node display name `{raw}` interpolation failed (non-fatal): {e}");
            raw.to_string()
        }
    }
}

/// Maximum number of device-disconnect retry cycles for a single instruction
/// before giving up. Each cycle waits for one full recovery-driver loop, so a
/// small bound prevents an instruction that disconnects on every retry from
/// looping forever while still surviving a handful of independent USB blips.
const MAX_DISCONNECT_RETRIES: u32 = 5;

/// How long to wait for the recovery driver to engage (`is_paused == true`)
/// after an instruction promotes a device-disconnect to recovery. The
/// instruction sends the recovery request synchronously before returning, but
/// the driver task flips `is_paused` asynchronously, so we poll for a short
/// window. If the driver never engages (no recovery channel / closed channel)
/// we fail closed rather than hang.
const RECOVERY_ENGAGE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const RECOVERY_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(200);

tokio::task_local! {
    /// Which device-disconnect retry cycle the instruction currently running on
    /// this task is on: 0 for the first execution, 1..=`MAX_DISCONNECT_RETRIES`
    /// for each retry.
    ///
    /// Ambient rather than a parameter because the value has to reach
    /// `InstructionResult::log_and_get_status_with_context`, which is called
    /// from ~30 instruction nodes and only ever sees the immutable
    /// `InstructionContext` snapshot. The retry loop awaits `execute()` inline
    /// on this same task, so the scope is exact. Code that is NOT under the
    /// retry wrapper (trigger-driven autofocus, one-shot bridge calls, tests)
    /// simply reads the default 0 and behaves as it always did.
    static DISCONNECT_RETRY_ATTEMPT: u32;
}

/// True when the instruction running right now is a re-execution of one whose
/// failure has already been published to the operator.
///
/// Publishing per attempt makes one failed node produce one error entry per
/// try: a node that fails with "No dome connected" (a message
/// [`crate::instructions::is_device_disconnected_message`] classifies as a
/// disconnect) runs six times, and the session report lists the same sentence
/// six times with six identical Critical toasts, so the error count never
/// matches the number of failed nodes.
pub(crate) fn is_disconnect_retry_attempt() -> bool {
    DISCONNECT_RETRY_ATTEMPT
        .try_with(|attempt| *attempt > 0)
        .is_ok_and(|is_retry| is_retry)
}

/// Execute an instruction node through the registry, retrying it if it fails
/// because a device disconnected.
///
/// The recovery driver runs in a parallel task. When an instruction fails with
/// a device-disconnect message, `log_and_get_status_with_context`:
/// 1. sets `context.device_disconnect_recovery_pending`, and
/// 2. posts a `DeviceDisconnected` recovery request.
///
/// WITHOUT this wrapper the node returned `Failure` immediately, the sequential
/// parent short-circuited, and the sequence ended *before* the recovery driver
/// reconnected the device — one USB blip killed the whole night. Here we
/// instead:
/// * detect the pending-recovery flag,
/// * wait for the recovery driver to engage and finish (it pauses the tree,
///   reconnects every device, then clears `is_paused` on success or sets
///   `is_cancelled` on give-up), and
/// * retry the same instruction once recovery succeeds.
///
/// Fails closed: if no recovery driver engages within `RECOVERY_ENGAGE_TIMEOUT`,
/// if recovery gives up (`is_cancelled`), or if retries are exhausted, the
/// original `Failure` propagates and the normal unwind/park-on-give-up logic
/// runs.
async fn execute_instruction_with_disconnect_retry(
    variant: &NodeType,
    node_id: &NodeId,
    node_type: &NodeType,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let Some(instruction) = registry().build(variant) else {
        tracing::error!(
            "No instruction registered for variant {:?}; sequence cannot proceed",
            variant
        );
        return NodeStatus::Failure;
    };

    let mut attempt: u32 = 0;
    loop {
        // Clear any stale pending flag from a prior instruction before running,
        // so we only react to a disconnect raised by THIS execution.
        context
            .device_disconnect_recovery_pending
            .store(false, Ordering::Relaxed);
        // Snapshot BEFORE executing: any recovery cycle that completes from here
        // on advances the counter past this value, including one that finishes
        // before we start watching for it.
        let recovery_generation_before = context
            .recovery_generation
            .load(std::sync::atomic::Ordering::Acquire);

        let result = DISCONNECT_RETRY_ATTEMPT
            .scope(attempt, instruction.execute(node_id, node_type, context))
            .await;

        // Only a Failure that was promoted to device-disconnect recovery is
        // eligible for the wait-and-retry path. Everything else (Success,
        // Skipped, Cancelled, or a non-disconnect Failure) returns as-is.
        if result != NodeStatus::Failure
            || !context
                .device_disconnect_recovery_pending
                .swap(false, Ordering::Relaxed)
        {
            return result;
        }

        if context.is_cancelled().await {
            // A cancel arrived concurrently with the disconnect; unwind.
            return NodeStatus::Cancelled;
        }

        if attempt >= MAX_DISCONNECT_RETRIES {
            tracing::error!(
                "[RECOVERY] Instruction '{}' still failing after {} device-disconnect \
                 recovery retries; giving up",
                node_id,
                attempt
            );
            return NodeStatus::Failure;
        }
        attempt += 1;

        tracing::warn!(
            "[RECOVERY] Instruction '{}' failed on device disconnect; waiting for recovery \
             driver to reconnect before retry {}/{}",
            node_id,
            attempt,
            MAX_DISCONNECT_RETRIES
        );

        match wait_for_disconnect_recovery(context, recovery_generation_before).await {
            DisconnectRecoveryOutcome::Recovered => {
                tracing::info!(
                    "[RECOVERY] Device reconnected; retrying instruction '{}' (retry {}/{})",
                    node_id,
                    attempt,
                    MAX_DISCONNECT_RETRIES
                );
                // Loop around and re-run the instruction.
            }
            DisconnectRecoveryOutcome::Cancelled => {
                tracing::warn!(
                    "[RECOVERY] Recovery for instruction '{}' ended without reconnect; \
                     propagating failure",
                    node_id
                );
                return NodeStatus::Cancelled;
            }
            DisconnectRecoveryOutcome::NoDriver => {
                tracing::error!(
                    "[RECOVERY] No recovery driver engaged within {:?} for instruction '{}'; \
                     cannot resume — failing closed",
                    RECOVERY_ENGAGE_TIMEOUT,
                    node_id
                );
                return NodeStatus::Failure;
            }
        }
    }
}

/// Outcome of waiting for the recovery driver after a device disconnect.
enum DisconnectRecoveryOutcome {
    /// Recovery succeeded — the device is reconnected and the tree is unpaused.
    Recovered,
    /// Recovery gave up or the sequence was cancelled — unwind.
    Cancelled,
    /// No recovery driver engaged (no channel / closed) within the window.
    NoDriver,
}

/// Block until the recovery driver finishes the recovery cycle it engages in
/// response to a device-disconnect request.
///
/// State contract with the executor's recovery driver task:
/// * on entry it sets `is_paused = true`,
/// * on success it clears `is_paused` (and leaves `is_cancelled` false),
/// * on give-up it sets `is_cancelled = true`.
async fn wait_for_disconnect_recovery(
    context: &ExecutionContext,
    generation_before: u64,
) -> DisconnectRecoveryOutcome {
    // Phase 1: wait for the driver to engage (is_paused true). Bounded so a
    // missing/closed recovery channel does not hang the night.
    let engage_deadline = tokio::time::Instant::now() + RECOVERY_ENGAGE_TIMEOUT;
    loop {
        if context.is_cancelled().await {
            return DisconnectRecoveryOutcome::Cancelled;
        }
        if context.is_paused() {
            break;
        }
        // A recovery cycle that ran to completion while we were getting here
        // never leaves `is_paused` set for us to see. Without this the run died
        // on a SUCCESSFUL recovery ("No recovery driver engaged within 10s"
        // logged right after "Loop succeeded ... resuming sequence"). Checked
        // after `is_paused` so an in-flight recovery still takes Phase 2.
        if context
            .recovery_generation
            .load(std::sync::atomic::Ordering::Acquire)
            > generation_before
        {
            return DisconnectRecoveryOutcome::Recovered;
        }
        if tokio::time::Instant::now() >= engage_deadline {
            return DisconnectRecoveryOutcome::NoDriver;
        }
        tokio::time::sleep(RECOVERY_POLL_INTERVAL).await;
    }

    // Phase 2: wait for the recovery cycle to finish. `wait_while_paused`
    // blocks until `is_paused` clears or `is_cancelled` is set, returning
    // `false` on cancel. A cleared pause with no cancel means the driver
    // reconnected successfully and resumed the tree.
    if context.wait_while_paused().await {
        DisconnectRecoveryOutcome::Recovered
    } else {
        DisconnectRecoveryOutcome::Cancelled
    }
}

/// Base trait for all behaviour-tree nodes.
#[async_trait]
pub trait Node: Send + Sync {
    fn id(&self) -> &NodeId;
    fn name(&self) -> &str;
    fn node_type(&self) -> &NodeType;
    fn is_enabled(&self) -> bool;
    async fn execute(&mut self, context: &mut ExecutionContext) -> NodeStatus;
    fn reset(&mut self);
    async fn abort(&mut self);
    fn children(&self) -> &[Box<dyn Node>];
    fn children_mut(&mut self) -> &mut Vec<Box<dyn Node>>;
    fn mark_completed(&mut self, node_id: &NodeId);

    /// record the live `current_iteration` of every Loop node in this
    /// subtree into `out` (keyed by node id), for checkpointing. Default is a
    /// no-op recursion is supplied by [`RuntimeNode`]; leaf mocks don't loop.
    fn snapshot_loop_iterations(&self, _out: &mut std::collections::HashMap<NodeId, u32>) {}

    /// restore the persisted `current_iteration` of Loop nodes in this
    /// subtree from `map`, so a resumed Count loop continues from where it
    /// stopped instead of restarting at iteration 1.
    fn restore_loop_iterations(&mut self, _map: &std::collections::HashMap<NodeId, u32>) {}

    /// Does this subtree contain `node_id`?
    fn contains_node(&self, node_id: &NodeId) -> bool {
        if self.id() == node_id {
            return true;
        }
        for child in self.children() {
            if child.contains_node(node_id) {
                return true;
            }
        }
        false
    }
}

/// A runtime node instance built from a NodeDefinition.
pub struct RuntimeNode {
    pub definition: NodeDefinition,
    pub children: Vec<Box<dyn Node>>,
    pub status: NodeStatus,
    pub current_iteration: u32,
}

impl RuntimeNode {
    pub fn from_definition(def: NodeDefinition) -> Self {
        Self {
            definition: def,
            children: Vec::new(),
            status: NodeStatus::Pending,
            current_iteration: 0,
        }
    }

    pub fn add_child(&mut self, child: Box<dyn Node>) {
        self.children.push(child);
    }
}

#[async_trait]
impl Node for RuntimeNode {
    fn id(&self) -> &NodeId {
        &self.definition.id
    }

    fn name(&self) -> &str {
        &self.definition.name
    }

    fn node_type(&self) -> &NodeType {
        &self.definition.node_type
    }

    fn is_enabled(&self) -> bool {
        self.definition.enabled
    }

    async fn execute(&mut self, context: &mut ExecutionContext) -> NodeStatus {
        if !self.definition.enabled {
            self.status = NodeStatus::Skipped;
            return NodeStatus::Skipped;
        }

        // resume short-circuit. On resume, `resume_from_checkpoint`
        // walks the freshly-built tree and calls `mark_completed` on every
        // already-Success node, then the executor re-walks the WHOLE tree.
        // The intended (and documented) behaviour is to skip those completed
        // nodes — but that short-circuit never existed, so this `execute`
        // overwrote the restored `Success` with `Running` below and re-ran
        // finished steps (re-slewing, re-exposing completed frames). Honour
        // the restored completion here. Loops call `child.reset()` (→ Pending)
        // before each iteration, so a legitimately-repeating child is never
        // wrongly skipped.
        if self.status == NodeStatus::Success {
            tracing::debug!(
                "Resume short-circuit: node '{}' already Success, skipping re-execution",
                self.id()
            );
            return NodeStatus::Success;
        }

        self.status = NodeStatus::Running;
        // render the node display name through the interpolation
        // engine so user-authored templates like
        // "Image ${target.name} with ${filter}" become live labels in the
        // Run Dashboard. Resolution failure is non-fatal here (a display
        // string is not load-bearing); we log and fall back to the raw
        // template so the operator still sees something.
        let display_name = render_node_display_name(self.name(), context);
        context.send_progress(ProgressUpdate::lifecycle(
            self.id().clone(),
            NodeStatus::Running,
            format!("Executing: {}", display_name),
        ));

        // Cloning is cheap on serde-derived configs; this avoids a mutable
        // borrow of self.definition while we also need &mut self for the
        // container variants.
        let node_type = self.definition.node_type.clone();
        let node_id = self.definition.id.clone();

        let result = match &node_type {
            // Container / logic variants. They take `&mut self` so they can
            // walk self.children; the trait-registry dispatch does NOT cover
            // them.
            NodeType::TargetHeader(config) | NodeType::TargetGroup(config) => {
                logic::target_header::execute_target_header(self, config.clone(), context).await
            }
            NodeType::Loop(config) => {
                logic::loop_node::execute_loop(self, config.clone(), context).await
            }
            NodeType::Parallel(config) => {
                logic::parallel::execute_parallel(self, config.clone(), context).await
            }
            NodeType::Conditional(config) => {
                logic::conditional::execute_conditional(self, config.clone(), context).await
            }
            NodeType::Recovery(config) => {
                logic::recovery::execute_recovery(self, config.clone(), context).await
            }
            // TargetScheduler — dynamic target picker. Container
            // variant: needs &mut self to walk + reset children, so it lives
            // here alongside the other logic nodes rather than in the
            // instruction registry.
            NodeType::TargetScheduler(config) => {
                logic::target_scheduler::execute_target_scheduler(self, config.clone(), context)
                    .await
            }
            // All other variants — instruction nodes — go through the registry,
            // wrapped so a device-disconnect failure waits for the recovery
            // driver to reconnect and then RETRIES the instruction instead of
            // ending the sequence on a single USB/comms blip.
            other => {
                execute_instruction_with_disconnect_retry(other, &node_id, &node_type, context)
                    .await
            }
        };

        self.status = result;
        // Re-render in case interpolation values changed between Running
        // and Completed events (e.g. a target swap between events).
        let display_name = render_node_display_name(self.name(), context);
        // The verb must follow `result`. This message was hardcoded to
        // "Completed: {}" for EVERY outcome, so a node that failed, was
        // cancelled or was skipped still announced that it had completed. It is
        // the last progress message a run emits (the root container is the last
        // node to reach a terminal status), and it lands in
        // `SequenceProgress.message`, which `/api/sequencer/status` returns
        // alongside the authoritative `state`.
        //
        // Observed verbatim on the live rig, on a run that genuinely failed at a
        // Move Rotator node with no rotator connected:
        //   {"state":"failed", ...,
        //    "message":"Completed: CLAUDE SEQ AUDIT R4 FAIL"}
        // The DB row for that run is `status='failed'` and its vitals carry
        // "Sequence failed", so `state` was right and the message was the lie —
        // but a client rendering the message (every status banner does) told the
        // operator the night had finished cleanly.
        let verb = match result {
            NodeStatus::Success => "Completed",
            NodeStatus::Failure => "Failed",
            NodeStatus::Cancelled => "Cancelled",
            NodeStatus::Skipped => "Skipped",
            // Not reachable: `result` is the terminal status of the node body.
            // Kept exhaustive so a new NodeStatus variant fails to compile here
            // rather than silently reporting the wrong verb.
            NodeStatus::Pending | NodeStatus::Running => "Finished",
        };
        context.send_progress(ProgressUpdate::lifecycle(
            self.id().clone(),
            result,
            format!("{}: {}", verb, display_name),
        ));

        result
    }

    fn reset(&mut self) {
        self.status = NodeStatus::Pending;
        self.current_iteration = 0;
        for child in &mut self.children {
            child.reset();
        }
    }

    async fn abort(&mut self) {
        self.status = NodeStatus::Cancelled;
        for child in &mut self.children {
            child.abort().await;
        }
    }

    fn children(&self) -> &[Box<dyn Node>] {
        &self.children
    }

    fn children_mut(&mut self) -> &mut Vec<Box<dyn Node>> {
        &mut self.children
    }

    fn mark_completed(&mut self, node_id: &NodeId) {
        if self.id() == node_id {
            self.status = NodeStatus::Success;
        } else {
            for child in &mut self.children {
                child.mark_completed(node_id);
            }
        }
    }

    fn snapshot_loop_iterations(&self, out: &mut std::collections::HashMap<NodeId, u32>) {
        if matches!(self.definition.node_type, NodeType::Loop(_)) && self.current_iteration > 0 {
            out.insert(self.id().clone(), self.current_iteration);
        }
        for child in &self.children {
            child.snapshot_loop_iterations(out);
        }
    }

    fn restore_loop_iterations(&mut self, map: &std::collections::HashMap<NodeId, u32>) {
        if matches!(self.definition.node_type, NodeType::Loop(_)) {
            if let Some(&iter) = map.get(self.id()) {
                self.current_iteration = iter;
            }
        }
        for child in &mut self.children {
            child.restore_loop_iterations(map);
        }
    }
}

#[cfg(test)]
mod disconnect_recovery_tests {
    use super::*;
    use crate::node::context::ExecutionContext;
    use std::sync::Arc;

    /// When the recovery driver engages (is_paused) and then resumes the tree
    /// (clears is_paused without cancelling), the wait resolves to Recovered so
    /// the node retries the failed instruction.
    #[tokio::test]
    async fn wait_resolves_recovered_when_driver_pauses_then_resumes() {
        let ctx = ExecutionContext::new_for_test("n".to_string());
        let is_paused = ctx.is_paused.clone();
        let resume_notify = ctx.resume_notify.clone();

        // Simulate the recovery driver: engage shortly after the wait starts,
        // hold the paused state well past the wait's poll interval so the
        // engage phase reliably observes is_paused == true, then resume.
        tokio::spawn(async move {
            is_paused.store(true, Ordering::Relaxed);
            tokio::time::sleep(std::time::Duration::from_millis(600)).await;
            is_paused.store(false, Ordering::Relaxed);
            resume_notify.notify_waiters();
        });

        let outcome =
            wait_for_disconnect_recovery(&ctx, ctx.recovery_generation.load(Ordering::Acquire))
                .await;
        assert!(
            matches!(outcome, DisconnectRecoveryOutcome::Recovered),
            "driver pause->resume must resolve as Recovered so the node retries"
        );
    }

    /// When the recovery driver engages then gives up (sets is_cancelled), the
    /// wait resolves to Cancelled so the node unwinds.
    #[tokio::test]
    async fn wait_resolves_cancelled_when_driver_gives_up() {
        let ctx = ExecutionContext::new_for_test("n".to_string());
        let is_paused = ctx.is_paused.clone();
        let is_cancelled = ctx.is_cancelled.clone();
        let resume_notify = ctx.resume_notify.clone();

        tokio::spawn(async move {
            is_paused.store(true, Ordering::Relaxed);
            tokio::time::sleep(std::time::Duration::from_millis(600)).await;
            // Give-up contract: set is_cancelled (the driver also leaves
            // is_paused set, but wait_while_paused checks is_cancelled first).
            is_cancelled.store(true, Ordering::Relaxed);
            resume_notify.notify_waiters();
        });

        let outcome =
            wait_for_disconnect_recovery(&ctx, ctx.recovery_generation.load(Ordering::Acquire))
                .await;
        assert!(
            matches!(outcome, DisconnectRecoveryOutcome::Cancelled),
            "driver give-up must resolve as Cancelled so the node unwinds"
        );
    }

    /// If a cancel is already pending when the wait begins, it resolves to
    /// Cancelled immediately without waiting for a driver to engage.
    #[tokio::test]
    async fn wait_resolves_cancelled_when_already_cancelled() {
        let ctx = ExecutionContext::new_for_test("n".to_string());
        ctx.is_cancelled.store(true, Ordering::Relaxed);
        let outcome =
            wait_for_disconnect_recovery(&ctx, ctx.recovery_generation.load(Ordering::Acquire))
                .await;
        assert!(matches!(outcome, DisconnectRecoveryOutcome::Cancelled));
    }

    /// The shared device-disconnect pending flag round-trips between an
    /// ExecutionContext and the InstructionContext it produces — the contract
    /// the retry wrapper relies on to detect a promoted disconnect.
    #[tokio::test]
    async fn pending_flag_is_shared_with_instruction_context() {
        let ctx = ExecutionContext::new_for_test("n".to_string());
        let inst = ctx.to_instruction_context("test-node").await;
        // Writing through the InstructionContext side is visible on the
        // ExecutionContext side (same Arc allocation).
        inst.device_disconnect_recovery_pending
            .store(true, Ordering::Relaxed);
        assert!(
            ctx.device_disconnect_recovery_pending
                .load(Ordering::Relaxed),
            "pending flag must be shared across the context boundary"
        );
        assert!(
            Arc::ptr_eq(
                &ctx.device_disconnect_recovery_pending,
                &inst.device_disconnect_recovery_pending
            ),
            "both contexts must reference the same flag allocation"
        );
    }
}

#[cfg(test)]
mod resume_short_circuit_tests {
    use super::*;
    use crate::node::context::ExecutionContext;
    use crate::node::logic::loop_node::execute_loop;
    use crate::node::Node;
    use crate::{DelayConfig, LoopCondition, LoopConfig, NodeStatus, ParallelConfig};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    /// Leaf spy that records how many times `execute` was entered. Used to prove
    /// a Loop re-runs its body the correct number of iterations on resume.
    struct ExecSpy {
        id: NodeId,
        node_type: NodeType,
        executed: Arc<AtomicUsize>,
        no_children: Vec<Box<dyn Node>>,
    }

    impl ExecSpy {
        fn new(id: &str, executed: Arc<AtomicUsize>) -> Self {
            Self {
                id: id.to_string(),
                node_type: NodeType::Park,
                executed,
                no_children: Vec::new(),
            }
        }
    }

    #[async_trait]
    impl Node for ExecSpy {
        fn id(&self) -> &NodeId {
            &self.id
        }
        fn name(&self) -> &str {
            "exec-spy"
        }
        fn node_type(&self) -> &NodeType {
            &self.node_type
        }
        fn is_enabled(&self) -> bool {
            true
        }
        async fn execute(&mut self, _context: &mut ExecutionContext) -> NodeStatus {
            self.executed.fetch_add(1, Ordering::SeqCst);
            NodeStatus::Success
        }
        fn reset(&mut self) {}
        async fn abort(&mut self) {}
        fn children(&self) -> &[Box<dyn Node>] {
            &self.no_children
        }
        fn children_mut(&mut self) -> &mut Vec<Box<dyn Node>> {
            &mut self.no_children
        }
        fn mark_completed(&mut self, _node_id: &NodeId) {}
    }

    fn delay_node(id: &str, seconds: f64) -> RuntimeNode {
        RuntimeNode::from_definition(crate::NodeDefinition {
            id: id.to_string(),
            name: id.to_string(),
            node_type: NodeType::Delay(DelayConfig { seconds }),
            enabled: true,
            children: Vec::new(),
        })
    }

    /// A node whose status was restored to `Success` on resume must
    /// short-circuit out of `execute` WITHOUT dispatching its instruction. We
    /// prove "did not dispatch" by giving the node a 9999s Delay: if the
    /// short-circuit holds, `execute` returns immediately; if the restored
    /// Success were overwritten with Running and dispatched, the Delay would
    /// run for ~9999s and the tight timeout would elapse.
    #[tokio::test]
    async fn resume_skips_already_success_node() {
        let mut node = delay_node("done-step", 9999.0);
        // Simulate `resume_from_checkpoint` marking this node completed.
        node.mark_completed(&"done-step".to_string());
        assert_eq!(node.status, NodeStatus::Success);

        let mut ctx = ExecutionContext::new_for_test("done-step".to_string());

        let status = tokio::time::timeout(Duration::from_secs(2), node.execute(&mut ctx))
            .await
            .expect("resume short-circuit must return immediately, not run the 9999s delay");

        assert_eq!(
            status,
            NodeStatus::Success,
            "an already-Success node must report Success on resume"
        );
        assert_eq!(
            node.status,
            NodeStatus::Success,
            "the restored Success must NOT be overwritten with Running"
        );
    }

    /// Negative control: a fresh (Pending) node of the same kind DOES dispatch.
    /// This guards against a short-circuit that fires unconditionally and would
    /// silently skip real work. A 0s Delay dispatches and completes instantly.
    #[tokio::test]
    async fn fresh_node_still_executes() {
        let mut node = delay_node("fresh-step", 0.0);
        assert_eq!(node.status, NodeStatus::Pending);

        let mut ctx = ExecutionContext::new_for_test("fresh-step".to_string());
        let status = node.execute(&mut ctx).await;
        assert_eq!(status, NodeStatus::Success);
    }

    /// (parallel): the resume short-circuit applies to container nodes too.
    /// A Parallel node restored to Success must NOT re-spawn its branches. The
    /// child here is a 9999s Delay; if the container re-executed, it would block
    /// on that delay and the tight timeout would elapse.
    #[tokio::test]
    async fn resume_skips_already_success_parallel_container() {
        let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
            id: "par".to_string(),
            name: "par".to_string(),
            node_type: NodeType::Parallel(ParallelConfig {
                required_successes: None,
            }),
            enabled: true,
            children: Vec::new(),
        });
        node.children.push(Box::new(delay_node("branch", 9999.0)));
        node.mark_completed(&"par".to_string());
        assert_eq!(node.status, NodeStatus::Success);

        let mut ctx = ExecutionContext::new_for_test("par".to_string());
        let status = tokio::time::timeout(Duration::from_secs(2), node.execute(&mut ctx))
            .await
            .expect("a resumed Success container must not re-spawn its branches");
        assert_eq!(status, NodeStatus::Success);
    }

    /// A Count loop resumed mid-run (current_iteration restored from a
    /// checkpoint) continues from where it stopped rather than restarting at 0 and
    /// re-imaging every completed iteration. Loop(count=3) restored to iteration 2
    /// runs exactly ONE more iteration (the 3rd), so the child executes exactly
    /// once.
    #[tokio::test]
    async fn resume_loop_continues_from_restored_iteration() {
        let executed = Arc::new(AtomicUsize::new(0));
        let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
            id: "loop".to_string(),
            name: "loop".to_string(),
            node_type: NodeType::Loop(LoopConfig {
                iterations: Some(3),
                condition: LoopCondition::Count,
                condition_value: None,
                horizon_profile: None,
            }),
            enabled: true,
            children: Vec::new(),
        });
        node.children
            .push(Box::new(ExecSpy::new("body", executed.clone())));

        // Simulate `resume_from_checkpoint` -> restore_loop_iterations setting
        // the live iteration count to 2 (two iterations already completed).
        let mut restored = std::collections::HashMap::new();
        restored.insert("loop".to_string(), 2u32);
        node.restore_loop_iterations(&restored);
        assert_eq!(node.current_iteration, 2, "iteration must be restored to 2");

        let cfg = LoopConfig {
            iterations: Some(3),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        };
        let mut ctx = ExecutionContext::new_for_test("loop".to_string());
        let status = execute_loop(&mut node, cfg, &mut ctx).await;

        assert_eq!(status, NodeStatus::Success);
        assert_eq!(
            executed.load(Ordering::SeqCst),
            1,
            "a Loop(3) resumed at iteration 2 must run only the final iteration"
        );
        assert_eq!(node.current_iteration, 3, "loop must finish at iteration 3");
    }

    /// Negative control for a FRESH Count loop (iteration 0) runs the full
    /// count. Guards against a resume fix that wrongly skips iterations on a
    /// normal (non-resumed) run.
    #[tokio::test]
    async fn fresh_loop_runs_full_count() {
        let executed = Arc::new(AtomicUsize::new(0));
        let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
            id: "loop".to_string(),
            name: "loop".to_string(),
            node_type: NodeType::Loop(LoopConfig {
                iterations: Some(3),
                condition: LoopCondition::Count,
                condition_value: None,
                horizon_profile: None,
            }),
            enabled: true,
            children: Vec::new(),
        });
        node.children
            .push(Box::new(ExecSpy::new("body", executed.clone())));

        let cfg = LoopConfig {
            iterations: Some(3),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        };
        let mut ctx = ExecutionContext::new_for_test("loop".to_string());
        let status = execute_loop(&mut node, cfg, &mut ctx).await;

        assert_eq!(status, NodeStatus::Success);
        assert_eq!(
            executed.load(Ordering::SeqCst),
            3,
            "a fresh Loop(3) must run all three iterations"
        );
    }
}

#[cfg(test)]
mod disconnect_recovery_race_tests {
    use super::*;
    use std::sync::atomic::Ordering as AtomicOrdering;

    fn ctx() -> ExecutionContext {
        ExecutionContext::new_for_test("node-under-test".to_string())
    }

    /// A recovery that COMPLETES before the failed instruction starts watching
    /// leaves `is_paused` already cleared, so a level-triggered check waits out
    /// its 10 s and returns `NoDriver`, killing the run on a SUCCESSFUL recovery.
    /// The generation counter makes completion observable after the fact.
    #[tokio::test]
    async fn already_completed_recovery_reads_as_recovered() {
        let context = ctx();
        let before = context.recovery_generation.load(AtomicOrdering::Acquire);

        // Driver engaged and finished entirely before we look: pause raised and
        // cleared again, generation advanced. `is_paused` is false right now.
        context
            .recovery_generation
            .fetch_add(1, AtomicOrdering::AcqRel);
        assert!(!context.is_paused());

        let outcome = wait_for_disconnect_recovery(&context, before).await;
        assert!(
            matches!(outcome, DisconnectRecoveryOutcome::Recovered),
            "a completed recovery must read as Recovered, not NoDriver"
        );
    }

    /// The fail-closed direction that must NOT regress: with no driver at all the
    /// generation never advances, so the wait still gives up rather than letting
    /// the instruction retry against hardware that was never reconnected.
    #[tokio::test(start_paused = true)]
    async fn genuinely_absent_driver_still_reports_no_driver() {
        let context = ctx();
        let before = context.recovery_generation.load(AtomicOrdering::Acquire);

        let outcome = wait_for_disconnect_recovery(&context, before).await;
        assert!(
            matches!(outcome, DisconnectRecoveryOutcome::NoDriver),
            "no driver must still fail closed"
        );
    }

    /// A cancel during the wait still unwinds rather than being mistaken for a
    /// recovery.
    #[tokio::test]
    async fn cancellation_during_wait_unwinds() {
        let context = ctx();
        let before = context.recovery_generation.load(AtomicOrdering::Acquire);
        context.is_cancelled.store(true, AtomicOrdering::Relaxed);

        let outcome = wait_for_disconnect_recovery(&context, before).await;
        assert!(matches!(outcome, DisconnectRecoveryOutcome::Cancelled));
    }
}
