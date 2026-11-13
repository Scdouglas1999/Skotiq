use crate::event::depthlock_events::DepthLockEvent;
use crate::event::equipment::{EquipmentEvent, EventCategory, EventSeverity};
use crate::event::guiding::GuidingEvent;
use crate::event::imaging::{
    ImagingEvent, PolarAlignmentEvent, PolarAlignmentImageEvent, PolarAlignmentStatus,
};
use crate::event::sequencer::SequencerEvent;
use crate::event::system::{SafetyEvent, SystemEvent};
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::broadcast;

/// Default event buffer size: 4096 broadcast slots, enough for the burstiest
/// producers (autofocus loops, 10 Hz guiding corrections). A receiver that falls
/// further behind than this gets `Lagged` and skips to the latest events.
pub const DEFAULT_EVENT_BUFFER_SIZE: usize = 4096;

/// A unified event that can be any category
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkotiqEvent {
    /// Unique event ID (monotonically increasing sequence number)
    pub event_id: u64,
    /// Timestamp when the event was created (milliseconds since Unix epoch)
    pub timestamp: i64,
    /// Severity level of the event
    pub severity: EventSeverity,
    /// Category of the event
    pub category: EventCategory,
    /// The actual event data
    pub payload: EventPayload,
    /// Event ID that caused this event (for causality tracking)
    /// None if this is a root event (no causal parent)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caused_by: Option<u64>,
    /// Correlation ID for grouping related events (e.g., all events from one exposure)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub correlation_id: Option<String>,
    /// Device ID if this event is device-related
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
}

/// Event payload - one of the specific event types
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum EventPayload {
    Equipment(EquipmentEvent),
    Imaging(ImagingEvent),
    Guiding(GuidingEvent),
    Sequencer(SequencerEvent),
    Safety(SafetyEvent),
    System(SystemEvent),
    PolarAlignment(PolarAlignmentEvent),
    PolarAlignmentStatus(PolarAlignmentStatus),
    PolarAlignmentImage(PolarAlignmentImageEvent),
    DepthLock(DepthLockEvent),
}

/// Global event bus for publishing and subscribing to events
pub struct EventBus {
    sender: broadcast::Sender<SkotiqEvent>,
    sequence: AtomicU64,
}

impl EventBus {
    /// Create a new event bus with the specified channel capacity
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self {
            sender,
            sequence: AtomicU64::new(1),
        }
    }

    /// Get the next sequence number
    fn next_sequence(&self) -> u64 {
        self.sequence.fetch_add(1, Ordering::SeqCst)
    }

    /// Publish an event to all subscribers
    /// Returns the event ID assigned to the published event
    pub fn publish(&self, event: SkotiqEvent) -> u64 {
        let event_id = event.event_id;
        // An error only means nobody is subscribed yet.
        let _ = self.sender.send(event);
        event_id
    }

    /// Publish an event, threading `caused_by` for causality tracking, and return
    /// the id it was published under.
    pub fn publish_with_tracking(
        &self,
        severity: EventSeverity,
        category: EventCategory,
        payload: EventPayload,
        caused_by: Option<u64>,
    ) -> u64 {
        let event_id = self.next_sequence();
        let event = SkotiqEvent {
            event_id,
            timestamp: chrono::Utc::now().timestamp_millis(),
            severity,
            category,
            payload,
            caused_by,
            correlation_id: None,
            device_id: None,
        };

        self.publish(event)
    }

    /// Publish an event with device context
    pub fn publish_device_event(
        &self,
        severity: EventSeverity,
        category: EventCategory,
        payload: EventPayload,
        device_id: &str,
        caused_by: Option<u64>,
    ) -> u64 {
        let event_id = self.next_sequence();
        let event = SkotiqEvent {
            event_id,
            timestamp: chrono::Utc::now().timestamp_millis(),
            severity,
            category,
            payload,
            caused_by,
            correlation_id: None,
            device_id: Some(device_id.to_string()),
        };

        self.publish(event)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SkotiqEvent> {
        self.sender.subscribe()
    }

    /// Get the number of active subscribers
    pub fn subscriber_count(&self) -> usize {
        self.sender.receiver_count()
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new(DEFAULT_EVENT_BUFFER_SIZE)
    }
}
