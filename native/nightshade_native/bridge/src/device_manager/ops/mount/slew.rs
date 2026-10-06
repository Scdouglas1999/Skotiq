use super::*;

/// Describe the failed half (or halves) of a two-direction axis stop.
///
/// An INDI axis stop is two switch writes (east+west, north+south) and the
/// caller only learns "the axis stopped" from the returned `Result`. Reporting
/// only the second write let a failed first write pass as success while that
/// direction's `TELESCOPE_MOTION_*` switch stayed On — the mount kept moving.
/// Both labels are named so the log says which direction is still commanded.
pub(crate) fn stop_failure_detail<E: std::fmt::Display>(
    first: (&str, Result<(), E>),
    second: (&str, Result<(), E>),
) -> String {
    let (first_label, first_result) = first;
    let (second_label, second_result) = second;
    let mut parts = Vec::new();
    if let Err(e) = first_result {
        parts.push(format!("{first_label}={e}"));
    }
    if let Err(e) = second_result {
        parts.push(format!("{second_label}={e}"));
    }
    format!("stop failed for {}", parts.join("; "))
}

impl DeviceManager {
    // Mount control

    pub async fn mount_slew(
        &self,
        device_id: &str,
        ra: f64,
        dec: f64,
    ) -> Result<(), DeviceOpError> {
        tracing::debug!(
            "mount_slew called: device_id={}, ra={}, dec={}",
            device_id,
            ra,
            dec
        );

        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| {
                tracing::error!("mount_slew: Device not found in devices map: {}", device_id);
                DeviceOpError::device_not_found(device_id)
            })?;
        drop(devices);

        tracing::debug!(
            "mount_slew: Found device with driver_type={:?}",
            info.driver_type
        );

