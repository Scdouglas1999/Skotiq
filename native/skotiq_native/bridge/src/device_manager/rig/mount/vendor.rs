//! A vendor (serial protocol) mount.
//!
//! The driver sits in a slot behind the device lock. A command holds the
//! lock for writing and a read for reading, for the whole operation, as the
//! mount map's lock was held before. An empty slot is a mount that was
//! disconnected or released: every operation then answers not connected.

use super::Mount;
use crate::device::*;
use crate::device_capabilities::{DeviceCapabilities, MountCapabilities};
use crate::device_manager::rig::{Exclusive, RigDriver};
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::mount_slew_with_timeout;
use async_trait::async_trait;
use skotiq_device::{DriverError, MountDriver};

pub(crate) struct VendorMount {
    device_id: String,
    driver: Exclusive<Option<Box<dyn MountDriver + Send + Sync>>>,
}

impl VendorMount {
    pub(crate) fn new(device_id: &str, driver: Box<dyn MountDriver + Send + Sync>) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Exclusive::new(Some(driver)),
        }
    }

    fn gone(&self) -> DeviceOpError {
        DeviceOpError::not_connected(Some(self.device_id.clone()), "Native mount not connected")
    }
}

#[async_trait]
impl RigDriver for VendorMount {
    async fn disconnect(&self) -> Result<(), DriverError> {
        match self.driver.write().await.take() {
            Some(mut mount) => mount.disconnect().await,
            None => Ok(()),
        }
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| {
            format!(
                "Native mount {} not registered in device manager",
                self.device_id
            )
        })?;
        if !mount.is_connected() {
            return Ok(false);
        }
        // A coordinate read, because it always crosses the wire. The
        // LX200 driver answers the tracking state from memory on most
        // firmware, so a mount that had gone silent still passed.
        mount
            .get_coordinates()
            .await
            .map(|_| true)
            .map_err(|e| format!("Native mount liveness probe failed: {}", e))
    }
}

#[async_trait]
impl Mount for VendorMount {
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
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
            tracing::error!("mount_slew Native error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn slew_alt_az(&self, _altitude: f64, _azimuth: f64) -> Result<(), DeviceOpError> {
        // Native mounts (SkyWatcher, iOptron, etc.) are equatorial; alt/az slew is not
        // natively supported. Return an error rather than silently failing.
        Err(DeviceOpError::unsupported(
            "Alt/Az slew is not supported for native serial mounts",
        ))
    }

    async fn abort(&self) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn stop(&self) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn move_axis(&self, _axis: i32, _rate: f64) -> Result<(), DeviceOpError> {
        tracing::warn!("mount_move_axis: Native SDK does not support mount axis movement");
        Err(DeviceOpError::unsupported(
            "Native SDK does not support mount axis movement",
        ))
    }

