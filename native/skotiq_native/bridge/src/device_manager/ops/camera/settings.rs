use super::*;

impl DeviceManager {
    /// Set camera gain
    pub async fn camera_set_gain(&self, device_id: &str, gain: i32) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_gain for {} gain={}",
            device_id,
            gain
        );

        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let cameras = self.ascom_cameras.read().await;
                    if let Some(camera) = cameras.get(device_id) {
                        let mut camera = camera.write().await;
                        return camera.set_gain(gain).await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to set ASCOM camera {} gain to {}: {}",
                                    device_id, gain, e
                                ),
                            )
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM camera {} not found", device_id),
                ))
            }
            Some(DriverType::Alpaca) => {
                let cameras = self.alpaca_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    return camera.set_gain(gain).await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    return camera.set_gain(gain).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to set native SDK camera {} gain to {}: {}",
                                device_id, gain, e
                            ),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // Parse INDI device ID: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    locked
                        .set_number(&device_name, "CCD_CONTROLS", "Gain", gain as f64)
                        .await
                        .map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!("Failed to set INDI camera gain: {}", e),
                            )
                        })?;
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for server {}", server_key),
                ))
            }
            Some(DriverType::Simulator) => {
                // Mutate the singleton so a subsequent `camera_get_status` /
                // `camera_download_image` reflects the new gain. A real driver
                // wouldn't silently drop the value; the simulator must not
                // either.
                let cam = crate::api::devices::simulation::get_sim_camera();
                let mut cam = cam.write().await;
                if !cam.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_camera(),
                    ));
                }
                cam.status.gain = gain;
                Ok(())
            }
            _ => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found or not supported", device_id),
            )),
        }
    }

    /// Set camera offset
    pub async fn camera_set_offset(
        &self,
        device_id: &str,
        offset: i32,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_offset for {} offset={}",
            device_id,
            offset
        );

        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let cameras = self.ascom_cameras.read().await;
                    if let Some(camera) = cameras.get(device_id) {
                        let mut camera = camera.write().await;
                        return camera.set_offset(offset).await.map_err(DeviceOpError::from);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM camera {} not found", device_id),
                ))
            }
            Some(DriverType::Alpaca) => {
                let cameras = self.alpaca_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    return camera.set_offset(offset).await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    return camera.set_offset(offset).await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // Parse INDI device ID: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    locked
                        .set_number(&device_name, "CCD_CONTROLS", "Offset", offset as f64)
                        .await
                        .map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!("Failed to set INDI camera offset: {}", e),
                            )
                        })?;
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for server {}", server_key),
                ))
            }
            Some(DriverType::Simulator) => {
                let cam = crate::api::devices::simulation::get_sim_camera();
                let mut cam = cam.write().await;
                if !cam.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_camera(),
                    ));
                }
                cam.status.offset = offset;
                Ok(())
            }
            _ => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found or not supported", device_id),
            )),
        }
    }

    /// Set camera binning
    pub async fn camera_set_binning(
        &self,
        device_id: &str,
        bin_x: i32,
        bin_y: i32,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_binning for {} bin={}x{}",
            device_id,
            bin_x,
            bin_y
        );

        if bin_x < 1 || bin_y < 1 {
            return Err(DeviceOpError::invalid_parameter(format!(
                "Invalid binning values: {}x{} (must be >= 1)",
                bin_x, bin_y
            )));
        }

        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let cameras = self.ascom_cameras.read().await;
                    if let Some(camera) = cameras.get(device_id) {
                        let mut camera = camera.write().await;
                        return camera
                            .set_binning(bin_x, bin_y)
                            .await
                            .map_err(DeviceOpError::from);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM camera {} not found", device_id),
                ))
            }
            Some(DriverType::Alpaca) => {
                let cameras = self.alpaca_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    camera.set_bin_x(bin_x).await?;
                    camera.set_bin_y(bin_y).await?;
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked_client = client.write().await;
                    locked_client
                        .set_number(&device_name, "CCD_BINNING", "HOR_BIN", bin_x as f64)
                        .await?;
                    locked_client
                        .set_number(&device_name, "CCD_BINNING", "VER_BIN", bin_y as f64)
                        .await?;
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for server {}", server_key),
                ))
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    return camera
                        .set_binning(bin_x, bin_y)
                        .await
                        .map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                let cam = crate::api::devices::simulation::get_sim_camera();
                let mut cam = cam.write().await;
                if !cam.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_camera(),
                    ));
                }
                cam.status.bin_x = bin_x;
                cam.status.bin_y = bin_y;
                Ok(())
            }
            _ => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found or not supported", device_id),
            )),
        }
    }

    /// Set camera readout mode by index
    ///
    /// ASCOM: Sets the ReadoutMode property (integer index)
    /// Alpaca: Sets the readoutmode property (integer index)
    /// INDI: Sets the CCD_READ_MODE switch to the element at the given index
    /// Native: Delegates to NativeCamera::set_readout_mode with a synthetic ReadoutMode
    pub async fn camera_set_readout_mode(
        &self,
        device_id: &str,
        mode_index: i32,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_readout_mode for {} mode_index={}",
            device_id,
            mode_index
        );

        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let cameras = self.ascom_cameras.read().await;
                    if let Some(camera) = cameras.get(device_id) {
                        let mut camera = camera.write().await;
                        let mode = skotiq_native::camera::ReadoutMode {
                            name: format!("Mode {}", mode_index),
                            description: String::new(),
                            index: mode_index,
                            gain_min: None,
                            gain_max: None,
                            offset_min: None,
                            offset_max: None,
                        };
                        return camera
                            .set_readout_mode(&mode)
                            .await
                            .map_err(DeviceOpError::from);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM camera {} not found", device_id),
                ))
            }
            Some(DriverType::Alpaca) => {
                let cameras = self.alpaca_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    return camera
                        .set_readout_mode(mode_index)
                        .await
                        .map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // INDI uses CCD_READ_MODE switch with indexed elements
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    // INDI cameras expose readout speed as a switch property.
                    // Common property names: CCD_READ_MODE, CCD_READOUT_SPEED, READOUT_QUALITY
                    let switch_props = ["CCD_READ_MODE", "CCD_READOUT_SPEED", "READOUT_QUALITY"];
                    let all_props = locked.get_properties(&device_name).await;
                    for prop_name in &switch_props {
                        if let Some(prop) = all_props.iter().find(|p| {
                            p.name == *prop_name
                                && p.property_type == skotiq_indi::IndiPropertyType::Switch
                        }) {
                            if (mode_index as usize) < prop.elements.len() {
                                let element = prop.elements[mode_index as usize].clone();
                                locked
                                    .set_switch(&device_name, prop_name, &element, true)
                                    .await
                                    .map_err(|e| {
                                        DeviceOpError::hardware(
                                            Some(device_id.to_string()),
                                            format!("Failed to set INDI readout mode: {}", e),
                                        )
                                    })?;
                                return Ok(());
                            } else {
                                return Err(DeviceOpError::invalid_parameter(format!(
                                    "Readout mode index {} out of range (camera has {} modes)",
                                    mode_index,
                                    prop.elements.len()
                                )));
                            }
                        }
                    }
                    // No readout mode property found - not an error, many INDI cameras lack this
                    tracing::debug!(
                        "No readout mode switch property found for INDI camera {}",
                        device_name
                    );
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for server {}", server_key),
                ))
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    let mode = skotiq_native::camera::ReadoutMode {
                        name: format!("Mode {}", mode_index),
                        description: String::new(),
                        index: mode_index,
                        gain_min: None,
                        gain_max: None,
                        offset_min: None,
                        offset_max: None,
                    };
                    return camera
                        .set_readout_mode(&mode)
                        .await
                        .map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                // `SimulatedCamera::status` has no readout-mode field and the
                // simulator advertises no readout modes, so there is no index
                // to select and nothing a read-back could contradict. Reporting
                // success would leave the caller believing a mode was applied.
                Err(DeviceOpError::unsupported(
                    "Simulated cameras do not support readout modes",
                ))
            }
            _ => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found or not supported", device_id),
            )),
        }
    }

    /// The setpoint that may accompany a cooler command.
    ///
    /// Switching a cooler **off** carries no setpoint: the TEC stops, and no
    /// temperature needs naming to make that happen. End-of-night warm-up and
    /// the `safe_rig` shutdown path are both `enabled = false` with no target,
    /// so this is the shape that matters.
    pub(crate) fn cooler_setpoint_to_command(
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Option<f64> {
        if enabled {
            target_temp
        } else {
            None
        }
    }

    /// Set camera cooler
    pub async fn camera_set_cooler(
        &self,
        device_id: &str,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let target_temp = Self::cooler_setpoint_to_command(enabled, target_temp);
        let result = self
            .camera_set_cooler_dispatch(device_id, enabled, target_temp)
            .await;

        // Record the commanded cooler state so an unplanned reconnect (USB yank
        // mid-run) can re-apply it. The driver comes back from a reconnect with
        // the cooler off and the setpoint cleared; without this the sensor
        // silently warms up while the sequence "resumes". Only record on a
        // successful command — a failed set must not overwrite the last known
        // good desired state.
        if result.is_ok() {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                dev.desired_cooler = Some((enabled, target_temp));
            }
        }

        result
    }

    /// Driver dispatch for `camera_set_cooler`. Split out so the public method
    /// can record the desired cooler state (for reconnect re-application)
    /// around the per-driver calls without threading the bookkeeping through
    /// every early-return arm.
    async fn camera_set_cooler_dispatch(
        &self,
        device_id: &str,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let cameras = self.ascom_cameras.read().await;
                    if let Some(cam) = cameras.get(device_id) {
                        let mut cam = cam.write().await;
                        cam.set_cooler(enabled, target_temp).await.map_err(|e| {
                            let target = match target_temp {
                                Some(t) => format!("{}C", t),
                                None => "unchanged".to_string(),
                            };
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                "Failed to set ASCOM camera {} cooler (enabled={}, target={}): {}",
                                device_id, enabled, target, e
                            ),
                            )
                        })?;
                        return Ok(());
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM camera not connected",
                ))
            }
            Some(DriverType::Alpaca) => {
                let cameras = self.alpaca_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    camera.set_cooler_on(enabled).await?;
                    if let Some(temp) = target_temp {
                        camera.set_ccd_temperature(temp).await?;
                    }
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // Parse device_id format: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked_client = client.write().await;
                    // Set cooler on/off
                    let switch_element = if enabled { "COOLER_ON" } else { "COOLER_OFF" };
                    locked_client
                        .set_switch(&device_name, "CCD_COOLER", switch_element, true)
                        .await?;
                    // Set target temperature if provided
                    if let Some(temp) = target_temp {
                        locked_client
                            .set_number(
                                &device_name,
                                "CCD_TEMPERATURE",
                                "CCD_TEMPERATURE_VALUE",
                                temp,
                            )
                            .await?;
                    }
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for server {}", server_key),
                ))
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    return camera
                        .set_cooler(enabled, target_temp)
                        .await
                        .map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                let cam = crate::api::devices::simulation::get_sim_camera();
                let mut cam = cam.write().await;
                if !cam.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_camera(),
                    ));
                }
                cam.status.cooler_on = enabled;
                if let Some(t) = target_temp {
                    cam.status.target_temp = Some(t);
                }
                Ok(())
            }
            None => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Driver type not found",
            )),
        }
    }
}
