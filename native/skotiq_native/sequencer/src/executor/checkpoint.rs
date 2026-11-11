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
//!   * [`SequenceExecutor::save_checkpoint`] — write the executor as it
//!     stands, through the run's one checkpoint writer.
//!   * [`SequenceExecutor::clear_checkpoint`] — remove the file.
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

use super::{CheckpointSources, CheckpointWriter, RunRig, SequenceExecutor};
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
    pub async fn load_checkpoint(
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

            self.set_location(cp.latitude, cp.longitude).await;

            self.save_path = cp.save_path.clone();

            tracing::info!("Loaded checkpoint for sequence: {}", cp.sequence.name);
        }

        Ok(checkpoint)
    }

    /// Write a checkpoint of the executor as it stands now.
    ///
    /// With a run in flight (or just ended) this is the run's own writer,
    /// the one the 30 s stream uses. Before any run it records the loaded
    /// sequence, with the node states of the checkpoint a resume was
    /// prepared from, if there is one.
    pub async fn save_checkpoint(&self) -> Result<(), String> {
        let manager = self
            .checkpoint_manager
            .as_ref()
            .ok_or("No checkpoint manager configured")?;
        let sequence = self.sequence.as_ref().ok_or("No sequence loaded")?;

        if let Some(writer) = self.run.as_ref().and_then(|run| run.checkpoint.as_ref()) {
            return writer.save().await;
        }

        let budget_registry = crate::scheduling::integration_budget::BudgetRegistry::new();
        let mut smart_exposure_states = std::collections::HashMap::new();
        let mut frames_taken = std::collections::HashMap::new();
        if let Some(prepared) = &self.current_checkpoint {
            frames_taken = prepared.exposure_frames_taken.clone();
            budget_registry
                .restore_snapshot(prepared.budget_states.clone())
                .await;
            smart_exposure_states = prepared.smart_exposure_states.clone();
        }
        let resume = match &self.root_node {
            Some(root) => {
                let mut passes = std::collections::HashMap::new();
                root.snapshot_loop_iterations(&mut passes);
                crate::node::resume::ResumeRecord::new(root.as_ref(), passes, frames_taken)
            }
            None => crate::node::resume::ResumeRecord::default(),
        };
        CheckpointWriter::new(
            manager.clone(),
            CheckpointSources {
                run_state: self.run_state.clone(),
                execution_order: self.build_execution_order(sequence),
                sequence: sequence.clone(),
                rig: RunRig {
                    camera_id: self.camera_id.clone(),
                    mount_id: self.mount_id.clone(),
                    focuser_id: self.focuser_id.clone(),
                    filterwheel_id: self.filterwheel_id.clone(),
                    rotator_id: self.rotator_id.clone(),
                    save_path: self.save_path.clone(),
                    ..RunRig::default()
                },
                settings: self.settings.clone(),
                trigger_manager: self.trigger_manager.clone(),
                triggers_enabled: self.triggers_enabled,
                budget_registry,
                smart_exposure_states: Arc::new(tokio::sync::RwLock::new(smart_exposure_states)),
                resume,
            },
        )
        .save()
        .await
    }

    /// Remove the on-disk checkpoint. No-op when no checkpoint manager is
    /// configured.
    pub fn clear_checkpoint(&self) -> Result<(), String> {
        if let Some(ref manager) = self.checkpoint_manager {
            manager.clear()?;
        }
        if let Some(writer) = self.run.as_ref().and_then(|run| run.checkpoint.as_ref()) {
            writer.forget();
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
            .load_checkpoint()
            .await?
            .ok_or("No checkpoint to resume from")?;

        if !checkpoint.can_resume() {
            return Err("Checkpoint cannot be resumed".to_string());
        }

        self.load_sequence(checkpoint.sequence.clone())?;
        self.current_checkpoint = Some(checkpoint.clone());
        self.resume_prepared = true;

        self.run_state.update_progress(|progress| {
            progress.node_statuses = checkpoint.node_statuses.clone();
            progress.completed_exposures = checkpoint.completed_exposures;
            progress.completed_integration_secs = checkpoint.completed_integration_secs;
        });

        // Marking completed nodes on the freshly built tree is what makes
        // resume idempotent — the executor still walks the full tree but
        // short-circuits already-Success nodes.
        if let Some(ref mut root) = self.root_node {
            let imaging = crate::node::resume::imaging_steps(root.as_ref());
            for node_id in checkpoint.get_completed_nodes() {
                if imaging.contains(&node_id) {
                    root.mark_completed(&node_id);
                }
            }
            let passes = checkpoint
                .loop_iterations
                .iter()
                .filter(|(id, _)| imaging.contains(*id))
                .map(|(id, passes)| (id.clone(), *passes))
                .collect();
            root.restore_loop_iterations(&passes);
        }

        if let Some(snapshot) = checkpoint.trigger_state.as_ref() {
            // The interrupted run's settings first, then its trigger state on
            // top, so the trigger state ends as the checkpoint had it.
            self.update_config(|config| {
                config.safety_fail_mode = snapshot.safety_fail_mode;
                config.filter_focus_offsets = snapshot.filter_focus_offsets.clone();
            })
            .await;
            self.triggers_enabled = snapshot.triggers_enabled;
            let trigger_state = {
                let manager = self.trigger_manager.read().await;
                manager.state()
            };
            snapshot.restore_into(&mut *trigger_state.write().await);
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
