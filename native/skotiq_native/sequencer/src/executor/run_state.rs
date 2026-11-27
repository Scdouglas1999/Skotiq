//! The run's state cell: the executor state, the progress snapshot the status
//! API reads, and the event stream they are announced on.
//!
//! The state is stored once, inside the progress snapshot, and only this
//! module writes it or builds [`ExecutorEvent::StateChanged`]. Everything
//! else asks for a transition.

use super::{ExecutorEvent, ExecutorState, SequenceProgress};
use parking_lot::{Mutex, RwLock};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::broadcast;

#[derive(Clone)]
pub(crate) struct RunCell {
    inner: Arc<Inner>,
}

struct Inner {
    /// `progress.state` is the executor state.
    progress: RwLock<SequenceProgress>,
    events: broadcast::Sender<ExecutorEvent>,
    /// The operator's own Stop ended the run in flight. Read by the one rule
    /// on how a run ends ([`super::start::night_end::owes_end_steps`]).
    stopped_by_operator: AtomicBool,
    /// The manual action's hold on the run, while one holds it. See
    /// [`RunCell::take_action_hold`].
    action_hold: Mutex<Option<ActionHold>>,
}

struct ActionHold {
    holder: String,
    /// Why the run was paused again while the hold lasted: weather, a
    /// safety or device pause, a trigger, the operator. That pause outlives
    /// the hold.
    paused_over: Option<String>,
}

/// What a hold's release leaves behind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HoldReleased {
    /// Another pause took the run over while the hold lasted; the run stays
    /// paused under it.
    pub still_paused: Option<String>,
}

/// A manual action of another holder holds the run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldByAction;

/// A state that has been stored and not yet announced. Sites that publish
/// other events between the two (a terminal state is announced last) hold
/// this until the `StateChanged` is due.
#[must_use = "a stored state has to be announced"]
pub(crate) struct Unannounced {
    events: broadcast::Sender<ExecutorEvent>,
    state: ExecutorState,
}

impl Unannounced {
    pub(crate) fn announce(self) {
        let _ = self.events.send(ExecutorEvent::StateChanged(self.state));
    }
}

impl RunCell {
    pub(crate) fn new(events: broadcast::Sender<ExecutorEvent>) -> Self {
        Self {
            inner: Arc::new(Inner {
                progress: RwLock::new(SequenceProgress::default()),
                events,
                stopped_by_operator: AtomicBool::new(false),
                action_hold: Mutex::new(None),
            }),
        }
    }

    /// A cell already in `state`, for a task driven without an executor.
    #[cfg(test)]
    pub(crate) fn starting_in(
        events: broadcast::Sender<ExecutorEvent>,
        state: ExecutorState,
    ) -> Self {
        let cell = Self::new(events);
        cell.force(state);
        cell
    }

    /// Put the cell in `state` without announcing it.
    #[cfg(test)]
    pub(crate) fn force(&self, state: ExecutorState) {
        self.inner.progress.write().state = state;
    }

    pub(crate) fn get(&self) -> ExecutorState {
        self.inner.progress.read().state
    }

    /// Whether a run is under way or stopping: started and not yet at its
    /// end.
    pub(crate) fn run_in_flight(&self) -> bool {
        let state = self.get();
        state.is_under_way() || state == ExecutorState::Stopping
    }

    /// The progress snapshot, state included.
    pub(crate) fn progress(&self) -> SequenceProgress {
        self.inner.progress.read().clone()
    }

    pub(crate) fn read_progress<R>(&self, read: impl FnOnce(&SequenceProgress) -> R) -> R {
        read(&self.inner.progress.read())
    }

    /// Edit the progress snapshot. The state is not part of what an edit may
    /// change: whatever `edit` writes to `state` is discarded.
    pub(crate) fn update_progress<R>(&self, edit: impl FnOnce(&mut SequenceProgress) -> R) -> R {
        let mut progress = self.inner.progress.write();
        let state = progress.state;
        let result = edit(&mut progress);
        progress.state = state;
        result
    }

    pub(crate) fn set_message(&self, message: impl Into<String>) {
        self.inner.progress.write().message = Some(message.into());
    }

    /// Store `state` with the progress edits that belong to it, without
    /// announcing it yet.
    pub(crate) fn store(
        &self,
        state: ExecutorState,
        edit: impl FnOnce(&mut SequenceProgress),
    ) -> Unannounced {
        {
            let mut progress = self.inner.progress.write();
            edit(&mut progress);
            progress.state = state;
        }
        if !state.is_under_way() {
            self.end_action_hold();
        }
        Unannounced {
            events: self.inner.events.clone(),
            state,
        }
    }

