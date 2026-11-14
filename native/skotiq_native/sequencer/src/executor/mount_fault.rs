//! Telling the run in progress something without taking the executor:
//! holding it for a mount fault, resuming it, logging an outside action.
//!
//! The device layer watches the mount for motion nobody commanded and for a
//! position the mount can no longer vouch for (see the bridge's
//! `device_manager::motion_guard`). Either one makes every frame worthless
//! and every automatic move dangerous, so the run is paused, not ended: the
//! operator recovers the mount and resumes. This is the run's half of that.

use super::*;
use crate::decision::{DecisionCategory, DecisionEvent};

impl ExecutorHandle {
    /// Pause a running run because its mount moved on its own or lost its
    /// position.
    ///
    /// The run's guiding is stopped through `device_ops` the way the run's own
    /// moves stop it, so it is never read as a lost guide star and starts again
    /// on a fresh star after the run recenters. The frame exposing now is
    /// rejected when it finishes, and the next light frame first centers on the
    /// target.
    ///
    /// Returns `Ok(false)` when there is no run to hold.
    pub async fn hold_for_mount_fault(
        &self,
        message: &str,
        device_ops: &SharedDeviceOps,
    ) -> Result<bool, String> {
        let state = self.run_state.get();
        if !matches!(
            state,
            ExecutorState::Running | ExecutorState::Paused | ExecutorState::Recovering
        ) {
            return Ok(false);
        }
        let trigger_state = self.trigger_manager.read().await.state();
        let run_guiding = {
            let mut ts = trigger_state.write().await;
            ts.latches.mount_fault_at = Some(chrono::Utc::now().timestamp());
            ts.latches.mount_fault_recenter_pending = true;
            ts.guiding.is_enabled()
        };
        if let Some(tx) = self.commands.sender() {
            tx.send(ExecutorCommand::Pause)
                .await
                .map_err(|e| e.to_string())?;
        }
        if run_guiding {
            crate::instructions::stop_an_active_guider(
                device_ops,
                "mount fault",
                crate::GuidingStopReason::MountFault,
            )
            .await;
            let mut ts = trigger_state.write().await;
            ts.set_guiding_enabled(false);
            ts.set_guide_star_lost(false);
            ts.guiding.set_resume_pending(true);
        }
        self.run_state.set_message(format!("Paused: {message}"));
        // No executor error: an error reads as the run failing, and the
        // device layer already raised the alarm with what the mount did.
        self.emit_manual_intervention("mount_fault_hold", serde_json::json!({ "reason": message }));
        Ok(true)
    }

