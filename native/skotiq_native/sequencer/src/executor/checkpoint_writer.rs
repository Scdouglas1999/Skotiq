//! The one writer of a run's checkpoint file.
//!
//! The writer holds handles to everything a checkpoint records and composes
//! the whole document from them each time it saves, so no save has to read
//! the file back to keep a part somebody else wrote.

use super::{ExecutorState, RunCell, RunConfigStore, RunRig};
use crate::checkpoint::{CheckpointManager, RunEnd, SessionCheckpoint, TriggerStateSnapshot};
use crate::scheduling::integration_budget::BudgetRegistry;
use crate::triggers::TriggerManager;
use crate::{NodeId, NodeStatus, SequenceDefinition, SmartExposureCheckpoint};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Where a checkpoint's contents come from.
pub(crate) struct CheckpointSources {
    pub run_state: RunCell,
    pub sequence: SequenceDefinition,
    /// Tree-walk position of every node. Node ids are operator-chosen
    /// strings, so their own ordering says nothing about run order.
    pub execution_order: HashMap<NodeId, usize>,
    pub rig: RunRig,
    pub settings: RunConfigStore,
    pub trigger_manager: Arc<RwLock<TriggerManager>>,
    pub triggers_enabled: bool,
    pub budget_registry: BudgetRegistry,
    pub smart_exposure_states: Arc<RwLock<HashMap<NodeId, SmartExposureCheckpoint>>>,
    pub loop_passes_finished: Arc<parking_lot::RwLock<HashMap<NodeId, u32>>>,
}

pub(crate) struct CheckpointWriter {
    manager: Arc<CheckpointManager>,
    sources: CheckpointSources,
    /// The document as last written; what the end of the run amends.
    written: parking_lot::Mutex<Option<SessionCheckpoint>>,
}

impl CheckpointWriter {
    pub(crate) fn new(manager: Arc<CheckpointManager>, sources: CheckpointSources) -> Self {
        Self {
            manager,
            sources,
            written: parking_lot::Mutex::new(None),
        }
    }

    async fn compose(&self) -> SessionCheckpoint {
        let sources = &self.sources;
        let progress = sources.run_state.progress();
        let state = progress.state;

        let mut checkpoint = SessionCheckpoint::new(sources.sequence.clone());
        checkpoint.current_node = progress.current_node_id.clone();
        checkpoint.executor_state = state;
        checkpoint.completed_exposures = progress.completed_exposures;
        checkpoint.completed_integration_secs = progress.completed_integration_secs;
        // A run in recovery is still in flight: a crash there resumes too.
        checkpoint.is_active = matches!(
            state,
            ExecutorState::Running | ExecutorState::Paused | ExecutorState::Recovering
        );
        checkpoint.last_completed_node = progress
            .node_statuses
            .iter()
            .filter(|(_, status)| matches!(status, NodeStatus::Success))
            .filter_map(|(id, _)| sources.execution_order.get(id).map(|order| (id, *order)))
            .max_by_key(|(_, order)| *order)
            .map(|(id, _)| id.clone());
        checkpoint.node_statuses = progress.node_statuses;

        let rig = &sources.rig;
        checkpoint.set_devices(
            rig.camera_id.clone(),
            rig.mount_id.clone(),
            rig.focuser_id.clone(),
            rig.filterwheel_id.clone(),
            rig.rotator_id.clone(),
        );
        checkpoint.set_save_path(rig.save_path.clone());
        let config = sources.settings.snapshot();
        checkpoint.set_location(config.latitude, config.longitude);

        let trigger_state = sources.trigger_manager.read().await.state();
        checkpoint.set_trigger_state(TriggerStateSnapshot::from_state(
            &*trigger_state.read().await,
            config.safety_fail_mode,
            sources.triggers_enabled,
            config.filter_focus_offsets,
        ));

        checkpoint.loop_iterations = sources.loop_passes_finished.read().clone();
        checkpoint.budget_states = sources.budget_registry.snapshot().await;
        checkpoint.smart_exposure_states = sources.smart_exposure_states.read().await.clone();
        checkpoint
    }

    /// Write the run as it stands now.
    pub(crate) async fn save(&self) -> Result<(), String> {
        let checkpoint = self.compose().await;
        self.manager.save(&checkpoint)?;
        tracing::debug!(
            "Checkpoint saved ({} exposures, {:.1}s integration)",
            checkpoint.completed_exposures,
            checkpoint.completed_integration_secs
        );
        *self.written.lock() = Some(checkpoint);
        Ok(())
    }

    /// Record how a run that keeps its checkpoint ended, with the progress it
    /// reached. The checkpoint stays resumable, as it was last saved while
    /// the run was live.
    pub(crate) fn record_run_end(
        &self,
        end: RunEnd,
        completed_exposures: u32,
        completed_integration_secs: f64,
    ) -> Result<(), String> {
        self.amend(
            |checkpoint| {
                checkpoint.ended = Some(end);
                checkpoint.completed_exposures = completed_exposures;
                checkpoint.completed_integration_secs = completed_integration_secs;
                checkpoint.timestamp = chrono::Utc::now();
            },
            |manager| manager.record_run_end(end, completed_exposures, completed_integration_secs),
        )
    }

    /// The run finished: keep the file for the session report, no longer
    /// resumable.
    pub(crate) fn mark_completed(&self) -> Result<(), String> {
        self.amend(
            |checkpoint| {
                checkpoint.is_active = false;
                checkpoint.executor_state = ExecutorState::Completed;
            },
            CheckpointManager::mark_completed,
        )
    }

    /// The file was removed; there is nothing left to amend.
    pub(crate) fn forget(&self) {
        *self.written.lock() = None;
    }

    /// Change the document last written and write it again. A run that ended
    /// before its first save has written nothing; what is on disk then is an
    /// earlier run's file, which `on_disk` amends as it always has.
    fn amend(
        &self,
        edit: impl FnOnce(&mut SessionCheckpoint),
        on_disk: impl FnOnce(&CheckpointManager) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut written = self.written.lock();
        match written.as_mut() {
            Some(checkpoint) => {
                edit(checkpoint);
                self.manager.save(checkpoint)
            }
            None => on_disk(&self.manager),
        }
    }
}
