//! Device vocabulary shared by every driver crate, the sequencer and the bridge.
//!
//! The color-filter vocabulary lives in `skotiq_cfa` below this crate. It holds the words the rest of
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
    DomeDriver, DomeState, ExposureAbort, FilterWheelDriver, FocuserDriver, MountDriver,
    RotatorDriver, SafetyMonitorDriver, SwitchDriver, WeatherDriver, WeatherReadings,
};
pub use error::DriverError;
pub use kind::DeviceKind;
pub use mount::{
    GuideDirection, MountClock, MountDescription, MountReadings, MountSiteAbilities, MountSiteInfo,
    PierSide, Reading, SiteSource, TrackingRate,
};
pub use skotiq_cfa::{BayerPattern, ColorFilterArray};
pub use vendor::Vendor;
