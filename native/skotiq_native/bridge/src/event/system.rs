use super::*;

/// Safety-specific events
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SafetyEvent {
    WeatherUnsafe { reason: String },
    WeatherSafe,
    EmergencyStop { reason: String },
    ParkInitiated { reason: String },
    ParkCompleted,
}

/// System-level events
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SystemEvent {
    Initialized,
    ShuttingDown,
    Error {
        message: String,
    },
    DiskSpaceLow {
        available_gb: f64,
    },
    Notification {
        title: String,
        message: String,
        level: String,
        /// per-NotificationNode override list of
        /// NotificationTransportKind names (Dart enum, serialised as strings).
        /// The Dart NotificationRouter consumes this field to bypass the
        /// matrix's `custom` rule and dispatch to the user-picked transports
        /// directly. `None` or empty = use matrix routing.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        explicit_transports: Option<Vec<String>>,
    },
    /// Notification that events were dropped due to slow consumer
    /// This is sent after the stream recovers to inform the Dart side
    EventsDropped {
        /// Number of events that were dropped/skipped
        dropped_count: u64,
        /// Total number of events dropped since app start
        total_dropped: u64,
    },
}
