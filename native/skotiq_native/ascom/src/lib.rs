//! ASCOM COM Interface (Windows Only)
//!
//! Provides real access to ASCOM devices via COM on Windows.
//! This module enables Skotiq to connect to actual astronomical
//! equipment through the ASCOM standard.

#[cfg(windows)]
mod windows;

// Not gated: the connect read-back policy is pure timing and message logic, so
// it stays testable on the Linux workstation where the COM plumbing cannot even
// compile.
pub mod connect_verify;

// Same reasoning: which cooler properties may be written is pure policy over
// the driver's declared capabilities.
pub mod cooler_policy;

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

/// ASCOM device types as defined by ASCOM standard
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AscomDeviceType {
    Camera,
    Telescope,
    Focuser,
    FilterWheel,
    Rotator,
    Dome,
    SafetyMonitor,
    ObservingConditions,
    Switch,
    CoverCalibrator,
}

impl AscomDeviceType {
    /// Get the registry key name for this device type
    pub fn registry_name(&self) -> &'static str {
        match self {
            AscomDeviceType::Camera => "Camera",
            AscomDeviceType::Telescope => "Telescope",
            AscomDeviceType::Focuser => "Focuser",
            AscomDeviceType::FilterWheel => "FilterWheel",
            AscomDeviceType::Rotator => "Rotator",
            AscomDeviceType::Dome => "Dome",
            AscomDeviceType::SafetyMonitor => "SafetyMonitor",
            AscomDeviceType::ObservingConditions => "ObservingConditions",
            AscomDeviceType::Switch => "Switch",
            AscomDeviceType::CoverCalibrator => "CoverCalibrator",
        }
    }
}

/// Discover ASCOM devices of a specific type
/// Returns a list of available drivers registered in the Windows Registry
#[cfg(windows)]
pub fn discover_devices(device_type: AscomDeviceType) -> Vec<AscomDevice> {
    windows::discover_devices(device_type.registry_name())
}

/// Discover ASCOM devices (non-Windows shim)
#[cfg(not(windows))]
pub fn discover_devices(_device_type: AscomDeviceType) -> Vec<AscomDevice> {
    Vec::new()
}

/// Check if ASCOM is available on this platform
pub fn is_available() -> bool {
    cfg!(windows)
}

// Re-export Windows-specific types when on Windows
#[cfg(windows)]
pub use windows::{
    // COM initialization
    init_com,
    uninit_com,
    // Device types
    AscomCamera,
    // Mockall seam for per-device wrapper unit tests
    AscomConnectionBackend,
    AscomCoverCalibrator,
    // Device connection wrapper
    AscomDeviceConnection,
    AscomDome,
    // Error types
    AscomError,
    AscomFilterWheel,
    AscomFocuser,
    AscomMount,
    AscomObservingConditions,
    AscomResult,
    AscomRotator,
    AscomSafetyMonitor,
    AscomSwitch,
    CameraExposureSettings,
    CameraFullStatus,
    CameraSensorConfig,
    // Batch status types - Camera
    CameraThermalStatus,
    // Health monitoring
    ConnectionHealth,
    // Batch status types - Cover Calibrator
    CoverCalibratorFullStatus,
    // Batch status types - Dome
    DomeFullStatus,
    // Batch status types - Filter Wheel
    FilterWheelFullStatus,
    // Batch status types - Focuser
    FocuserCapabilities,
    FocuserFullStatus,
    HealthMonitor,
    MountCapabilities,
    MountFullStatus,
    MountGuideRates,
    MountMotionStatus,
    // Batch status types - Mount
    MountPositionStatus,
    MountSiteStatus,
    ObservingConditionsFullStatus,
    // Batch status types - Rotator
    RotatorFullStatus,
    // Batch status types - Safety Monitor
    SafetyMonitorFullStatus,
    SkyStatus,
    // Batch status types - Switch
    SwitchChannelState,
    SwitchFullStatus,
    // Batch status types - Observing Conditions
    WeatherStatus,
    WindStatus,
};

// Why: surface the generated mock only when the `mock` feature is on (or in
// unit-test builds). Integration tests in `ascom/tests/` enable the feature
// via dev-dependencies in `Cargo.toml` so they can name this type.
#[cfg(all(windows, any(test, feature = "mock")))]
pub use windows::MockAscomConnectionBackend;
