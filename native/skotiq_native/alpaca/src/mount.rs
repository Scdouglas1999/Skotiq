//! An Alpaca telescope as a mount driver.
//!
//! The client holds no state and takes no lock: every operation is its own
//! HTTP requests, so an abort or a status read never waits for another
//! operation of this mount.

use crate::{AlpacaError, AlpacaTelescope};
use async_trait::async_trait;
use skotiq_device::ascom::telescope::{unix_seconds_of_utc_date, utc_date, wait_for_pulse_end};
use skotiq_device::ascom::DriveRate;
use skotiq_device::{
    DeviceDriver, DriverError, GuideDirection, MountClock, MountDescription, MountDriver,
    MountReadings, MountSiteAbilities, MountSiteInfo, PierSide, TrackingRate, Vendor,
};
use std::sync::Arc;
use tokio::time::Instant;

/// A connected Alpaca telescope. A clone is the same mount.
#[derive(Clone)]
pub struct AlpacaMount {
    telescope: Arc<AlpacaTelescope>,
    id: String,
}

impl AlpacaMount {
    /// `telescope` is connected.
    pub fn new(telescope: AlpacaTelescope) -> Self {
        let id = format!(
            "alpaca:{}:telescope:{}",
            telescope.base_url(),
            telescope.device_number()
        );
        Self {
            telescope: Arc::new(telescope),
            id,
        }
    }

    pub fn telescope(&self) -> &AlpacaTelescope {
        &self.telescope
    }
}

impl std::fmt::Debug for AlpacaMount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("AlpacaMount").field(&self.id).finish()
    }
}

fn tracking_rate(rate: DriveRate) -> TrackingRate {
    match rate {
        DriveRate::Sidereal => TrackingRate::Sidereal,
        DriveRate::Lunar => TrackingRate::Lunar,
        DriveRate::Solar => TrackingRate::Solar,
        DriveRate::King => TrackingRate::King,
    }
}

/// One optional reading: only its kind is kept, which tells a reading the
/// telescope does not have from one that failed.
fn reading<T>(read: Result<T, AlpacaError>) -> Result<T, DriverError> {
    read.map_err(DriverError::from)
}

/// A failed operation in the server's own words. Whoever shows it reads its
/// kind from the Alpaca error inside.
fn own(error: AlpacaError) -> DriverError {
    DriverError::Backend(Box::new(error))
}

#[async_trait]
impl DeviceDriver for AlpacaMount {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.id
    }

    fn vendor(&self) -> Vendor {
        Vendor::Ascom
    }

    /// A value of this type is a telescope that was connected;
    /// [`MountDriver::heartbeat`] asks the server whether it still is.
    fn is_connected(&self) -> bool {
        true
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        self.telescope.connect().await.map_err(own)
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        self.telescope.disconnect().await.map_err(own)
    }
}

