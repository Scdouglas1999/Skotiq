//! Crash-recovery checkpoint surface on the [`SequenceExecutor`].
//!
//! Five-and-a-half methods that wire [`crate::checkpoint::CheckpointManager`]
//! into the executor lifecycle:
//!
//!   * [`SequenceExecutor::set_checkpoint_dir`] — opt the executor into
//!     persistence by giving it a directory.
//!   * [`SequenceExecutor::has_recoverable_checkpoint`] /
//!     [`SequenceExecutor::get_checkpoint_info`] — pre-start UI probes.
//!   * [`SequenceExecutor::load_checkpoint`] /
//!     [`SequenceExecutor::resume_from_checkpoint`] — rehydrate the
//!     executor from the latest on-disk snapshot.
//!   * [`SequenceExecutor::save_checkpoint`] — write the current
//!     in-memory state to disk; called by the streaming-checkpoint
//!     task on every milestone (frame completed, node finished).
//!   * [`SequenceExecutor::clear_checkpoint`] /
//!     [`SequenceExecutor::mark_checkpoint_completed`] — terminal
//!     hygiene.
//!
//! Why these belong together: every method is gated on
//! `self.checkpoint_manager`, treats `None` as "checkpoint feature
//! disabled" (so a CLI run without a checkpoint dir behaves as if the
//! feature did not exist), and routes through the same on-disk format.
//! Splitting them across files would force every caller to learn two
//! file boundaries to read the persistence contract.
//!
//!16 invariant (preserved): the same `Arc<CheckpointManager>`
//! is shared between the executor's public API (these methods) and the
//! streaming-checkpoint task spawned inside `start()`. The
//! `checkpoint_manager_is_arc_shared` test in `mod.rs` enforces this
//! by pointer equality.
//!
//! What is deliberately NOT here:
//!   * The streaming-checkpoint task itself — that lives inline in
//!     `start()` because it captures dozens of locals from the spawn
//!     site.
//!   * The on-disk format (`SessionCheckpoint`, `CheckpointManager`) —
//!     that lives in [`crate::checkpoint`]. This file is only the
//!     executor-side bridge.

use super::SequenceExecutor;
use crate::NodeStatus;
use std::sync::Arc;

impl SequenceExecutor {
    /// Set the checkpoint directory for crash recovery.
    ///
    /// Wraps the [`crate::checkpoint::CheckpointManager`] in an `Arc`
    /// so the spawned streaming-checkpoint task in `start()` shares the
    /// exact same instance (including its `info_cache`) —
    /// Constructing a second manager via `CheckpointManager::new` would
    /// bypass the cache and cause UI staleness on
    /// [`Self::has_recoverable_checkpoint`].
    pub fn set_checkpoint_dir<P: AsRef<std::path::Path>>(&mut self, path: P) {
        self.checkpoint_manager = Some(Arc::new(crate::checkpoint::CheckpointManager::new(path)));
    }

    /// True iff a recoverable on-disk checkpoint exists for the
    /// configured directory.
    ///
    /// Returns `false` when no checkpoint manager has been configured —
    /// that case is "feature disabled" (CLI runs without a checkpoint
    /// dir), not "feature broken", so the false answer is honest.
    pub fn has_recoverable_checkpoint(&self) -> bool {
        self.checkpoint_manager
            .as_ref()
            .map(|m| m.has_recoverable_checkpoint())
            // Why: `checkpoint_manager` is `Option<Arc<CheckpointManager>>`
            // — None means `set_checkpoint_dir` has not been called, so checkpoint recovery
            // is disabled for this executor instance. No manager = no recoverable
            // checkpoint, which is the correct sentinel.
            .unwrap_or(false)
    }

    /// Info about the on-disk checkpoint (sequence name, save path,
    /// completed-exposures count) for the recovery banner. `None` when
    /// no manager is configured OR when the info fetch itself fails —
    /// the UI treats both as "no checkpoint to offer".
    pub fn get_checkpoint_info(&self) -> Option<crate::checkpoint::CheckpointInfo> {
        self.checkpoint_manager
            .as_ref()
            .and_then(|m| m.get_checkpoint_info().ok().flatten())
    }

