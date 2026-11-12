//! Device vocabulary shared by every driver crate, the sequencer and the bridge.
//!
//! This crate depends on no other Skotiq crate. It holds the words the rest of
//! the workspace uses to talk about devices: kinds, states, the per-device-type
//! driver traits and the driver error.

pub mod ascom;
pub mod camera;
pub mod driver;
pub mod error;
pub mod kind;
pub mod mount;
pub mod vendor;

pub use camera::*;
pub use driver::{
    AccessoryDriver, CameraDriver, CoverCalibratorDriver, CoverCalibratorState, DeviceDriver,
    DomeDriver, DomeState, FilterWheelDriver, FocuserDriver, MountDriver, RotatorDriver,
    SafetyMonitorDriver, SwitchDriver, WeatherDriver, WeatherReadings,
};
pub use error::DriverError;
pub use kind::DeviceKind;
pub use mount::{GuideDirection, MountClock, MountSiteInfo, PierSide, SiteSource, TrackingRate};
pub use vendor::Vendor;
