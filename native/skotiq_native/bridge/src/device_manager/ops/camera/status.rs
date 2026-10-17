use super::*;

impl DeviceManager {
    /// Get camera status
    pub async fn camera_get_status(
        &self,
        device_id: &str,
    ) -> Result<crate::device::CameraStatus, DeviceOpError> {
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
                        let camera_guard = camera.read().await;
                        let native_status = camera_guard
                            .get_status()
                            .await
                            .map_err(DeviceOpError::from)?;
                        let ascom_caps = camera_guard.get_capabilities().await.ok();

                        return Ok(crate::device::CameraStatus {
                            connected: true,
                            state: match native_status.state {
                                skotiq_native::camera::CameraState::Idle => {
                                    crate::device::CameraState::Idle
                                }
                                skotiq_native::camera::CameraState::Waiting => {
                                    crate::device::CameraState::Waiting
                                }
                                skotiq_native::camera::CameraState::Exposing => {
                                    crate::device::CameraState::Exposing
                                }
                                skotiq_native::camera::CameraState::Reading => {
                                    crate::device::CameraState::Reading
                                }
                                skotiq_native::camera::CameraState::Downloading => {
                                    crate::device::CameraState::Download
                                }
                                skotiq_native::camera::CameraState::Error => {
                                    crate::device::CameraState::Error
                                }
                            },
                            sensor_temp: native_status.sensor_temp,
                            cooler_power: native_status.cooler_power,
                            target_temp: native_status.target_temp,
                            cooler_on: native_status.cooler_on,
                            gain: native_status.gain,
                            offset: native_status.offset,
                            bin_x: native_status.bin_x,
                            bin_y: native_status.bin_y,
                            sensor_width: ascom_caps.as_ref().map(|c| c.max_width).unwrap_or(0),
                            sensor_height: ascom_caps.as_ref().map(|c| c.max_height).unwrap_or(0),
                            pixel_size_x: ascom_caps
                                .as_ref()
                                .and_then(|c| c.pixel_size_x)
                                .unwrap_or(0.0),
                            pixel_size_y: ascom_caps
                                .as_ref()
                                .and_then(|c| c.pixel_size_y)
                                .unwrap_or(0.0),
                            // The driver's own MaxADU, not `2^bit_depth - 1`:
                            // `bit_depth` here is a bucket (8/16/32) inferred FROM
                            // MaxADU, so reconstructing the range from it reported
                            // 65535 for every driver whose MaxADU exceeded 255.
                            max_adu: ascom_caps
                                .as_ref()
                                .map(|c| if c.max_adu == 0 { 65535 } else { c.max_adu })
                                .unwrap_or(65535),
                            can_cool: ascom_caps
                                .as_ref()
                                .map(|c| c.can_set_ccd_temperature)
                                .unwrap_or(false),
                            // Read from the driver like every other field here,
                            // rather than asserting true. These were hardcoded
                            // while `ascom_caps` — already in hand and used for
                            // `can_cool` directly above — carried the real
                            // answer, so `/api/equipment/camera/status` flatly
                            // contradicted `/api/equipment/camera/capabilities`
                            // for the same device. Observed against the ASCOM
                            // Camera Simulator: capabilities correctly said
                            // `canSetGain: false` (its Gain property throws
                            // 0x80020009 / PropertyNotImplemented) while status
                            // claimed `canSetGain: true`, so a client trusting
                            // status offered a gain control that always failed.
                            // `unwrap_or(false)` matches `can_cool`: if the
                            // capability probe itself failed we must not promise
                            // a control we cannot deliver.
                            can_set_gain: ascom_caps
                                .as_ref()
                                .map(|c| c.can_set_gain)
                                .unwrap_or(false),
                            can_set_offset: ascom_caps
                                .as_ref()
                                .map(|c| c.can_set_offset)
                                .unwrap_or(false),
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
                    let status = camera.get_status().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read Alpaca camera status for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let capabilities = camera.get_capabilities().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read Alpaca camera capabilities for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let sensor = camera.get_sensor_info().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read Alpaca camera sensor info for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let gain = camera.gain().await.ok();
                    let offset = camera.offset().await.ok();

                    return Ok(crate::device::CameraStatus {
                        connected: true,
                        state: match status.state {
                            skotiq_alpaca::CameraState::Idle => {
                                crate::device::CameraState::Idle
                            }
                            skotiq_alpaca::CameraState::Waiting => {
                                crate::device::CameraState::Waiting
                            }
                            skotiq_alpaca::CameraState::Exposing => {
                                crate::device::CameraState::Exposing
                            }
                            skotiq_alpaca::CameraState::Reading => {
                                crate::device::CameraState::Reading
                            }
                            skotiq_alpaca::CameraState::Download => {
                                crate::device::CameraState::Download
                            }
                            skotiq_alpaca::CameraState::Error => {
                                crate::device::CameraState::Error
                            }
                        },
                        sensor_temp: status.ccd_temperature,
                        cooler_power: status.cooler_power,
                        target_temp: None, // Alpaca doesn't provide target temp directly
                        cooler_on: status.cooler_on.unwrap_or(false),
                        gain: gain.unwrap_or(0),
                        offset: offset.unwrap_or(0),
                        bin_x: status.bin_x,
                        bin_y: status.bin_y,
                        sensor_width: sensor.camera_x_size as u32,
                        sensor_height: sensor.camera_y_size as u32,
                        pixel_size_x: sensor.pixel_size_x,
                        pixel_size_y: sensor.pixel_size_y,
                        max_adu: sensor.max_adu as u32,
                        can_cool: capabilities.can_set_ccd_temperature,
                        can_set_gain: gain.is_some(),
                        can_set_offset: offset.is_some(),
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                crate::device_manager::ops::sim_gate::read_camera_status()
                    .await
                    .map_err(DeviceOpError::from)
            }
            Some(DriverType::Native) => {
                let native_cameras = self.native_cameras.read().await;
                if let Some(camera) = native_cameras.get(device_id) {
                    let native_status = camera.get_status().await.map_err(DeviceOpError::from)?;
                    let capabilities = camera.capabilities();
                    let sensor_info = camera.get_sensor_info();

                    return Ok(crate::device::CameraStatus {
                        connected: camera.is_connected(),
                        state: match native_status.state {
                            skotiq_native::camera::CameraState::Idle => {
                                crate::device::CameraState::Idle
                            }
                            skotiq_native::camera::CameraState::Waiting => {
                                crate::device::CameraState::Waiting
                            }
                            skotiq_native::camera::CameraState::Exposing => {
                                crate::device::CameraState::Exposing
                            }
                            skotiq_native::camera::CameraState::Reading => {
                                crate::device::CameraState::Reading
                            }
                            skotiq_native::camera::CameraState::Downloading => {
                                crate::device::CameraState::Download
                            }
                            skotiq_native::camera::CameraState::Error => {
                                crate::device::CameraState::Error
                            }
                        },
                        sensor_temp: native_status.sensor_temp,
                        cooler_power: native_status.cooler_power,
                        target_temp: native_status.target_temp,
                        cooler_on: native_status.cooler_on,
                        gain: native_status.gain,
                        offset: native_status.offset,
                        bin_x: native_status.bin_x,
                        bin_y: native_status.bin_y,
                        sensor_width: sensor_info.width,
                        sensor_height: sensor_info.height,
                        pixel_size_x: sensor_info.pixel_size_x,
                        pixel_size_y: sensor_info.pixel_size_y,
                        // The DRIVER owns this value. Re-deriving it from
                        // `bit_depth` here overwrote whatever the vendor SDK
                        // reported with the ADC range, which is a different
                        // quantity: an ASI1600MM (12-bit, Raw16 left-justified)
                        // was published as `maxAdu: 4095` while its frames
                        // measurably contained values up to 65504. See the
                        // `skotiq_native::camera::SensorInfo` contract.
                        // 0 = the driver never populated it; 65535 is the
                        // container ceiling and the documented fallback (see the
                        // `unwrap_or` policy in this module's header).
                        max_adu: if sensor_info.max_adu == 0 {
                            65535
                        } else {
                            sensor_info.max_adu
                        },
                        can_cool: capabilities.can_cool,
                        can_set_gain: capabilities.can_set_gain,
                        can_set_offset: capabilities.can_set_offset,
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // Parse device_id format: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked_client = client.read().await;

                    // Query INDI camera properties
                    let sensor_temp = locked_client
                        .get_number(&device_name, "CCD_TEMPERATURE", "CCD_TEMPERATURE_VALUE")
                        .await;
                    let cooler_state = locked_client
                        .get_switch(&device_name, "CCD_COOLER", "COOLER_ON")
                        .await;
                    let has_cooler = cooler_state.is_some();
                    let cooler_on = cooler_state.unwrap_or(false);
                    let bin_x = locked_client
                        .get_number(&device_name, "CCD_BINNING", "HOR_BIN")
                        .await
                        .map(|v| v as i32)
                        .ok_or_else(|| {
                            DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_BINNING.HOR_BIN; cannot determine current binning.",
                                device_id
                            ))
                        })?;
                    let bin_y = locked_client
                        .get_number(&device_name, "CCD_BINNING", "VER_BIN")
                        .await
                        .map(|v| v as i32)
                        .ok_or_else(|| {
                            DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_BINNING.VER_BIN; cannot determine current binning.",
                                device_id
                            ))
                        })?;
                    let exposure_value = locked_client
                        .get_number(&device_name, "CCD_EXPOSURE", "CCD_EXPOSURE_VALUE")
                        .await;

                    // Determine camera state based on exposure value
                    let state = match exposure_value {
                        Some(v) if v > 0.0 => crate::device::CameraState::Exposing,
                        Some(_) => crate::device::CameraState::Idle,
                        None => {
                            return Err(DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_EXPOSURE.CCD_EXPOSURE_VALUE; cannot determine camera state.",
                                device_id
                            )))
                        }
                    };

                    // Read sensor info from INDI CCD_INFO property.
                    let sensor_width = locked_client
                        .get_number(&device_name, "CCD_INFO", "CCD_MAX_X")
                        .await
                        .map(|v| v as u32)
                        .ok_or_else(|| {
                            DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_INFO.CCD_MAX_X; cannot determine sensor width.",
                                device_id
                            ))
                        })?;
                    let sensor_height = locked_client
                        .get_number(&device_name, "CCD_INFO", "CCD_MAX_Y")
                        .await
                        .map(|v| v as u32)
                        .ok_or_else(|| {
                            DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_INFO.CCD_MAX_Y; cannot determine sensor height.",
                                device_id
                            ))
                        })?;
                    let pixel_size_x = locked_client
                        .get_number(&device_name, "CCD_INFO", "CCD_PIXEL_SIZE_X")
                        .await
                        .ok_or_else(|| {
                            DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_INFO.CCD_PIXEL_SIZE_X; cannot determine pixel size.",
                                device_id
                            ))
                        })?;
                    let pixel_size_y = locked_client
                        .get_number(&device_name, "CCD_INFO", "CCD_PIXEL_SIZE_Y")
                        .await
                        .ok_or_else(|| {
                            DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_INFO.CCD_PIXEL_SIZE_Y; cannot determine pixel size.",
                                device_id
                            ))
                        })?;
                    let bit_depth = locked_client
                        .get_number(&device_name, "CCD_INFO", "CCD_BITSPERPIXEL")
                        .await
                        .map(|v| v as u32)
                        .ok_or_else(|| {
                            DeviceOpError::hardware(Some(device_id.to_string()), format!(
                                "INDI camera {} missing required property CCD_INFO.CCD_BITSPERPIXEL; cannot determine ADU scaling.",
                                device_id
                            ))
                        })?;
                    if bit_depth == 0 {
                        return Err(DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "INDI camera {} reported invalid CCD_INFO.CCD_BITSPERPIXEL=0.",
                                device_id
                            ),
                        ));
                    }
                    let gain_value = match locked_client
                        .get_number(&device_name, "CCD_GAIN", "GAIN")
                        .await
                    {
                        Some(value) => Some(value),
                        None => {
                            locked_client
                                .get_number(&device_name, "CCD_CONTROLS", "Gain")
                                .await
                        }
                    };
                    let offset_value = locked_client
                        .get_number(&device_name, "CCD_OFFSET", "OFFSET")
                        .await;
                    let gain = gain_value.map(|v| v as i32).unwrap_or(0);
                    let offset = offset_value.map(|v| v as i32).unwrap_or(0);
                    let cooler_power = locked_client
                        .get_number(&device_name, "CCD_COOLER_POWER", "CCD_COOLER_VALUE")
                        .await;
                    let has_gain = gain_value.is_some();
                    let has_offset = offset_value.is_some();
                    let max_adu_from_driver = match locked_client
                        .get_number(&device_name, "CCD_MAX_PIXEL_VALUE", "CCD_MAX_PIXEL_VALUE")
                        .await
                    {
                        Some(value) => Some(value),
                        None => {
                            locked_client
                                .get_number(&device_name, "CCD_INFO", "CCD_MAX_PIXEL")
                                .await
                        }
                    };
                    let max_adu = if let Some(value) = max_adu_from_driver {
                        value.max(0.0) as u32
                    } else if bit_depth >= 32 {
                        u32::MAX
                    } else {
                        (1u32 << bit_depth) - 1
                    };

                    return Ok(crate::device::CameraStatus {
                        connected: true,
                        state,
                        sensor_temp,
                        cooler_power,
                        target_temp: None,
                        cooler_on,
                        gain,
                        offset,
                        bin_x,
                        bin_y,
                        sensor_width,
                        sensor_height,
                        pixel_size_x,
                        pixel_size_y,
                        max_adu,
                        can_cool: has_cooler,
                        can_set_gain: has_gain,
                        can_set_offset: has_offset,
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for server {}", server_key),
                ))
            }
            None => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found or status not supported", device_id),
            )),
        }
    }

    /// Query the camera's SDK for manufacturer-recommended gain/offset values.
    ///
    /// Only native vendor SDKs are queried — ASCOM/Alpaca/INDI do not expose
    /// per-camera unity gain through their protocols (ASCOM's
    /// `IntegerListSetting`-style enumeration only lists allowed values, not
    /// which one is "recommended"). For non-native drivers this returns an
    /// empty struct (all fields `None`).
    ///
    /// On native cameras, propagates the per-vendor implementation in
    /// [`skotiq_native::traits::NativeCamera::get_recommended_settings`].
    /// A query failure is logged and reported up — callers must treat it as
    /// "no recommendation" rather than swallowing it.
    pub async fn camera_get_recommended_settings(
        &self,
        device_id: &str,
    ) -> Result<skotiq_native::camera::CameraRecommendedSettings, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Native) => {
                let native_cameras = self.native_cameras.read().await;
                if let Some(camera) = native_cameras.get(device_id) {
                    return camera.get_recommended_settings().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to query recommended settings for native camera {}: {}",
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
            // ASCOM, Alpaca, INDI, and simulators don't expose a unity-gain
            // recommendation through their protocols. Honest empty answer.
            Some(DriverType::Ascom)
            | Some(DriverType::Alpaca)
            | Some(DriverType::Indi)
            | Some(DriverType::Simulator) => {
                Ok(skotiq_native::camera::CameraRecommendedSettings::default())
            }
            _ => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found", device_id),
            )),
        }
    }
}
