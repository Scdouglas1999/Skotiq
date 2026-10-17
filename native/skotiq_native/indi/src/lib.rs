//! # INDI Protocol Support
//!
//! This module implements INDI (Instrument Neutral Distributed Interface) protocol
//! support for device communication on Linux/macOS platforms.
//!
//! ## Support Matrix
//!
//! | Device Type      | Support Level | Notes                                    |
//! |------------------|---------------|------------------------------------------|
//! | Camera           | Full          | All standard INDI camera properties      |
//! | Mount            | Full          | Slew, sync, park, tracking               |
//! | Focuser          | Full          | Absolute and relative positioning        |
//! | Filter Wheel     | Full          | Position control and naming              |
//! | Rotator          | Full          | Angle control                            |
//! | Dome             | Full          | Slew, park, shutter control              |
//! | Safety Monitor   | Full          | Safety state monitoring                  |
//! | Cover Calibrator | Full          | Open, close, halt, calibrator brightness |
//! | Weather          | Full          | All standard INDI weather properties     |
//! | Switch           | Full          | Custom switch property enumeration       |
//!
//! ## Unsupported Features
//!
//! BLOB streaming for video is unsupported; frames arrive as standard BLOB
//! transfers. ASCOM Alpaca is the cross-platform alternative for streaming.
//!
//! Cover calibrator open/close/halt each try several property vocabularies
//! (`CAP_*`, `LIGHTBOX_CONTROL`, `DUST_CAP`) and error out only when the driver
//! exposes none of them.
//!
//! ## Features
//!
//! - Robust error handling with IndiError types
//! - Reader task supervision with automatic reconnection
//! - XML parse timeout for incomplete messages
//! - Atomic keepalive operations to prevent race conditions
//! - BLOB format validation and detection
//! - Property min/max extraction for number elements
//! - Permission checking before property writes
//! - Protocol version negotiation support (1.7, 1.8, 1.9)
//! - Exponential backoff with jitter for reconnection

pub mod autofocus;
mod camera;
mod client;
mod covercalibrator;
pub mod discovery;
mod dome;
mod error;
mod filterwheel;
mod focuser;
mod mount;
mod protocol;
mod rotator;
mod safetymonitor;
mod switch_device;
mod weather;

pub use autofocus::{AutofocusMethod, IndiAutofocus, IndiAutofocusConfig, IndiAutofocusResult};
pub use camera::{IndiBayerPattern, IndiCamera, IndiReadoutMode};
pub use client::*;
pub use covercalibrator::{IndiCalibratorState, IndiCoverCalibrator, IndiCoverState};
pub use discovery::{
    discover_common_hosts, discover_local_network, discover_localhost, discover_mdns,
    discover_server, IndiDeviceInfo, IndiDeviceType, IndiServer,
};
pub use dome::{IndiDome, IndiShutterStatus};
pub use error::{IndiError, IndiResult};
pub use filterwheel::IndiFilterWheel;
pub use focuser::IndiFocuser;
pub use mount::{IndiMount, IndiMountGuideDirection};
pub use protocol::{standard_properties, CcdFrameType, INDI_PROTOCOL_VERSION};
pub use rotator::IndiRotator;
pub use safetymonitor::IndiSafetyMonitor;
pub use switch_device::{IndiSwitchDevice, IndiSwitchInfo};
pub use weather::{IndiWeather, IndiWeatherStatus, DEFAULT_WEATHER_STALE_MS};

/// Default INDI server port
pub const INDI_DEFAULT_PORT: u16 = 7624;

/// INDI device information
#[derive(Debug, Clone)]
pub struct IndiDevice {
    pub name: String,
    pub driver: String,
}

/// Check if INDI is available on this platform
pub fn is_available() -> bool {
    !cfg!(target_os = "windows")
}

/// INDI property types
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndiPropertyType {
    Text,
    Number,
    Switch,
    Light,
    Blob,
}

/// INDI property state
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiPropertyState {
    Idle,
    Ok,
    Busy,
    Alert,
}