#[async_trait]
impl MountDriver for AlpacaMount {
    /// One quick, unretried read. A server that does not answer is a mount
    /// that is not connected, not a failed probe.
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        match self.telescope.heartbeat().await {
            Ok(rtt_ms) => {
                tracing::trace!("Alpaca mount {} heartbeat: {}ms RTT", self.id, rtt_ms);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("Alpaca mount {} heartbeat failed: {}", self.id, e);
                Ok(false)
            }
        }
    }

    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        self.telescope
            .slew_to_coordinates_async(ra_hours, dec_degrees)
            .await
            .map_err(own)
    }

    async fn slew_to_alt_az(
        &mut self,
        altitude_deg: f64,
        azimuth_deg: f64,
    ) -> Result<(), DriverError> {
        self.telescope
            .slew_to_alt_az_async(altitude_deg, azimuth_deg)
            .await
            .map_err(own)
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        let ra = self.telescope.right_ascension().await.map_err(own)?;
        let dec = self.telescope.declination().await.map_err(own)?;
        Ok((ra, dec))
    }

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        self.telescope
            .sync_to_coordinates(ra_hours, dec_degrees)
            .await
            .map_err(own)
    }

    async fn park(&mut self) -> Result<(), DriverError> {
        self.telescope.park().await.map_err(own)
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        self.telescope.unpark().await.map_err(own)
    }

    async fn is_slewing(&self) -> Result<bool, DriverError> {
        self.telescope.slewing().await.map_err(own)
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        self.telescope.at_park().await.map_err(own)
    }

    async fn can_park(&self) -> Result<bool, DriverError> {
        self.telescope.can_park().await.map_err(own)
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        let direction = match direction {
            GuideDirection::North => 0,
            GuideDirection::South => 1,
            GuideDirection::East => 2,
            GuideDirection::West => 3,
        };
        // `PulseGuide` takes a signed 32-bit count of milliseconds.
        let duration = i32::try_from(duration_ms).map_err(|_| {
            DriverError::InvalidParameter(format!(
                "Alpaca pulse_guide duration {}ms exceeds i32::MAX",
                duration_ms
            ))
        })?;
        let started = Instant::now();
        self.telescope
            .pulse_guide(direction, duration)
            .await
            .map_err(own)?;
        wait_for_pulse_end(started, duration_ms, || self.telescope.is_pulse_guiding()).await
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        self.telescope.abort_slew().await.map_err(own)
    }

    async fn move_axis(&mut self, axis: i32, rate: f64) -> Result<(), DriverError> {
        self.telescope.move_axis(axis, rate).await.map_err(own)
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        self.telescope.set_tracking(enabled).await.map_err(own)
    }

    async fn get_tracking(&self) -> Result<bool, DriverError> {
        self.telescope.tracking().await.map_err(own)
    }

    /// `DriveRates` has no custom rate: a custom rate is set as offsets.
    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError> {
        let rate = match rate {
            TrackingRate::Sidereal => DriveRate::Sidereal,
            TrackingRate::Lunar => DriveRate::Lunar,
            TrackingRate::Solar => DriveRate::Solar,
            TrackingRate::King => DriveRate::King,
            TrackingRate::Custom => return Err(DriverError::NotSupported),
        };
        self.telescope.set_tracking_rate(rate).await.map_err(own)
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        self.telescope
            .tracking_rate()
            .await
            .map(tracking_rate)
            .map_err(own)
    }

    /// `TrackingRates` lists the rates `TrackingRate` takes.
    async fn tracking_rates(&self) -> Vec<TrackingRate> {
        self.telescope
            .tracking_rates()
            .await
            .unwrap_or_default()
            .into_iter()
            .map(tracking_rate)
            .collect()
    }

    async fn can_slew(&self) -> bool {
        self.telescope.can_slew().await.unwrap_or(false)
    }

    async fn can_sync(&self) -> bool {
        self.telescope.can_sync().await.unwrap_or(false)
    }

    async fn can_pulse_guide(&self) -> bool {
        self.telescope.can_pulse_guide().await.unwrap_or(false)
    }

    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        self.telescope.side_of_pier().await.map_err(own)
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        let altitude = self.telescope.altitude().await.map_err(own)?;
        let azimuth = self.telescope.azimuth().await.map_err(own)?;
        Ok((altitude, azimuth))
    }

    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        self.telescope.sidereal_time().await.map_err(own)
    }

    async fn status(&self) -> Result<MountReadings, DriverError> {
        let mount = &self.telescope;
        let right_ascension = mount.right_ascension().await.map_err(own)?;
        let declination = mount.declination().await.map_err(own)?;
        let tracking = mount.tracking().await.map_err(own)?;
        let slewing = mount.slewing().await.map_err(own)?;
        let parked = mount.at_park().await.map_err(own)?;

        let altitude = reading(mount.altitude().await);
        let azimuth = reading(mount.azimuth().await);
        let at_home = reading(mount.at_home().await);
        let sidereal_time = reading(mount.sidereal_time().await);
        let side_of_pier = reading(mount.side_of_pier().await);

        let (can_park, can_slew, can_sync, can_pulse_guide) = match mount.get_capabilities().await {
            Ok(caps) => (
                caps.can_park,
                caps.can_slew,
                caps.can_sync,
                caps.can_pulse_guide,
            ),
            Err(e) => {
                tracing::warn!(
                    "Failed to query Alpaca mount capabilities for {}: {}. Marking capabilities unsupported.",
                    self.id,
                    e
                );
                (false, false, false, false)
            }
        };
        let can_set_tracking_rate = !self.tracking_rates().await.is_empty();
        let tracking_rate = reading(mount.tracking_rate().await).map(tracking_rate);

        Ok(MountReadings {
            right_ascension,
            declination,
            tracking,
            slewing,
            parked: Some(parked),
            at_home,
            side_of_pier,
            altitude,
            azimuth,
            sidereal_time,
            tracking_rate,
            can_park,
            can_slew,
            can_sync,
            can_pulse_guide,
            can_set_tracking_rate,
        })
    }

    async fn get_site(&self) -> Result<MountSiteInfo, DriverError> {
        let latitude_deg = self.telescope.site_latitude().await.map_err(own)?;
        let longitude_deg = self.telescope.site_longitude().await.map_err(own)?;
        Ok(MountSiteInfo {
            latitude_deg,
            longitude_deg,
            elevation_m: self.telescope.site_elevation().await.ok(),
        })
    }

    async fn set_site(&mut self, site: MountSiteInfo) -> Result<(), DriverError> {
        self.telescope
            .set_site_latitude(site.latitude_deg)
            .await
            .map_err(own)?;
        self.telescope
            .set_site_longitude(site.longitude_deg)
            .await
            .map_err(own)?;
        if let Some(elevation) = site.elevation_m {
            if let Err(e) = self.telescope.set_site_elevation(elevation).await {
                tracing::warn!(
                    "Mount {} accepted lat/lon but refused elevation: {}",
                    self.id,
                    e
                );
            }
        }
        Ok(())
    }

    /// `UTCDate` is UTC: the mount has no offset of its own to report.
    async fn get_clock(&self) -> Result<MountClock, DriverError> {
        let iso = self.telescope.utc_date().await.map_err(own)?;
        Ok(MountClock {
            utc_unix_seconds: unix_seconds_of_utc_date(&iso)?,
            utc_offset_hours: 0.0,
        })
    }

    async fn set_clock(&mut self, clock: MountClock) -> Result<(), DriverError> {
        self.telescope
            .set_utc_date(&utc_date(clock.utc_unix_seconds)?)
            .await
            .map_err(own)
    }

    /// `ITelescope` has the site and the clock as members.
    async fn site_abilities(&self) -> Result<MountSiteAbilities, DriverError> {
        Ok(MountSiteAbilities {
            can_read_site: true,
            can_write_site: true,
            can_read_time: true,
            can_write_time: true,
        })
    }

    async fn can_find_home(&self) -> Result<bool, DriverError> {
        self.telescope.can_find_home().await.map_err(own)
    }

    /// Every `CanXxx` member is optional: a server answers `NotImplemented`
    /// for a feature the mount lacks, so an unanswered one reads as absent.
    /// ASCOM has no pulse length limits and no axis count.
    async fn describe(&self) -> MountDescription {
        let mount = &self.telescope;
        MountDescription {
            can_slew: mount.can_slew().await.unwrap_or(false),
            can_slew_async: mount.can_slew_async().await.unwrap_or(false),
            can_sync: mount.can_sync().await.unwrap_or(false),
            can_park: mount.can_park().await.unwrap_or(false),
            can_unpark: mount.can_unpark().await.unwrap_or(false),
            can_set_park: mount.can_set_park().await.unwrap_or(false),
            can_find_home: mount.can_find_home().await.unwrap_or(false),
            can_pulse_guide: mount.can_pulse_guide().await.unwrap_or(false),
            can_set_tracking: mount.can_set_tracking().await.unwrap_or(false),
            tracking_rates: self.tracking_rates().await,
            // An unreadable AlignmentMode is not taken for equatorial.
            is_equatorial: mount
                .alignment_mode()
                .await
                .is_ok_and(|mode| crate::AlignmentMode::from(mode).is_equatorial()),
            can_abort_slew: true,
            axis_count: 2,
            ..MountDescription::default()
        }
    }

    async fn find_home(&mut self) -> Result<(), DriverError> {
        self.telescope.find_home().await.map_err(own)
    }

    async fn at_home(&self) -> Result<bool, DriverError> {
        self.telescope.at_home().await.map_err(own)
    }

    async fn can_set_park(&self) -> Result<bool, DriverError> {
        self.telescope.can_set_park().await.map_err(own)
    }

    async fn set_park(&mut self) -> Result<(), DriverError> {
        self.telescope.set_park().await.map_err(own)
    }
}
