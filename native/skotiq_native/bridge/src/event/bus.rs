use super::*;

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

/// Statistics about the event bus
#[derive(Debug, Clone, Default)]
pub struct EventBusStats {
    /// Total events published
    pub events_published: u64,
    /// Events dropped due to slow receivers
    pub events_dropped: u64,
    /// Current number of subscribers
    pub subscriber_count: usize,
    /// Events by category (for the last N events)
    pub events_by_category: HashMap<EventCategory, u64>,
}

/// Global event bus for publishing and subscribing to events
pub struct EventBus {
    /// Main event channel
    sender: broadcast::Sender<SkotiqEvent>,
    /// Sequence number generator
    sequence: AtomicU64,
    /// Events published counter
    events_published: AtomicU64,
    /// Events dropped counter
    events_dropped: AtomicU64,
    /// Total events published by category
    events_by_category: Mutex<HashMap<EventCategory, u64>>,
    /// Channel capacity
    capacity: usize,
}

impl EventBus {
    /// Create a new event bus with the specified channel capacity
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self {
            sender,
            sequence: AtomicU64::new(1),
            events_published: AtomicU64::new(0),
            events_dropped: AtomicU64::new(0),
            events_by_category: Mutex::new(HashMap::new()),
            capacity,
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
        let category = event.category;
        self.events_published.fetch_add(1, Ordering::Relaxed);
        {
            let mut counts = self
                .events_by_category
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *counts.entry(category).or_insert(0) += 1;
        }

        let would_evict_for_lagging_receiver =
            self.sender.receiver_count() > 0 && self.sender.len() >= self.capacity;

        match self.sender.send(event) {
            Ok(_) => {
                if would_evict_for_lagging_receiver {
                    self.events_dropped.fetch_add(1, Ordering::Relaxed);
                }
            }
            Err(_) => {
                // No receivers - this is fine
            }
        }

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

    /// Publish an event with correlation ID for grouping related events
    pub fn publish_correlated(
        &self,
        severity: EventSeverity,
        category: EventCategory,
        payload: EventPayload,
        correlation_id: &str,
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
            correlation_id: Some(correlation_id.to_string()),
            device_id: None,
        };

        self.publish(event)
    }

    /// Subscribe to receive events
    pub fn subscribe(&self) -> broadcast::Receiver<SkotiqEvent> {
        self.sender.subscribe()
    }

    /// Get the number of active subscribers
    pub fn subscriber_count(&self) -> usize {
        self.sender.receiver_count()
    }

    /// Get the current sequence number (useful for debugging)
    pub fn current_sequence(&self) -> u64 {
        self.sequence.load(Ordering::SeqCst)
    }

    /// Get statistics about the event bus
    pub fn stats(&self) -> EventBusStats {
        let events_by_category = self
            .events_by_category
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        EventBusStats {
            events_published: self.events_published.load(Ordering::Relaxed),
            events_dropped: self.events_dropped.load(Ordering::Relaxed),
            subscriber_count: self.sender.receiver_count(),
            events_by_category,
        }
    }

    /// Check if there's capacity for more events
    pub fn has_capacity(&self) -> bool {
        // Broadcast channels don't have a way to check capacity directly
        // We rely on the lagged error handling
        true
    }

    /// Get the configured capacity
    pub fn capacity(&self) -> usize {
        self.capacity
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new(DEFAULT_EVENT_BUFFER_SIZE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stats_track_events_by_category() {
        let bus = EventBus::new(8);

        bus.publish_with_tracking(
            EventSeverity::Info,
            EventCategory::Equipment,
            EventPayload::System(SystemEvent::Initialized),
            None,
        );
        bus.publish_with_tracking(
            EventSeverity::Info,
            EventCategory::Imaging,
            EventPayload::System(SystemEvent::Initialized),
            None,
        );

        let stats = bus.stats();
        assert_eq!(stats.events_published, 2);
        assert_eq!(stats.events_by_category[&EventCategory::Equipment], 1);
        assert_eq!(stats.events_by_category[&EventCategory::Imaging], 1);
    }

    #[test]
    fn stats_count_broadcast_evictions_for_lagging_receivers() {
        let bus = EventBus::new(1);
        let _receiver = bus.subscribe();

        for index in 0..2 {
            bus.publish_with_tracking(
                EventSeverity::Info,
                EventCategory::System,
                EventPayload::System(SystemEvent::Notification {
                    title: "test".to_string(),
                    message: format!("event {}", index),
                    level: "info".to_string(),
                    // added an opt-in transport override; this
                    // test exercises the broadcast-eviction path and doesn't
                    // care about routing, so opt out by passing None.
                    explicit_transports: None,
                }),
                None,
            );
        }

        assert_eq!(bus.stats().events_dropped, 1);
    }
}
