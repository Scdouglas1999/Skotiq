//! A mount behind a [`MountDriver`]: a serial mount, an Alpaca telescope or
//! an INDI telescope.
//!
//! Which requests an operation makes of the mount is the driver's; this file
//! adds what is the same for every driver: the time a goto may take to be
//! accepted, the sentences an operator reads, and the status and capability
//! shapes the application uses.

use super::Mount;
use crate::device::*;
use crate::device_capabilities::{DeviceCapabilities, MountCapabilities};
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::rig::{RigDriver, Slot};
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{with_timeout, Timeouts};
use async_trait::async_trait;
use skotiq_device::{DriverError, MountDriver};
use std::sync::Arc;
use tokio::sync::RwLock;

type Driver = dyn MountDriver + Send + Sync;

/// What differs by protocol around a [`MountDriver`]: its name in messages,
/// where a description of the device comes from, and the sentence for each
/// operation the protocol's driver does not offer (`None`: the driver's own
/// words).
struct Protocol {
    /// "Native", "Alpaca", "INDI": in "Native mount not connected" and logs.
    name: &'static str,
    /// The protocol inside a sentence: "native", "Alpaca", "INDI".
    in_sentence: &'static str,
    described_by: Description,
    no_alt_az_slew: Option<&'static str>,
    no_axis_move: Option<&'static str>,
    no_tracking_rate_read: Option<&'static str>,
    no_tracking_rate_write: Option<&'static str>,
    no_site_read: Option<&'static str>,
    no_site_write: Option<&'static str>,
    no_clock_read: Option<&'static str>,
    no_clock_write: Option<&'static str>,
}

enum Description {
    /// From the driver's own answers.
    Driver,
    /// From the protocol's capability probe of the device id.
    Alpaca,
    Indi,
}

const VENDOR: Protocol = Protocol {
    name: "Native",
    in_sentence: "native",
    described_by: Description::Driver,
    no_alt_az_slew: Some("Alt/Az slew is not supported for native serial mounts"),
    no_axis_move: Some("Native SDK does not support mount axis movement"),
    no_tracking_rate_read: None,
    no_tracking_rate_write: None,
    no_site_read: None,
    no_site_write: None,
    no_clock_read: None,
    no_clock_write: None,
};

const NO_RATE_READ: &str = "Getting tracking rate is not supported by this driver type";
const NO_RATE_WRITE: &str = "Setting tracking rate is not supported by this driver type";

const ALPACA: Protocol = Protocol {
    name: "Alpaca",
    in_sentence: "Alpaca",
    described_by: Description::Alpaca,
    no_alt_az_slew: None,
    no_axis_move: None,
    no_tracking_rate_read: Some(NO_RATE_READ),
    no_tracking_rate_write: Some(NO_RATE_WRITE),
    no_site_read: None,
    no_site_write: None,
    no_clock_read: None,
    no_clock_write: None,
};

const INDI: Protocol = Protocol {
    name: "INDI",
    in_sentence: "INDI",
    described_by: Description::Indi,
    no_alt_az_slew: None,
    no_axis_move: None,
    no_tracking_rate_read: Some(NO_RATE_READ),
    no_tracking_rate_write: Some(NO_RATE_WRITE),
    no_site_read: Some("Reading the site from an INDI mount is not wired up yet"),
    no_site_write: Some("Writing the site to an INDI mount is not wired up yet"),
    no_clock_read: Some("Reading the clock from an INDI mount is not wired up yet"),
    no_clock_write: Some("Writing the clock to an INDI mount is not wired up yet"),
};

pub(crate) struct DriverMount {
    device_id: String,
    driver: Slot<Driver>,
    protocol: &'static Protocol,
}