    async fn park(&self) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.park().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!("Failed to park native mount {}: {}", device_id, e),
                e,
            )
        })
    }

    async fn unpark(&self) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.unpark().await.map_err(DeviceOpError::from)
    }

    async fn find_home(&self) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.find_home().await.map_err(|e| {
            tracing::error!("mount_find_home native error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_find_home(&self) -> Result<bool, DeviceOpError> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        Ok(mount.can_find_home())
    }

    async fn set_park(&self) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.set_park().await.map_err(|e| {
            tracing::error!("mount_set_park native error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_set_park(&self) -> Result<bool, DeviceOpError> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        Ok(mount.can_set_park())
    }

    async fn can_park(&self) -> Result<bool, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        match mount.is_parked().await {
            Ok(_) => Ok(true),
            Err(skotiq_device::DriverError::NotSupported) => Ok(false),
            Err(e) => Err(DeviceOpError::hardware(
                Some(device_id.to_string()),
                format!(
                    "Failed to determine native mount park capability for {}: {}",
                    device_id, e
                ),
            )),
        }
    }

    async fn sync(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.sync_to_coordinates(ra, dec).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to sync native mount {} to RA={:.4} Dec={:.4}: {}",
                    device_id, ra, dec, e
                ),
                e,
            )
        })
    }

    async fn coordinates(&self) -> Result<(f64, f64), DeviceOpError> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        mount.get_coordinates().await.map_err(DeviceOpError::from)
    }

    async fn status(&self) -> Result<MountStatus, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        // Required fields propagate read failures — these are not optional.
        let (ra, dec) = mount.get_coordinates().await.map_err(DeviceOpError::from)?;
        let tracking = mount.get_tracking().await.map_err(DeviceOpError::from)?;
        let slewing = mount.is_slewing().await.map_err(DeviceOpError::from)?;
        let (parked, can_park, parked_readable) = match mount.is_parked().await {
            Ok(p) => (p, true, true),
            Err(skotiq_device::DriverError::NotSupported) => (false, false, false),
            Err(e) => {
                return Err(DeviceOpError::hardware(
                    Some(device_id.to_string()),
                    format!(
                        "Failed to read native mount parked state for {}: {}",
                        device_id, e
                    ),
                ));
            }
        };

        let mut availability = DeviceManager::mount_status_availability_map();
        if !parked_readable {
            // The `parked: false` above is fabricated, not observed
            // — record that so consumers can refuse to trust it
            // (`parked_from_status`). Only this Native arm launders
            // NotSupported into a bool; every other backend either
            // reads `parked` genuinely or propagates the error.
            availability.insert(
                mount_status_field::PARKED.to_string(),
                FieldAvailability::Unsupported,
            );
        }

        // get_side_of_pier on `MountDriver` returns Unknown rather than Err
        // for some unsupported mounts, so distinguish here:
        // Unknown → Unsupported availability; East/West → Available.
        let side_of_pier_opt = match mount.get_side_of_pier().await {
            Ok(skotiq_device::PierSide::Unknown) => {
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
                Some(DeviceManager::pier_side_from_native(other))
            }
            Err(skotiq_device::DriverError::NotSupported) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::SIDE_OF_PIER,
                    FieldAvailability::Unsupported,
                );
                None
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

        // Native drivers report Err(NotSupported) explicitly for alt/az and
        // sidereal time on protocols that lack them (e.g. LX200).
        let alt_az_pair = DeviceManager::availability_from_native_result(
            mount.get_alt_az().await,
            // Use ALTITUDE as primary key; AZIMUTH mirror is set below.
            mount_status_field::ALTITUDE,
            &mut availability,
        );
        // Mirror availability onto the AZIMUTH key — they share a single call.
        let alt_avail = availability
            .get(mount_status_field::ALTITUDE)
            .cloned()
            .unwrap_or(FieldAvailability::Available);
        DeviceManager::set_mount_availability(
            &mut availability,
            mount_status_field::AZIMUTH,
            alt_avail,
        );
        let (alt_opt, az_opt) = match alt_az_pair {
            Some((a, z)) => (Some(a), Some(z)),
            None => (None, None),
        };

        let sidereal_time_opt = DeviceManager::availability_from_native_result(
            mount.get_sidereal_time().await,
            mount_status_field::SIDEREAL_TIME,
            &mut availability,
        );

        // OnStep reports home in `:GU#`; drivers with no home
        // concept answer NotSupported and land as Unsupported here,
        // the same distinction the other driver types make.
        let at_home_opt = DeviceManager::availability_from_native_result(
            mount.at_home().await,
            mount_status_field::AT_HOME,
            &mut availability,
        );

        let tracking_rate_opt = DeviceManager::availability_from_native_result(
            mount.get_tracking_rate().await,
            mount_status_field::TRACKING_RATE,
            &mut availability,
        )
        .map(DeviceManager::tracking_rate_from_native);

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
            can_slew: mount.can_slew(),
            can_sync: mount.can_sync(),
            can_pulse_guide: mount.can_pulse_guide(),
            can_set_tracking_rate: mount.can_set_tracking_rate(),
            availability,
        })
    }

    async fn set_tracking(&self, enabled: bool) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount.set_tracking(enabled).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to set native mount {} tracking={}: {}",
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
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount
            .pulse_guide(dir, duration_ms)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn set_tracking_rate(&self, rate: i32) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        // Convert i32 rate to TrackingRate enum
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
            .map_err(DeviceOpError::from)
    }

    async fn tracking_rate(&self) -> Result<i32, DeviceOpError> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        let rate = mount
            .get_tracking_rate()
            .await
            .map_err(DeviceOpError::from)?;
        // Why: `TrackingRate` is a C-like enum
        // (Sidereal=0, Lunar=1, Solar=2, King=3); `as i32`
        // extracts the discriminant — SAFE narrowing.
        Ok(rate as i32)
    }

    async fn site(&self) -> Result<MountSite, DeviceOpError> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        let site = mount.get_site().await.map_err(DeviceOpError::from)?;
        Ok(MountSite {
            latitude_deg: site.latitude_deg,
            longitude_deg: site.longitude_deg,
            elevation_m: site.elevation_m,
        })
    }

    async fn set_site(&self, site: MountSite) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount
            .set_site(skotiq_device::MountSiteInfo {
                latitude_deg: site.latitude_deg,
                longitude_deg: site.longitude_deg,
                elevation_m: site.elevation_m,
            })
            .await
            .map_err(DeviceOpError::from)
    }

    async fn time(&self) -> Result<MountTimeInfo, DeviceOpError> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        let clock = mount.get_clock().await.map_err(DeviceOpError::from)?;
        Ok(MountTimeInfo {
            utc_unix_seconds: clock.utc_unix_seconds,
            utc_offset_hours: clock.utc_offset_hours,
        })
    }

    async fn set_time(&self, time: MountTimeInfo) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let mount = driver.as_mut().ok_or_else(|| self.gone())?;
        mount
            .set_clock(skotiq_device::MountClock {
                utc_unix_seconds: time.utc_unix_seconds,
                utc_offset_hours: time.utc_offset_hours,
            })
            .await
            .map_err(DeviceOpError::from)
    }

    /// The native trait defaults to NotSupported, so a serial protocol
    /// without site commands reports false by simply not implementing
    /// them. Probing is the only honest way to know.
    async fn site_capabilities(&self) -> Result<MountSiteCapabilities, DeviceOpError> {
        let driver = self.driver.read().await;
        let mount = driver.as_ref().ok_or_else(|| self.gone())?;
        let can_read_site = !matches!(
            mount.get_site().await,
            Err(skotiq_device::DriverError::NotSupported)
        );
        let can_read_time = !matches!(
            mount.get_clock().await,
            Err(skotiq_device::DriverError::NotSupported)
        );
        // Write support tracks read support in every native
        // driver: a protocol either has the site commands or
        // it does not.
        Ok(MountSiteCapabilities {
            can_read_site,
            can_write_site: can_read_site,
            can_read_time,
            can_write_time: can_read_time,
        })
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        let driver = self.driver.read().await;
        let mount = driver
            .as_ref()
            .ok_or_else(|| SkotiqError::hardware_error(device_id, "Native mount not connected"))?;
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
            can_find_home: mount.can_find_home(),
            can_set_park: mount.can_set_park(),
            is_equatorial: true,
            tracking,
            axis_count: 2,
            ..Default::default()
        }))
    }

    /// Drops the driver, and with it the serial port, without sending the
    /// mount anything: `disconnect` sends a stop, and recovering a link must
    /// not halt a mount that may be slewing or tracking perfectly well.
    async fn release(&self) {
        drop(self.driver.write().await.take());
    }
}
