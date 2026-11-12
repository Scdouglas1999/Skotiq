//! Reading and writing the mount's own site and clock.
//!
//! Two sources of truth exist the moment a mount is connected: the computer's
//! configured site/time and the mount's own. They are frequently different, and
//! neither is automatically right — a hand controller set once at the pier is
//! often better than a laptop that has never had its timezone corrected, and a
//! laptop with GPS is often better than a mount whose battery died. So this
//! module only ever moves values in the direction the operator asks for, and
//! [`DeviceManager::mount_site_capabilities`] says which directions the driver
//! can honour so the UI never offers one that will be refused.

use super::*;

/// Days between the OLE Automation epoch (1899-12-30) and the Unix epoch.
///
/// Only ASCOM speaks OLE dates, so on a non-Windows build nothing outside the
/// tests calls these. Kept compiled everywhere — and tested everywhere — so the
/// conversion cannot rot unnoticed on the platform that cannot exercise it.
#[cfg_attr(not(windows), allow(dead_code))]
const OLE_EPOCH_TO_UNIX_DAYS: f64 = 25_569.0;
#[cfg_attr(not(windows), allow(dead_code))]
const SECONDS_PER_DAY: f64 = 86_400.0;

#[cfg_attr(not(windows), allow(dead_code))]
fn ole_to_unix_seconds(ole_days: f64) -> i64 {
    ((ole_days - OLE_EPOCH_TO_UNIX_DAYS) * SECONDS_PER_DAY).round() as i64
}

#[cfg_attr(not(windows), allow(dead_code))]
fn unix_seconds_to_ole(unix_seconds: i64) -> f64 {
    unix_seconds as f64 / SECONDS_PER_DAY + OLE_EPOCH_TO_UNIX_DAYS
}