impl DriverMount {
    /// A serial mount: the driver keeps state between calls and holds the
    /// port, so it is reached one call at a time.
    pub(crate) fn vendor(device_id: &str, driver: Box<Driver>) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Slot::held(driver),
            protocol: &VENDOR,
        }
    }

    pub(crate) fn alpaca(device_id: &str, mount: skotiq_alpaca::AlpacaMount) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Slot::per_call(move || Box::new(mount.clone()) as Box<Driver>),
            protocol: &ALPACA,
        }
    }

    pub(crate) fn indi(
        device_id: &str,
        client: Arc<RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        let device_name = device_name.to_string();
        Self {
            device_id: device_id.to_string(),
            driver: Slot::per_call(move || {
                Box::new(skotiq_indi::IndiMount::new(client.clone(), &device_name)) as Box<Driver>
            }),
            protocol: &INDI,
        }
    }

    fn gone(&self) -> DeviceOpError {
        DeviceOpError::not_connected(
            Some(self.device_id.clone()),
            format!("{} mount not connected", self.protocol.name),
        )
    }

    /// `error` in the driver's words, or in `sentence` when the driver says
    /// the mount has no such operation.
    fn or_unsupported(error: DriverError, sentence: Option<&'static str>) -> DeviceOpError {
        match (&error, sentence) {
            (DriverError::NotSupported, Some(sentence)) => DeviceOpError::unsupported(sentence),
            _ => DeviceOpError::from(error),
        }
    }

    fn failed(&self, what: String, error: DriverError) -> DeviceOpError {
        DeviceOpError::caused_by(
            Some(self.device_id.clone()),
            format!("{what}: {error}"),
            error,
        )
    }
}

#[async_trait]
impl RigDriver for DriverMount {
    async fn disconnect(&self) -> Result<(), DriverError> {
        match self.driver.take().await {
            Some(mut mount) => mount.disconnect().await,
            None => Ok(()),
        }
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let mount = self.driver.read().await.ok_or_else(|| {
            format!(
                "{} mount {} not registered in device manager",
                self.protocol.name, self.device_id
            )
        })?;
        mount.heartbeat().await.map_err(|e| {
            format!(
                "{} mount liveness probe failed: {}",
                self.protocol.name, e
            )
        })
    }

    async fn identity(&self) -> Option<DeviceIdentity> {
        if !matches!(self.protocol.described_by, Description::Driver) {
            return None;
        }
        let mount = self.driver.read().await?;
        Some(DeviceManager::identity_from_device(&self.device_id, &*mount))
    }
}