    /// Turn the run `Paused`, with `reason` as its status message when
    /// given. A run that is already paused takes the new reason and returns
    /// nothing to announce: one pause is announced once, however many of the
    /// things that can hold a run ask for it.
    pub(crate) fn pause(&self, reason: Option<String>) -> Option<Unannounced> {
        let mut progress = self.inner.progress.write();
        if let Some(reason) = reason {
            progress.message = Some(reason);
        }
        if progress.state == ExecutorState::Paused {
            return None;
        }
        progress.state = ExecutorState::Paused;
        Some(Unannounced {
            events: self.inner.events.clone(),
            state: ExecutorState::Paused,
        })
    }

    pub(crate) fn transition(&self, state: ExecutorState) {
        self.store(state, |_| {}).announce();
    }

    pub(crate) fn transition_with_message(&self, state: ExecutorState, message: impl Into<String>) {
        let message = message.into();
        self.store(state, |progress| progress.message = Some(message))
            .announce();
    }

    /// Move `from` -> `to` with `message`, only if the state still is `from`
    /// and `allowed` holds, checked and stored under one lock. Returns
    /// whether it moved.
    pub(crate) fn transition_from(
        &self,
        from: ExecutorState,
        to: ExecutorState,
        message: &str,
        allowed: impl FnOnce() -> bool,
    ) -> bool {
        {
            let mut progress = self.inner.progress.write();
            if progress.state != from || !allowed() {
                return false;
            }
            progress.state = to;
            progress.message = Some(message.to_string());
        }
        if !to.is_under_way() {
            self.end_action_hold();
        }
        let _ = self.inner.events.send(ExecutorEvent::StateChanged(to));
        true
    }

    /// Turn a run that is under way `Stopping`, announced once however many
    /// stop requests arrive. A run already at its end keeps its state.
    pub(crate) fn begin_stopping(&self) {
        {
            let mut progress = self.inner.progress.write();
            if !progress.state.is_under_way() {
                return;
            }
            progress.state = ExecutorState::Stopping;
        }
        self.end_action_hold();
        let _ = self
            .inner
            .events
            .send(ExecutorEvent::StateChanged(ExecutorState::Stopping));
    }

    /// [`Self::begin_stopping`] for the operator's own Stop, which is
    /// remembered for the run's end: after it the rig is the operator's. A
    /// run that already ended, or is already stopping for another reason,
    /// keeps the end it had.
    pub(crate) fn begin_operator_stop(&self) {
        {
            let progress = self.inner.progress.read();
            if progress.state.is_under_way() {
                self.inner
                    .stopped_by_operator
                    .store(true, Ordering::Release);
            }
        }
        self.begin_stopping();
    }

    /// Whether the operator's own Stop ended this run.
    pub(crate) fn stopped_by_operator(&self) -> bool {
        self.inner.stopped_by_operator.load(Ordering::Acquire)
    }

    /// A new run starts with no stop recorded and no hold.
    pub(crate) fn clear_stop(&self) {
        self.inner
            .stopped_by_operator
            .store(false, Ordering::Release);
        self.end_action_hold();
    }

    /// Hold the run for a manual action of `holder`. While it lasts only the
    /// holder's release lets the run go on: a resume or skip from anywhere
    /// else is refused. Taking a hold the holder already has changes nothing;
    /// one another holder has is refused.
    pub(crate) fn take_action_hold(&self, holder: &str) -> Result<(), HeldByAction> {
        {
            let mut hold = self.inner.action_hold.lock();
            match hold.as_ref() {
                Some(current) if current.holder == holder => return Ok(()),
                Some(_) => return Err(HeldByAction),
                None => {
                    *hold = Some(ActionHold {
                        holder: holder.to_string(),
                        paused_over: None,
                    })
                }
            }
        }
        self.emit(ExecutorEvent::ActionHoldChanged { held: true });
        Ok(())
    }

    /// End `holder`'s hold. The run is left as it is: still paused until
    /// someone resumes it. None when `holder` did not hold it.
    pub(crate) fn release_action_hold(&self, holder: &str) -> Option<HoldReleased> {
        let released = {
            let mut hold = self.inner.action_hold.lock();
            if hold.as_ref().map(|h| h.holder.as_str()) != Some(holder) {
                return None;
            }
            hold.take()?
        };
        self.emit(ExecutorEvent::ActionHoldChanged { held: false });
        Some(HoldReleased {
            still_paused: released.paused_over,
        })
    }

    /// A pause other than the hold's own reached the run while a hold lasts:
    /// it outlives the hold, so the release does not resume the run.
    pub(crate) fn note_pause_over_hold(&self, origin: &str) {
        if let Some(hold) = self.inner.action_hold.lock().as_mut() {
            hold.paused_over = Some(origin.to_string());
        }
    }