    /// Resume a paused run. The run wakes and picks up at its next step.
    pub async fn resume(&self) -> Result<(), String> {
        if let Some(tx) = self.commands.sender() {
            tx.send(ExecutorCommand::Resume)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.emit_manual_intervention("resume", serde_json::json!({}));
        Ok(())
    }

    /// Record an operator's (or the device layer's) action on the run in its
    /// decision log.
    pub(crate) fn emit_manual_intervention(&self, action: &str, details: serde_json::Value) {
        if !self.settings.read().decision_logging_enabled {
            return;
        }
        let _ = self
            .decision_tx
            .send(self.manual_intervention_row(action, details));
    }

    pub(crate) fn manual_intervention_row(
        &self,
        action: &str,
        details: serde_json::Value,
    ) -> DecisionEvent {
        let mut full = details;
        if let serde_json::Value::Object(ref mut m) = full {
            m.insert(
                "action".to_string(),
                serde_json::Value::String(action.to_string()),
            );
        } else {
            full = serde_json::json!({ "action": action, "data": full });
        }
        DecisionEvent {
            timestamp: chrono::Utc::now(),
            category: DecisionCategory::ManualIntervention,
            summary: format!("Operator: {action}"),
            details: full,
            node_id: None,
            sequence_run_id: *self.active_sequence_run_id.read(),
            notice: None,
            stop: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_ops::NullDeviceOps;
    use crate::{DelayConfig, NodeDefinition, NodeType, SequenceDefinition};

    fn waiting_plan() -> SequenceDefinition {
        let mut sequence = SequenceDefinition::new("Long wait".to_string());
        sequence.nodes.push(NodeDefinition {
            id: "wait".to_string(),
            name: "Wait".to_string(),
            node_type: NodeType::Delay(DelayConfig { seconds: 120.0 }),
            enabled: true,
            children: vec![],
        });
        sequence.root_node_id = Some("wait".to_string());
        sequence
    }

    /// What the run announced within `window`: its state changes, and how
    /// many errors of any kind.
    async fn announced(
        events: &mut broadcast::Receiver<ExecutorEvent>,
        window: std::time::Duration,
    ) -> (Vec<ExecutorState>, usize) {
        let mut states = Vec::new();
        let mut errors = 0;
        let deadline = tokio::time::Instant::now() + window;
        while let Ok(Ok(event)) = tokio::time::timeout_at(deadline, events.recv()).await {
            match event {
                ExecutorEvent::StateChanged(state) => states.push(state),
                ExecutorEvent::Error { .. }
                | ExecutorEvent::RunHeld { .. }
                | ExecutorEvent::StepProblem { .. }
                | ExecutorEvent::SequenceFailed { .. } => errors += 1,
                _ => {}
            }
        }
        (states, errors)
    }

    /// A mount fault pauses the run, and the run says so once: the device
    /// layer's alarm is the notice, so the hold raises no error, and a
    /// runaway that ends in a lost position holds the same run a second time
    /// without a second "Sequence paused".
    #[tokio::test]
    async fn a_mount_fault_hold_pauses_the_run_and_announces_it_once() {
        let mut executor = SequenceExecutor::new();
        executor.set_device_ops(Arc::new(NullDeviceOps));
        executor
            .load_sequence(waiting_plan())
            .expect("sequence loads");
        let mut events = executor.subscribe();
        executor.start().await.expect("run starts");
        // What the start announced is not under test.
        announced(&mut events, std::time::Duration::from_millis(300)).await;

        let ops: SharedDeviceOps = Arc::new(NullDeviceOps);
        let held = executor
            .handle()
            .hold_for_mount_fault("the mount moved on its own", &ops)
            .await
            .expect("the hold is accepted");
        let held_again = executor
            .handle()
            .hold_for_mount_fault("the mount lost its position", &ops)
            .await
            .expect("the second hold is accepted");
        let (states, errors) = announced(&mut events, std::time::Duration::from_millis(500)).await;

        assert!(held && held_again);
        assert_eq!(states, vec![ExecutorState::Paused]);
        assert_eq!(errors, 0, "a hold is not an error of the run");
        assert_eq!(
            executor.get_progress().message.as_deref(),
            Some("Paused: the mount lost its position")
        );
        executor.stop().await.expect("the run stops");
    }

    /// The device layer holds the run while something else has the executor
    /// taken (a start or a stop in progress): the hold does not wait for it.
    #[tokio::test]
    async fn a_run_is_held_while_the_executor_is_taken() {
        let mut executor = SequenceExecutor::new();
        executor.set_device_ops(Arc::new(NullDeviceOps));
        executor
            .load_sequence(waiting_plan())
            .expect("sequence loads");
        executor.start().await.expect("run starts");
        let handle = executor.handle();
        let executor = Arc::new(RwLock::new(executor));
        let taken = executor.write().await;

        let held = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            handle.hold_for_mount_fault(
                "the mount moved on its own",
                &(Arc::new(NullDeviceOps) as SharedDeviceOps),
            ),
        )
        .await
        .expect("the hold does not wait for the executor")
        .expect("the hold is accepted");

        assert!(held);
        drop(taken);
        executor.write().await.stop().await.expect("the run stops");
    }

    #[tokio::test]
    async fn with_no_run_there_is_nothing_to_hold() {
        let executor = SequenceExecutor::new();
        let mut events = executor.subscribe();

        let held = executor
            .handle()
            .hold_for_mount_fault(
                "the mount moved on its own",
                &(Arc::new(NullDeviceOps) as SharedDeviceOps),
            )
            .await
            .expect("the call is accepted");
        let (states, _) = announced(&mut events, std::time::Duration::from_millis(100)).await;

        assert!(!held);
        assert!(states.is_empty());
    }
}
