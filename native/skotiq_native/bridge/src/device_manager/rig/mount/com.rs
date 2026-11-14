//! An ASCOM mount over COM.
//!
//! The wrapper sits behind its device lock, and every operation takes that
//! lock exactly as it took the wrapper's lock before: `read` or `write`, for
//! the same span of wrapper calls. Each wrapper call is one command on the
//! wrapper's queue, run by the STA worker.

use super::{pulse_error, Mount};
use crate::ascom_wrapper::mount::AscomMountWrapper;
use crate::device::{
    mount_status_field, FieldAvailability, MountSite, MountSiteCapabilities, MountStatus,
    MountTimeInfo,
};
use crate::device_capabilities::types::DeviceCapabilities;
use crate::device_manager::ops::mount::site::{ole_to_unix_seconds, unix_seconds_to_ole};
use crate::device_manager::rig::{Exclusive, RigDriver};
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{mount_slew_with_timeout, with_timeout_str, Timeouts};
use async_trait::async_trait;
use skotiq_device::ascom::telescope::wait_for_pulse_end;
use skotiq_device::{DeviceDriver, DriverError, MountDriver};
use tokio::time::Instant;
use tracing::warn;

pub(crate) struct ComMount {
    device_id: String,
    mount: Exclusive<AscomMountWrapper>,
}

impl ComMount {
    pub(crate) fn new(device_id: &str, mount: AscomMountWrapper) -> Self {
        Self {
            device_id: device_id.to_string(),
            mount: Exclusive::new(mount),
        }
    }
}

#[async_trait]
impl RigDriver for ComMount {
    async fn disconnect(&self) -> Result<(), DriverError> {
        self.mount.write().await.disconnect().await
    }

    /// A light COM command through the worker, so the answer says the mount
    /// responds and not merely that a flag is set.
    async fn heartbeat(&self) -> Result<bool, String> {
        let device_id = self.device_id.as_str();
        let mount_guard = self.mount.read().await;
        match mount_guard.get_tracking().await {
            Ok(_) => {
                tracing::trace!("ASCOM mount {} heartbeat: healthy", device_id,);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("ASCOM mount {} heartbeat failed: {:?}", device_id, e);
                Ok(false)
            }
        }
    }
}

