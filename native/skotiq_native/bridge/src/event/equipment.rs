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

#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum EquipmentEvent {
    // Generic device events
    /// `device_name` is the name the device is shown by, so a linked client
    /// that never ran discovery labels it the way the host does.
    Connecting {
        device_type: String,
        device_id: String,
        device_name: String,
    },
    Connected {
        device_type: String,
        device_id: String,
        device_name: String,
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

    // Mount events. Every device event names its device, so a second mount,
    // focuser, wheel or rotator is never taken for the one in the app's slot.
    MountSlewStarted {
        device_id: String,
        ra: f64,
        dec: f64,
    },
    MountSlewCompleted {
        device_id: String,
        ra: f64,
        dec: f64,
    },
    MountTrackingStarted {
        device_id: String,
    },
    MountTrackingStopped {
        device_id: String,
    },
    MountParkStarted {
        device_id: String,
    },
    MountParkCompleted {
        device_id: String,
    },
    MountUnparked {
        device_id: String,
    },

    // Focuser events
    FocuserMoveStarted {
        device_id: String,
        target_position: i32,
    },
    FocuserMoveCompleted {
        device_id: String,
        position: i32,
    },

    // Filter wheel events
    /// Positions are the wheel's 0-based slots; the names are the profile's
    /// names for the slots moved from and to, when it has them.
    FilterChanging {
        device_id: String,
        from_position: i32,
        to_position: i32,
        filter_name: Option<String>,
        from_filter_name: Option<String>,
    },
    FilterChanged {
        device_id: String,
        position: i32,
        filter_name: Option<String>,
    },

    // Rotator events
    RotatorMoveStarted {
        device_id: String,
        target_angle: f64,
    },
    RotatorMoveCompleted {
        device_id: String,
        angle: f64,
    },

    // Camera events. The cooler events name the camera, so a cooled guide
    // camera is never taken for the imaging camera.
    CameraCoolingStarted {
        device_id: String,
        target_temp: f64,
    },
    CameraCoolingReached {
        device_id: String,
        temperature: f64,
    },
    CameraWarmingStarted {
        device_id: String,
    },
    CameraWarmingCompleted {
        device_id: String,
    },
    /// The sensor temperature and cooler power a status read of the camera
    /// returned, published when either has changed since the last one
    /// published for that camera (0.1 C, 1 %), so every UI and linked client
    /// shows the reading the host took.
    CameraTemperatureChanged {
        device_id: String,
        temperature: f64,
        cooler_power: Option<f64>,
    },
    /// The camera's readout settings as it reports them, published after a
    /// gain, offset or binning change and once on connect. Every field is
    /// the camera's full current value, not only the one that changed.
    CameraSettingsChanged {
        device_id: String,
        gain: i32,
        /// `gain` is an ISO speed, and the camera has no offset (a DSLR or
        /// mirrorless body).
        #[serde(default)]
        gain_is_iso: bool,
        offset: i32,
        bin_x: i32,
        bin_y: i32,
    },

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

impl EquipmentEvent {
    /// The device the event is about.
    pub(crate) fn device_id(&self) -> &str {
        match self {
            EquipmentEvent::Connecting { device_id, .. }
            | EquipmentEvent::Connected { device_id, .. }
            | EquipmentEvent::Disconnected { device_id, .. }
            | EquipmentEvent::PropertyChanged { device_id, .. }
            | EquipmentEvent::Error { device_id, .. }
            | EquipmentEvent::MountSlewStarted { device_id, .. }
            | EquipmentEvent::MountSlewCompleted { device_id, .. }
            | EquipmentEvent::MountTrackingStarted { device_id }
            | EquipmentEvent::MountTrackingStopped { device_id }
            | EquipmentEvent::MountParkStarted { device_id }
            | EquipmentEvent::MountParkCompleted { device_id }
            | EquipmentEvent::MountUnparked { device_id }
            | EquipmentEvent::FocuserMoveStarted { device_id, .. }
            | EquipmentEvent::FocuserMoveCompleted { device_id, .. }
            | EquipmentEvent::FilterChanging { device_id, .. }
            | EquipmentEvent::FilterChanged { device_id, .. }
            | EquipmentEvent::RotatorMoveStarted { device_id, .. }
            | EquipmentEvent::RotatorMoveCompleted { device_id, .. }
            | EquipmentEvent::CameraCoolingStarted { device_id, .. }
            | EquipmentEvent::CameraCoolingReached { device_id, .. }
            | EquipmentEvent::CameraWarmingStarted { device_id }
            | EquipmentEvent::CameraWarmingCompleted { device_id }
            | EquipmentEvent::CameraTemperatureChanged { device_id, .. }
            | EquipmentEvent::CameraSettingsChanged { device_id, .. }
            | EquipmentEvent::HeartbeatStarted { device_id, .. }
            | EquipmentEvent::HeartbeatStopped { device_id, .. }
            | EquipmentEvent::HeartbeatStatusChanged { device_id, .. }
            | EquipmentEvent::HeartbeatReconnecting { device_id, .. }
            | EquipmentEvent::HeartbeatReconnected { device_id, .. } => device_id,
            EquipmentEvent::DeviceDiscovered { id, .. } | EquipmentEvent::DeviceLost { id, .. } => {
                id
            }
        }
    }
}
