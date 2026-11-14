//! ASCOM COM Interface (Windows Only)
//!
//! Provides real access to ASCOM devices via COM on Windows.
//! This module enables Skotiq to connect to actual astronomical
//! equipment through the ASCOM standard.

#[cfg(windows)]
mod windows;

// The device wrappers and what a COM call consists of are not gated: they
// reach the driver only through `com::ComDispatch`, so the tests drive them
// with a recording stand-in on any host. Only `windows` talks to COM.
#[macro_use]
mod members;

mod camera;
pub mod com;
mod cover_calibrator;
mod dome;
mod error;
mod filter_wheel;
mod focuser;
mod health;
mod mount;
mod observing_conditions;
mod rotator;
mod safety_monitor;
mod switch;

// Not gated: the connect read-back policy is pure timing and message logic, so
// it stays testable on the Linux workstation where the COM plumbing cannot even
// compile.
pub mod connect_verify;

/// ASCOM device information discovered from Windows Registry
#[derive(Debug, Clone)]
pub struct AscomDevice {
    /// The COM ProgID used to instantiate the driver
    pub prog_id: String,
    /// Human-readable name
    pub name: String,
    /// Description from ASCOM profile
    pub description: String,
}

use skotiq_device::ascom::AscomDeviceType;

/// Discover ASCOM devices of a specific type
/// Returns a list of available drivers registered in the Windows Registry
#[cfg(windows)]
pub fn discover_devices(device_type: AscomDeviceType) -> Vec<AscomDevice> {
    windows::discover_devices(device_type.name())
}

/// Discover ASCOM devices (non-Windows shim)
#[cfg(not(windows))]
pub fn discover_devices(_device_type: AscomDeviceType) -> Vec<AscomDevice> {
    Vec::new()
}

pub use camera::{
    Camera, CameraExposureSettings, CameraFullStatus, CameraSensorConfig, CameraThermalStatus,
};
pub use cover_calibrator::CoverCalibrator;
pub use dome::Dome;
pub use error::{AscomError, AscomResult};
pub use filter_wheel::FilterWheel;
pub use focuser::Focuser;
pub use health::{ConnectionHealth, HealthMonitor};
pub use mount::{
    Mount, MountCapabilities, MountFullStatus, MountGuideRates, MountMotionStatus,
    MountPositionStatus, MountSiteStatus,
};
pub use observing_conditions::ObservingConditions;
pub use rotator::Rotator;
pub use safety_monitor::SafetyMonitor;
pub use switch::Switch;

#[cfg(windows)]
pub use windows::{init_com, uninit_com, AscomDeviceConnection};

/// The device wrappers over a real COM connection.
#[cfg(windows)]
mod com_devices {
    use super::*;

    pub type AscomCamera = Camera<AscomDeviceConnection>;
    pub type AscomCoverCalibrator = CoverCalibrator<AscomDeviceConnection>;
    pub type AscomDome = Dome<AscomDeviceConnection>;
    pub type AscomFilterWheel = FilterWheel<AscomDeviceConnection>;
    pub type AscomFocuser = Focuser<AscomDeviceConnection>;
    pub type AscomMount = Mount<AscomDeviceConnection>;
    pub type AscomObservingConditions = ObservingConditions<AscomDeviceConnection>;
    pub type AscomRotator = Rotator<AscomDeviceConnection>;
    pub type AscomSafetyMonitor = SafetyMonitor<AscomDeviceConnection>;
    pub type AscomSwitch = Switch<AscomDeviceConnection>;
}
#[cfg(windows)]
pub use com_devices::*;
