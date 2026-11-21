//! Device vocabulary shared by every driver crate, the sequencer and the bridge.
//!
//! The frame vocabulary (color filter arrays, the filter-name rule) lives in
//! `skotiq_frame` below this crate. This crate holds the words the rest of
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
pub use skotiq_frame::filter_name::{
    self, filter_bands, match_filter_slot, same_filter, FilterSlotMatch,
};
pub use skotiq_frame::{BayerPattern, ColorFilterArray};
pub use vendor::Vendor;
