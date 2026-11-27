//! Why the guider is stopped or held, whichever guider it is. The run states
//! its reason before it stops the guider, so a planned stop (autofocus, a
//! flip, a mount move) never reads as lost guiding.

use crate::event::equipment::EventSeverity;
use crate::event::guiding::GuidingEvent;
use crate::state::get_state;
use skotiq_sequencer::GuidingStopReason;

static REASON: std::sync::Mutex<Option<GuidingStopReason>> = std::sync::Mutex::new(None);

fn reason_slot() -> std::sync::MutexGuard<'static, Option<GuidingStopReason>> {
    REASON
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn publish(reason: Option<GuidingStopReason>) {
    get_state().publish_guiding_event(
        GuidingEvent::StopReason {
            reason: reason.map(|reason| reason.as_wire().to_string()),
        },
        EventSeverity::Info,
    );
}

/// The recorded reason the guider is stopped, if any.
pub(crate) fn current() -> Option<GuidingStopReason> {
    *reason_slot()
}

/// Record why the guider is stopped (`None` once it guides again) and tell
/// the UI when that changes.
pub(crate) fn set(reason: Option<GuidingStopReason>) {
    let previous = std::mem::replace(&mut *reason_slot(), reason);
    if previous != reason {
        if let Some(reason) = reason {
            tracing::info!("[GUIDING] {}", reason.describe());
        }
        publish(reason);
    }
}

/// Withdraw `reason` if it is still the one recorded; a reason given since
/// (a stop someone asked for during a dither's settle) stays.
pub(crate) fn withdraw(reason: GuidingStopReason) {
    let mut current = reason_slot();
    if *current != Some(reason) {
        return;
    }
    *current = None;
    drop(current);
    publish(None);
}

/// The run ended: a hold it gave as the reason is over; a reason that says
/// why guiding stopped stays.
pub(crate) fn run_ended() {
    if current().is_some_and(GuidingStopReason::is_hold) {
        set(None);
    }
}

/// An operator's stop: recorded as such unless the run already said why it
/// is stopping the guider. A dither settling does not stop it, so it gives
/// way. Returns whether it recorded it.
pub(crate) fn note_operator_stop() -> bool {
    let mut current = reason_slot();
    if current.is_some_and(GuidingStopReason::stops_guiding) {
        return false;
    }
    *current = Some(GuidingStopReason::Operator);
    drop(current);
    publish(Some(GuidingStopReason::Operator));
    true
}

/// The stop reason a status in `state` reports. A guider that is guiding
/// again (started outside the run, say) reports none, except while it
/// settles after a dither.
pub(crate) fn reported(state: &super::GuiderActivity) -> Option<String> {
    current()
        .filter(|reason| {
            *state != super::GuiderActivity::Guiding || *reason == GuidingStopReason::DitherSettle
        })
        .map(|reason| reason.as_wire().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The run states its reason before it stops the guider; a stop from
    /// the guider controls with no reason is the operator's; a start clears it.
    #[test]
    fn a_stop_reason_is_the_runs_unless_none_was_given() {
        let _slot = crate::simulator::sim_singleton_test_lock().blocking_lock();
        set(None);
        note_operator_stop();
        assert_eq!(current(), Some(GuidingStopReason::Operator));

        set(Some(GuidingStopReason::Autofocus));
        note_operator_stop();
        assert_eq!(
            current(),
            Some(GuidingStopReason::Autofocus),
            "an autofocus stop is never relabelled as the operator's"
        );
        assert_eq!(
            reported(&super::super::GuiderActivity::Stopped).as_deref(),
            Some("autofocus")
        );
        assert_eq!(
            reported(&super::super::GuiderActivity::Guiding),
            None,
            "a guider guiding again is not reported stopped"
        );
        set(Some(GuidingStopReason::DitherSettle));
        assert_eq!(
            reported(&super::super::GuiderActivity::Guiding).as_deref(),
            Some("dither_settle")
        );
        set(None);
        assert_eq!(current(), None);
    }

    /// A dither withdraws only its own settle: a stop given while it
    /// settled (a center's move, the operator's) keeps its reason, and an
    /// operator's stop replaces the settle, which does not stop guiding.
    #[test]
    fn a_dither_withdraws_only_its_own_settle() {
        let _slot = crate::simulator::sim_singleton_test_lock().blocking_lock();
        set(Some(GuidingStopReason::DitherSettle));
        set(Some(GuidingStopReason::MountMove));
        withdraw(GuidingStopReason::DitherSettle);
        assert_eq!(current(), Some(GuidingStopReason::MountMove));

        set(Some(GuidingStopReason::DitherSettle));
        assert!(note_operator_stop(), "the operator's stop is recorded");
        withdraw(GuidingStopReason::DitherSettle);
        assert_eq!(current(), Some(GuidingStopReason::Operator));

        set(Some(GuidingStopReason::DitherSettle));
        withdraw(GuidingStopReason::DitherSettle);
        assert_eq!(current(), None);
    }

    /// A run's end withdraws the hold it left ("paused while the mount
    /// moves") and keeps a reason that says why guiding stopped.
    #[test]
    fn a_run_end_withdraws_holds_only() {
        let _slot = crate::simulator::sim_singleton_test_lock().blocking_lock();
        for reason in GuidingStopReason::ALL {
            set(Some(reason));
            run_ended();
            let expected = (!reason.is_hold()).then_some(reason);
            assert_eq!(current(), expected, "{reason:?}");
        }
        set(None);
    }
}
