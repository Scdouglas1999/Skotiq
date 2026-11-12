//! The run's state cell: the executor state, the progress snapshot the status
//! API reads, and the event stream they are announced on.
//!
//! The state is stored once, inside the progress snapshot, and only this
//! module writes it or builds [`ExecutorEvent::StateChanged`]. Everything
//! else asks for a transition.

use super::{ExecutorEvent, ExecutorState, SequenceProgress};
use parking_lot::RwLock;
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
}

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
        Unannounced {
            events: self.inner.events.clone(),
            state,
        }
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
        let _ = self.inner.events.send(ExecutorEvent::StateChanged(to));
        true
    }

    /// Turn a run that is under way `Stopping`, announced once however many
    /// stop requests arrive. A run already at its end keeps its state.
    pub(crate) fn begin_stopping(&self) {
        {
            let mut progress = self.inner.progress.write();
            if !matches!(
                progress.state,
                ExecutorState::Running | ExecutorState::Paused | ExecutorState::Recovering
            ) {
                return;
            }
            progress.state = ExecutorState::Stopping;
        }
        let _ = self
            .inner
            .events
            .send(ExecutorEvent::StateChanged(ExecutorState::Stopping));
    }

    /// Back to `Idle` with an empty snapshot, unannounced: the executor is
    /// being recycled, not run.
    pub(crate) fn reset(&self) {
        *self.inner.progress.write() = SequenceProgress::default();
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
    /// Pause the run for the operator, with `reason` as the status banner
    /// when given.
    pub(crate) fn pause(&self, reason: Option<String>) {
        self.is_paused.store(true, Ordering::Relaxed);
        self.state
            .store(ExecutorState::Paused, |progress| {
                if let Some(reason) = reason {
                    progress.message = Some(reason);
                }
            })
            .announce();
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
