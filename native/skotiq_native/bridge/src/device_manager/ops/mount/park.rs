use super::*;

impl DeviceManager {
    pub async fn mount_park(&self, device_id: &str) -> Result<(), DeviceOpError> {
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
                        return mount.park().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!("Failed to park ASCOM mount {}: {}", device_id, e),
                            )
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
                    return mount.park().await.map_err(DeviceOpError::driver);
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
                        return mount.park().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!("Failed to park INDI mount {}: {}", device_name, e),
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
            DriverType::Native => {
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.park().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to park native mount {}: {}", device_id, e),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                crate::device_manager::ops::sim_gate::refuse_while_mount_slewing("park").await?;
                // Drop the in-flight slew BEFORE writing the park position: a
                // status read landing in between would otherwise advance the
                // abandoned slew straight back over it.
                crate::api::devices::simulation::cancel_sim_slew().await;
                let (ra, dec) = crate::api::devices::simulation::sim_park_position();
                let mut m = crate::api::devices::simulation::get_sim_mount()
                    .write()
                    .await;
                m.status.right_ascension = ra;
                m.status.declination = dec;
                m.status.parked = true;
                m.status.tracking = false;
                m.status.slewing = false;
                drop(m);
                crate::api::devices::simulation::reset_sim_guide_offset().await;
                Ok(())
            }
        }
    }

    pub async fn mount_unpark(&self, device_id: &str) -> Result<(), DeviceOpError> {
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
                        mount.unpark().await.map_err(DeviceOpError::driver)?;
                        let deadline =
                            tokio::time::Instant::now() + std::time::Duration::from_secs(15);
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
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    return mount.unpark().await.map_err(DeviceOpError::driver);
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
                        return mount.unpark().await.map_err(DeviceOpError::driver);
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
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.unpark().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                // Goes through the shared gate rather than an inline
                // `connected` read: the gate is also what runs the fault
                // injector and advances the in-flight slew, so unpark now sees
                // — and can be made to fail on — the same mount state every
                // other mutating op does.
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                let m = crate::api::devices::simulation::get_sim_mount();
                m.write().await.status.parked = false;
                Ok(())
            }
        }
    }

    pub async fn mount_find_home(&self, device_id: &str) -> Result<(), DeviceOpError> {
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
                        return mount.find_home().await.map_err(|e| {
                            tracing::error!("mount_find_home ASCOM error: {}", e);
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
                    return mount.find_home().await.map_err(|e| {
                        tracing::error!("mount_find_home Alpaca error: {}", e);
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
                        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
                        return mount.find_home().await.map_err(|e| {
                            tracing::error!("mount_find_home INDI error: {}", e);
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
                // Not every serial protocol has a home command, but OnStep does
                // (`:hF#`) and the driver now implements it. Mounts that cannot
                // home still answer NotSupported from the trait default, so the
                // refusal comes from the driver that knows rather than from a
                // blanket assumption about the whole driver class.
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.find_home().await.map_err(|e| {
                        tracing::error!("mount_find_home native error: {}", e);
                        DeviceOpError::driver(e)
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                crate::api::devices::simulation::cancel_sim_slew().await;
                // Home is the same mechanical rest position park uses; the
                // difference is that a homed mount is not parked. Leaving the
                // pointing at the previous target would report the altitude of
                // whatever it had been imaging.
                let (ra, dec) = crate::api::devices::simulation::sim_park_position();
                let mut m = crate::api::devices::simulation::get_sim_mount()
                    .write()
                    .await;
                m.status.right_ascension = ra;
                m.status.declination = dec;
                m.status.at_home = Some(true);
                m.status.parked = false;
                m.status.slewing = false;
                drop(m);
                crate::api::devices::simulation::reset_sim_guide_offset().await;
                Ok(())
            }
        }
    }

    pub async fn mount_can_park(&self, device_id: &str) -> Result<bool, DeviceOpError> {
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
                        return mount.can_park().await.map_err(DeviceOpError::driver);
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
                    return match mount.is_parked().await {
                        Ok(_) => Ok(true),
                        Err(skotiq_native::traits::NativeError::NotSupported) => Ok(false),
                        Err(e) => Err(DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to determine native mount park capability for {}: {}",
                                device_id, e
                            ),
                        )),
                    };
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native mount {} not connected", device_id),
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    return mount.can_park().await.map_err(DeviceOpError::driver);
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
                        let locked = client.read().await;
                        let supports_park = locked
                            .get_switch(&device_name, "TELESCOPE_PARK", "PARK")
                            .await
                            .is_some()
                            || locked
                                .get_switch(&device_name, "TELESCOPE_PARK", "UNPARK")
                                .await
                                .is_some();
                        return Ok(supports_park);
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
                let sim = crate::device_manager::ops::sim_gate::read_mount_status().await?;
                Ok(sim.can_park)
            }
        }
    }
}
