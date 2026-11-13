//! Control of the sequence run that callers inside the bridge share with the
//! app's FFI functions.

use crate::error::SkotiqError;
use crate::event::bus::EventPayload;
use crate::event::correlation::create_event_auto_id;
use crate::event::equipment::{EventCategory, EventSeverity};
use crate::event::sequencer::SequencerEvent;
use crate::state::get_state;

/// Resume a paused run and announce it.
///
/// A run held for a mount fault resumes only once the mount is recovered: its
/// first act would be a slew, and the mount is not where it says.
pub(crate) async fn resume() -> Result<(), SkotiqError> {
    if let Some(reason) = crate::device_manager::motion_guard::any_block_reason() {
        return Err(SkotiqError::OperationFailed(reason));
    }

    skotiq_sequencer::get_executor()
        .read()
        .await
        .resume()
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to resume sequence: {}", e)))?;

    get_state().publish_event(create_event_auto_id(
        EventSeverity::Info,
        EventCategory::Sequencer,
        EventPayload::Sequencer(SequencerEvent::Resumed),
    ));
    Ok(())
}