        // Catalog/solver coordinates are J2000; real mounts (ASCOM default
        // equTopocentric, INDI EQUATORIAL_EOD_COORD, native LX200-protocol)
        // expect of-date coordinates — ~22′ apart in 2026. Convert at this
        // single choke point so every caller (sequencer, planetarium GOTO,
        // centering) lands on target. The Simulator is an of-date mount too
        // unless pinned to J2000 (`epoch::SimMountFrame`), so frame mixing
        // above this layer shows up offline instead of first on the rig.
        // See `device_manager::epoch` for the direction policy.
        let (ra, dec) = if crate::device_manager::epoch::mount_frame_is_of_date(info.driver_type) {
            let (ra_now, dec_now) = crate::device_manager::epoch::j2000_to_jnow(ra, dec);
            tracing::debug!(
                "mount_slew: J2000 ({:.5}h, {:.4}°) -> JNOW ({:.5}h, {:.4}°)",
                ra,
                dec,
                ra_now,
                dec_now
            );
            (ra_now, dec_now)
        } else {
            (ra, dec)
        };

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    tracing::debug!("mount_slew: ascom_mounts contains {} entries", mounts.len());
                    if let Some(mount) = mounts.get(device_id) {
                        let mut mount = mount.write().await;
                        return mount_slew_with_timeout(
                            async {
                                mount
                                    .slew_to_coordinates(ra, dec)
                                    .await
                                    .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                            },
                            device_id,
                        )
                        .await
                        .map_err(|e| {
                            tracing::error!("mount_slew ASCOM error: {}", e);
                            DeviceOpError::driver(e)
                        });
                    } else {
                        tracing::error!(
                            "mount_slew: Mount {} not found in ascom_mounts. Available: {:?}",
                            device_id,
                            mounts.keys().collect::<Vec<_>>()
                        );
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    tracing::debug!("mount_slew: Calling Alpaca slew_to_coordinates_async");
                    return mount_slew_with_timeout(
                        async {
                            mount
                                .slew_to_coordinates_async(ra, dec)
                                .await
                                .map_err(NightshadeError::OperationFailed)
                        },
                        device_id,
                    )
                    .await
                    .map_err(|e| {
                        tracing::error!("mount_slew Alpaca error: {}", e);
                        DeviceOpError::driver(e)
                    });
                }
                tracing::error!("mount_slew: Alpaca mount {} not connected", device_id);
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca mount {} not connected", device_id),
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        tracing::debug!(
                            "mount_slew: Creating INDI mount wrapper for {}",
                            device_name
                        );
                        let mount = nightshade_indi::IndiMount::new(client.clone(), &device_name);
                        return mount_slew_with_timeout(
                            async {
                                mount
                                    .slew_to_coordinates(ra, dec)
                                    .await
                                    .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                            },
                            device_id,
                        )
                        .await
                        .map_err(|e| {
                            tracing::error!("mount_slew INDI error: {}", e);
                            DeviceOpError::driver(e)
                        });
                    }
                    tracing::error!("mount_slew: INDI client not connected for {}", server_key);
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(format!(
                    "Invalid INDI device ID format: {}",
                    device_id
                )))
            }
            DriverType::Native => {
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount_slew_with_timeout(
                        async {
                            mount
                                .slew_to_coordinates(ra, dec)
                                .await
                                .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                        },
                        device_id,
                    )
                    .await
                    .map_err(|e| {
                        tracing::error!("mount_slew Native error: {}", e);
                        DeviceOpError::driver(e)
                    });
                }
                tracing::error!("mount_slew: Native mount {} not connected", device_id);
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                crate::device_manager::ops::sim_gate::refuse_while_mount_slewing("slew").await?;
                // Travels to the target over time rather than teleporting, and
                // records the pier side the mount lands on. See
                // `simulation::begin_sim_slew`.
                crate::api::devices::simulation::begin_sim_slew(ra, dec, chrono::Utc::now()).await;
                // Repointing starts a new target: the previous one's accumulated
                // drift does not carry over, and this is what stops a long
                // session leaving the field pinned at its offset clamp.
                crate::api::devices::simulation::reset_sim_guide_offset().await;
                Ok(())
            }
        }
    }

    pub async fn mount_slew_alt_az(
        &self,
        device_id: &str,
        altitude: f64,
        azimuth: f64,
    ) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mount = mount.write().await;
                        return with_timeout_str(
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
                            DeviceOpError::driver(e)
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
                if let Some(mount) = mounts.get(device_id) {
                    return with_timeout_str(
                        mount.slew_to_alt_az_async(altitude, azimuth),
                        Timeouts::long_slew(),
                        device_id,
                        "slew_to_alt_az",
                    )
                    .await
                    .map_err(|e| {
                        tracing::error!("mount_slew_alt_az Alpaca error: {}", e);
                        DeviceOpError::driver(e)
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca mount {} not connected", device_id),
                ))
            }
            DriverType::Indi => {
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let mount = nightshade_indi::IndiMount::new(client.clone(), &device_name);
                        return with_timeout_str(
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
                            DeviceOpError::driver(e)
                        });
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(format!(
                    "Invalid INDI device ID format: {}",
                    device_id
                )))
            }
            DriverType::Native => {
                // Native mounts (SkyWatcher, iOptron, etc.) are equatorial; alt/az slew is not
                // natively supported. Return an error rather than silently failing.
                Err(DeviceOpError::unsupported(
                    "Alt/Az slew is not supported for native serial mounts",
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                crate::device_manager::ops::sim_gate::refuse_while_mount_slewing("alt/az slew")
                    .await?;
                // Store the equatorial pointing the alt/az slew produced, not the
                // alt/az pair itself: RA/Dec is the simulator's single source of
                // truth and the horizon-frame fields are derived from it on every
                // read (see `sim_gate::read_mount_status`). Writing alt/az here
                // instead left them frozen at the commanded value while the sky
                // moved on underneath.
                let site = crate::api::get_state()
                    .get_observer_location()
                    .ok()
                    .flatten();
                let Some(site) = site else {
                    return Err(DeviceOpError::unsupported(
                        "Alt/Az slew needs an observer location; set the site first",
                    ));
                };
                let now = chrono::Utc::now();
                let (ra, dec) = nightshade_sequencer::meridian::alt_az_to_ra_dec(
                    altitude,
                    azimuth,
                    site.latitude,
                    site.longitude,
                    now,
                );
                crate::api::devices::simulation::begin_sim_slew(ra, dec, now).await;
                crate::api::devices::simulation::reset_sim_guide_offset().await;
                Ok(())
            }
        }
    }

    pub async fn mount_abort(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mut mount = mount.write().await;
                        return mount.abort_slew().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Native => {
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.abort_slew().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    return mount.abort_slew().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca mount {} not connected", device_id),
                ))
            }
            DriverType::Indi => {
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");
                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let mount = nightshade_indi::IndiMount::new(client.clone(), &device_name);
                        return mount.abort_slew().await.map_err(DeviceOpError::driver);
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(format!(
                    "Invalid INDI device ID format: {}",
                    device_id
                )))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                // Drop the in-flight slew first, or the interpolation would
                // carry the mount on to the target it was just told to stop
                // travelling to.
                crate::api::devices::simulation::cancel_sim_slew().await;
                crate::api::devices::simulation::get_sim_mount()
                    .write()
                    .await
                    .status
                    .slewing = false;
                Ok(())
            }
        }
    }

    pub async fn mount_stop(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mount = mount.read().await;
                        return mount.stop().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Native => {
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.abort_slew().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    return mount.abort_slew().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca mount {} not connected", device_id),
                ))
            }
            DriverType::Indi => {
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");
                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let mount = nightshade_indi::IndiMount::new(client.clone(), &device_name);
                        return mount.abort_slew().await.map_err(DeviceOpError::driver);
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(format!(
                    "Invalid INDI device ID format: {}",
                    device_id
                )))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                crate::api::devices::simulation::cancel_sim_slew().await;
                let mut m = crate::api::devices::simulation::get_sim_mount()
                    .write()
                    .await;
                m.status.slewing = false;
                m.status.tracking = false;
                Ok(())
            }
        }
    }

    /// Move an axis at the specified rate (degrees/second)
    /// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
    /// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
    pub async fn mount_move_axis(
        &self,
        device_id: &str,
        axis: i32,
        rate: f64,
    ) -> Result<(), DeviceOpError> {
        tracing::debug!(
            "mount_move_axis called: device_id={}, axis={}, rate={}",
            device_id,
            axis,
            rate
        );

        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| {
                tracing::error!(
                    "mount_move_axis: Device not found in devices map: {}",
                    device_id
                );
                DeviceOpError::device_not_found(device_id)
            })?;

        tracing::debug!(
            "mount_move_axis: Found device with driver_type={:?}",
            info.driver_type
        );

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    tracing::debug!(
                        "mount_move_axis: ascom_mounts contains {} entries",
                        mounts.len()
                    );
                    if let Some(mount) = mounts.get(device_id) {
                        let mut mount = mount.write().await;
                        return mount.move_axis(axis, rate).await.map_err(|e| {
                            tracing::error!("mount_move_axis ASCOM error: {}", e);
                            DeviceOpError::driver(e)
                        });
                    } else {
                        tracing::error!(
                            "mount_move_axis: Mount {} not found in ascom_mounts. Available: {:?}",
                            device_id,
                            mounts.keys().collect::<Vec<_>>()
                        );
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    tracing::debug!("mount_move_axis: Calling Alpaca move_axis");
                    return mount.move_axis(axis, rate).await.map_err(|e| {
                        tracing::error!("mount_move_axis Alpaca error: {}", e);
                        DeviceOpError::driver(e)
                    });
                }
                tracing::error!("mount_move_axis: Alpaca mount {} not connected", device_id);
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca mount {} not connected", device_id),
                ))
            }
            DriverType::Indi => {
                // INDI uses directional movement (NSEW) instead of axis rates
                // We need to map axis/rate to directional commands
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let mount = nightshade_indi::IndiMount::new(client.clone(), &device_name);

                        // Convert axis/rate to directional movement
                        // axis 0 = RA/Az (East/West), axis 1 = Dec/Alt (North/South)
                        // rate > 0 = North/East, rate < 0 = South/West, rate = 0 = stop
                        if axis == 0 {
                            // RA/Azimuth axis
                            if rate > 0.0 {
                                return mount.move_east(true).await.map_err(|e| {
                                    tracing::error!(
                                        "mount_move_axis INDI error (move east): {}",
                                        e
                                    );
                                    DeviceOpError::driver(e)
                                });
                            } else if rate < 0.0 {
                                return mount.move_west(true).await.map_err(|e| {
                                    tracing::error!(
                                        "mount_move_axis INDI error (move west): {}",
                                        e
                                    );
                                    DeviceOpError::driver(e)
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
                                        let detail =
                                            stop_failure_detail(("east", east), ("west", west));
                                        tracing::error!(
                                            "mount_move_axis INDI error (stop RA): {}",
                                            detail
                                        );
                                        Err(DeviceOpError::driver(detail))
                                    }
                                };
                            }
                        } else {
                            // Dec/Altitude axis
                            if rate > 0.0 {
                                return mount.move_north(true).await.map_err(|e| {
                                    tracing::error!(
                                        "mount_move_axis INDI error (move north): {}",
                                        e
                                    );
                                    DeviceOpError::driver(e)
                                });
                            } else if rate < 0.0 {
                                return mount.move_south(true).await.map_err(|e| {
                                    tracing::error!(
                                        "mount_move_axis INDI error (move south): {}",
                                        e
                                    );
                                    DeviceOpError::driver(e)
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
                                        let detail =
                                            stop_failure_detail(("north", north), ("south", south));
                                        tracing::error!(
                                            "mount_move_axis INDI error (stop Dec): {}",
                                            detail
                                        );
                                        Err(DeviceOpError::driver(detail))
                                    }
                                };
                            }
                        }
                    }
                    tracing::error!(
                        "mount_move_axis: INDI client not connected for {}",
                        server_key
                    );
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(format!(
                    "Invalid INDI device ID format: {}",
                    device_id
                )))
            }
            DriverType::Native => {
                tracing::warn!("mount_move_axis: Native SDK does not support mount axis movement");
                Err(DeviceOpError::unsupported(
                    "Native SDK does not support mount axis movement",
                ))
            }
            DriverType::Simulator => {
                // See `mount_unpark`: the shared gate, not an inline
                // `connected` read, is what advances the motion and runs the
                // fault injector.
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                // NOT refused mid-slew: `rate == 0.0` is how the hand-controller
                // buttons STOP an axis, and a stop must never be rejected.
                // The simulator has no axis-rate state model — just record
                // `slewing` so subsequent `mount_get_status` reflects the move
                // command. A real driver wouldn't no-op silently.
                let m = crate::api::devices::simulation::get_sim_mount();
                m.write().await.status.slewing = rate != 0.0;
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod axis_stop_tests {
    use super::stop_failure_detail;

    /// The regression: the RA/Dec stop arms issued two switch writes and
    /// returned only the second one's result, so a mount that refused the first
    /// write reported a clean stop while that direction was still commanded.
    #[test]
    fn a_failed_first_write_is_named_even_when_the_second_succeeds() {
        let detail = stop_failure_detail(
            ("east", Err::<(), _>("device disconnected")),
            ("west", Ok::<(), &str>(())),
        );
        assert_eq!(detail, "stop failed for east=device disconnected");
    }

    /// A failure on the second write alone must still name its direction.
    #[test]
    fn a_failed_second_write_is_named() {
        let detail = stop_failure_detail(
            ("north", Ok::<(), &str>(())),
            ("south", Err::<(), _>("timeout")),
        );
        assert_eq!(detail, "stop failed for south=timeout");
    }

    /// Both halves failing reports both — the operator needs to know the whole
    /// axis is still under motion, not just one direction of it.
    #[test]
    fn both_failures_are_reported_together() {
        let detail = stop_failure_detail(
            ("east", Err::<(), _>("write failed")),
            ("west", Err::<(), _>("broken pipe")),
        );
        assert_eq!(
            detail,
            "stop failed for east=write failed; west=broken pipe"
        );
    }
}
