use super::*;

impl DeviceManager {
    pub async fn mount_set_tracking(
        &self,
        device_id: &str,
        enabled: bool,
    ) -> Result<(), DeviceOpError> {
        let result = self.mount_set_tracking_dispatch(device_id, enabled).await;

        // Record the commanded tracking state so an unplanned reconnect (USB /
        // serial yank mid-run) can re-apply it. A mount that comes back from a
        // reconnect is parked / not tracking; without this the sequence would
        // "resume" while the mount sits still. Only record on success so a
        // failed command does not clobber the last known good desired state.
        if result.is_ok() {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                dev.desired_tracking = Some(enabled);
            }
        }

        result
    }

    /// Driver dispatch for `mount_set_tracking`. Split out so the public method
    /// can record the desired tracking state (for reconnect re-application)
    /// without holding the `devices` read lock across the per-driver calls.
    async fn mount_set_tracking_dispatch(
        &self,
        device_id: &str,
        enabled: bool,
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
                        let mut mount = mount.write().await;
                        return mount.set_tracking(enabled).await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to set ASCOM mount {} tracking={}: {}",
                                    device_id, enabled, e
                                ),
                            )
                        });
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
                    return mount.set_tracking(enabled).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to set native mount {} tracking={}: {}",
                                device_id, enabled, e
                            ),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    return mount.set_tracking(enabled).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to set Alpaca mount {} tracking={}: {}",
                                device_id, enabled, e
                            ),
                        )
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
                        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
                        return mount.set_tracking(enabled).await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to set INDI mount {} tracking={}: {}",
                                    device_name, enabled, e
                                ),
                            )
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
            DriverType::Simulator => {
                // See `mount_unpark`: the shared gate, not an inline
                // `connected` read, is what advances the motion and runs the
                // fault injector.
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                let m = crate::api::devices::simulation::get_sim_mount();
                m.write().await.status.tracking = enabled;
                Ok(())
            }
        }
    }

    pub async fn mount_pulse_guide(
        &self,
        device_id: &str,
        direction: String,
        duration_ms: u32,
    ) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        let direction_lower = direction.to_lowercase();
        let dir = match direction_lower.as_str() {
            "north" | "n" => skotiq_native::traits::GuideDirection::North,
            "south" | "s" => skotiq_native::traits::GuideDirection::South,
            "east" | "e" => skotiq_native::traits::GuideDirection::East,
            "west" | "w" => skotiq_native::traits::GuideDirection::West,
            _ => {
                return Err(DeviceOpError::invalid_parameter(format!(
                    "Invalid direction: {}",
                    direction
                )))
            }
        };

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mut mount = mount.write().await;
                        return mount
                            .pulse_guide(dir, duration_ms)
                            .await
                            .map_err(DeviceOpError::driver);
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
                    return mount
                        .pulse_guide(dir, duration_ms)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    let alpaca_dir = match dir {
                        skotiq_native::traits::GuideDirection::North => 0,
                        skotiq_native::traits::GuideDirection::South => 1,
                        skotiq_native::traits::GuideDirection::East => 2,
                        skotiq_native::traits::GuideDirection::West => 3,
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
                    return mount
                        .pulse_guide(alpaca_dir, duration_i32)
                        .await
                        .map_err(DeviceOpError::driver);
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
                        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
                        let direction = match dir {
                            skotiq_native::traits::GuideDirection::North => {
                                skotiq_indi::IndiMountGuideDirection::North
                            }
                            skotiq_native::traits::GuideDirection::South => {
                                skotiq_indi::IndiMountGuideDirection::South
                            }
                            skotiq_native::traits::GuideDirection::East => {
                                skotiq_indi::IndiMountGuideDirection::East
                            }
                            skotiq_native::traits::GuideDirection::West => {
                                skotiq_indi::IndiMountGuideDirection::West
                            }
                        };
                        return mount
                            .pulse_guide(direction, duration_ms)
                            .await
                            .map_err(DeviceOpError::driver);
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
                // Move the simulated star field. A guide pulse that gates on
                // connection and returns Ok without recording anything leaves
                // the built-in guider's own pulses never shifting the field it
                // is measuring, so calibration aborts with "Calibration
                // response on east axis was too small (0.000px)" and guiding,
                // dithering and the correction loop cannot be exercised
                // without a mount.
                crate::device_manager::ops::sim_gate::require_mount_connected()
                    .await
                    .map_err(DeviceOpError::driver)?;
                crate::api::devices::simulation::advance_sim_guide_pulse(
                    &direction_lower,
                    duration_ms,
                )
                .await;
                Ok(())
            }
        }
    }

    pub async fn mount_set_tracking_rate(
        &self,
        device_id: &str,
        rate: i32,
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
                        let mut mount = mount.write().await;
                        return mount
                            .set_tracking_rate_raw(rate)
                            .await
                            .map_err(DeviceOpError::driver);
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
                    // Convert i32 rate to TrackingRate enum
                    let tracking_rate = match rate {
                        0 => skotiq_native::traits::TrackingRate::Sidereal,
                        1 => skotiq_native::traits::TrackingRate::Lunar,
                        2 => skotiq_native::traits::TrackingRate::Solar,
                        3 => skotiq_native::traits::TrackingRate::King,
                        4 => skotiq_native::traits::TrackingRate::Custom,
                        _ => {
                            return Err(DeviceOpError::invalid_parameter(format!(
                                "Invalid tracking rate: {}",
                                rate
                            )))
                        }
                    };
                    return mount
                        .set_tracking_rate(tracking_rate)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                // See `mount_unpark`: the shared gate, not an inline
                // `connected` read, is what advances the motion and runs the
                // fault injector. It runs before the rate is parsed so a
                // disconnected mount reports being disconnected rather than
                // grading the caller's argument.
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                // The simulated mount advertises `can_set_tracking_rate: true`
                // and reports a rate, so it has to accept one — falling through
                // to the unsupported arm made its own capability report a lie.
                let rate = match rate {
                    0 => TrackingRate::Sidereal,
                    1 => TrackingRate::Lunar,
                    2 => TrackingRate::Solar,
                    3 => TrackingRate::King,
                    4 => TrackingRate::Custom,
                    _ => {
                        return Err(DeviceOpError::invalid_parameter(format!(
                            "Invalid tracking rate: {}",
                            rate
                        )))
                    }
                };
                let m = crate::api::devices::simulation::get_sim_mount();
                m.write().await.status.tracking_rate = Some(rate);
                Ok(())
            }
            _ => Err(DeviceOpError::unsupported(
                "Setting tracking rate is not supported by this driver type",
            )),
        }
    }

    pub async fn mount_get_tracking_rate(&self, device_id: &str) -> Result<i32, DeviceOpError> {
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
                        return mount
                            .get_tracking_rate_raw()
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Native => {
                let native_mounts = self.native_mounts.read().await;
                if let Some(mount) = native_mounts.get(device_id) {
                    let rate = mount
                        .get_tracking_rate()
                        .await
                        .map_err(DeviceOpError::driver)?;
                    // Why: `TrackingRate` is a C-like enum
                    // (Sidereal=0, Lunar=1, Solar=2, King=3); `as i32`
                    // extracts the discriminant — SAFE narrowing.
                    return Ok(rate as i32);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_mount_status().await?;
                // Project the singleton's `tracking_rate` Option onto the
                // i32 wire form. None → 0 (Sidereal) is the project-wide
                // default for "rate not declared".
                Ok(match sim.tracking_rate {
                    Some(TrackingRate::Sidereal) => 0,
                    Some(TrackingRate::Lunar) => 1,
                    Some(TrackingRate::Solar) => 2,
                    Some(TrackingRate::King) => 3,
                    Some(TrackingRate::Custom) => 4,
                    None => 0,
                })
            }
            _ => Err(DeviceOpError::unsupported(
                "Getting tracking rate is not supported by this driver type",
            )),
        }
    }
}
