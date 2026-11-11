//! Stage 4 of a monitor tick: one handler per recovery action. Each takes the
//! handles it needs and reports how the dispatch ends as an [`ActionFlow`].

use super::*;

pub(super) mod autofocus;
pub(super) mod cloud;
pub(super) mod custom_branch;
pub(super) mod dither;
pub(super) mod meridian_flip;
pub(super) mod park;
pub(super) mod recenter;
pub(super) mod recovery;
pub(super) mod science;

/// How a dispatched action ended.
pub(super) enum ActionFlow {
    /// The action ran (or was turned away with the operator told); record the
    /// firing and go on.
    Finished,
    /// Nothing ran and nothing is recorded: the action was no longer due.
    NotRun,
    /// The run ends: record the firing as `recorded` and stop the monitor.
    Terminate {
        recorded: RecoveryAction,
        reason: &'static str,
    },
}

/// The rig an action drives and the shared state it reads and updates.
pub(super) struct Rig {
    pub device_ops: SharedDeviceOps,
    pub context: RunRig,
    pub trigger_state: Arc<RwLock<TriggerState>>,
    pub runtime_config: RunConfigStore,
}

impl Rig {
    /// An instruction context for a trigger-run instruction, aimed at
    /// `target`.
    pub(super) fn instruction_context(
        &self,
        target: TargetSnapshot,
        run: &RunControl,
    ) -> crate::instructions::InstructionContext {
        build_trigger_autofocus_context(
            &self.context,
            target.name,
            target.ra_hours,
            target.dec_degrees,
            target.filter,
            run.is_cancelled.clone(),
            self.device_ops.clone(),
            self.trigger_state.clone(),
            &self.runtime_config,
            Some(run.state.events().clone()),
        )
    }

    /// The current target and filter, as an instruction context wants them.
    pub(super) async fn target(&self) -> TargetSnapshot {
        let state = self.trigger_state.read().await;
        TargetSnapshot {
            name: state.target.current_target_name.clone(),
            // Trigger state keeps RA in degrees; instructions take hours.
            ra_hours: state.target.target_ra.map(|ra| ra / 15.0),
            dec_degrees: state.target.target_dec,
            filter: state.latches.current_filter.clone(),
        }
    }
}

/// The target an action aims at.
#[derive(Default)]
pub(super) struct TargetSnapshot {
    pub name: Option<String>,
    pub ra_hours: Option<f64>,
    pub dec_degrees: Option<f64>,
    pub filter: Option<String>,
}