    /// Load the on-disk checkpoint, mirror its device / location /
    /// save-path fields onto the executor, and stash a clone in
    /// `current_checkpoint` for the spawned task in `start()` to read.
    ///
    /// Errors when no checkpoint manager is configured: a silent fallback would
    /// let the operator press "Resume" and get a freshly-zeroed executor.
    pub fn load_checkpoint(
        &mut self,
    ) -> Result<Option<crate::checkpoint::SessionCheckpoint>, String> {
        let checkpoint = self
            .checkpoint_manager
            .as_ref()
            .ok_or("No checkpoint manager configured")?
            .load()?;

        if let Some(ref cp) = checkpoint {
            self.current_checkpoint = Some(cp.clone());

            self.camera_id = cp.camera_id.clone();
            self.mount_id = cp.mount_id.clone();
            self.focuser_id = cp.focuser_id.clone();
            self.filterwheel_id = cp.filterwheel_id.clone();
            self.rotator_id = cp.rotator_id.clone();

            self.latitude = cp.latitude;
            self.longitude = cp.longitude;

            self.save_path = cp.save_path.clone();

            tracing::info!("Loaded checkpoint for sequence: {}", cp.sequence.name);
        }

        Ok(checkpoint)
    }

    /// Snapshot the current execution state and write it to disk.
    ///
    /// Called by the streaming-checkpoint task in `start()` after every
    /// milestone (frame completed, node finished). The "last completed"
    /// node id is computed via [`Self::build_execution_order`] — tree-
    /// walk order, NOT lexical id ordering, because NodeIds are user-
    /// set strings and an earlier user-named "z_setup" would sort after
    /// a later "a_target".
    ///
    /// `Recovering` is treated as an active state alongside `Running` /
    /// `Paused` so a crash mid-recovery survives the reload; the
    /// operator decides whether to retry the recovery or give up.
    pub async fn save_checkpoint(&self) -> Result<(), String> {
        let manager = self
            .checkpoint_manager
            .as_ref()
            .ok_or("No checkpoint manager configured")?;

        let sequence = self.sequence.as_ref().ok_or("No sequence loaded")?;

        let progress = self.progress.read().clone();
        let state = self.get_state().await;

        let mut checkpoint = crate::checkpoint::SessionCheckpoint::new(sequence.clone());
        checkpoint.node_statuses = progress.node_statuses.clone();
        checkpoint.current_node = progress.current_node_id.clone();
        checkpoint.executor_state = state;
        checkpoint.completed_exposures = progress.completed_exposures;
        checkpoint.completed_integration_secs = progress.completed_integration_secs;
        // recovery is an active in-flight state too — preserve it
        // through checkpoints so a resumed session knows it crashed mid
        // recovery and the operator can decide whether to retry.
        checkpoint.is_active = matches!(
            state,
            super::ExecutorState::Running
                | super::ExecutorState::Paused
                | super::ExecutorState::Recovering
        );

        // Track "last completed" by the tree-walk order, not lexical NodeId
        // ordering — the latter would falsely pick an earlier node whose id
        // happens to sort after a later one (NodeIds are user-set strings).
        let execution_order = self.build_execution_order(sequence);
        checkpoint.last_completed_node = progress
            .node_statuses
            .iter()
            .filter(|(_, status)| matches!(status, NodeStatus::Success))
            .filter_map(|(id, _)| execution_order.get(id).map(|order| (id, *order)))
            .max_by_key(|(_, order)| *order)
            .map(|(id, _)| (*id).clone());

        checkpoint.set_devices(
            self.camera_id.clone(),
            self.mount_id.clone(),
            self.focuser_id.clone(),
            self.filterwheel_id.clone(),
            self.rotator_id.clone(),
        );
        checkpoint.set_location(self.latitude, self.longitude);
        checkpoint.set_save_path(self.save_path.clone());
        let trigger_state = {
            let manager = self.trigger_manager.read().await;
            manager.state()
        };
        let trigger_state = trigger_state.read().await;
        checkpoint.set_trigger_state(crate::checkpoint::TriggerStateSnapshot::from_state(
            &trigger_state,
            self.safety_fail_mode,
            self.triggers_enabled,
            self.filter_focus_offsets.clone(),
        ));

        // snapshot every Loop node's live current_iteration so a resumed
        // Count loop continues from where it stopped instead of restarting at
        // iteration 1 and re-imaging completed iterations.
        if let Some(ref root) = self.root_node {
            let mut loop_iterations = std::collections::HashMap::new();
            root.snapshot_loop_iterations(&mut loop_iterations);
            checkpoint.loop_iterations = loop_iterations;
        }

        // this public writer (driven by the Dart ~30s checkpoint
        // watchdog) does NOT hold the live budget / smart-exposure / scheduler
        // / wizard registries — those belong to the running ExecutionContext
        // and are persisted by the streaming-checkpoint task. Writing them
        // EMPTY here would overwrite the full-fidelity streaming checkpoint, so
        // a crash-resume would read zeroed budgets and re-image already-completed
        // targets. Carry the rich state forward from the existing on-disk
        // checkpoint so this writer only updates the fields it actually owns
        // (node statuses, current node, progress, trigger state, loop
        // iterations) and never wipes the rest.
        if let Ok(Some(existing)) = manager.load() {
            checkpoint.budget_states = existing.budget_states;
            checkpoint.smart_exposure_states = existing.smart_exposure_states;
            checkpoint.scheduler_states = existing.scheduler_states;
            checkpoint.wizard_states = existing.wizard_states;
        }

        manager.save(&checkpoint)?;

        Ok(())
    }

