use super::*;

/// Event severity levels
#[frb]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventSeverity {
    Info,
    Warning,
    Error,
    Critical,
}

/// Categories of events
#[frb]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EventCategory {
    Equipment,
    Imaging,
    Guiding,
    Sequencer,
    Safety,
    System,
    PolarAlignment,
}

/// Heartbeat status for device health monitoring
#[frb]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HeartbeatStatus {
    /// Device is responding normally
    Healthy,
    /// Device has failed some health checks but not yet marked disconnected
    Degraded,
    /// Device is not responding and marked as disconnected
    Disconnected,
    /// Attempting to reconnect to the device
    Reconnecting,
    /// Successfully reconnected after failures
    Reconnected,
}

/// Equipment-specific events
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum EquipmentEvent {
    // Generic device events
    Connecting {
        device_type: String,
        device_id: String,
    },
    Connected {
        device_type: String,
        device_id: String,
    },
    Disconnected {
        device_type: String,
        device_id: String,
    },
    PropertyChanged {
        device_type: String,
        device_id: String,
        property: String,
        value: String,
    },
    Error {
        device_type: String,
        device_id: String,
        message: String,
    },

    // Mount events
    MountSlewStarted {
        ra: f64,
        dec: f64,
    },
    MountSlewCompleted {
        ra: f64,
        dec: f64,
    },
    MountTrackingStarted,
    MountTrackingStopped,
    MountParkStarted,
    MountParkCompleted,
    MountUnparked,

    // Focuser events
    FocuserMoveStarted {
        target_position: i32,
    },
    FocuserMoveCompleted {
        position: i32,
    },
    FocuserTemperatureChanged {
        temperature: f64,
    },

    // Filter wheel events
    FilterChanging {
        from_position: i32,
        to_position: i32,
        filter_name: Option<String>,
    },
    FilterChanged {
        position: i32,
        filter_name: Option<String>,
    },

    // Rotator events
    RotatorMoveStarted {
        target_angle: f64,
    },
    RotatorMoveCompleted {
        angle: f64,
    },

    // Camera events
    CameraCoolingStarted {
        target_temp: f64,
    },
    CameraCoolingReached {
        temperature: f64,
    },
    CameraWarmingStarted,
    CameraWarmingCompleted,

    // Heartbeat monitoring events
    HeartbeatStarted {
        device_type: String,
        device_id: String,
        interval_secs: u64,
    },
    HeartbeatStopped {
        device_type: String,
        device_id: String,
    },
    HeartbeatStatusChanged {
        device_type: String,
        device_id: String,
        status: HeartbeatStatus,
        consecutive_failures: u32,
        last_rtt_ms: Option<u64>,
    },
    HeartbeatReconnecting {
        device_type: String,
        device_id: String,
        attempt: u32,
        max_attempts: u32,
    },
    HeartbeatReconnected {
        device_type: String,
        device_id: String,
        after_attempts: u32,
    },

    // Hot-plug discovery events (wave-6b). Emitted by `crate::hotplug` when the
    // OS bus listener / slow-poll watcher diffs the live device list and detects
    // an arrival or removal. Dart filters these by `EventCategory::Equipment` +
    // the `DeviceDiscovered` / `DeviceLost` event-type strings to refresh the
    // equipment screen without a user-driven rescan.
    DeviceDiscovered {
        /// Canonical device class (`camera`, `mount`, `focuser`, `filterWheel`,
        /// `rotator`, …).
        device_class: String,
        /// Driver backend (`native`, `ascom`, `alpaca`, `indi`, `simulator`).
        driver: String,
        /// Backend-scoped device id used to connect.
        id: String,
        /// Raw device name as reported by the SDK / driver.
        name: String,
        /// User-facing display name (may equal `name`).
        display_name: String,
        /// Stable hardware identity (USB serial, etc.) when the backend exposes
        /// one; `None` otherwise.
        unique_id: Option<String>,
    },
    DeviceLost {
        device_class: String,
        driver: String,
        id: String,
    },
}
