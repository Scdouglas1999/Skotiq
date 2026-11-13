use crate::event::bus::{EventBus, EventPayload, SkotiqEvent};
use crate::event::equipment::{EventCategory, EventSeverity};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

/// Global sequence counter for events created outside of the EventBus.
/// This is used by `create_event_auto_id` for ad-hoc event creation.
static GLOBAL_EVENT_SEQUENCE: AtomicU64 = AtomicU64::new(1_000_000);

/// Create an event with the current timestamp and a specified event ID
pub fn create_event(
    event_id: u64,
    severity: EventSeverity,
    category: EventCategory,
    payload: EventPayload,
) -> SkotiqEvent {
    SkotiqEvent {
        event_id,
        timestamp: chrono::Utc::now().timestamp_millis(),
        severity,
        category,
        payload,
        caused_by: None,
        correlation_id: None,
        device_id: None,
    }
}

/// Create an event with an auto-generated event ID.
/// Useful for ad-hoc events created outside of the main EventBus.
/// Note: IDs start at 1,000,000 to avoid collisions with EventBus IDs which start at 1.
pub fn create_event_auto_id(
    severity: EventSeverity,
    category: EventCategory,
    payload: EventPayload,
) -> SkotiqEvent {
    let event_id = GLOBAL_EVENT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    create_event(event_id, severity, category, payload)
}

/// Thread-safe shared event bus
pub type SharedEventBus = Arc<EventBus>;