/// INDI switch vector rule (see INDI protocol §3.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiSwitchRule {
    OneOfMany,
    AtMostOne,
    AnyOfMany,
    OneOfManyZeroOff,
}

/// An INDI property
#[derive(Debug, Clone)]
pub struct IndiProperty {
    pub device: String,
    pub name: String,
    pub label: String,
    pub group: String,
    pub property_type: IndiPropertyType,
    pub state: IndiPropertyState,
    pub perm: IndiPermission,
    pub elements: Vec<String>,
    /// Switch rule from `defSwitchVector` / `setSwitchVector` (`rule="..."`).
    pub switch_rule: Option<IndiSwitchRule>,
}

/// INDI property permission
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiPermission {
    ReadOnly,
    WriteOnly,
    ReadWrite,
}

/// Timeout configuration for INDI operations
#[derive(Debug, Clone)]
pub struct IndiTimeoutConfig {
    /// Connection timeout for initial TCP connection (default: 30 seconds)
    pub connection_timeout_secs: u64,
    /// Timeout for completing partial XML messages (default: 60 seconds)
    /// If a partial XML message is not completed within this time, the parser resets
    pub message_timeout_secs: u64,
    /// Timeout for receiving BLOB data (default: 300 seconds for large images)
    pub blob_timeout_secs: u64,
    /// Timeout for property responses (default: 30 seconds)
    pub property_timeout_secs: u64,
    /// Mount slew timeout (default: 300 seconds)
    pub mount_slew_timeout_secs: u64,
    /// Focuser move timeout (default: 120 seconds)
    pub focuser_move_timeout_secs: u64,
    /// Filter change timeout (default: 60 seconds)
    pub filter_change_timeout_secs: u64,
    /// Dome slew timeout (default: 300 seconds)
    pub dome_slew_timeout_secs: u64,
    /// Rotator move timeout (default: 120 seconds)
    pub rotator_move_timeout_secs: u64,
    /// Camera exposure timeout buffer (added to exposure time, default: 60 seconds)
    pub camera_exposure_buffer_secs: u64,
    /// Property state polling interval (default: 500ms)
    pub property_poll_interval_ms: u64,
    /// Connection keepalive interval (default: 30 seconds)
    pub keepalive_interval_secs: u64,
    /// Reconnection base delay (default: 1 second)
    pub reconnect_base_delay_secs: u64,
    /// Reconnection max delay (default: 30 seconds)
    pub reconnect_max_delay_secs: u64,
    /// Reconnection max attempts (default: 5)
    pub reconnect_max_attempts: u32,
}

impl Default for IndiTimeoutConfig {
    fn default() -> Self {
        Self {
            connection_timeout_secs: 30,
            message_timeout_secs: 60,
            blob_timeout_secs: 300,
            property_timeout_secs: 30,
            mount_slew_timeout_secs: 300,
            focuser_move_timeout_secs: 120,
            filter_change_timeout_secs: 60,
            dome_slew_timeout_secs: 300,
            rotator_move_timeout_secs: 120,
            camera_exposure_buffer_secs: 60,
            property_poll_interval_ms: 500,
            keepalive_interval_secs: 30,
            reconnect_base_delay_secs: 1,
            reconnect_max_delay_secs: 30,
            reconnect_max_attempts: 5,
        }
    }
}

impl IndiTimeoutConfig {
    /// Get the message timeout as a Duration
    pub fn message_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.message_timeout_secs)
    }

    /// Get the BLOB timeout as a Duration
    pub fn blob_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.blob_timeout_secs)
    }

    /// Get the property timeout as a Duration
    pub fn property_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.property_timeout_secs)
    }

    /// Get the connection timeout as a Duration
    pub fn connection_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.connection_timeout_secs)
    }
}

/// Timeout error with context
#[derive(Debug, Clone, thiserror::Error)]
#[error("Operation timeout for device '{device}', property '{property}': {context}")]
pub struct IndiTimeoutError {
    pub device: String,
    pub property: String,
    pub context: String,
    pub last_state: Option<IndiPropertyState>,
}
