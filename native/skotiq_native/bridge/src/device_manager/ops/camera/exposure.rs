use super::*;
use skotiq_indi::names as indi;

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
        frame_type: skotiq_device::FrameType,
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
        frame_type: skotiq_device::FrameType,
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
                            DeviceOpError::caused_by(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to start ASCOM camera exposure on {}: {}",
                                    device_id, e
                                ),
                                e,
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
                    return alpaca_start_exposure(
                        camera, device_id, duration, gain, offset, (bin_x, bin_y), subframe,
                        frame_type,
                    )
                    .await;
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
                                .set_number(
                                    &device_name,
                                    indi::CCD_CONTROLS,
                                    indi::CONTROLS_GAIN,
                                    g as f64,
                                )
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
                                .set_number(
                                    &device_name,
                                    indi::CCD_CONTROLS,
                                    indi::CONTROLS_OFFSET,
                                    o as f64,
                                )
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
                            .set_number(
                                &device_name,
                                indi::CCD_BINNING,
                                indi::HOR_BIN,
                                bin_x as f64,
                            )
                            .await
                            .map_err(|e| {
                                DeviceOpError::caused_by(
                                    Some(device_id.to_string()),
                                    format!("Failed to set INDI camera horizontal binning: {}", e),
                                    e,
                                )
                            })?;
                        locked_client
                            .set_number(
                                &device_name,
                                indi::CCD_BINNING,
                                indi::VER_BIN,
                                bin_y as f64,
                            )
                            .await
                            .map_err(|e| {
                                DeviceOpError::caused_by(
                                    Some(device_id.to_string()),
                                    format!("Failed to set INDI camera vertical binning: {}", e),
                                    e,
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
                                    .get_number(&device_name, indi::CCD_INFO, indi::CCD_MAX_X)
                                    .await
                                    .filter(|value| value.is_finite() && *value > 0.0)
                                    .ok_or_else(|| {
                                        DeviceOpError::hardware(
                                        Some(device_id.to_string()),
                                        "INDI camera did not report CCD_MAX_X for full-frame reset",
                                    )
                                    })?;
                                let sensor_height = locked_client
                                    .get_number(&device_name, indi::CCD_INFO, indi::CCD_MAX_Y)
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
                                indi::CCD_FRAME,
                                &[
                                    ("X", frame_x),
                                    ("Y", frame_y),
                                    (indi::WIDTH, frame_width),
                                    (indi::HEIGHT, frame_height),
                                ],
                            )
                            .await
                            .map_err(|e| {
                                DeviceOpError::caused_by(
                                    Some(device_id.to_string()),
                                    format!("Failed to set INDI camera frame geometry: {}", e),
                                    e,
                                )
                            })?;
                        return locked_client
                            .set_number(
                                &device_name,
                                indi::CCD_EXPOSURE,
                                indi::CCD_EXPOSURE_VALUE,
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
                        DeviceOpError::caused_by(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to start native SDK camera exposure on {}: {}",
                                device_id, e
                            ),
                            e,
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                crate::device_manager::ops::sim_gate::require_camera_connected(device_id).await?;
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
                    crate::api::devices::simulation::begin_sim_exposure_for(
                        device_id,
                        crate::api::devices::simulation::SimExposureRequest {
                            secs: duration,
                            frame_type,
                            subframe: subframe
                                .as_ref()
                                .map(|r| (r.start_x, r.start_y, r.width, r.height)),
                        },
                    )
                    .await;
                    let sim = crate::api::devices::simulation::get_sim_camera_for(device_id);
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
                            .get_number(&device_name, indi::CCD_EXPOSURE, indi::CCD_EXPOSURE_VALUE)
                            .await
                        {
                            return Ok(value <= 0.0);
                        }
                        if locked_client
                            .is_property_busy(&device_name, indi::CCD_EXPOSURE)
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
                crate::device_manager::ops::sim_gate::require_camera_connected(device_id).await?;
                Ok(crate::api::devices::simulation::sim_exposure_is_complete(device_id).await)
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
                            .set_switch(&device_name, indi::CCD_ABORT_EXPOSURE, indi::ABORT, true)
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
                crate::device_manager::ops::sim_gate::require_camera_connected(device_id)
                    .await?;
                // Release a caller polling for completion, but remember that the
                // frame was abandoned: a download afterwards has nothing to
                // hand back and must say so.
                crate::api::devices::simulation::abort_sim_exposure(device_id).await;
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

/// One Alpaca exposure, by the ASCOM camera rules both transports share
/// (`skotiq_device::ascom::camera`): binning, then the whole frame in binned
/// pixels, then gain and offset in the camera's own mode, then
/// `StartExposure` with the shutter closed for darks and biases.
#[allow(clippy::too_many_arguments)]
async fn alpaca_start_exposure(
    camera: &skotiq_alpaca::AlpacaCamera,
    device_id: &str,
    duration: f64,
    gain: Option<i32>,
    offset: Option<i32>,
    bin: (i32, i32),
    subframe: Option<SubFrame>,
    frame_type: skotiq_device::FrameType,
) -> Result<(), DeviceOpError> {
    use skotiq_device::ascom::camera::{exposes_to_light, frame_geometry};
    let failed = |what: &str, e: skotiq_alpaca::AlpacaError| {
        DeviceOpError::caused_by(
            Some(device_id.to_string()),
            format!("Failed to {what} on Alpaca camera {device_id}: {e}"),
            e,
        )
    };
    let (sensor_x, sensor_y, max_bin_x, max_bin_y) = tokio::join!(
        camera.camera_x_size(),
        camera.camera_y_size(),
        camera.max_bin_x(),
        camera.max_bin_y(),
    );
    let sensor = (
        sensor_x.map_err(|e| failed("read CameraXSize", e))?,
        sensor_y.map_err(|e| failed("read CameraYSize", e))?,
    );
    let max_bin = (max_bin_x.unwrap_or(1), max_bin_y.unwrap_or(1));
    let frame = frame_geometry(sensor, max_bin, bin, subframe.as_ref())
        .map_err(|e| DeviceOpError::hardware(Some(device_id.to_string()), e.to_string()))?;

    camera
        .set_bin_x(bin.0)
        .await
        .map_err(|e| failed("set BinX", e))?;
    camera
        .set_bin_y(bin.1)
        .await
        .map_err(|e| failed("set BinY", e))?;
    camera
        .set_start_x(frame.start_x)
        .await
        .map_err(|e| failed("set StartX", e))?;
    camera
        .set_start_y(frame.start_y)
        .await
        .map_err(|e| failed("set StartY", e))?;
    camera
        .set_num_x(frame.num_x)
        .await
        .map_err(|e| failed("set NumX", e))?;
    camera
        .set_num_y(frame.num_y)
        .await
        .map_err(|e| failed("set NumY", e))?;

    // Gain and offset are optional members: a camera without them, or one that
    // refuses the value, still exposes at its current setting (as INDI does).
    let controls = camera.controls().await;
    if let Some(requested) = gain {
        match controls.gain.to_wire(requested, "Gain") {
            Ok(wire) => {
                if let Err(e) = camera.set_gain(wire).await {
                    warn!("Alpaca camera {device_id} refused gain {requested}; exposing at its current gain: {e}");
                }
            }
            Err(skotiq_device::DriverError::NotSupported) => {}
            Err(e) => warn!("Alpaca camera {device_id}: {e}; exposing at its current gain"),
        }
    }
    if let Some(requested) = offset {
        match controls.offset.to_wire(requested, "Offset") {
            Ok(wire) => {
                if let Err(e) = camera.set_offset(wire).await {
                    warn!("Alpaca camera {device_id} refused offset {requested}; exposing at its current offset: {e}");
                }
            }
            Err(skotiq_device::DriverError::NotSupported) => {}
            Err(e) => warn!("Alpaca camera {device_id}: {e}; exposing at its current offset"),
        }
    }
    camera
        .start_exposure(duration, exposes_to_light(frame_type))
        .await
        .map_err(DeviceOpError::from)
}
