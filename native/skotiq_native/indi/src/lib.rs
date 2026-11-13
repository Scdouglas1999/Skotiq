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

/// The connection half of an INDI device wrapper with `client` and
/// `device_name` fields: every wrapper reaches its device on the server's
/// shared connection the same way.
macro_rules! indi_device {
    ($device:ty) => {
        impl $device {
            pub fn device_name(&self) -> &str {
                &self.device_name
            }

            /// The shared server connection this device is reached through.
            pub fn client(&self) -> &std::sync::Arc<tokio::sync::RwLock<$crate::IndiClient>> {
                &self.client
            }

            /// Connects the device and returns once the driver confirms it.
            pub async fn connect(&self) -> $crate::IndiResult<()> {
                self.client
                    .write()
                    .await
                    .connect_and_confirm(&self.device_name)
                    .await
            }

            /// Disconnects the device and returns once the driver confirms it.
            pub async fn disconnect(&self) -> $crate::IndiResult<()> {
                self.client
                    .write()
                    .await
                    .disconnect_and_confirm(&self.device_name)
                    .await
            }

            pub async fn is_connected(&self) -> bool {
                self.client
                    .read()
                    .await
                    .is_device_connected(&self.device_name)
                    .await
            }

            /// One heartbeat; see `IndiClient::check_device`.
            pub async fn check(&self) -> $crate::IndiResult<bool> {
                self.client
                    .write()
                    .await
                    .check_device(&self.device_name)
                    .await
            }
        }
    };
}

/// [`indi_device`] plus the accessory lifecycle trait.
macro_rules! indi_accessory {
    ($device:ty) => {
        indi_device!($device);

        #[async_trait::async_trait]
        impl skotiq_device::AccessoryDriver for $device {
            async fn disconnect(&self) -> Result<(), skotiq_device::DriverError> {
                Ok(<$device>::disconnect(self).await?)
            }

            async fn heartbeat(&self) -> Result<(), skotiq_device::DriverError> {
                if self.check().await? {
                    Ok(())
                } else {
                    Err(skotiq_device::DriverError::NotConnected)
                }
            }
        }
    };
}

mod camera;
mod camera_driver;
mod client;
mod covercalibrator;
pub mod discovery;
mod dome;
mod error;
mod filterwheel;
mod focuser;
mod frame;
mod kind;
mod mount;
mod mount_driver;
mod protocol;
mod rig_drivers;
mod rotator;
mod safetymonitor;
mod switch_device;
mod weather;

pub use camera::{IndiCamera, IndiReadoutMode};
pub use client::*;
pub use covercalibrator::{IndiCalibratorState, IndiCoverCalibrator, IndiCoverState};
pub use discovery::{
    discover_common_hosts, discover_local_network, discover_localhost, discover_mdns,
    discover_server, list_devices, wait_for_definitions, IndiDeviceInfo, IndiServer,
};
pub use dome::{IndiDome, IndiShutterStatus};
pub use error::{IndiError, IndiResult};
pub use filterwheel::IndiFilterWheel;
pub use focuser::IndiFocuser;
pub use kind::IndiDeviceDescription;
pub use frame::{decode_frame, IndiFrame};
pub use mount::IndiMount;
pub use protocol::{names, CcdFrameType, INDI_PROTOCOL_VERSION};
pub use rotator::IndiRotator;
pub use safetymonitor::IndiSafetyMonitor;
pub use switch_device::{IndiSwitchDevice, IndiSwitchInfo};
pub use weather::{IndiWeather, IndiWeatherStatus, DEFAULT_WEATHER_STALE_MS};

/// Default INDI server port
pub const INDI_DEFAULT_PORT: u16 = 7624;

#[derive(Debug, Clone)]
pub struct IndiDevice {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndiPropertyType {
    Text,
    Number,
    Switch,
    Light,
    Blob,
}

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
    pub fn message_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.message_timeout_secs)
    }

    pub fn blob_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.blob_timeout_secs)
    }

    pub fn connection_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.connection_timeout_secs)
    }
}

#[derive(Debug, Clone, thiserror::Error)]
#[error("Operation timeout for device '{device}', property '{property}': {context}")]
pub struct IndiTimeoutError {
    pub device: String,
    pub property: String,
    pub context: String,
    pub last_state: Option<IndiPropertyState>,
}