    /// Whether a manual action holds the run.
    pub(crate) fn held_by_action(&self) -> bool {
        self.inner.action_hold.lock().is_some()
    }

    /// The run ended or is ending: nothing holds it any more.
    fn end_action_hold(&self) {
        if self.inner.action_hold.lock().take().is_some() {
            self.emit(ExecutorEvent::ActionHoldChanged { held: false });
        }
    }

    /// Back to `Idle` with an empty snapshot, unannounced: the executor is
    /// being recycled, not run.
    pub(crate) fn reset(&self) {
        *self.inner.progress.write() = SequenceProgress::default();
        self.clear_stop();
    }

    pub(crate) fn emit(&self, event: ExecutorEvent) {
        let _ = self.inner.events.send(event);
    }

    pub(crate) fn events(&self) -> &broadcast::Sender<ExecutorEvent> {
        &self.inner.events
    }

    pub(crate) fn subscribe(&self) -> broadcast::Receiver<ExecutorEvent> {
        self.inner.events.subscribe()
    }
}

/// What a run task may change about the run itself: its state, its pause and
/// its cancellation.
#[derive(Clone)]
pub(crate) struct RunControl {
    pub state: RunCell,
    pub is_cancelled: Arc<AtomicBool>,
    pub is_paused: Arc<AtomicBool>,
}

impl RunControl {
    /// Pause the run from inside it (a trigger, a recovery), with `reason`
    /// as the status banner when given.
    pub(crate) fn pause(&self, reason: Option<String>) {
        self.state
            .note_pause_over_hold(reason.as_deref().unwrap_or("a run trigger paused it"));
        self.pause_run(reason);
    }

    /// Pause the run on a command from outside it; `origin` names who asked.
    pub(crate) fn pause_from(&self, origin: Option<&str>) {
        self.state
            .note_pause_over_hold(origin.unwrap_or("it was paused again"));
        self.pause_run(None);
    }

    /// The pause a manual action's hold makes for itself.
    pub(crate) fn pause_for_action(&self) {
        self.pause_run(None);
    }

    fn pause_run(&self, reason: Option<String>) {
        self.is_paused.store(true, Ordering::Relaxed);
        if let Some(paused) = self.state.pause(reason) {
            paused.announce();
        }
    }

    /// Freeze the node tree without the rest of a pause.
    pub(crate) fn hold_node_tree(&self) {
        self.is_paused.store(true, Ordering::Relaxed);
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        self.is_cancelled.load(Ordering::Relaxed)
    }

    pub(crate) fn send(&self, event: ExecutorEvent) {
        self.state.emit(event);
    }

    pub(crate) fn error(&self, message: String) {
        self.send(ExecutorEvent::Error { message });
    }

    pub(crate) fn warning(&self, message: String) {
        self.send(ExecutorEvent::Warning { message });
    }

    /// A step had a problem and the run carries on.
    pub(crate) fn step_problem(&self, message: String) {
        self.send(ExecutorEvent::StepProblem { message });
    }

