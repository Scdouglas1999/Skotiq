//! The mount behind its handle, once per protocol.
//!
//! Each method is the protocol's own sequence of driver calls for one mount
//! operation, in the order and under the locks it always ran with: what the
//! mount is sent, and what else can reach it meanwhile, is decided here and
//! pinned by the recorded traces in `device_manager/tests/golden`. The
//! checks, motion-guard bookkeeping, frame conversion and events around an
//! operation are the device manager's (`ops/mount`).
//!
//! Coordinates are in the mount's own frame; the caller converts.

pub(crate) mod alpaca;
#[cfg(windows)]
pub(crate) mod com;
pub(crate) mod indi;
pub(crate) mod vendor;

#[cfg(windows)]
pub(crate) use com::ComMount;

use super::RigDriver;
use crate::device::{MountSite, MountSiteCapabilities, MountStatus, MountTimeInfo};
use crate::device_capabilities::types::DeviceCapabilities;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use std::time::Duration;
use tokio::time::Instant;

#[async_trait]
pub(crate) trait Mount: RigDriver {
    /// Starts a goto; returns once the mount has taken the command.
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError>;

    async fn slew_alt_az(&self, altitude: f64, azimuth: f64) -> Result<(), DeviceOpError>;

    /// Stops a goto.
    async fn abort(&self) -> Result<(), DeviceOpError>;

    /// Stops all motion, tracking included where the protocol has one
    /// command for it.
    async fn stop(&self) -> Result<(), DeviceOpError>;

    /// Moves an axis at `rate` degrees per second until sent rate 0.
    async fn move_axis(&self, axis: i32, rate: f64) -> Result<(), DeviceOpError>;

    async fn park(&self) -> Result<(), DeviceOpError>;

    async fn unpark(&self) -> Result<(), DeviceOpError>;

    async fn find_home(&self) -> Result<(), DeviceOpError>;

    async fn can_find_home(&self) -> Result<bool, DeviceOpError>;

    /// Stores the current position as the park position.
    async fn set_park(&self) -> Result<(), DeviceOpError>;

    async fn can_set_park(&self) -> Result<bool, DeviceOpError>;

    async fn can_park(&self) -> Result<bool, DeviceOpError>;

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

    async fn tracking_rate(&self) -> Result<i32, DeviceOpError>;

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

/// How long past its nominal end an ASCOM guide pulse may still read as
/// running before the wait for it gives up.
const PULSE_END_GRACE: Duration = Duration::from_secs(2);
const PULSE_END_POLL: Duration = Duration::from_millis(50);

/// Waits until an ASCOM guide pulse the driver accepted at `started` is over.
///
/// An ITelescopeV4 driver returns from `PulseGuide` at once and reports the
/// pulse through `IsPulseGuiding`; older drivers often return when the pulse
/// ends. Either way `mount_pulse_guide` hands control back once the mount has
/// stopped correcting, so the next pulse or guide frame does not overlap this
/// one (NINA's direct guider waits the same way). A driver that cannot report
/// `IsPulseGuiding` is taken to be done when the pulse's length has passed.
pub(super) async fn wait_for_ascom_pulse_end<F, Fut, E>(
    device_id: &str,
    started: Instant,
    duration_ms: u32,
    mut is_pulse_guiding: F,
) -> Result<(), DeviceOpError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, E>>,
    E: std::fmt::Display,
{
    let nominal_end = started + Duration::from_millis(u64::from(duration_ms));
    tokio::time::sleep_until(nominal_end).await;
    let deadline = nominal_end + PULSE_END_GRACE;
    loop {
        match is_pulse_guiding().await {
            Ok(false) => return Ok(()),
            Ok(true) if Instant::now() >= deadline => {
                return Err(DeviceOpError::Timeout {
                    device_id: Some(device_id.to_string()),
                    detail: format!(
                        "the mount still reports a guide pulse {:.1} s after a {} ms pulse \
                         should have ended",
                        PULSE_END_GRACE.as_secs_f64(),
                        duration_ms
                    ),
                })
            }
            Ok(true) => tokio::time::sleep(PULSE_END_POLL).await,
            Err(error) => {
                tracing::debug!(
                    "mount_pulse_guide: {} cannot report IsPulseGuiding ({}); the pulse's \
                     length was the wait",
                    device_id,
                    error
                );
                return Ok(());
            }
        }
    }
}
