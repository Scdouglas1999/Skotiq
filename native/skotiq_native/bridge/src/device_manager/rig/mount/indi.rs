//! An INDI mount on its server's shared connection.

use super::Mount;
use crate::device::*;
use crate::device_capabilities::DeviceCapabilities;
use crate::device_manager::ops::mount::slew::stop_failure_detail;
use crate::device_manager::rig::RigDriver;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{mount_slew_with_timeout, with_timeout_str, Timeouts};
use async_trait::async_trait;
use skotiq_device::DriverError;
use skotiq_indi::names as indi;
use std::sync::Arc;
use tokio::sync::RwLock;

pub(crate) struct IndiMountHandle {
    device_id: String,
    client: Arc<RwLock<skotiq_indi::IndiClient>>,
    device_name: String,
}

impl IndiMountHandle {
    pub(crate) fn new(
        device_id: &str,
        client: Arc<RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        Self {
            device_id: device_id.to_string(),
            client,
            device_name: device_name.to_string(),
        }
    }
}

#[async_trait]
impl RigDriver for IndiMountHandle {
    /// Waits for the driver to confirm the disconnect.
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(self
            .client
            .write()
            .await
            .disconnect_and_confirm(&self.device_name)
            .await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        self.client
            .write()
            .await
            .check_device(&self.device_name)
            .await
            .map_err(|e| e.to_string())
    }
}

#[async_trait]
impl Mount for IndiMountHandle {
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        tracing::debug!(
            "mount_slew: Creating INDI mount wrapper for {}",
            device_name
        );
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
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
            tracing::error!("mount_slew INDI error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn slew_alt_az(&self, altitude: f64, azimuth: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
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
            tracing::error!("mount_slew_alt_az INDI error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn abort(&self) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn stop(&self) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.abort_slew().await.map_err(DeviceOpError::from)
    }

    async fn move_axis(&self, axis: i32, rate: f64) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);

