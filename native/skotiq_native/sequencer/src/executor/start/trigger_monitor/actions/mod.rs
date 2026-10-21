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

/// What an action may change about the run itself: its pause, its
/// cancellation and its event stream.
pub(super) struct RunControl {
    pub events: broadcast::Sender<ExecutorEvent>,
    pub is_cancelled: Arc<AtomicBool>,
    pub is_paused: Arc<AtomicBool>,
    pub executor_state: Arc<RwLock<ExecutorState>>,
    pub progress: Arc<StdRwLock<SequenceProgress>>,
}

impl RunControl {
    /// Pause the run for the operator. The status API reads the progress
    /// snapshot rather than the executor state, so both are stamped, with
    /// `reason` as the banner when given.
    pub(super) async fn pause(&self, reason: Option<String>) {
        self.is_paused.store(true, Ordering::Relaxed);
        *self.executor_state.write().await = ExecutorState::Paused;
        {
            let mut progress = self.progress.write();
            progress.state = ExecutorState::Paused;
            if let Some(reason) = reason {
                progress.message = Some(reason);
            }
        }
        let _ = self
            .events
            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
    }

    /// Freeze the node tree without the rest of a pause.
    pub(super) fn hold_node_tree(&self) {
        self.is_paused.store(true, Ordering::Relaxed);
    }

    pub(super) fn is_cancelled(&self) -> bool {
        self.is_cancelled.load(Ordering::Relaxed)
    }

    pub(super) fn send(&self, event: ExecutorEvent) {
        let _ = self.events.send(event);
    }

    pub(super) fn error(&self, message: String) {
        self.send(ExecutorEvent::Error { message });
    }

    pub(super) fn warning(&self, message: String) {
        self.send(ExecutorEvent::Warning { message });
    }
}

/// The run's decision log; every row is stamped with the run id.
pub(super) struct DecisionLog {
    pub tx: crate::decision::DecisionSender,
    pub run_id: Arc<StdRwLock<Option<i64>>>,
}

impl DecisionLog {
    pub(super) fn send(&self, mut decision: crate::decision::DecisionEvent) {
        decision.sequence_run_id = *self.run_id.read();
        let _ = self.tx.send(decision);
    }
}

/// The rig an action drives and the shared state it reads and updates.
pub(super) struct Rig {
    pub device_ops: SharedDeviceOps,
    pub context: TriggerActionContext,
    pub trigger_state: Arc<RwLock<TriggerState>>,
    pub runtime_config: Arc<StdRwLock<RuntimeConfig>>,
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
            Some(run.events.clone()),
        )
    }

    /// The current target and filter, as an instruction context wants them.
    pub(super) async fn target(&self) -> TargetSnapshot {
        let state = self.trigger_state.read().await;
        TargetSnapshot {
            name: state.current_target_name.clone(),
            // Trigger state keeps RA in degrees; instructions take hours.
            ra_hours: state.target_ra.map(|ra| ra / 15.0),
            dec_degrees: state.target_dec,
            filter: state.current_filter.clone(),
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

/// The handshake with the run supervisor for an action that ends the run by
/// parking.
pub(super) struct ParkSignals {
    /// Set before the node tree is cancelled, so the supervisor reports the
    /// run as parked and aborted.
    pub park_and_abort: Arc<AtomicBool>,
    pub done: watch::Sender<bool>,
    pub execution_quiesced: watch::Receiver<bool>,
}

impl ParkSignals {
    /// Cancel the node tree and wait until its exposure has been aborted, so
    /// nothing moves or closes under a live integration.
    pub(super) async fn stop_node_tree(&mut self, is_cancelled: &Arc<AtomicBool>) {
        cancel_and_wait_for_execution(is_cancelled, &mut self.execution_quiesced).await;
    }

    pub(super) fn parking_begins(&self) {
        self.park_and_abort.store(true, Ordering::Release);
    }

    pub(super) fn parked(&self) {
        let _ = self.done.send(true);
    }
}