/// An Alpaca `UTCDate` value: ISO 8601 in UTC with a `Z` suffix.
fn alpaca_utc_date(unix_seconds: i64) -> Result<String, DeviceOpError> {
    chrono::DateTime::from_timestamp(unix_seconds, 0)
        .map(|utc| utc.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        .ok_or_else(|| DeviceOpError::from(format!("{unix_seconds} is not a UTC time")))
}

impl DeviceManager {
    /// What this mount can actually do, so the reconciliation card offers only
    /// directions the driver supports.
    pub async fn mount_site_capabilities(
        &self,
        device_id: &str,
    ) -> Result<MountSiteCapabilities, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        Ok(match info.driver_type {
            // The native trait defaults to NotSupported, so a serial protocol
            // without site commands reports false by simply not implementing
            // them. Probing is the only honest way to know.
            DriverType::Native => {
                let mounts = self.native_mounts.read().await;
                match mounts.get(device_id) {
                    Some(mount) => {
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
                        MountSiteCapabilities {
                            can_read_site,
                            can_write_site: can_read_site,
                            can_read_time,
                            can_write_time: can_read_time,
                        }
                    }
                    None => {
                        return Err(DeviceOpError::not_connected(
                            Some(device_id.to_string()),
                            "Native mount not connected",
                        ))
                    }
                }
            }
            DriverType::Ascom => MountSiteCapabilities {
                can_read_site: true,
                can_write_site: true,
                can_read_time: true,
                can_write_time: true,
            },
            DriverType::Alpaca => MountSiteCapabilities {
                can_read_site: true,
                can_write_site: true,
                can_read_time: true,
                can_write_time: true,
            },
            // INDI carries GEOGRAPHIC_COORD and TIME_UTC, but this client does
            // not wire them yet. Reported as absent rather than attempted.
            DriverType::Indi => MountSiteCapabilities {
                can_read_site: false,
                can_write_site: false,
                can_read_time: false,
                can_write_time: false,
            },
            DriverType::Simulator => MountSiteCapabilities {
                can_read_site: true,
                can_write_site: true,
                can_read_time: true,
                can_write_time: true,
            },
        })
    }

    pub async fn mount_get_site(&self, device_id: &str) -> Result<MountSite, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Native => {
                let mounts = self.native_mounts.read().await;
                let mount = mounts.get(device_id).ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Native mount not connected",
                    )
                })?;
                let site = mount.get_site().await.map_err(DeviceOpError::from)?;
                Ok(MountSite {
                    latitude_deg: site.latitude_deg,
                    longitude_deg: site.longitude_deg,
                    elevation_m: site.elevation_m,
                })
            }
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mount = self.ascom_mounts.read().await.get(device_id).cloned();
                    if let Some(mount) = mount {
                        let mount = mount.read().await;
                        let (latitude_deg, longitude_deg, elevation_m) =
                            mount.get_site().await.map_err(DeviceOpError::from)?;
                        return Ok(MountSite {
                            latitude_deg,
                            longitude_deg,
                            elevation_m,
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                let mount = mounts.get(device_id).ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Alpaca mount not connected",
                    )
                })?;
                let latitude_deg = mount.site_latitude().await.map_err(DeviceOpError::from)?;
                let longitude_deg = mount.site_longitude().await.map_err(DeviceOpError::from)?;
                Ok(MountSite {
                    latitude_deg,
                    longitude_deg,
                    elevation_m: mount.site_elevation().await.ok(),
                })
            }
            DriverType::Indi => Err(DeviceOpError::unsupported(
                "Reading the site from an INDI mount is not wired up yet",
            )),
            DriverType::Simulator => {
                let location = crate::api::get_state()
                    .get_observer_location()
                    .map_err(|e| DeviceOpError::from(e.to_string()))?;
                match location {
                    Some(loc) => Ok(MountSite {
                        latitude_deg: loc.latitude,
                        longitude_deg: loc.longitude,
                        elevation_m: Some(loc.elevation),
                    }),
                    None => Err(DeviceOpError::unsupported(
                        "The simulated mount has no site until the observer location is set",
                    )),
                }
            }
        }
    }

    pub async fn mount_set_site(
        &self,
        device_id: &str,
        site: MountSite,
    ) -> Result<(), DeviceOpError> {
        if !(-90.0..=90.0).contains(&site.latitude_deg)
            || !(-180.0..=180.0).contains(&site.longitude_deg)
        {
            return Err(DeviceOpError::from(format!(
                "Refusing to write site {:.4},{:.4}: out of range",
                site.latitude_deg, site.longitude_deg
            )));
        }

        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Native => {
                let mut mounts = self.native_mounts.write().await;
                let mount = mounts.get_mut(device_id).ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Native mount not connected",
                    )
                })?;
                mount
                    .set_site(skotiq_device::MountSiteInfo {
                        latitude_deg: site.latitude_deg,
                        longitude_deg: site.longitude_deg,
                        elevation_m: site.elevation_m,
                    })
                    .await
                    .map_err(DeviceOpError::from)
            }
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mount = self.ascom_mounts.read().await.get(device_id).cloned();
                    if let Some(mount) = mount {
                        let mount = mount.write().await;
                        // Elevation tolerance lives inside the wrapper's worker,
                        // where the three property writes happen on the one COM
                        // thread that owns the driver.
                        return mount
                            .set_site(site.latitude_deg, site.longitude_deg, site.elevation_m)
                            .await
                            .map_err(DeviceOpError::from);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                let mount = mounts.get(device_id).ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Alpaca mount not connected",
                    )
                })?;
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
            DriverType::Indi => Err(DeviceOpError::unsupported(
                "Writing the site to an INDI mount is not wired up yet",
            )),
            DriverType::Simulator => Ok(()),
        }
    }

    pub async fn mount_get_time(&self, device_id: &str) -> Result<MountTimeInfo, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Native => {
                let mounts = self.native_mounts.read().await;
                let mount = mounts.get(device_id).ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Native mount not connected",
                    )
                })?;
                let clock = mount.get_clock().await.map_err(DeviceOpError::from)?;
                Ok(MountTimeInfo {
                    utc_unix_seconds: clock.utc_unix_seconds,
                    utc_offset_hours: clock.utc_offset_hours,
                })
            }
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mount = self.ascom_mounts.read().await.get(device_id).cloned();
                    if let Some(mount) = mount {
                        let mount = mount.read().await;
                        let ole = mount.get_utc_date().await.map_err(DeviceOpError::from)?;
                        return Ok(MountTimeInfo {
                            utc_unix_seconds: ole_to_unix_seconds(ole),
                            // ASCOM's UTCDate is UTC by definition; the mount's
                            // local offset is not exposed, so report zero rather
                            // than inventing one.
                            utc_offset_hours: 0.0,
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                let mount = mounts.get(device_id).ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Alpaca mount not connected",
                    )
                })?;
                let iso = mount.utc_date().await.map_err(DeviceOpError::from)?;
                let parsed = chrono::DateTime::parse_from_rfc3339(&iso)
                    .map(|d| d.timestamp())
                    .or_else(|_| {
                        chrono::NaiveDateTime::parse_from_str(&iso, "%Y-%m-%dT%H:%M:%S%.f")
                            .map(|d| d.and_utc().timestamp())
                    })
                    .map_err(|e| {
                        DeviceOpError::from(format!("Unparseable Alpaca utcdate {iso:?}: {e}"))
                    })?;
                Ok(MountTimeInfo {
                    utc_unix_seconds: parsed,
                    utc_offset_hours: 0.0,
                })
            }
            DriverType::Indi => Err(DeviceOpError::unsupported(
                "Reading the clock from an INDI mount is not wired up yet",
            )),
            DriverType::Simulator => Ok(MountTimeInfo {
                utc_unix_seconds: chrono::Utc::now().timestamp(),
                utc_offset_hours: 0.0,
            }),
        }
    }

    pub async fn mount_set_time(
        &self,
        device_id: &str,
        time: MountTimeInfo,
    ) -> Result<(), DeviceOpError> {
        if !(-14.0..=14.0).contains(&time.utc_offset_hours) {
            return Err(DeviceOpError::from(format!(
                "Refusing to write UTC offset {}: out of range",
                time.utc_offset_hours
            )));
        }

        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Native => {
                let mut mounts = self.native_mounts.write().await;
                let mount = mounts.get_mut(device_id).ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Native mount not connected",
                    )
                })?;
                mount
                    .set_clock(skotiq_device::MountClock {
                        utc_unix_seconds: time.utc_unix_seconds,
                        utc_offset_hours: time.utc_offset_hours,
                    })
                    .await
                    .map_err(DeviceOpError::from)
            }
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mount = self.ascom_mounts.read().await.get(device_id).cloned();
                    if let Some(mount) = mount {
                        let mount = mount.write().await;
                        return mount
                            .set_utc_date(unix_seconds_to_ole(time.utc_unix_seconds))
                            .await
                            .map_err(DeviceOpError::from);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mount = self.alpaca_mounts.read().await.get(device_id).cloned();
                let mount = mount.ok_or_else(|| {
                    DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Alpaca mount not connected",
                    )
                })?;
                mount
                    .set_utc_date(&alpaca_utc_date(time.utc_unix_seconds)?)
                    .await
                    .map_err(DeviceOpError::from)
            }
            DriverType::Indi => Err(DeviceOpError::unsupported(
                "Writing the clock to an INDI mount is not wired up yet",
            )),
            DriverType::Simulator => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_alpaca_utc_date_is_iso_8601_in_utc() {
        let unix = chrono::DateTime::parse_from_rfc3339("2026-09-09T12:00:05Z")
            .expect("parse")
            .timestamp();
        assert_eq!(
            alpaca_utc_date(unix).expect("in range"),
            "2026-09-09T12:00:05.000Z"
        );
    }

    #[test]
    fn ole_dates_round_trip_through_unix_seconds() {
        // 2026-09-09T12:00:00Z, checked against the OLE epoch of 1899-12-30.
        let unix = chrono::DateTime::parse_from_rfc3339("2026-09-09T12:00:00Z")
            .unwrap()
            .timestamp();
        let ole = unix_seconds_to_ole(unix);
        assert!(
            (ole_to_unix_seconds(ole) - unix).abs() <= 1,
            "OLE round trip drifted: {} -> {} -> {}",
            unix,
            ole,
            ole_to_unix_seconds(ole)
        );
    }

    #[test]
    fn the_ole_epoch_itself_maps_to_the_expected_unix_time() {
        // OLE day 25569.0 is exactly the Unix epoch.
        assert_eq!(ole_to_unix_seconds(OLE_EPOCH_TO_UNIX_DAYS), 0);
        assert!((unix_seconds_to_ole(0) - OLE_EPOCH_TO_UNIX_DAYS).abs() < 1e-9);
    }
}