        // Convert axis/rate to directional movement
        // axis 0 = RA/Az (East/West), axis 1 = Dec/Alt (North/South)
        // rate > 0 = North/East, rate < 0 = South/West, rate = 0 = stop
        if axis == 0 {
            // RA/Azimuth axis
            if rate > 0.0 {
                return mount.move_east(true).await.map_err(|e| {
                    tracing::error!("mount_move_axis INDI error (move east): {}", e);
                    DeviceOpError::from(e)
                });
            } else if rate < 0.0 {
                return mount.move_west(true).await.map_err(|e| {
                    tracing::error!("mount_move_axis INDI error (move west): {}", e);
                    DeviceOpError::from(e)
                });
            } else {
                // Stop both directions. Attempt-all, then report
                // BOTH outcomes: swallowing the east-stop meant a
                // successful west-stop returned Ok() while the
                // mount was still slewing east under
                // TELESCOPE_MOTION_WE — "axis stopped" was a lie
                // and no caller (manual slew release, guider,
                // safing) could see it.
                let east = mount.move_east(false).await;
                let west = mount.move_west(false).await;
                return match (east, west) {
                    (Ok(()), Ok(())) => Ok(()),
                    (east, west) => {
                        let detail = stop_failure_detail(("east", east), ("west", west));
                        tracing::error!("mount_move_axis INDI error (stop RA): {}", detail);
                        Err(DeviceOpError::from(detail))
                    }
                };
            }
        } else {
            // Dec/Altitude axis
            if rate > 0.0 {
                return mount.move_north(true).await.map_err(|e| {
                    tracing::error!("mount_move_axis INDI error (move north): {}", e);
                    DeviceOpError::from(e)
                });
            } else if rate < 0.0 {
                return mount.move_south(true).await.map_err(|e| {
                    tracing::error!("mount_move_axis INDI error (move south): {}", e);
                    DeviceOpError::from(e)
                });
            } else {
                // Stop both directions — see the RA arm above for
                // why a discarded north-stop cannot ride out on a
                // successful south-stop.
                let north = mount.move_north(false).await;
                let south = mount.move_south(false).await;
                return match (north, south) {
                    (Ok(()), Ok(())) => Ok(()),
                    (north, south) => {
                        let detail = stop_failure_detail(("north", north), ("south", south));
                        tracing::error!("mount_move_axis INDI error (stop Dec): {}", detail);
                        Err(DeviceOpError::from(detail))
                    }
                };
            }
        }
    }

    async fn park(&self) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.park().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!("Failed to park INDI mount {}: {}", device_name, e),
                e,
            )
        })
    }

    async fn unpark(&self) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.unpark().await.map_err(DeviceOpError::from)
    }

    async fn find_home(&self) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.find_home().await.map_err(|e| {
            tracing::error!("mount_find_home INDI error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_find_home(&self) -> Result<bool, DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        // `IndiMount::find_home` drives TELESCOPE_HOME.GO, so
        // that element is the capability.
        let locked = client.read().await;
        Ok(locked
            .get_switch(&device_name, indi::TELESCOPE_HOME, indi::GO)
            .await
            .is_some())
    }

    async fn set_park(&self) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.set_park_to_current().await.map_err(|e| {
            tracing::error!("mount_set_park INDI error: {}", e);
            DeviceOpError::from(e)
        })
    }

    async fn can_set_park(&self) -> Result<bool, DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        Ok(mount.can_set_park().await)
    }

    async fn can_park(&self) -> Result<bool, DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let locked = client.read().await;
        let supports_park = locked
            .get_switch(&device_name, indi::TELESCOPE_PARK, indi::PARK)
            .await
            .is_some()
            || locked
                .get_switch(&device_name, indi::TELESCOPE_PARK, indi::UNPARK)
                .await
                .is_some();
        Ok(supports_park)
    }

    async fn sync(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.sync_to_coordinates(ra, dec).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to sync INDI mount {} to RA={:.4} Dec={:.4}: {}",
                    device_name, ra, dec, e
                ),
                e,
            )
        })
    }

    async fn coordinates(&self) -> Result<(f64, f64), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.get_coordinates().await.map_err(DeviceOpError::from)
    }

    async fn status(&self) -> Result<MountStatus, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        let (ra, dec) = mount.get_coordinates().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read INDI mount coordinates for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;
        let tracking = mount.try_is_tracking().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read INDI mount tracking for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;
        let slewing = mount.try_is_slewing().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!("Failed to read INDI mount slewing for {}: {}", device_id, e),
                e,
            )
        })?;
        let parked = mount.try_is_parked().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read INDI mount parked state for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;

        let mut availability = DeviceManager::mount_status_availability_map();

        let (alt_opt, az_opt) = match mount.get_horizontal_coordinates().await {
            Ok((a, z)) => {
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
                (Some(a), Some(z))
            }
            Err(e) => {
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::ALTITUDE,
                    FieldAvailability::Error(e.to_string()),
                );
                DeviceManager::set_mount_availability(
                    &mut availability,
                    mount_status_field::AZIMUTH,
                    FieldAvailability::Error(e.to_string()),
                );
                (None, None)
            }
        };
        let side_of_pier_opt = mount
            .get_pier_side()
            .await
            .map(|side| DeviceManager::pier_side_from_indi_element(&side));

        let locked = client.read().await;
        let (can_park, can_slew, can_sync, can_pulse_guide) = {
            let can_park = locked
                .get_switch(&device_name, indi::TELESCOPE_PARK, indi::PARK)
                .await
                .is_some()
                || locked
                    .get_switch(&device_name, indi::TELESCOPE_PARK, indi::UNPARK)
                    .await
                    .is_some();
            let can_slew = locked
                .get_switch(&device_name, indi::ON_COORD_SET, indi::SLEW)
                .await
                .is_some();
            let can_sync = locked
                .get_switch(&device_name, indi::ON_COORD_SET, indi::SYNC)
                .await
                .is_some();
            let can_pulse_guide = locked
                .get_number(
                    &device_name,
                    indi::TELESCOPE_TIMED_GUIDE_NS,
                    indi::TIMED_GUIDE_N,
                )
                .await
                .is_some()
                || locked
                    .get_number(
                        &device_name,
                        indi::TELESCOPE_TIMED_GUIDE_WE,
                        indi::TIMED_GUIDE_E,
                    )
                    .await
                    .is_some();
            (can_park, can_slew, can_sync, can_pulse_guide)
        };
        let (tracking_rate_native, can_set_tracking_rate) =
            DeviceManager::indi_mount_tracking_rate(&locked, &device_name).await;
        let tracking_rate_opt = if can_set_tracking_rate {
            DeviceManager::set_mount_availability(
                &mut availability,
                mount_status_field::TRACKING_RATE,
                FieldAvailability::Available,
            );
            Some(tracking_rate_native)
        } else {
            // INDI helper currently signals "no tracking-rate property" by
            // returning false for the second tuple element; treat that as
            // Unsupported rather than asserting Sidereal.
            DeviceManager::set_mount_availability(
                &mut availability,
                mount_status_field::TRACKING_RATE,
                FieldAvailability::Unsupported,
            );
            None
        };

        // INDI does not standardise an at-home property, and TIME_LST is
        // optional — record both as Unsupported until per-driver support
        // can be added.
        DeviceManager::set_mount_availability(
            &mut availability,
            mount_status_field::AT_HOME,
            FieldAvailability::Unsupported,
        );
        DeviceManager::set_mount_availability(
            &mut availability,
            mount_status_field::SIDEREAL_TIME,
            FieldAvailability::Unsupported,
        );
        DeviceManager::set_mount_availability(
            &mut availability,
            mount_status_field::SIDE_OF_PIER,
            if side_of_pier_opt.is_some() {
                FieldAvailability::Available
            } else {
                FieldAvailability::Unsupported
            },
        );

        Ok(MountStatus {
            connected: true,
            tracking,
            slewing,
            parked,
            at_home: None,
            side_of_pier: side_of_pier_opt,
            right_ascension: ra,
            declination: dec,
            altitude: alt_opt,
            azimuth: az_opt,
            sidereal_time: None,
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
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount.set_tracking(enabled).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to set INDI mount {} tracking={}: {}",
                    device_name, enabled, e
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
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
        mount
            .pulse_guide(dir, duration_ms)
            .await
            .map_err(DeviceOpError::from)
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
        Err(DeviceOpError::unsupported(
            "Reading the site from an INDI mount is not wired up yet",
        ))
    }

    async fn set_site(&self, _site: MountSite) -> Result<(), DeviceOpError> {
        Err(DeviceOpError::unsupported(
            "Writing the site to an INDI mount is not wired up yet",
        ))
    }

    async fn time(&self) -> Result<MountTimeInfo, DeviceOpError> {
        Err(DeviceOpError::unsupported(
            "Reading the clock from an INDI mount is not wired up yet",
        ))
    }

    async fn set_time(&self, _time: MountTimeInfo) -> Result<(), DeviceOpError> {
        Err(DeviceOpError::unsupported(
            "Writing the clock to an INDI mount is not wired up yet",
        ))
    }

    /// INDI carries GEOGRAPHIC_COORD and TIME_UTC, but this client does not
    /// wire them yet. Reported as absent rather than attempted.
    async fn site_capabilities(&self) -> Result<MountSiteCapabilities, DeviceOpError> {
        Ok(MountSiteCapabilities {
            can_read_site: false,
            can_write_site: false,
            can_read_time: false,
            can_write_time: false,
        })
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        crate::device_capabilities::get_indi_capabilities(device_id).await
    }
}
