use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

/// Safety-specific events
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SafetyEvent {
    WeatherUnsafe {
        reason: String,
    },
    WeatherSafe,
    EmergencyStop {
        reason: String,
    },
    ParkInitiated {
        reason: String,
    },
    ParkCompleted,
    /// A mount moved with no command from Skotiq to explain it: an axis
    /// running far faster than tracking and guiding, `Slewing` with no slew,
    /// or a dive below the horizon. `kind` is `runaway`, `slewing` or
    /// `below_horizon`; `message` says what the mount reported.
    MountMotionFault {
        device_id: String,
        kind: String,
        message: String,
    },
    /// Skotiq no longer trusts the mount's reported position (it reported
    /// home without a home command, went silent and came back at home, or a
    /// plate solve disagreed with it). Automatic moves are refused until the
    /// operator recovers the position.
    MountPositionUnknown {
        device_id: String,
        reason: String,
        message: String,
    },
    /// A motion fault was acknowledged or the mount's position was recovered.
    MountGuardCleared {
        device_id: String,
        message: String,
    },
}

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
