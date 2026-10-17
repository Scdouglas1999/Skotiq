use super::*;

impl DeviceManager {
    // Camera control

    /// Start a camera exposure
    pub async fn camera_start_exposure(
        &self,
        device_id: &str,
        duration: f64,
        // `None` means "leave the camera's current gain/offset unchanged" — the
        // node did not specify one. It stays optional end-to-end so each driver
        // branch can skip the setter; collapsing `None` to `0` both masks the
        // real value and, on drivers that honor it, sets gain/offset to 0.
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        frame_type: skotiq_native::camera::FrameType,
    ) -> Result<(), DeviceOpError> {
        self.camera_start_exposure_configured(
            device_id, duration, gain, offset, bin_x, bin_y, None, frame_type,
        )
        .await
    }

    /// Start an exposure while preserving the complete per-frame acquisition
    /// contract, including a binned-pixel ROI when one was requested.
    #[allow(clippy::too_many_arguments)]
    pub async fn camera_start_exposure_configured(
        &self,
        device_id: &str,
        duration: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<SubFrame>,
        frame_type: skotiq_native::camera::FrameType,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_start_exposure for {} duration={}",
            device_id,
            duration
        );

        // Get the driver type for this device
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
                        let params = ExposureParams {
                            duration_secs: duration,
                            bin_x,
                            bin_y,
                            gain,
                            offset,
                            subframe,
                            readout_mode: None,
                            frame_type,
                        };
                        tracing::info!(
                            "DeviceManager: Calling AscomCameraWrapper.start_exposure()"
                        );
                        let mut camera = camera.write().await;
                        return camera.start_exposure(params).await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to start ASCOM camera exposure on {}: {}",
                                    device_id, e
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
                    tracing::info!("DeviceManager: Calling AlpacaCamera.start_exposure()");
                    // Gain and Offset are OPTIONAL in ASCOM ICameraV3 — a camera
                    // that doesn't implement them throws PropertyNotImplemented
                    // (error 1024). Warn and continue rather than failing the
                    // whole exposure (mirrors the INDI path below), so gain-less
                    // cameras (many CCDs, and CMOS in certain modes) can still
                    // capture instead of erroring out on every frame.
                    if let Some(g) = gain {
                        if let Err(e) = camera.set_gain(g).await {
                            tracing::warn!(
                                "Failed to set Alpaca camera gain (device may not \
                                 support it); continuing without it: {}",
                                e
                            );
                        }
                    }
                    if let Some(o) = offset {
                        if let Err(e) = camera.set_offset(o).await {
                            tracing::warn!(
                                "Failed to set Alpaca camera offset (device may not \
                                 support it); continuing without it: {}",
                                e
                            );
                        }
                    }
                    // Set binning - propagate errors
                    camera.set_bin_x(bin_x).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to set Alpaca camera bin_x: {}", e),
                        )
                    })?;
                    camera.set_bin_y(bin_y).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to set Alpaca camera bin_y: {}", e),
                        )
                    })?;
                    // Alpaca/ASCOM defines NumX/NumY in binned pixels. Changing
                    // BinX/BinY does not require drivers to resize an existing
                    // full-frame ROI, and several leave the unbinned
                    // dimensions in place. Reset the full-frame ROI after
                    // binning so a 2x2 exposure on an 800x600 sensor requests
                    // 400x300 instead of the invalid 800x600.
                    let sensor_width = camera.camera_x_size().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to read Alpaca camera width: {}", e),
                        )
                    })?;
                    let sensor_height = camera.camera_y_size().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to read Alpaca camera height: {}", e),
                        )
                    })?;
                    let full_width = sensor_width
                        .checked_div(bin_x)
                        .filter(|v| *v > 0)
                        .ok_or_else(|| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Invalid Alpaca full-frame width {} at bin {}",
                                    sensor_width, bin_x
                                ),
                            )
                        })?;
                    let full_height = sensor_height
                        .checked_div(bin_y)
                        .filter(|v| *v > 0)
                        .ok_or_else(|| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Invalid Alpaca full-frame height {} at bin {}",
                                    sensor_height, bin_y
                                ),
                            )
                        })?;
                    let (start_x, start_y, num_x, num_y) = match subframe {
                        Some(ref roi) => {
                            let start_x = i32::try_from(roi.start_x).map_err(|_| {
                                DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    "Alpaca ROI start_x exceeds the driver integer range",
                                )
                            })?;
                            let start_y = i32::try_from(roi.start_y).map_err(|_| {
                                DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    "Alpaca ROI start_y exceeds the driver integer range",
                                )
                            })?;
                            let width = i32::try_from(roi.width).map_err(|_| {
                                DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    "Alpaca ROI width exceeds the driver integer range",
                                )
                            })?;
                            let height = i32::try_from(roi.height).map_err(|_| {
                                DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    "Alpaca ROI height exceeds the driver integer range",
                                )
                            })?;
                            if start_x.checked_add(width).is_none_or(|v| v > full_width)
                                || start_y.checked_add(height).is_none_or(|v| v > full_height)
                            {
                                return Err(DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    format!(
                                        "Alpaca ROI {}x{}+{}+{} exceeds binned sensor {}x{}",
                                        width, height, start_x, start_y, full_width, full_height
                                    ),
                                ));
                            }
                            (start_x, start_y, width, height)
                        }
                        None => (0, 0, full_width, full_height),
                    };
                    camera
                        .set_start_x(start_x)
                        .await
                        .map_err(DeviceOpError::from)?;
                    camera
                        .set_start_y(start_y)
                        .await
                        .map_err(DeviceOpError::from)?;
                    camera.set_num_x(num_x).await.map_err(DeviceOpError::from)?;
                    camera.set_num_y(num_y).await.map_err(DeviceOpError::from)?;
                    // Start the exposure
                    return camera
                        .start_exposure(duration, true)
                        .await
                        .map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        tracing::info!("DeviceManager: Starting INDI exposure on {}", device_name);
                        let mut locked_client = client.write().await;
                        // Set gain/offset if the node specified them (None =
                        // leave unchanged). Some INDI cameras don't support
                        // these, so warn but continue.
                        if let Some(g) = gain {
                            if let Err(e) = locked_client
                                .set_number(&device_name, "CCD_CONTROLS", "Gain", g as f64)
                                .await
                            {
                                tracing::warn!(
                                    "Failed to set INDI camera gain (device may not support it): {}",
                                    e
                                );
                            }
                        }
                        if let Some(o) = offset {
                            if let Err(e) = locked_client
                                .set_number(&device_name, "CCD_CONTROLS", "Offset", o as f64)
                                .await
                            {
                                tracing::warn!(
                                    "Failed to set INDI camera offset (device may not support it): {}",
                                    e
                                );
                            }
                        }
                        // Set binning - propagate errors since binning is typically supported
                        locked_client
                            .set_number(&device_name, "CCD_BINNING", "HOR_BIN", bin_x as f64)
                            .await
                            .map_err(|e| {
                                DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    format!("Failed to set INDI camera horizontal binning: {}", e),
                                )
                            })?;
                        locked_client
                            .set_number(&device_name, "CCD_BINNING", "VER_BIN", bin_y as f64)
                            .await
                            .map_err(|e| {
                                DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    format!("Failed to set INDI camera vertical binning: {}", e),
                                )
                            })?;
                        let (frame_x, frame_y, frame_width, frame_height) =
                            if let Some(ref roi) = subframe {
                                (
                                    f64::from(roi.start_x),
                                    f64::from(roi.start_y),
                                    f64::from(roi.width),
                                    f64::from(roi.height),
                                )
                            } else {
                                let sensor_width = locked_client
                                    .get_number(&device_name, "CCD_INFO", "CCD_MAX_X")
                                    .await
                                    .filter(|value| value.is_finite() && *value > 0.0)
                                    .ok_or_else(|| {
                                        DeviceOpError::hardware(
                                        Some(device_id.to_string()),
                                        "INDI camera did not report CCD_MAX_X for full-frame reset",
                                    )
                                    })?;
                                let sensor_height = locked_client
                                    .get_number(&device_name, "CCD_INFO", "CCD_MAX_Y")
                                    .await
                                    .filter(|value| value.is_finite() && *value > 0.0)
                                    .ok_or_else(|| {
                                        DeviceOpError::hardware(
                                        Some(device_id.to_string()),
                                        "INDI camera did not report CCD_MAX_Y for full-frame reset",
                                    )
                                    })?;
                                (
                                    0.0,
                                    0.0,
                                    sensor_width / f64::from(bin_x),
                                    sensor_height / f64::from(bin_y),
                                )
                            };
                        locked_client
                            .set_numbers(
                                &device_name,
                                "CCD_FRAME",
                                &[
                                    ("X", frame_x),
                                    ("Y", frame_y),
                                    ("WIDTH", frame_width),
                                    ("HEIGHT", frame_height),
                                ],
                            )
                            .await
                            .map_err(|e| {
                                DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    format!("Failed to set INDI camera frame geometry: {}", e),
                                )
                            })?;
                        // Start exposure
                        return locked_client
                            .set_number(
                                &device_name,
                                "CCD_EXPOSURE",
                                "CCD_EXPOSURE_VALUE",
                                duration,
                            )
                            .await
                            .map_err(DeviceOpError::from);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI camera {} not found", device_id),
                ))
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    tracing::info!("DeviceManager: Starting Native SDK exposure");
                    let params = ExposureParams {
                        duration_secs: duration,
                        bin_x,
                        bin_y,
                        gain,
                        offset,
                        subframe,
                        readout_mode: None,
                        frame_type,
                    };
                    return camera.start_exposure(params).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to start native SDK camera exposure on {}: {}",
                                device_id, e
                            ),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                crate::device_manager::ops::sim_gate::require_camera_connected().await?;
                // Commit the requested settings to the singleton so the download
                // reports what this exposure was actually taken with. Skipping
                // this made the simulator answer with its defaults (gain 100 /
                // offset 10 / 1.0s) regardless of the request, so a simulated
                // run wrote FITS headers that contradicted the sequence — the
                // kind of disagreement that makes simulator testing worse than
                // no testing. `None` gain/offset still means "leave unchanged",
                // matching the real driver branches above.
                {
                    // Starts the exposure CLOCK as well as recording the
                    // duration: the simulator integrates for the time it was
                    // asked for, so callers are paced the way real hardware
                    // paces them.
                    crate::api::devices::simulation::begin_sim_exposure(
                        crate::api::devices::simulation::SimExposureRequest {
                            secs: duration,
                            frame_type,
                            subframe: subframe
                                .as_ref()
                                .map(|r| (r.start_x, r.start_y, r.width, r.height)),
                        },
                    )
                    .await;
                    let sim = crate::api::devices::simulation::get_sim_camera();
                    let mut guard = sim.write().await;
                    if let Some(g) = gain {
                        guard.status.gain = g;
                    }
                    if let Some(o) = offset {
                        guard.status.offset = o;
                    }
                    guard.status.bin_x = bin_x;
                    guard.status.bin_y = bin_y;
                }
                tracing::info!("camera_start_exposure: Simulator exposure started");
                Ok(())
            }
            None => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Device {} not found", device_id),
            )),
        }
    }

    /// Check if camera exposure is complete
    pub async fn camera_is_exposure_complete(
        &self,
        device_id: &str,
    ) -> Result<bool, DeviceOpError> {
        // Get the driver type for this device
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
                        let camera = camera.read().await;
                        return camera
                            .is_exposure_complete()
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
                    return camera.image_ready().await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // For INDI, check CCD_EXPOSURE state - when value is 0, exposure is complete
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let locked_client = client.read().await;
                        // Check if exposure value is 0 (complete) - get_number returns Option
                        if let Some(value) = locked_client
                            .get_number(&device_name, "CCD_EXPOSURE", "CCD_EXPOSURE_VALUE")
                            .await
                        {
                            return Ok(value <= 0.0);
                        }
                        if locked_client
                            .is_property_busy(&device_name, "CCD_EXPOSURE")
                            .await
                        {
                            return Ok(false);
                        }
                        return Err(DeviceOpError::hardware(Some(device_id.to_string()), format!(
                            "INDI camera {} exposure status is unavailable (missing CCD_EXPOSURE_VALUE)",
                            device_name
                        )));
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                // Complete only once the requested integration time has
                // elapsed, so the simulator paces a capture loop the way a real
                // camera does (see `SIM_EXPOSURE_START`). Refuse the call when
                // not connected, so callers can distinguish "nothing to expose"
                // from "no camera attached".
                crate::device_manager::ops::sim_gate::require_camera_connected().await?;
                Ok(crate::api::devices::simulation::sim_exposure_is_complete().await)
            }
            Some(DriverType::Native) => {
                let native_cameras = self.native_cameras.read().await;
                if let Some(camera) = native_cameras.get(device_id) {
                    return camera
                        .is_exposure_complete()
                        .await
                        .map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            None => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found", device_id),
            )),
        }
    }

    /// Abort a camera exposure
    pub async fn camera_abort_exposure(&self, device_id: &str) -> Result<(), DeviceOpError> {
        tracing::info!("DeviceManager: camera_abort_exposure for {}", device_id);

        // Get the driver type for this device
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
                        return camera.abort_exposure().await.map_err(DeviceOpError::from);
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
                    return camera.abort_exposure().await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // For INDI, set exposure to 0 to abort
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let mut locked_client = client.write().await;
                        return locked_client
                            .set_switch(&device_name, "CCD_ABORT_EXPOSURE", "ABORT", true)
                            .await
                            .map_err(DeviceOpError::from);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                crate::device_manager::ops::sim_gate::require_camera_connected()
                    .await
                    .map_err(DeviceOpError::from)?;
                // Release a caller polling for completion, but remember that the
                // frame was abandoned: a download afterwards has nothing to
                // hand back and must say so.
                crate::api::devices::simulation::abort_sim_exposure().await;
                Ok(())
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    return camera.abort_exposure().await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            None => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found", device_id),
            )),
        }
    }
}