    /// Why the run is paused for the operator. The pause is a separate call.
    pub(crate) fn held(&self, message: String) {
        self.send(ExecutorEvent::RunHeld { message });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell() -> (RunCell, broadcast::Receiver<ExecutorEvent>) {
        let (tx, rx) = broadcast::channel(16);
        (RunCell::new(tx), rx)
    }

    #[test]
    fn a_transition_is_what_progress_reports_and_is_announced_once() {
        let (state, mut events) = cell();
        state.transition(ExecutorState::Stopping);

        assert_eq!(state.get(), ExecutorState::Stopping);
        assert_eq!(state.progress().state, ExecutorState::Stopping);
        assert!(matches!(
            events.try_recv(),
            Ok(ExecutorEvent::StateChanged(ExecutorState::Stopping))
        ));
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn a_progress_edit_cannot_change_the_state() {
        let (state, _events) = cell();
        state.transition(ExecutorState::Running);
        state.update_progress(|progress| {
            progress.state = ExecutorState::Failed;
            progress.completed_exposures = 3;
        });

        assert_eq!(state.get(), ExecutorState::Running);
        assert_eq!(state.progress().completed_exposures, 3);
    }

    #[test]
    fn a_stored_state_is_announced_when_the_caller_says() {
        let (state, mut events) = cell();
        let pending = state.store(ExecutorState::Failed, |progress| {
            progress.message = Some("why".into());
        });
        state.emit(ExecutorEvent::SequenceFailed {
            error: "why".into(),
        });
        pending.announce();

        assert_eq!(state.progress().message.as_deref(), Some("why"));
        assert!(matches!(
            events.try_recv(),
            Ok(ExecutorEvent::SequenceFailed { .. })
        ));
        assert!(matches!(
            events.try_recv(),
            Ok(ExecutorEvent::StateChanged(ExecutorState::Failed))
        ));
    }

    fn control(state: RunCell) -> RunControl {
        RunControl {
            state,
            is_cancelled: Arc::new(AtomicBool::new(false)),
            is_paused: Arc::new(AtomicBool::new(false)),
        }
    }

    fn state_changes(events: &mut broadcast::Receiver<ExecutorEvent>) -> Vec<ExecutorState> {
        let mut out = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let ExecutorEvent::StateChanged(state) = event {
                out.push(state);
            }
        }
        out
    }

    /// A runaway that ends in a lost position holds the run twice, and a
    /// trigger can pause a run the operator already paused.
    #[test]
    fn pausing_a_paused_run_takes_the_new_reason_and_announces_nothing() {
        let (state, mut events) = cell();
        state.transition(ExecutorState::Running);
        let run = control(state.clone());

        run.pause(Some("Paused: the mount moved on its own".into()));
        run.pause(None);
        run.pause(Some("Paused: the mount lost its position".into()));

        assert_eq!(
            state_changes(&mut events),
            vec![ExecutorState::Running, ExecutorState::Paused]
        );
        assert_eq!(state.get(), ExecutorState::Paused);
        assert!(run.is_paused.load(Ordering::Relaxed));
        assert_eq!(
            state.progress().message.as_deref(),
            Some("Paused: the mount lost its position")
        );
    }

    #[test]
    fn a_pause_after_a_resume_is_announced_again() {
        let (state, mut events) = cell();
        let run = control(state.clone());
        run.pause(None);
        state.transition(ExecutorState::Running);
        run.pause(None);

        assert_eq!(
            state_changes(&mut events),
            vec![
                ExecutorState::Paused,
                ExecutorState::Running,
                ExecutorState::Paused
            ]
        );
    }

    fn hold_changes(events: &mut broadcast::Receiver<ExecutorEvent>) -> Vec<bool> {
        let mut out = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let ExecutorEvent::ActionHoldChanged { held } = event {
                out.push(held);
            }
        }
        out
    }

    #[test]
    fn a_hold_is_the_holders_until_it_releases_it() {
        let (state, mut events) = cell();
        state.transition(ExecutorState::Paused);

        assert_eq!(state.take_action_hold("phone"), Ok(()));
        assert_eq!(state.take_action_hold("phone"), Ok(()));
        assert_eq!(state.take_action_hold("host"), Err(HeldByAction));
        assert!(state.held_by_action());
        assert!(state.release_action_hold("host").is_none());
        assert!(state.held_by_action());
        assert!(state.release_action_hold("phone").is_some());

        assert!(!state.held_by_action());
        assert_eq!(hold_changes(&mut events), vec![true, false]);
    }

    #[test]
    fn a_hold_ends_with_the_run() {
        for end in [
            ExecutorState::Stopping,
            ExecutorState::Completed,
            ExecutorState::Failed,
            ExecutorState::Cancelled,
            ExecutorState::Idle,
        ] {
            let (state, mut events) = cell();
            state.transition(ExecutorState::Paused);
            state.take_action_hold("host").unwrap();
            state.transition(end);
            assert!(!state.held_by_action(), "{end:?}");
            assert_eq!(hold_changes(&mut events), vec![true, false], "{end:?}");
        }

        let (state, _events) = cell();
        state.transition(ExecutorState::Paused);
        state.take_action_hold("host").unwrap();
        state.begin_operator_stop();
        assert!(!state.held_by_action());

        let (state, _events) = cell();
        state.transition(ExecutorState::Paused);
        state.take_action_hold("host").unwrap();
        state.reset();
        assert!(!state.held_by_action());
    }

    #[test]
    fn a_hold_lasts_through_the_pause_it_makes_and_a_recovery() {
        let (state, _events) = cell();
        state.transition(ExecutorState::Running);
        state.take_action_hold("host").unwrap();
        let run = control(state.clone());
        run.pause_for_action();
        state.transition(ExecutorState::Recovering);
        state.transition(ExecutorState::Paused);
        assert!(state.held_by_action());
    }

    #[test]
    fn a_conditional_transition_only_moves_from_the_named_state() {
        let (state, mut events) = cell();
        state.transition(ExecutorState::Paused);
        let _ = events.try_recv();

        assert!(!state.transition_from(
            ExecutorState::Recovering,
            ExecutorState::Running,
            "resumed",
            || true
        ));
        assert_eq!(state.get(), ExecutorState::Paused);
        assert!(events.try_recv().is_err());
    }
}
