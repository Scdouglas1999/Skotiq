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
                // ASCOM resets AtHome on any slew, and parking is one: a
                // parked mount reports AtPark, not AtHome, even though the
                // simulator parks on the same pose it homes to.
                m.status.at_home = Some(false);
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

    /// Send the mount to its home position.
    ///
    /// Homing is NOT parking. A homed mount is left unparked and keeps
    /// accepting slews, syncs and tracking commands; nothing here marks it
    /// parked. Tracking is left exactly as the driver leaves it — ASCOM's
    /// `FindHome` stops tracking, and turning it back on would carry the mount
    /// straight off the pose the operator asked for.
    ///
    /// Two preconditions are checked for every driver before anything moves:
    ///
    /// * the driver must report that it can home ([`Self::mount_can_find_home`]),
    ///   otherwise the call fails as [`DeviceOpError::Unsupported`];
    /// * the mount must not be parked. Several drivers answer `FindHome` on a
    ///   parked mount by quietly unparking it first, so a parked mount is
    ///   refused with [`DeviceOpError::InvalidState`] and the operator unparks
    ///   it deliberately.
    ///
    /// Most drivers return as soon as the home motion has started (INDI,
    /// OnStep, iOptron, ASCOM Platform 7 drivers, the simulator) and report
    /// progress through `Slewing`/`AtHome`; ASCOM V3 and Alpaca drivers that
    /// implement `FindHome` synchronously return when the mount arrives. An
    /// abort reaches the mount through [`Self::mount_abort`] in the first case;
    /// in the second it waits for the driver to hand the call back.
    pub async fn mount_find_home(&self, device_id: &str) -> Result<(), DeviceOpError> {
        if !self.mount_can_find_home(device_id).await? {
            return Err(DeviceOpError::unsupported(format!(
                "Mount {} cannot find home: its driver does not report a home position",
                device_id
            )));
        }
        // Read through the full status path, which is also how the sequencer
        // learns the parked state, so every caller is refused on the same
        // reading. Done before taking the device map lock below: the status
        // read takes it too.
        if self.mount_get_status(device_id).await?.parked {
            return Err(DeviceOpError::invalid_state(
                device_id,
                format!(
                    "Mount {} is parked. Unpark it before sending it home.",
                    device_id
                ),
            ));
        }

        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        // `find_home` takes `&self`: the wrapper's COM worker
                        // serializes the call, so a read guard is all the map
                        // needs, and status reads are not locked out for the
                        // length of the motion.
                        let mount = mount.read().await;
                        return mount.find_home().await.map_err(|e| {
                            tracing::error!("mount_find_home ASCOM error: {}", e);
                            DeviceOpError::from(e)
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
                // OnStep (`:hF#`) and iOptron (`:MH#`) can home; every other
                // serial protocol answers NotSupported from the trait default,
                // which `mount_can_find_home` has already turned into a clear
                // refusal above.
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.find_home().await.map_err(|e| {
                        tracing::error!("mount_find_home native error: {}", e);
                        DeviceOpError::from(e)
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                // A real driver refuses FindHome mid-slew; abort first.
                crate::device_manager::ops::sim_gate::refuse_while_mount_slewing("home").await?;
                // Travels to the home pose over time and reports AtHome only
                // once it has arrived and settled; see
                // `simulation::begin_sim_home`.
                crate::api::devices::simulation::begin_sim_home().await;
                crate::api::devices::simulation::reset_sim_guide_offset().await;
                Ok(())
            }
        }
    }

    /// Whether the mount's driver can send it to a home position.
    ///
    /// The same answer the capability snapshot publishes as `can_find_home`,
    /// read live from the driver so a command is never sent on a stale flag.
    pub async fn mount_can_find_home(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mount = mount.read().await;
                        return mount
                            .get_capabilities()
                            .await
                            .map(|caps| caps.can_find_home)
                            .map_err(DeviceOpError::driver);
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
                    return mount.can_find_home().await.map_err(DeviceOpError::driver);
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
                        // `IndiMount::find_home` drives TELESCOPE_HOME.GO, so
                        // that element is the capability.
                        let locked = client.read().await;
                        return Ok(locked
                            .get_switch(&device_name, "TELESCOPE_HOME", "GO")
                            .await
                            .is_some());
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
                let native_mounts = self.native_mounts.read().await;
                if let Some(mount) = native_mounts.get(device_id) {
                    return Ok(mount.can_find_home());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native mount {} not connected", device_id),
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::read_mount_status().await?;
                Ok(true)
            }
        }
    }

    /// Store the mount's current position as its park position.
    ///
    /// Nothing moves. Two preconditions are checked for every driver first:
    ///
    /// * the driver must report that it can set park
    ///   ([`Self::mount_can_set_park`]), otherwise the call fails as
    ///   [`DeviceOpError::Unsupported`];
    /// * the mount must not be slewing: the position read mid-slew is a point
    ///   the mount is passing through, not one the operator chose, so it is
    ///   refused with [`DeviceOpError::InvalidState`].
    pub async fn mount_set_park(&self, device_id: &str) -> Result<(), DeviceOpError> {
        if !self.mount_can_set_park(device_id).await? {
            return Err(DeviceOpError::unsupported(format!(
                "Mount {} cannot set its park position: its driver does not support it",
                device_id
            )));
        }
        // The same status path the sequencer reads, taken before the device
        // map lock below because it takes that lock too.
        if self.mount_get_status(device_id).await?.slewing {
            return Err(DeviceOpError::invalid_state(
                device_id,
                format!(
                    "Mount {} is moving. Wait for it to stop before setting park.",
                    device_id
                ),
            ));
        }

        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        // `set_park` takes `&self`: the wrapper's COM worker
                        // serializes the call, so a read guard is enough.
                        let mount = mount.read().await;
                        return mount.set_park().await.map_err(|e| {
                            tracing::error!("mount_set_park ASCOM error: {}", e);
                            DeviceOpError::from(e)
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
                    return mount.set_park().await.map_err(|e| {
                        tracing::error!("mount_set_park Alpaca error: {}", e);
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
                        return mount.set_park_to_current().await.map_err(|e| {
                            tracing::error!("mount_set_park INDI error: {}", e);
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
                // Only OnStep (`:hQ#`) can store a park position; every other
                // serial protocol answers NotSupported from the trait default,
                // already refused above through `mount_can_set_park`.
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.set_park().await.map_err(|e| {
                        tracing::error!("mount_set_park native error: {}", e);
                        DeviceOpError::from(e)
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                crate::device_manager::ops::sim_gate::refuse_while_mount_slewing("set park")
                    .await?;
                let (ra, dec) = {
                    let m = crate::api::devices::simulation::get_sim_mount()
                        .read()
                        .await;
                    (m.status.right_ascension, m.status.declination)
                };
                crate::api::devices::simulation::set_sim_park_position(ra, dec);
                Ok(())
            }
        }
    }

    /// Whether the mount's driver can store the current position as its park
    /// position.
    ///
    /// The same answer the capability snapshot publishes as `can_set_park`,
    /// read live from the driver so a command is never sent on a stale flag.
    pub async fn mount_can_set_park(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mount = mount.read().await;
                        return mount
                            .get_capabilities()
                            .await
                            .map(|caps| caps.can_set_park)
                            .map_err(DeviceOpError::driver);
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
                    return mount.can_set_park().await.map_err(DeviceOpError::driver);
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
                        return Ok(mount.can_set_park().await);
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
                let native_mounts = self.native_mounts.read().await;
                if let Some(mount) = native_mounts.get(device_id) {
                    return Ok(mount.can_set_park());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native mount {} not connected", device_id),
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::read_mount_status().await?;
                Ok(true)
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
