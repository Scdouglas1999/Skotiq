//! An Alpaca mount. The client holds no state and takes no lock: every
//! operation is its own HTTP requests, so an abort or a status read never
//! waits for another operation of this mount.

use super::{wait_for_ascom_pulse_end, Mount};
use crate::device::*;
use crate::device_capabilities::DeviceCapabilities;
use crate::device_manager::ops::mount::site::alpaca_utc_date;
use crate::device_manager::rig::RigDriver;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{mount_slew_with_timeout, with_timeout_str, Timeouts};
use async_trait::async_trait;
use skotiq_device::DriverError;
use std::sync::Arc;
use tokio::time::Instant;
use tracing::warn;

pub(crate) struct AlpacaMount {
    device_id: String,
    mount: Arc<skotiq_alpaca::AlpacaTelescope>,
}

impl AlpacaMount {
    pub(crate) fn new(device_id: &str, mount: skotiq_alpaca::AlpacaTelescope) -> Self {
        Self {
            device_id: device_id.to_string(),
            mount: Arc::new(mount),
        }
    }
}

#[async_trait]
impl RigDriver for AlpacaMount {
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(self.mount.disconnect().await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let device_id = self.device_id.as_str();
        match self.mount.heartbeat().await {
            Ok(rtt_ms) => {
                tracing::trace!("Alpaca mount {} heartbeat: {}ms RTT", device_id, rtt_ms);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("Alpaca mount {} heartbeat failed: {}", device_id, e);
                Ok(false)
            }
        }
    }
}