#[async_trait]
impl Mount for ComMount {
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount_slew_with_timeout(
            async {
                mount
                    .slew_to_coordinates(ra, dec)
                    .await
                    .map_err(|e| SkotiqError::from(DeviceOpError::from(e)))
            },
            device_id,
        )
        .await
        .map_err(|e| {
            tracing::error!("mount_slew ASCOM error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn slew_alt_az(&self, altitude: f64, azimuth: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let mount = mount.write().await;
        with_timeout_str(
            async {
                mount
                    .slew_to_alt_az(altitude, azimuth)
                    .await
                    .map_err(|e| e.to_string())
            },
            Timeouts::long_slew(),
            device_id,
            "slew_to_alt_az",
        )
        .await
        .map_err(|e| {
            tracing::error!("mount_slew_alt_az ASCOM error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn abort(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn move_axis(&self, axis: i32, rate: f64) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount.move_axis(axis, rate).await.map_err(|e| {
            tracing::error!("mount_move_axis ASCOM error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn park(&self) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount.park().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!("Failed to park ASCOM mount {}: {}", device_id, e),
                e,
            )
        })
    }

    async fn unpark(&self) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount.unpark().await.map_err(DeviceOpError::from)?;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
        loop {
            match mount.is_parked().await {
                Ok(false) => return Ok(()),
                Ok(true) => {}
                Err(error) => {
                    return Err(DeviceOpError::hardware(
                        Some(device_id.to_string()),
                        format!(
                            "ASCOM mount {} accepted Unpark but its parked-state readback failed: {}",
                            device_id, error
                        ),
                    ));
                }
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(DeviceOpError::hardware(
                    Some(device_id.to_string()),
                    format!(
                        "ASCOM mount {} did not report unparked within 15s",
                        device_id
                    ),
                ));
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    }

    async fn find_home(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        // `find_home` takes `&self`: the wrapper's COM worker
        // serializes the call, so a read guard is all the map
        // needs, and status reads are not locked out for the
        // length of the motion.
        let mount = mount.read().await;
        mount.find_home().await.map_err(|e| {
            tracing::error!("mount_find_home ASCOM error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_find_home(&self) -> Result<bool, DeviceOpError> {
        let mount = &self.mount;
        let mount = mount.read().await;
        mount
            .get_capabilities()
            .await
            .map(|caps| caps.can_find_home)
            .map_err(DeviceOpError::from)
    }

    async fn set_park(&self) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        // `set_park` takes `&self`: the wrapper's COM worker
        // serializes the call, so a read guard is enough.
        let mount = mount.read().await;
        mount.set_park().await.map_err(|e| {
            tracing::error!("mount_set_park ASCOM error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_set_park(&self) -> Result<bool, DeviceOpError> {
        let mount = &self.mount;
        let mount = mount.read().await;
        mount
            .get_capabilities()
            .await
            .map(|caps| caps.can_set_park)
            .map_err(DeviceOpError::from)
    }

    async fn sync(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount.sync_to_coordinates(ra, dec).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to sync ASCOM mount {} to RA={:.4} Dec={:.4}: {}",
                    device_id, ra, dec, e
                ),
                e,
            )
        })
    }

    async fn coordinates(&self) -> Result<(f64, f64), DeviceOpError> {
        let mount = &self.mount;
        let mount = mount.read().await;
        mount.get_coordinates().await.map_err(DeviceOpError::from)
    }

    async fn status(&self) -> Result<MountStatus, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let mount = mount.read().await;

        // Required fields propagate read failures — these are not optional.
        let (ra, dec) = mount.get_coordinates().await.map_err(DeviceOpError::from)?;
        let tracking = mount.get_tracking().await.map_err(DeviceOpError::from)?;
        let slewing = mount.is_slewing().await.map_err(DeviceOpError::from)?;
        let parked = mount.is_parked().await.map_err(DeviceOpError::from)?;

        let mut availability = DeviceManager::mount_status_availability_map();

        // Optional fields: the ASCOM wrapper currently does not surface a
        // distinct "not supported" error so any failure is recorded as Error.
        let (alt_opt, az_opt) = match mount.get_alt_az().await {
            Ok((a, z)) => (Some(a), Some(z)),
            Err(e) => {
                let msg = e.to_string();
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::ALTITUDE,
                    FieldAvailability::Error(msg.clone()),
                );
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::AZIMUTH,
                    FieldAvailability::Error(msg),
                );
                (None, None)
            }
        };
        if alt_opt.is_some() {
            DeviceManager::set_mount_availability(
                &mut availability,
                mount_status_field::ALTITUDE,
                FieldAvailability::Available,
            );
            DeviceManager::set_mount_availability(
                &mut availability,
                mount_status_field::AZIMUTH,
                FieldAvailability::Available,
            );
        }

        let side_of_pier_opt = DeviceManager::availability_from_native_result(
            mount.get_side_of_pier().await,
            mount_status_field::SIDE_OF_PIER,
            &mut availability,
        )
        .map(DeviceManager::pier_side_from_native);

        let sidereal_time_opt = DeviceManager::availability_from_native_result(
            mount.get_sidereal_time().await,
            mount_status_field::SIDEREAL_TIME,
            &mut availability,
        );

        let at_home_opt = DeviceManager::availability_from_native_result(
            mount.at_home().await,
            mount_status_field::AT_HOME,
            &mut availability,
        );

        let capabilities = match mount.get_capabilities().await {
            Ok(caps) => caps,
            Err(err) => {
                warn!(
                    "Failed to query ASCOM mount capabilities for {}: {}. Marking capabilities unavailable.",
                    device_id, err
                );
                crate::ascom_wrapper::mount::AscomMountCapabilities::default()
            }
        };

        let (tracking_rate_opt, can_set_tracking_rate) = match mount.get_tracking_rate().await {
            Ok(rate) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::TRACKING_RATE,
                    FieldAvailability::Available,
                );
                (Some(DeviceManager::tracking_rate_from_native(rate)), true)
            }
            Err(skotiq_device::DriverError::NotSupported) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::TRACKING_RATE,
                    FieldAvailability::Unsupported,
                );
                (None, false)
            }
            Err(err) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::TRACKING_RATE,
                    FieldAvailability::Error(err.to_string()),
                );
                (None, false)
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
            can_park: capabilities.can_park,
            can_slew: capabilities.can_slew,
            can_sync: capabilities.can_sync,
            can_pulse_guide: capabilities.can_pulse_guide,
            can_set_tracking_rate,
            availability,
        })
    }

    async fn set_tracking(&self, enabled: bool) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount.set_tracking(enabled).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to set ASCOM mount {} tracking={}: {}",
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
        let started = Instant::now();
        mount
            .write()
            .await
            .pulse_guide(dir, duration_ms)
            .await
            .map_err(DeviceOpError::from)?;
        wait_for_pulse_end(started, duration_ms, || async move {
            mount.read().await.is_pulse_guiding().await
        })
        .await
        .map_err(|e| pulse_error(device_id, e))
    }

    async fn set_tracking_rate(&self, rate: i32) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        let mut mount = mount.write().await;
        mount
            .set_tracking_rate_raw(rate)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn site(&self) -> Result<MountSite, DeviceOpError> {
        let mount = &self.mount;
        let mount = mount.read().await;
        let (latitude_deg, longitude_deg, elevation_m) =
            mount.get_site().await.map_err(DeviceOpError::from)?;
        Ok(MountSite {
            latitude_deg,
            longitude_deg,
            elevation_m,
        })
    }

    async fn set_site(&self, site: MountSite) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        let mount = mount.write().await;
        // Elevation tolerance lives inside the wrapper's worker,
        // where the three property writes happen on the one COM
        // thread that owns the driver.
        mount
            .set_site(site.latitude_deg, site.longitude_deg, site.elevation_m)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn time(&self) -> Result<MountTimeInfo, DeviceOpError> {
        let mount = &self.mount;
        let mount = mount.read().await;
        let ole = mount.get_utc_date().await.map_err(DeviceOpError::from)?;
        Ok(MountTimeInfo {
            utc_unix_seconds: ole_to_unix_seconds(ole),
            // ASCOM's UTCDate is UTC by definition; the mount's
            // local offset is not exposed, so report zero rather
            // than inventing one.
            utc_offset_hours: 0.0,
        })
    }

    async fn set_time(&self, time: MountTimeInfo) -> Result<(), DeviceOpError> {
        let mount = &self.mount;
        let mount = mount.write().await;
        mount
            .set_utc_date(unix_seconds_to_ole(time.utc_unix_seconds))
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

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        let ascom_caps = self
            .mount
            .read()
            .await
            .get_capabilities()
            .await
            .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
        Ok(DeviceCapabilities::Mount(
            crate::device_capabilities::ascom::mount_capabilities_from_ascom(ascom_caps),
        ))
    }
}