    /// Clear the on-disk checkpoint. Called by the bridge when a
    /// sequence completes normally so a subsequent start of an
    /// unrelated sequence does not see a stale "recoverable" banner.
    ///
    /// No-op when no checkpoint manager is configured.
    pub fn clear_checkpoint(&self) -> Result<(), String> {
        if let Some(ref manager) = self.checkpoint_manager {
            manager.clear()?;
        }
        Ok(())
    }

    /// Mark the checkpoint as completed (sequence finished gracefully).
    ///
    /// Distinct from [`Self::clear_checkpoint`] in that the on-disk
    /// file is preserved with a "completed" flag, letting the post-
    /// session report read totals without depending on transient
    /// in-memory state. The next start auto-clears it.
    pub fn mark_checkpoint_completed(&self) -> Result<(), String> {
        if let Some(ref manager) = self.checkpoint_manager {
            manager.mark_completed()?;
        }
        Ok(())
    }

    /// Resume a sequence from the most recent on-disk checkpoint.
    ///
    /// Loads the checkpoint (mirroring devices / location onto the
    /// executor via [`Self::load_checkpoint`]), rebuilds the runtime
    /// node tree from the persisted definition, marks already-Success
    /// nodes on the fresh tree, restores the trigger state snapshot,
    /// and re-applies safety / triggers-enabled / filter-offsets
    /// fields. The next `start()` walks the same tree and short-
    /// circuits the marked nodes — that is what makes resume
    /// idempotent.
    ///
    /// Errors when no checkpoint is loaded or when the checkpoint
    /// itself reports `can_resume() == false` (e.g. checkpoint was
    /// written by a future version of the sequencer).
    pub async fn resume_from_checkpoint(&mut self) -> Result<(), String> {
        let checkpoint = self
            .load_checkpoint()?
            .ok_or("No checkpoint to resume from")?;

        if !checkpoint.can_resume() {
            return Err("Checkpoint cannot be resumed".to_string());
        }

        self.load_sequence(checkpoint.sequence.clone())?;

        {
            let mut progress = self.progress.write();
            progress.node_statuses = checkpoint.node_statuses.clone();
            progress.completed_exposures = checkpoint.completed_exposures;
            progress.completed_integration_secs = checkpoint.completed_integration_secs;
        }

        // Marking completed nodes on the freshly built tree is what makes
        // resume idempotent — the executor still walks the full tree but
        // short-circuits already-Success nodes.
        if let Some(ref mut root) = self.root_node {
            for node_id in checkpoint.get_completed_nodes() {
                root.mark_completed(&node_id);
            }
            // restore each Loop node's current_iteration so a resumed
            // Count loop continues from where it stopped.
            root.restore_loop_iterations(&checkpoint.loop_iterations);
        }

        if let Some(snapshot) = checkpoint.trigger_state.as_ref() {
            let trigger_state = {
                let manager = self.trigger_manager.read().await;
                manager.state()
            };
            let mut trigger_state = trigger_state.write().await;
            snapshot.restore_into(&mut trigger_state);
            self.safety_fail_mode = snapshot.safety_fail_mode;
            self.triggers_enabled = snapshot.triggers_enabled;
            self.filter_focus_offsets = snapshot.filter_focus_offsets.clone();
        }

        tracing::info!(
            "Prepared to resume sequence '{}' from checkpoint ({}  exposures, {:.1} min integration)",
            checkpoint.sequence.name,
            checkpoint.completed_exposures,
            checkpoint.completed_integration_secs / 60.0
        );

        Ok(())
    }
}
