//! The mount behind its handle, once per protocol.
//!
//! A serial mount, an Alpaca telescope and an INDI telescope are a
//! `skotiq_device::MountDriver` behind [`DriverMount`]; an ASCOM COM
//! telescope and the simulator answer here themselves. What the mount is
//! sent for each operation is pinned by the recorded traces in
//! `device_manager/tests/golden`. The
//! checks, motion-guard bookkeeping, frame conversion and events around an
//! operation are the device manager's (`ops/mount`).
//!
//! Coordinates are in the mount's own frame; the caller converts.

#[cfg(windows)]
pub(crate) mod com;
pub(crate) mod driver;

#[cfg(windows)]
pub(crate) use com::ComMount;

use super::RigDriver;
use crate::device::{MountSite, MountSiteCapabilities, MountStatus, MountTimeInfo};
use crate::device_capabilities::types::DeviceCapabilities;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;

#[async_trait]
pub(crate) trait Mount: RigDriver {
    /// Starts a goto; returns once the mount has taken the command.
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError>;

    async fn slew_alt_az(&self, altitude: f64, azimuth: f64) -> Result<(), DeviceOpError>;

    /// Stops a goto.
    async fn abort(&self) -> Result<(), DeviceOpError>;

    /// Moves an axis at `rate` degrees per second until sent rate 0.
    async fn move_axis(&self, axis: i32, rate: f64) -> Result<(), DeviceOpError>;

    async fn park(&self) -> Result<(), DeviceOpError>;

    async fn unpark(&self) -> Result<(), DeviceOpError>;

    async fn find_home(&self) -> Result<(), DeviceOpError>;

    async fn can_find_home(&self) -> Result<bool, DeviceOpError>;

    /// Stores the current position as the park position.
    async fn set_park(&self) -> Result<(), DeviceOpError>;

    async fn can_set_park(&self) -> Result<bool, DeviceOpError>;

    async fn sync(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError>;

    /// Right ascension in hours and declination in degrees.
    async fn coordinates(&self) -> Result<(f64, f64), DeviceOpError>;

    async fn status(&self) -> Result<MountStatus, DeviceOpError>;

    async fn set_tracking(&self, enabled: bool) -> Result<(), DeviceOpError>;

    /// Returns when the pulse is over.
    async fn pulse_guide(
        &self,
        dir: skotiq_device::GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DeviceOpError>;

    /// `rate` is the ASCOM `DriveRates` number.
    async fn set_tracking_rate(&self, rate: i32) -> Result<(), DeviceOpError>;

    async fn site(&self) -> Result<MountSite, DeviceOpError>;

    async fn set_site(&self, site: MountSite) -> Result<(), DeviceOpError>;

    async fn time(&self) -> Result<MountTimeInfo, DeviceOpError>;

    async fn set_time(&self, time: MountTimeInfo) -> Result<(), DeviceOpError>;

    /// Which of site and clock the mount can be read and written.
    async fn site_capabilities(&self) -> Result<MountSiteCapabilities, DeviceOpError>;

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError>;

    /// Lets go of whatever the handle holds open without sending the mount
    /// anything. Only a vendor mount holds something: its serial port.
    async fn release(&self) {}
}

/// A failed guide pulse. A pulse that outlasted its wait is a timeout of
/// this mount, in the wait's own sentence.
pub(super) fn pulse_error(device_id: &str, error: skotiq_device::DriverError) -> DeviceOpError {
    match error {
        skotiq_device::DriverError::Timeout(detail) => DeviceOpError::Timeout {
            device_id: Some(device_id.to_string()),
            detail,
        },
        other => DeviceOpError::from(other),
    }
}
