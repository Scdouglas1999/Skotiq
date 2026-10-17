//! Real Windows ASCOM COM implementation
//!
//! Full COM interop for ASCOM devices using windows-rs.
//!
//! This module provides robust, production-quality ASCOM driver support with:
//! - Proper error types with detailed COM and ASCOM error information
//! - Connection health monitoring
//! - RAII-based resource cleanup

pub mod camera;
pub mod connection;
pub mod cover_calibrator;
pub mod dome;
pub mod error;
pub mod filter_wheel;
pub mod focuser;
pub mod health;
pub mod mount;
pub mod observing_conditions;
pub mod rotator;
pub mod safety_monitor;
pub mod switch;
pub mod variant;

pub use camera::{
    AscomCamera, CameraExposureSettings, CameraFullStatus, CameraSensorConfig, CameraThermalStatus,
};
pub use connection::{
    discover_devices, init_com, uninit_com, AscomConnectionBackend, AscomDeviceConnection,
};
// Why: mockall generates `MockAscomConnectionBackend` only when the `mock`
// feature is on (or in unit-test builds). Re-export it under the same gate so
// integration tests in the `tests/` crate can name it after enabling the
// feature via dev-dependencies.
#[cfg(any(test, feature = "mock"))]
pub use connection::MockAscomConnectionBackend;
pub use cover_calibrator::{AscomCoverCalibrator, CoverCalibratorFullStatus};
pub use dome::{AscomDome, DomeFullStatus};
pub use error::{AscomError, AscomResult};
pub use filter_wheel::{AscomFilterWheel, FilterWheelFullStatus};
pub use focuser::{AscomFocuser, FocuserCapabilities, FocuserFullStatus};
pub use health::{ConnectionHealth, HealthMonitor};
pub use mount::{
    AscomMount, MountCapabilities, MountFullStatus, MountGuideRates, MountMotionStatus,
    MountPositionStatus, MountSiteStatus,
};
pub use observing_conditions::{
    AscomObservingConditions, ObservingConditionsFullStatus, SkyStatus, WeatherStatus, WindStatus,
};
pub use rotator::{AscomRotator, RotatorFullStatus};
pub use safety_monitor::{AscomSafetyMonitor, SafetyMonitorFullStatus};
pub use switch::{AscomSwitch, SwitchChannelState, SwitchFullStatus};
