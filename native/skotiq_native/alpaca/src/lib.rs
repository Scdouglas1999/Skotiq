//! Alpaca Protocol Client
//!
//! Implements the ASCOM Alpaca REST API for cross-platform device control.
//! This provides network-based access to astronomical equipment without
//! requiring platform-specific COM or INDI interfaces.

mod camera;
mod client;
mod covercalibrator;
mod discovery;
mod dome;
mod filterwheel;
mod focuser;
mod guard;
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
pub use guard::*;
pub use observingconditions::*;
pub use rotator::*;
pub use safetymonitor::*;
pub use switch::*;
pub use telescope::*;

/// Alpaca API version
pub const ALPACA_API_VERSION: u32 = 1;

/// Default Alpaca discovery port
pub const ALPACA_DISCOVERY_PORT: u16 = 32227;

/// Default Alpaca API port
pub const ALPACA_DEFAULT_PORT: u16 = 11111;

/// Alpaca device types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AlpacaDeviceType {
    Camera,
    CoverCalibrator,
    Dome,
    FilterWheel,
    Focuser,
    ObservingConditions,
    Rotator,
    SafetyMonitor,
    Switch,
    Telescope,
}

impl AlpacaDeviceType {
    pub fn as_str(&self) -> &'static str {
        match self {
            AlpacaDeviceType::Camera => "camera",
            AlpacaDeviceType::CoverCalibrator => "covercalibrator",
            AlpacaDeviceType::Dome => "dome",
            AlpacaDeviceType::FilterWheel => "filterwheel",
            AlpacaDeviceType::Focuser => "focuser",
            AlpacaDeviceType::ObservingConditions => "observingconditions",
            AlpacaDeviceType::Rotator => "rotator",
            AlpacaDeviceType::SafetyMonitor => "safetymonitor",
            AlpacaDeviceType::Switch => "switch",
            AlpacaDeviceType::Telescope => "telescope",
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "camera" => Some(AlpacaDeviceType::Camera),
            "covercalibrator" => Some(AlpacaDeviceType::CoverCalibrator),
            "dome" => Some(AlpacaDeviceType::Dome),
            "filterwheel" => Some(AlpacaDeviceType::FilterWheel),
            "focuser" => Some(AlpacaDeviceType::Focuser),
            "observingconditions" => Some(AlpacaDeviceType::ObservingConditions),
            "rotator" => Some(AlpacaDeviceType::Rotator),
            "safetymonitor" => Some(AlpacaDeviceType::SafetyMonitor),
            "switch" => Some(AlpacaDeviceType::Switch),
            "telescope" => Some(AlpacaDeviceType::Telescope),
            _ => None,
        }
    }

    /// Get a display name for the device type
    pub fn display_name(&self) -> &'static str {
        match self {
            AlpacaDeviceType::Camera => "Camera",
            AlpacaDeviceType::CoverCalibrator => "Cover Calibrator",
            AlpacaDeviceType::Dome => "Dome",
            AlpacaDeviceType::FilterWheel => "Filter Wheel",
            AlpacaDeviceType::Focuser => "Focuser",
            AlpacaDeviceType::ObservingConditions => "Observing Conditions",
            AlpacaDeviceType::Rotator => "Rotator",
            AlpacaDeviceType::SafetyMonitor => "Safety Monitor",
            AlpacaDeviceType::Switch => "Switch",
            AlpacaDeviceType::Telescope => "Telescope",
        }
    }
}

impl std::fmt::Display for AlpacaDeviceType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.display_name())
    }
}

/// An Alpaca device discovered on the network
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AlpacaDevice {
    pub device_type: AlpacaDeviceType,
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
        device_type: AlpacaDeviceType,
        device_number: u32,
    ) -> String {
        format!(
            "{}:{}:{}",
            base_url.trim_end_matches('/'),
            device_type.as_str(),
            device_number
        )
    }

    /// Create an Alpaca device from direct server details.
    ///
    /// Discovery provides server/manufacturer/name fields, but direct connect
    /// paths often only know the URL, type, and device number. The unique ID
    /// must still be non-empty so cross-layer grouping can distinguish multiple
    /// devices on the same Alpaca host.
    pub fn from_server(device_type: AlpacaDeviceType, base_url: &str, device_number: u32) -> Self {
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

    /// Get a unique identifier for this device
    pub fn id(&self) -> String {
        format!(
            "alpaca:{}:{}:{}",
            self.base_url,
            self.device_type.as_str(),
            self.device_number
        )
    }

    /// Get a display name combining device name and type
    pub fn display_name(&self) -> String {
        if self.device_name.is_empty() {
            format!(
                "{} #{}",
                self.device_type.display_name(),
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
            AlpacaDevice::from_server(AlpacaDeviceType::Camera, "http://127.0.0.1:11111/", 0);
        let focuser =
            AlpacaDevice::from_server(AlpacaDeviceType::Focuser, "http://127.0.0.1:11111/", 0);
        let camera_1 =
            AlpacaDevice::from_server(AlpacaDeviceType::Camera, "http://127.0.0.1:11111/", 1);

        assert_eq!(camera.unique_id, "http://127.0.0.1:11111:camera:0");
        assert_ne!(camera.unique_id, focuser.unique_id);
        assert_ne!(camera.unique_id, camera_1.unique_id);
    }
}
