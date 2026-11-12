//! Alpaca Protocol Client
//!
//! Implements the ASCOM Alpaca REST API for cross-platform device control.
//! This provides network-based access to astronomical equipment without
//! requiring platform-specific COM or INDI interfaces.

#[macro_use]
mod members;

mod accessory;
mod camera;
mod client;
mod covercalibrator;
mod discovery;
mod dome;
mod filterwheel;
mod focuser;
mod observingconditions;
mod rotator;
mod safetymonitor;
mod switch;
mod telescope;

pub use camera::*;
pub use client::*;
pub use covercalibrator::*;
pub use discovery::*;
pub use dome::*;
pub use filterwheel::*;
pub use focuser::*;
pub use observingconditions::*;
pub use rotator::*;
pub use safetymonitor::*;
pub use switch::*;
pub use telescope::*;

// The ASCOM enumerations are shared with the COM transport.
pub use skotiq_device::ascom::{
    AlignmentMode, AscomDeviceType, AxisRate, CalibratorStatus, CameraState, CoverStatus, DriveRate, PierSide,
    SensorType, ShutterStatus, TelescopeAxis,
};

/// Default Alpaca discovery port
pub const ALPACA_DISCOVERY_PORT: u16 = 32227;

/// An Alpaca device discovered on the network
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AlpacaDevice {
    pub device_type: AscomDeviceType,
    pub device_number: u32,
    pub server_name: String,
    pub manufacturer: String,
    pub device_name: String,
    pub unique_id: String,
    pub base_url: String,
}

impl AlpacaDevice {
    /// Build a deterministic device identity for clients constructed directly
    /// from a server URL and device number rather than full discovery metadata.
    pub fn server_unique_id(
        base_url: &str,
        device_type: AscomDeviceType,
        device_number: u32,
    ) -> String {
        format!(
            "{}:{}:{}",
            base_url.trim_end_matches('/'),
            device_type.alpaca_path(),
            device_number
        )
    }

    /// Create an Alpaca device from direct server details.
    ///
    /// Discovery provides server/manufacturer/name fields, but direct connect
    /// paths often only know the URL, type, and device number. The unique ID
    /// must still be non-empty so cross-layer grouping can distinguish multiple
    /// devices on the same Alpaca host.
    pub fn from_server(device_type: AscomDeviceType, base_url: &str, device_number: u32) -> Self {
        Self {
            device_type,
            device_number,
            server_name: String::new(),
            manufacturer: String::new(),
            device_name: String::new(),
            unique_id: Self::server_unique_id(base_url, device_type, device_number),
            base_url: base_url.to_string(),
        }
    }

    pub fn id(&self) -> String {
        format!(
            "alpaca:{}:{}:{}",
            self.base_url,
            self.device_type.alpaca_path(),
            self.device_number
        )
    }

    /// Get a display name combining device name and type
    pub fn display_name(&self) -> String {
        if self.device_name.is_empty() {
            format!(
                "{} #{}",
                self.device_type.label(),
                self.device_number
            )
        } else {
            self.device_name.clone()
        }
    }
}

impl std::fmt::Display for AlpacaDevice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} at {}", self.display_name(), self.base_url)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_server_sets_stable_unique_id() {
        let camera =
            AlpacaDevice::from_server(AscomDeviceType::Camera, "http://127.0.0.1:11111/", 0);
        let focuser =
            AlpacaDevice::from_server(AscomDeviceType::Focuser, "http://127.0.0.1:11111/", 0);
        let camera_1 =
            AlpacaDevice::from_server(AscomDeviceType::Camera, "http://127.0.0.1:11111/", 1);

        assert_eq!(camera.unique_id, "http://127.0.0.1:11111:camera:0");
        assert_ne!(camera.unique_id, focuser.unique_id);
        assert_ne!(camera.unique_id, camera_1.unique_id);
    }
}
