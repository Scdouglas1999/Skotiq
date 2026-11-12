//! Why the guider is stopped or held, whichever guider it is. The run states
//! its reason before it stops the guider, so a planned stop (autofocus, a
//! flip, a mount move) never reads as lost guiding.

use crate::state::get_state;
use crate::event::{EventSeverity, GuidingEvent};
use skotiq_sequencer::GuidingStopReason;

static REASON: std::sync::Mutex<Option<GuidingStopReason>> = std::sync::Mutex::new(None);

fn reason_slot() -> std::sync::MutexGuard<'static, Option<GuidingStopReason>> {
    REASON.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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

/// An operator's stop: recorded as such unless the run already said why it
/// is stopping the guider.
pub(crate) fn note_operator_stop() {
    let mut current = reason_slot();
    if current.is_none() {
        *current = Some(GuidingStopReason::Operator);
        drop(current);
        publish(Some(GuidingStopReason::Operator));
    }
}

/// The stop reason a status in `state` reports. A guider that is guiding
/// again (started outside the run, say) reports none, except while it
/// settles after a dither.
pub(crate) fn reported(state: &str) -> Option<String> {
    current()
        .filter(|reason| state != "Guiding" || *reason == GuidingStopReason::DitherSettle)
        .map(|reason| reason.as_wire().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The run states its reason before it stops the guider; a stop from
    /// the guider controls with no reason is the operator's; a start clears it.
    #[test]
    fn a_stop_reason_is_the_runs_unless_none_was_given() {
        let _slot = crate::guider::TEST_SLOT.blocking_lock();
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
        assert_eq!(reported("Stopped").as_deref(), Some("autofocus"));
        assert_eq!(
            reported("Guiding"),
            None,
            "a guider guiding again is not reported stopped"
        );
        set(Some(GuidingStopReason::DitherSettle));
        assert_eq!(reported("Guiding").as_deref(), Some("dither_settle"));
        set(None);
        assert_eq!(current(), None);
    }
}