#[async_trait]
impl Mount for AlpacaMount {
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        tracing::debug!("mount_slew: Calling Alpaca slew_to_coordinates_async");
        mount_slew_with_timeout(
            async {
                mount
                    .slew_to_coordinates_async(ra, dec)
                    .await
                    .map_err(|e| SkotiqError::from(DeviceOpError::from(e)))
            },
            device_id,
        )
        .await
        .map_err(|e| {
            tracing::error!("mount_slew Alpaca error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn slew_alt_az(&self, altitude: f64, azimuth: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        with_timeout_str(
            async {
                mount
                    .slew_to_alt_az_async(altitude, azimuth)
                    .await
                    .map_err(|e| e.to_string())
            },
            Timeouts::long_slew(),
            device_id,
            "slew_to_alt_az",
        )
        .await
        .map_err(|e| {
            tracing::error!("mount_slew_alt_az Alpaca error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn abort(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn stop(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn move_axis(&self, axis: i32, rate: f64) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        tracing::debug!("mount_move_axis: Calling Alpaca move_axis");
        mount.move_axis(axis, rate).await.map_err(|e| {
            tracing::error!("mount_move_axis Alpaca error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn park(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount.park().await.map_err(DeviceOpError::from)
    }

    async fn unpark(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount.unpark().await.map_err(DeviceOpError::from)
    }

    async fn find_home(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount.find_home().await.map_err(|e| {
            tracing::error!("mount_find_home Alpaca error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_find_home(&self) -> Result<bool, DeviceOpError> {
        let mount = &self.mount;
        mount.can_find_home().await.map_err(DeviceOpError::from)
    }

    async fn set_park(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount.set_park().await.map_err(|e| {
            tracing::error!("mount_set_park Alpaca error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_set_park(&self) -> Result<bool, DeviceOpError> {
        let mount = &self.mount;
        mount.can_set_park().await.map_err(DeviceOpError::from)
    }

    async fn can_park(&self) -> Result<bool, DeviceOpError> {
        let mount = &self.mount;
        mount.can_park().await.map_err(DeviceOpError::from)
    }

    async fn sync(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount
            .sync_to_coordinates(ra, dec)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn coordinates(&self) -> Result<(f64, f64), DeviceOpError> {
        let mount = &self.mount;
        let ra = mount.right_ascension().await.map_err(DeviceOpError::from)?;
        let dec = mount.declination().await.map_err(DeviceOpError::from)?;
        Ok((ra, dec))
    }

    async fn status(&self) -> Result<MountStatus, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        // Required fields propagate read failures.
        let ra = mount.right_ascension().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!("Failed to read Alpaca mount RA for {}: {}", device_id, e),
                e,
            )
        })?;
        let dec = mount.declination().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!("Failed to read Alpaca mount Dec for {}: {}", device_id, e),
                e,
            )
        })?;
        let tracking = mount.tracking().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read Alpaca mount tracking for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;
        let slewing = mount.slewing().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read Alpaca mount slewing for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;
        let parked = mount.at_park().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read Alpaca mount at_park for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;

        let mut availability = DeviceManager::mount_status_availability_map();

        // Alpaca returns Result<_, String>; we cannot reliably distinguish
        // "PropertyNotImplemented" from a transient HTTP failure without
        // parsing the error message. Treat all failures as Error so callers
        // see the underlying reason verbatim. UI can match on the prefix
        // "PropertyNotImplemented" if it wants to render Unsupported.
        let alt_opt = DeviceManager::availability_from_string_result(
            mount.altitude().await.map_err(|e| e.to_string()),
            mount_status_field::ALTITUDE,
            &mut availability,
        );
        let az_opt = DeviceManager::availability_from_string_result(
            mount.azimuth().await.map_err(|e| e.to_string()),
            mount_status_field::AZIMUTH,
            &mut availability,
        );
        let at_home_opt = DeviceManager::availability_from_string_result(
            mount.at_home().await.map_err(|e| e.to_string()),
            mount_status_field::AT_HOME,
            &mut availability,
        );
        let sidereal_time_opt = DeviceManager::availability_from_string_result(
            mount.sidereal_time().await.map_err(|e| e.to_string()),
            mount_status_field::SIDEREAL_TIME,
            &mut availability,
        );

        let side_of_pier_opt = match mount.side_of_pier().await {
            Ok(skotiq_alpaca::PierSide::Unknown) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::SIDE_OF_PIER,
                    FieldAvailability::Unsupported,
                );
                None
            }
            Ok(other) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::SIDE_OF_PIER,
                    FieldAvailability::Available,
                );
                Some(match other {
                    skotiq_alpaca::PierSide::East => crate::device::PierSide::East,
                    skotiq_alpaca::PierSide::West => crate::device::PierSide::West,
                    skotiq_alpaca::PierSide::Unknown => crate::device::PierSide::Unknown,
                })
            }
            Err(e) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::SIDE_OF_PIER,
                    FieldAvailability::Error(e.to_string()),
                );
                None
            }
        };

        let (can_park, can_slew, can_sync, can_pulse_guide) = match mount.get_capabilities().await {
            Ok(caps) => (
                caps.can_park,
                caps.can_slew,
                caps.can_sync,
                caps.can_pulse_guide,
            ),
            Err(e) => {
                warn!(
                        "Failed to query Alpaca mount capabilities for {}: {}. Marking capabilities unsupported.",
                        device_id, e
                    );
                (false, false, false, false)
            }
        };
        // CanSetTracking governs the boolean Tracking property.
        // Rate mutability is advertised by TelescopeRates.
        let can_set_tracking_rate = mount
            .tracking_rates()
            .await
            .map(|rates| !rates.is_empty())
            .unwrap_or(false);

        let tracking_rate_opt = match mount.tracking_rate().await {
            Ok(rate) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::TRACKING_RATE,
                    FieldAvailability::Available,
                );
                Some(match rate {
                    skotiq_alpaca::DriveRate::Sidereal => TrackingRate::Sidereal,
                    skotiq_alpaca::DriveRate::Lunar => TrackingRate::Lunar,
                    skotiq_alpaca::DriveRate::Solar => TrackingRate::Solar,
                    skotiq_alpaca::DriveRate::King => TrackingRate::King,
                })
            }
            Err(e) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::TRACKING_RATE,
                    FieldAvailability::Error(e.to_string()),
                );
                None
            }
        };

        Ok(MountStatus {
            connected: true,
            tracking,
            slewing,
            parked,
            at_home: at_home_opt,
            side_of_pier: side_of_pier_opt,
            right_ascension: ra,
            declination: dec,
            altitude: alt_opt,
            azimuth: az_opt,
            sidereal_time: sidereal_time_opt,
            tracking_rate: tracking_rate_opt,
            can_park,
            can_slew,
            can_sync,
            can_pulse_guide,
            can_set_tracking_rate,
            availability,
        })
    }

    async fn set_tracking(&self, enabled: bool) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        mount.set_tracking(enabled).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to set Alpaca mount {} tracking={}: {}",
                    device_id, enabled, e
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
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let alpaca_dir = match dir {
            skotiq_device::GuideDirection::North => 0,
            skotiq_device::GuideDirection::South => 1,
            skotiq_device::GuideDirection::East => 2,
            skotiq_device::GuideDirection::West => 3,
        };
        // Why: Alpaca PulseGuide takes i32 ms;
        // u32 > i32::MAX is ~24.8 days of pulse which is
        // physically impossible for guiding. Saturating
        // try_from rejects the impossible-but-defined case.
        let duration_i32 = i32::try_from(duration_ms).map_err(|_| {
            DeviceOpError::invalid_parameter(format!(
                "Alpaca pulse_guide duration {}ms exceeds i32::MAX",
                duration_ms
            ))
        })?;
        let started = Instant::now();
        mount
            .pulse_guide(alpaca_dir, duration_i32)
            .await
            .map_err(DeviceOpError::from)?;
        wait_for_ascom_pulse_end(device_id, started, duration_ms, || mount.is_pulse_guiding()).await
    }

    async fn set_tracking_rate(&self, _rate: i32) -> Result<(), DeviceOpError> {
        Err(DeviceOpError::unsupported(
            "Setting tracking rate is not supported by this driver type",
        ))
    }

    async fn tracking_rate(&self) -> Result<i32, DeviceOpError> {
        Err(DeviceOpError::unsupported(
            "Getting tracking rate is not supported by this driver type",
        ))
    }

    async fn site(&self) -> Result<MountSite, DeviceOpError> {
        let mount = &self.mount;
        let latitude_deg = mount.site_latitude().await.map_err(DeviceOpError::from)?;
        let longitude_deg = mount.site_longitude().await.map_err(DeviceOpError::from)?;
        Ok(MountSite {
            latitude_deg,
            longitude_deg,
            elevation_m: mount.site_elevation().await.ok(),
        })
    }

    async fn set_site(&self, site: MountSite) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        mount
            .set_site_latitude(site.latitude_deg)
            .await
            .map_err(DeviceOpError::from)?;
        mount
            .set_site_longitude(site.longitude_deg)
            .await
            .map_err(DeviceOpError::from)?;
        if let Some(elevation) = site.elevation_m {
            if let Err(e) = mount.set_site_elevation(elevation).await {
                tracing::warn!(
                    "Mount {} accepted lat/lon but refused elevation: {}",
                    device_id,
                    e
                );
            }
        }
        Ok(())
    }

    async fn time(&self) -> Result<MountTimeInfo, DeviceOpError> {
        let mount = &self.mount;
        let iso = mount.utc_date().await.map_err(DeviceOpError::from)?;
        let parsed = chrono::DateTime::parse_from_rfc3339(&iso)
            .map(|d| d.timestamp())
            .or_else(|_| {
                chrono::NaiveDateTime::parse_from_str(&iso, "%Y-%m-%dT%H:%M:%S%.f")
                    .map(|d| d.and_utc().timestamp())
            })
            .map_err(|e| DeviceOpError::from(format!("Unparseable Alpaca utcdate {iso:?}: {e}")))?;
        Ok(MountTimeInfo {
            utc_unix_seconds: parsed,
            utc_offset_hours: 0.0,
        })
    }

    async fn set_time(&self, time: MountTimeInfo) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        mount
            .set_utc_date(&alpaca_utc_date(time.utc_unix_seconds)?)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn site_capabilities(&self) -> Result<MountSiteCapabilities, DeviceOpError> {
        Ok(MountSiteCapabilities {
            can_read_site: true,
            can_write_site: true,
            can_read_time: true,
            can_write_time: true,
        })
    }

    async fn capabilities(&self, _device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        Ok(DeviceCapabilities::Mount(
            crate::device_capabilities::alpaca_mount_capabilities(&self.mount).await,
        ))
    }
}