#[async_trait]
impl Mount for DriverMount {
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        with_timeout(
            async {
                mount
                    .slew_to_coordinates(ra, dec)
                    .await
                    .map_err(|e| SkotiqError::from(DeviceOpError::from(e)))
            },
            Timeouts::long_slew(),
            &self.device_id,
            "slew_to_coordinates",
        )
        .await
        .map_err(|e| {
            tracing::error!("mount_slew {} error: {}", self.protocol.name, e);
            DeviceOpError::from(e)
        })
    }

    async fn slew_alt_az(&self, altitude: f64, azimuth: f64) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        let slew = tokio::time::timeout(
            Timeouts::long_slew(),
            mount.slew_to_alt_az(altitude, azimuth),
        )
        .await;
        match slew {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(Self::or_unsupported(e, self.protocol.no_alt_az_slew)),
            Err(_) => Err(DeviceOpError::from(SkotiqError::DeviceTimeout {
                device_id: self.device_id.clone(),
                operation: "slew_to_alt_az".to_string(),
                timeout_secs: Timeouts::long_slew().as_secs_f64(),
            })),
        }
        .map_err(|e| {
            tracing::error!("mount_slew_alt_az {} error: {}", self.protocol.name, e);
            e
        })
    }

    async fn abort(&self) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn stop(&self) -> Result<(), DeviceOpError> {
        self.abort().await
    }

    async fn move_axis(&self, axis: i32, rate: f64) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.move_axis(axis, rate).await.map_err(|e| {
            tracing::error!("mount_move_axis {} error: {}", self.protocol.name, e);
            Self::or_unsupported(e, self.protocol.no_axis_move)
        })
    }

    async fn park(&self) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.park().await.map_err(|e| {
            self.failed(
                format!(
                    "Failed to park {} mount {}",
                    self.protocol.in_sentence, self.device_id
                ),
                e,
            )
        })
    }

    async fn unpark(&self) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.unpark().await.map_err(DeviceOpError::from)
    }

    async fn find_home(&self) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.find_home().await.map_err(|e| {
            tracing::error!("mount_find_home {} error: {}", self.protocol.name, e);
            DeviceOpError::from(e)
        })
    }

    async fn can_find_home(&self) -> Result<bool, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        mount.can_find_home().await.map_err(DeviceOpError::from)
    }

    async fn set_park(&self) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.set_park().await.map_err(|e| {
            tracing::error!("mount_set_park {} error: {}", self.protocol.name, e);
            DeviceOpError::from(e)
        })
    }

    async fn can_set_park(&self) -> Result<bool, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        mount.can_set_park().await.map_err(DeviceOpError::from)
    }

    async fn can_park(&self) -> Result<bool, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        mount.can_park().await.map_err(|e| {
            DeviceOpError::hardware(
                Some(self.device_id.clone()),
                format!(
                    "Failed to determine {} mount park capability for {}: {}",
                    self.protocol.in_sentence, self.device_id, e
                ),
            )
        })
    }

    async fn sync(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.sync_to_coordinates(ra, dec).await.map_err(|e| {
            self.failed(
                format!(
                    "Failed to sync {} mount {} to RA={:.4} Dec={:.4}",
                    self.protocol.in_sentence, self.device_id, ra, dec
                ),
                e,
            )
        })
    }

    async fn coordinates(&self) -> Result<(f64, f64), DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        mount.get_coordinates().await.map_err(DeviceOpError::from)
    }

    async fn status(&self) -> Result<MountStatus, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        let read = mount.status().await.map_err(DeviceOpError::from)?;

        let mut availability = DeviceManager::mount_status_availability_map();
        if read.parked.is_none() {
            // `parked: false` below is not an observation; consumers that
            // act on the park state refuse to trust it
            // (`parked_from_status`).
            availability.insert(
                mount_status_field::PARKED.to_string(),
                FieldAvailability::Unsupported,
            );
        }
        // A mount that answers `Unknown` does not report its pier side.
        let side_of_pier = DeviceManager::availability_from_native_result(
            read.side_of_pier.and_then(|side| match side {
                skotiq_device::PierSide::Unknown => Err(DriverError::NotSupported),
                side => Ok(side),
            }),
            mount_status_field::SIDE_OF_PIER,
            &mut availability,
        )
        .map(DeviceManager::pier_side_from_native);
        let altitude = DeviceManager::availability_from_native_result(
            read.altitude,
            mount_status_field::ALTITUDE,
            &mut availability,
        );
        let azimuth = DeviceManager::availability_from_native_result(
            read.azimuth,
            mount_status_field::AZIMUTH,
            &mut availability,
        );
        let sidereal_time = DeviceManager::availability_from_native_result(
            read.sidereal_time,
            mount_status_field::SIDEREAL_TIME,
            &mut availability,
        );
        let at_home = DeviceManager::availability_from_native_result(
            read.at_home,
            mount_status_field::AT_HOME,
            &mut availability,
        );
        let tracking_rate = DeviceManager::availability_from_native_result(
            read.tracking_rate,
            mount_status_field::TRACKING_RATE,
            &mut availability,
        )
        .map(DeviceManager::tracking_rate_from_native);

        Ok(MountStatus {
            connected: true,
            tracking: read.tracking,
            slewing: read.slewing,
            parked: read.parked.unwrap_or(false),
            at_home,
            side_of_pier,
            right_ascension: read.right_ascension,
            declination: read.declination,
            altitude,
            azimuth,
            sidereal_time,
            tracking_rate,
            can_park: read.can_park,
            can_slew: read.can_slew,
            can_sync: read.can_sync,
            can_pulse_guide: read.can_pulse_guide,
            can_set_tracking_rate: read.can_set_tracking_rate,
            availability,
        })
    }

    async fn set_tracking(&self, enabled: bool) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount.set_tracking(enabled).await.map_err(|e| {
            self.failed(
                format!(
                    "Failed to set {} mount {} tracking={}",
                    self.protocol.in_sentence, self.device_id, enabled
                ),
                e,
            )
        })
    }

    async fn pulse_guide(
        &self,
        dir: skotiq_device::GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount
            .pulse_guide(dir, duration_ms)
            .await
            .map_err(|e| super::pulse_error(&self.device_id, e))
    }

    async fn set_tracking_rate(&self, rate: i32) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        let tracking_rate = match rate {
            0 => skotiq_device::TrackingRate::Sidereal,
            1 => skotiq_device::TrackingRate::Lunar,
            2 => skotiq_device::TrackingRate::Solar,
            3 => skotiq_device::TrackingRate::King,
            4 => skotiq_device::TrackingRate::Custom,
            _ => {
                return Err(DeviceOpError::invalid_parameter(format!(
                    "Invalid tracking rate: {}",
                    rate
                )))
            }
        };
        mount
            .set_tracking_rate(tracking_rate)
            .await
            .map_err(|e| Self::or_unsupported(e, self.protocol.no_tracking_rate_write))
    }

    async fn tracking_rate(&self) -> Result<i32, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        let rate = mount
            .get_tracking_rate()
            .await
            .map_err(|e| Self::or_unsupported(e, self.protocol.no_tracking_rate_read))?;
        // The discriminants are the ASCOM `DriveRates` numbers.
        Ok(rate as i32)
    }

    async fn site(&self) -> Result<MountSite, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        let site = mount
            .get_site()
            .await
            .map_err(|e| Self::or_unsupported(e, self.protocol.no_site_read))?;
        Ok(MountSite {
            latitude_deg: site.latitude_deg,
            longitude_deg: site.longitude_deg,
            elevation_m: site.elevation_m,
        })
    }

    async fn set_site(&self, site: MountSite) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount
            .set_site(skotiq_device::MountSiteInfo {
                latitude_deg: site.latitude_deg,
                longitude_deg: site.longitude_deg,
                elevation_m: site.elevation_m,
            })
            .await
            .map_err(|e| Self::or_unsupported(e, self.protocol.no_site_write))
    }

    async fn time(&self) -> Result<MountTimeInfo, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        let clock = mount
            .get_clock()
            .await
            .map_err(|e| Self::or_unsupported(e, self.protocol.no_clock_read))?;
        Ok(MountTimeInfo {
            utc_unix_seconds: clock.utc_unix_seconds,
            utc_offset_hours: clock.utc_offset_hours,
        })
    }

    async fn set_time(&self, time: MountTimeInfo) -> Result<(), DeviceOpError> {
        let mut mount = self.driver.write().await.ok_or_else(|| self.gone())?;
        mount
            .set_clock(skotiq_device::MountClock {
                utc_unix_seconds: time.utc_unix_seconds,
                utc_offset_hours: time.utc_offset_hours,
            })
            .await
            .map_err(|e| Self::or_unsupported(e, self.protocol.no_clock_write))
    }

    async fn site_capabilities(&self) -> Result<MountSiteCapabilities, DeviceOpError> {
        let mount = self.driver.read().await.ok_or_else(|| self.gone())?;
        let abilities = mount.site_abilities().await.map_err(DeviceOpError::from)?;
        Ok(MountSiteCapabilities {
            can_read_site: abilities.can_read_site,
            can_write_site: abilities.can_write_site,
            can_read_time: abilities.can_read_time,
            can_write_time: abilities.can_write_time,
        })
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        match self.protocol.described_by {
            Description::Alpaca => {
                return crate::device_capabilities::get_alpaca_capabilities(device_id).await
            }
            Description::Indi => {
                return crate::device_capabilities::get_indi_capabilities(device_id).await
            }
            Description::Driver => {}
        }
        let mount = self.driver.read().await.ok_or_else(|| {
            SkotiqError::hardware_error(
                device_id,
                format!("{} mount not connected", self.protocol.name),
            )
        })?;
        let tracking = mount.get_tracking().await.ok();
        let can_set_tracking = tracking.is_some();
        let can_park = mount.is_parked().await.is_ok();
        let can_abort_slew = mount.is_slewing().await.is_ok();
        Ok(DeviceCapabilities::Mount(MountCapabilities {
            can_slew: true,
            can_slew_async: true,
            can_sync: true,
            can_park,
            can_unpark: can_park,
            can_pulse_guide: true,
            can_set_tracking,
            can_abort_slew,
            can_find_home: mount.can_find_home().await.unwrap_or(false),
            can_set_park: mount.can_set_park().await.unwrap_or(false),
            is_equatorial: true,
            tracking,
            axis_count: 2,
            ..Default::default()
        }))
    }

    /// Drops a held driver, and with it the serial port, without sending the
    /// mount anything: `disconnect` sends a stop, and recovering a link must
    /// not halt a mount that may be slewing or tracking perfectly well.
    async fn release(&self) {
        if let Slot::Held(_) = self.driver {
            drop(self.driver.take().await);
        }
    }
}
