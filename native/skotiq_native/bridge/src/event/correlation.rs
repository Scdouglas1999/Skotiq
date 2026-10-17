use super::*;

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

/// Create an event with causality tracking
pub fn create_event_with_cause(
    event_id: u64,
    severity: EventSeverity,
    category: EventCategory,
    payload: EventPayload,
    caused_by: u64,
) -> SkotiqEvent {
    SkotiqEvent {
        event_id,
        timestamp: chrono::Utc::now().timestamp_millis(),
        severity,
        category,
        payload,
        caused_by: Some(caused_by),
        correlation_id: None,
        device_id: None,
    }
}

/// Thread-safe shared event bus
pub type SharedEventBus = Arc<EventBus>;

// Event context for tracking causality

/// Context for tracking event causality
///
/// Pass this through operations to automatically track which events
/// caused other events.
#[derive(Debug, Clone)]
pub struct EventContext {
    /// The event ID that started this chain
    pub root_event_id: u64,
    /// The immediate parent event ID
    pub parent_event_id: u64,
    /// Correlation ID for grouping
    pub correlation_id: Option<String>,
    /// Device ID if this context is device-specific
    pub device_id: Option<String>,
}

impl EventContext {
    /// Create a new root event context
    pub fn new(event_id: u64) -> Self {
        Self {
            root_event_id: event_id,
            parent_event_id: event_id,
            correlation_id: None,
            device_id: None,
        }
    }

    /// Create a child context from this context
    pub fn child(&self, event_id: u64) -> Self {
        Self {
            root_event_id: self.root_event_id,
            parent_event_id: event_id,
            correlation_id: self.correlation_id.clone(),
            device_id: self.device_id.clone(),
        }
    }

    /// Set the correlation ID
    pub fn with_correlation(mut self, correlation_id: &str) -> Self {
        self.correlation_id = Some(correlation_id.to_string());
        self
    }

    /// Set the device ID
    pub fn with_device(mut self, device_id: &str) -> Self {
        self.device_id = Some(device_id.to_string());
        self
    }
}

// Correlation ID generator

/// Generate a unique correlation ID
///
/// # `unwrap_or` policy
///
/// `duration_since(UNIX_EPOCH).unwrap_or_default()` — only fails if the
/// system clock is set before 1970-01-01. A zero `Duration` then produces
/// the same correlation-ID format `corr-0-<seq>`; the suffix is still
/// derived from `timestamp.wrapping_mul`, so collisions are unlikely
/// over a short pre-1970-clock interval. The ID is for log correlation
/// only — uniqueness is best-effort, not load-bearing for correctness.
pub fn generate_correlation_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros();

    // Simple format: timestamp-random (no external deps)
    let random = timestamp.wrapping_mul(6364136223846793005) % 100000;
    format!("corr-{}-{:05}", timestamp, random)
}
