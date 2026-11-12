//! `DeviceDriver` / `CameraDriver` implementations for `ZwoCamera`.

use super::*;
use crate::camera_core::{unpack_samples, SampleLayout};

#[async_trait]
impl DeviceDriver for ZwoCamera {
    fn id(&self) -> &str {
        &self.device_id
    }

    /// The model the SDK reports, e.g. `ZWO ASI1600MM-Cool`.
    ///
    /// The device-identity check and the FITS `INSTRUME` keyword both read this
    /// method expecting the model, so `device_id` will not do: `native:zwo:1` is
    /// the ASI enumeration index and re-binds to another body across a replug,
    /// which would stamp an enumeration index into an archival header.
    ///
    /// Falls back to the id only before `load_camera_info` has run, i.e. before
    /// there is any model to report.
    fn name(&self) -> &str {
        if self.model_name.is_empty() {
            &self.device_id
        } else {
            &self.model_name
        }
    }

    fn vendor(&self) -> Vendor {
        Vendor::Zwo
    }

    fn serial_number(&self) -> Option<String> {
        self.serial_number.clone()
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        tracing::info!("Connecting to ZWO camera ID {}...", self.camera_id);

        let sdk = AsiSdk::installed().inspect_err(|_| {
            tracing::error!("Cannot connect to ZWO camera: ASI SDK not loaded");
        })?;

        // Hold the SDK lock for all SDK operations during connect
        let sdk = sdk.lock().await;

        tracing::debug!("Loading camera info for ID {}", self.camera_id);
        self.load_camera_info(&sdk).map_err(|e| {
            tracing::error!(
                "Failed to load camera info for ID {}: {:?}",
                self.camera_id,
                e
            );
            e
        })?;
        tracing::debug!("Camera info loaded successfully");

        tracing::debug!("Opening camera ID {}", self.camera_id);
        // SAFETY: camera_id is the stable ASICameraInfo::CameraID resolved by load_camera_info().
        let result = unsafe { (sdk.open_camera)(self.camera_id) };
        if result != 0 {
            tracing::error!(
                "ASIOpenCamera failed for ID {}: ASI error code {}",
                self.camera_id,
                result
            );
            return Err(check_asi_error(result).unwrap_err());
        }
        tracing::debug!("Camera opened successfully");

        let camera_id = self.camera_id;
        let locked_sdk: &AsiSdk = &sdk;
        let cleanup_guard = CleanupGuard::new(|| {
            tracing::debug!("Cleaning up ZWO camera {} after failed connect", camera_id);
            // SAFETY: Best-effort cleanup on error path; camera_id was successfully opened above (we only reach the guard after ASIOpenCamera succeeded). The cleanup borrows the lock guard, so it runs while connect() still holds the lock.
            let _ = unsafe { (locked_sdk.close_camera)(camera_id) };
        });

        tracing::debug!("Initializing camera ID {}", self.camera_id);
        // SAFETY: camera_id was successfully opened by ASIOpenCamera above.
        let result = unsafe { (sdk.init_camera)(self.camera_id) };
        if result != 0 {
            tracing::error!(
                "ASIInitCamera failed for ID {}: ASI error code {}",
                self.camera_id,
                result
            );
            // cleanup_guard will handle closing the camera
            return Err(check_asi_error(result).unwrap_err());
        }
        tracing::debug!("Camera initialized successfully");

        // Full frame, bin 1, in the deepest raw format the camera lists.
        if let Some(info) = &self.camera_info {
            self.image_type = ZwoCamera::readout_format(info).ok_or_else(|| {
                DriverError::InvalidDevice(format!(
                    "The {} offers neither 16-bit nor 8-bit raw frames",
                    self.camera_name()
                ))
            })?;
            if matches!(self.image_type, ASIImgType::Raw8) {
                tracing::warn!(
                    "{} lists no 16-bit readout; frames are read out in 8 bits",
                    self.camera_name()
                );
            }
            // SAFETY: camera_id is open and initialized; width/height come from the SDK-reported ASICameraInfo and bin=1 is always valid.
            let result = unsafe {
                (sdk.set_roi_format)(
                    self.camera_id,
                    info.max_width as c_int,
                    info.max_height as c_int,
                    1, // bin
                    self.image_type as c_int,
                )
            };
            if result != 0 {
                tracing::error!("ASISetROIFormat failed: ASI error code {}", result);
                return Err(check_asi_error(result).unwrap_err());
            }
        }

        self.exposure_range_us = self
            .control_caps(&sdk, ASIControlType::ASI_EXPOSURE)
            .ok()
            .map(|(min, max, _)| (min, max))
            .filter(|&(min, max)| min > 0 && max >= min);
        self.log_connect_settings(&sdk);

        // Get current gain and offset (use synchronous versions since we already hold the mutex)
        tracing::debug!("Reading current gain and offset");
        if let Ok(val) = self.get_control(&sdk, ASIControlType::ASI_GAIN) {
            // get_control returns c_long (i64 on Linux); gain fits in i32.
            self.current_gain = val as i32;
            tracing::debug!("Current gain: {}", self.current_gain);
        }
        if let Ok(val) = self.get_control(&sdk, ASIControlType::ASI_OFFSET) {
            // get_control returns c_long (i64 on Linux); offset fits in i32.
            self.current_offset = val as i32;
            tracing::debug!("Current offset: {}", self.current_offset);
        }

        cleanup_guard.defuse();

        self.connected = true;
        // Read identity while the camera is open and the SDK mutex is still
        // held. `native:zwo:{n}` is an enumeration index that re-binds to a
        // different body across a replug, so the serial is the only thing that
        // lets a caller notice the swap.
        self.serial_number = self.read_serial_number_locked(&sdk);
        let camera_name = self.camera_name();
        tracing::info!(
            "Successfully connected to ZWO camera: {} (serial: {})",
            camera_name,
            self.serial_number.as_deref().unwrap_or("not reported")
        );
        let quirk_lookup_id = format!("native:zwo:{}", camera_name);
        {
            let mut pending = self
                .temperature_skip_first_pending
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            *pending = crate::quirks::should_skip_first_temperature_read(&quirk_lookup_id);
        }

        // Release the SDK lock before any post-connect settle so other threads
        // can resume.
        drop(sdk);

        // Apply per-model DelayAfterConnect quirk (e.g. ASI533: 200ms). The
        // quirks database is queried with a synthetic device_id that embeds the
        // SDK-reported model name so per-model `ModelContains` matchers fire.
        if let Some(delay_ms) = crate::quirks::get_connect_delay_ms(&quirk_lookup_id) {
            tracing::debug!(
                "Applying DelayAfterConnect quirk: sleeping {}ms after connecting to {}",
                delay_ms,
                camera_name
            );
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if self.connected {
            let sdk = AsiSdk::lock().await?;
            // SAFETY: camera_id is valid because self.connected is true (only set after successful connect()).
            let result = unsafe { (sdk.close_camera)(self.camera_id) };
            check_asi_error(result)?;
            self.connected = false;
            tracing::info!("Disconnected from {}", self.camera_name());
        }
        Ok(())
    }
}

#[async_trait]
impl CameraDriver for ZwoCamera {
    fn capabilities(&self) -> CameraCapabilities {
        if let Some(info) = &self.camera_info {
            let max_bin = self.supported_bins().into_iter().max().unwrap_or(1);
            CameraCapabilities {
                can_cool: info.is_cooler_cam != 0,
                can_set_gain: true,
                can_set_offset: true,
                can_set_binning: true,
                can_subframe: true,
                has_shutter: info.mechanical_shutter != 0,
                has_guider_port: info.st4_port != 0,
                max_bin_x: max_bin,
                max_bin_y: max_bin,
                supports_readout_modes: false,
            }
        } else {
            CameraCapabilities::default()
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = AsiSdk::lock().await?;

        let mut exp_status: c_int = 0;
        // SAFETY: `exp_status` is a valid stack pointer; camera_id is valid (self.connected was checked).
        let result = unsafe { (sdk.get_exp_status)(self.camera_id, &mut exp_status) };
        check_open_camera_error(result)?;

        let exposure_active = self.exposure_active.load(Ordering::Acquire);
        let state = match exp_status {
            0 => CameraState::Idle,
            1 => CameraState::Exposing,
            2 if exposure_active => CameraState::Downloading,
            2 => CameraState::Idle,
            3 if exposure_active => CameraState::Error,
            3 => CameraState::Idle,
            _ => CameraState::Error,
        };

        // Get temperature (ASI_TEMPERATURE returns 10*temperature) - use sync version since we hold mutex
        let temp = self.read_temperature_celsius_sync(&sdk).ok();

        let supports_cooler = if let Some(info) = self.camera_info.as_ref() {
            info.is_cooler_cam != 0
        } else {
            tracing::warn!(
                "ZWO camera_info metadata unavailable while reading status; probing cooler capability via control API."
            );
            self.get_control(&sdk, ASIControlType::ASI_COOLER_ON)
                .is_ok()
        };

        let cooler_power = if supports_cooler {
            self.get_control(&sdk, ASIControlType::ASI_COOLER_POWER_PERC)
                .ok()
                .map(|v| v as f64)
        } else {
            None
        };

        // Report what the camera reads back for both the cooler switch and its
        // set-point; the value last written via set_cooler is only the fallback
        // when a read fails. Locked-state poisoning is recovered (we own the
        // data, not a foreign invariant), since refusing to report status
        // because of a poisoned lock would be a worse failure mode than reading
        // a last-known-good copy. Cameras without a cooler always report `false`.
        let (cooler_on, target_temp) = if supports_cooler {
            let local = *self.cooler_state.lock().unwrap_or_else(|e| e.into_inner());
            let sdk_enabled = self
                .get_control(&sdk, ASIControlType::ASI_COOLER_ON)
                .ok()
                .map(|v| v != 0);
            let sdk_target = self
                .get_control(&sdk, ASIControlType::ASI_TARGET_TEMP)
                .ok()
                .map(|v| v as f64);
            (sdk_enabled.or(local.enabled), sdk_target.or(local.target_c))
        } else {
            (Some(false), None)
        };

        Ok(CameraStatus {
            state,
            sensor_temp: temp,
            target_temp,
            cooler_on,
            cooler_power,
            gain: self.current_gain,
            offset: self.current_offset,
            bin_x: self.current_bin,
            bin_y: self.current_bin,
            exposure_remaining: None,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        // ExposureParams is the per-frame source of truth for binning and the
        // frame region: a full-frame request also clears a previous subframe.
        let bin = self.validate_bin(params.bin_x, params.bin_y)?;
        let roi = self.frame_roi(bin, params.subframe.as_ref())?;

        // ASISetControlValue clamps an exposure past the camera's maximum and
        // reports success, so the frame would be shorter than its EXPTIME says.
        let requested_us = params.duration_secs * 1_000_000.0;
        if let Some((_, max_us)) = self.exposure_range_us {
            if requested_us > max_us as f64 {
                return Err(DriverError::InvalidParameter(format!(
                    "The {} exposes at most {} s; {} s was requested",
                    self.camera_name(),
                    max_us as f64 / 1_000_000.0,
                    params.duration_secs
                )));
            }
        }

        let sdk = AsiSdk::lock().await?;
        self.apply_roi(&sdk, bin, roi, params.subframe.is_some())?;

        // Microseconds; within the camera's maximum, so within c_long on Windows.
        let exposure_us = requested_us as c_long;
        self.set_control(&sdk, ASIControlType::ASI_EXPOSURE, exposure_us, false)?;

        // Set gain, then cache what the SENSOR ended up at, not what was asked
        // for. See `read_back_control_sync` for why.
        if let Some(gain) = params.gain {
            self.set_control(&sdk, ASIControlType::ASI_GAIN, gain as c_long, false)?;
            self.current_gain = self.read_back_control_sync(&sdk, ASIControlType::ASI_GAIN, gain);
        }

        if let Some(offset) = params.offset {
            self.set_control(&sdk, ASIControlType::ASI_OFFSET, offset as c_long, false)?;
            self.current_offset =
                self.read_back_control_sync(&sdk, ASIControlType::ASI_OFFSET, offset);
        }

        // Start exposure with the correct shutter state for calibration frames.
        let is_dark = if params.frame_type.opens_shutter() {
            ASI_FALSE
        } else {
            ASI_TRUE
        };
        // SAFETY: camera_id is valid (connected=true checked earlier).
        let result = unsafe { (sdk.start_exposure)(self.camera_id, is_dark) };
        check_open_camera_error(result)?;

        // Track exposure time for metadata
        self.exposure_time = params.duration_secs;
        self.exposure_active.store(true, Ordering::Release);

        tracing::info!("Started {}s exposure", params.duration_secs);
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = AsiSdk::lock().await?;
        // SAFETY: camera_id is valid (connected=true checked earlier).
        let result = unsafe { (sdk.stop_exposure)(self.camera_id) };
        check_open_camera_error(result)?;
        self.exposure_active.store(false, Ordering::Release);

        tracing::info!("Aborted exposure");
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = AsiSdk::lock().await?;

        let mut status: c_int = 0;
        // SAFETY: `status` is a valid stack pointer; camera_id is valid (connected=true checked).
        let result = unsafe { (sdk.get_exp_status)(self.camera_id, &mut status) };
        check_open_camera_error(result)?;

        let is_complete = status == ASIExposureStatus::Success as c_int;
        if is_complete {
            self.exposure_active.store(false, Ordering::Release);
        } else if status == ASIExposureStatus::Failed as c_int {
            self.exposure_active.store(false, Ordering::Release);
            return Err(DriverError::SdkError(
                "ZWO camera reported a failed exposure".to_string(),
            ));
        }
        // Log status for debugging (0=Idle, 1=Working, 2=Success, 3=Failed)
        if is_complete || status == ASIExposureStatus::Failed as c_int {
            tracing::info!(
                "ZWO exposure status: {} ({})",
                status,
                match status {
                    0 => "Idle",
                    1 => "Working",
                    2 => "Success",
                    3 => "Failed",
                    _ => "Unknown",
                }
            );
        }

        Ok(is_complete)
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = AsiSdk::lock().await?;

        let mut width: c_int = 0;
        let mut height: c_int = 0;
        let mut bin: c_int = 0;
        let mut img_type: c_int = 0;

        // SAFETY: all four out-pointers are valid stack pointers; camera_id is valid (connected=true checked).
        let result = unsafe {
            (sdk.get_roi_format)(
                self.camera_id,
                &mut width,
                &mut height,
                &mut bin,
                &mut img_type,
            )
        };
        check_open_camera_error(result)?;

        let bytes_per_pixel = if img_type == ASIImgType::Raw16 as c_int {
            2
        } else {
            1
        };
        let buffer_size = calculate_buffer_size_i32(width, height, bytes_per_pixel)?;

        let mut pooled_buffer = global_u8_pool().get_buffer(buffer_size);
        pooled_buffer.resize(buffer_size);

        // SAFETY: `pooled_buffer` was resized to exactly `buffer_size` bytes (computed via calculate_buffer_size_i32 from the SDK-reported ROI), and the SDK writes at most `buffer_size` bytes into the pointer. camera_id is valid (connected=true checked).
        let result = unsafe {
            (sdk.get_data_after_exp)(
                self.camera_id,
                pooled_buffer.as_mut_ptr(),
                buffer_size as c_long,
            )
        };
        check_open_camera_error(result)?;

        // Why: 8-bit pixel `x: u8` widened to u16 then multiplied by 256 is the standard
        // 8-bit to 16-bit promotion; u8 -> u16 is always lossless.
        let layout = if bytes_per_pixel == 2 {
            SampleLayout::U16Native
        } else {
            SampleLayout::U8Scaled
        };
        let data = unpack_samples(&pooled_buffer[..], layout);

        // Raw-buffer statistics, for diagnosing blank or mid-gray frames.
        //
        // This runs while the ZWO SDK mutex is held, so every pass costs the
        // filter wheel and focuser sharing that mutex too: a 62 MP frame is
        // ~125 M elements. It is therefore one pass, only when someone is
        // listening at DEBUG. The same statistics are computed downstream in
        // the imaging pipeline for every frame that reaches it.
        if tracing::enabled!(tracing::Level::DEBUG) {
            if let Some(stats) = FrameBufferStats::of(&data) {
                tracing::debug!(
                    "ZWO raw buffer stats - min={}, max={}, avg={}, non_zero={}/{}, img_type={}",
                    stats.min,
                    stats.max,
                    stats.mean,
                    stats.non_zero,
                    data.len(),
                    img_type
                );
                if stats.min == stats.max {
                    tracing::warn!(
                        "ZWO: every pixel of the downloaded frame is {}, which means no image data was captured",
                        stats.min
                    );
                }
            }
        }

        tracing::info!(
            "Downloaded {}x{} image ({} bytes, img_type={})",
            width,
            height,
            buffer_size,
            img_type
        );

        let bayer_pattern = self.delivered_bayer_pattern(&sdk);

        // Get temperature and vendor features using sync methods since we already hold the lock
        // (calling async methods here would deadlock because they try to acquire the same mutex)
        let temperature = self
            .get_control(&sdk, ASIControlType::ASI_TEMPERATURE)
            .map(|v| v as f64 / 10.0)
            .ok();

        let mut vendor_data = VendorFeatures::default();
        if let Ok(bw) = self.get_control(&sdk, ASIControlType::ASI_BANDWIDTHOVERLOAD) {
            vendor_data.usb_bandwidth = Some(bw as f64);
        }
        if let Ok(heater) = self.get_control(&sdk, ASIControlType::ASI_ANTI_DEW_HEATER) {
            vendor_data.anti_dew_heater = Some(heater != 0);
        }

        // Why: width/height came from ASIGetROIFormat (c_int) which the ZWO SDK guarantees
        // non-negative for connected cameras with a valid ROI. Surface SDK corruption
        // (negative value) via try_into rather than wrap into a giant u32.
        let width_u32 = u32::try_from(width).map_err(|_| {
            DriverError::SdkError(format!("ZWO returned negative ROI width: {}", width))
        })?;
        let height_u32 = u32::try_from(height).map_err(|_| {
            DriverError::SdkError(format!("ZWO returned negative ROI height: {}", height))
        })?;
        Ok(ImageData {
            width: width_u32,
            height: height_u32,
            data,
            bits_per_pixel: self.delivered_bit_depth(),
            bayer_pattern,
            metadata: ImageMetadata {
                exposure_time: self.exposure_time,
                gain: self.current_gain,
                offset: self.current_offset,
                bin_x: self.current_bin,
                bin_y: self.current_bin,
                temperature,
                timestamp: chrono::Utc::now(),
                subframe: self.current_subframe.clone(),
                readout_mode: None,
                vendor_data,
                camera_file: None,
            },
        })
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let supports_cooler = self
            .camera_info
            .as_ref()
            .map(|i| i.is_cooler_cam != 0)
            .ok_or_else(|| {
                DriverError::InvalidDevice(
                    "Camera capability metadata unavailable for cooler operation".to_string(),
                )
            })?;
        if !supports_cooler {
            return Err(DriverError::NotSupported);
        }

        // Only touch ASI_TARGET_TEMP when the caller actually named a
        // setpoint. Writing it unconditionally meant a plain "cooler off"
        // command first drove the TEC target somewhere the operator never
        // asked for.
        // ASI_TARGET_TEMP takes whole degrees; the set-point is rounded to the
        // nearest one and that is what is recorded, so the reported target is the
        // one the camera holds (a cast would truncate toward zero: -10.7 to -10).
        let target_temp = target_temp.map(zwo_target_degrees);
        if let Some(target) = target_temp {
            // Use async versions with mutex protection
            self.set_control_async(ASIControlType::ASI_TARGET_TEMP, target as c_long, false)
                .await?;
        }
        self.set_control_async(
            ASIControlType::ASI_COOLER_ON,
            if enabled { 1 } else { 0 },
            false,
        )
        .await?;

        // Persist the commanded state only after both SDK writes succeed: a partial
        // write must not leave the local cache asserting a state the hardware never
        // reached. Lock poisoning is recovered because a previous panic in this
        // section could not have left the cooler in an unknown state.
        {
            let mut state = self.cooler_state.lock().unwrap_or_else(|e| e.into_inner());
            state.enabled = Some(enabled);
            if let Some(target) = target_temp {
                state.target_c = Some(target);
            }
        }

        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        let sdk = AsiSdk::lock().await?;
        self.read_temperature_celsius_sync(&sdk)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        let supports_cooler = self
            .camera_info
            .as_ref()
            .map(|i| i.is_cooler_cam != 0)
            .ok_or_else(|| {
                DriverError::InvalidDevice(
                    "Camera capability metadata unavailable for cooler power query".to_string(),
                )
            })?;
        if !supports_cooler {
            return Err(DriverError::NotSupported);
        }
        let value = self
            .get_control_async(ASIControlType::ASI_COOLER_POWER_PERC)
            .await?;
        Ok(value as f64)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        let sdk_result = self
            .set_control_async(ASIControlType::ASI_GAIN, gain as c_long, false)
            .await;
        let effective = if sdk_result.is_ok() {
            self.read_back_control_async(ASIControlType::ASI_GAIN, gain)
                .await
        } else {
            gain
        };
        commit_zwo_cached_setting(&mut self.current_gain, effective, sdk_result)
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        // get_control_async returns c_long (i64 on Linux); gain fits in i32.
        let val = self.get_control_async(ASIControlType::ASI_GAIN).await?;
        Ok(val as i32)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        let sdk_result = self
            .set_control_async(ASIControlType::ASI_OFFSET, offset as c_long, false)
            .await;
        let effective = if sdk_result.is_ok() {
            self.read_back_control_async(ASIControlType::ASI_OFFSET, offset)
                .await
        } else {
            offset
        };
        commit_zwo_cached_setting(&mut self.current_offset, effective, sdk_result)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        // get_control_async returns c_long (i64 on Linux); offset fits in i32.
        let val = self.get_control_async(ASIControlType::ASI_OFFSET).await?;
        Ok(val as i32)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        let bin = self.validate_bin(bin_x, bin_y)?;
        let roi = self.frame_roi(bin, None)?;
        let sdk = AsiSdk::lock().await?;
        self.apply_roi(&sdk, bin, roi, false)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.current_bin, self.current_bin))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        let bin = self.current_bin;
        let roi = self.frame_roi(bin, subframe.as_ref())?;
        let sdk = AsiSdk::lock().await?;
        self.apply_roi(&sdk, bin, roi, subframe.is_some())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        if let Some(info) = &self.camera_info {
            // Why: max_width/max_height are c_long sensor dimensions populated by
            // ASIGetCameraProperty; ZWO cameras top out under 10k pixels per dim. A
            // negative value would be SDK corruption — saturate to 0 so the caller
            // sees a degenerate sensor and can refuse to capture. We can't propagate
            // an error from this synchronous accessor; the alternative is a default
            // sensor or a wrap, both worse.
            // Same reasoning for bit_depth (c_int, range 8..=16 in practice).
            SensorInfo {
                width: u32::try_from(info.max_width).unwrap_or(0),
                height: u32::try_from(info.max_height).unwrap_or(0),
                pixel_size_x: info.pixel_size,
                pixel_size_y: info.pixel_size,
                // Container full scale, NOT the ADC range: RAW16 left-justifies
                // sub-16-bit samples and RAW8 frames are scaled by 256 on
                // download. See [`raw16_container_max_adu`] and the
                // `SensorInfo::max_adu` contract.
                max_adu: raw16_container_max_adu(self.delivered_bit_depth()),
                bit_depth: self.delivered_bit_depth(),
                color: info.is_color_cam != 0,
                bayer_pattern: if info.is_color_cam != 0 {
                    Some(match info.bayer_pattern {
                        0 => BayerPattern::Rggb,
                        1 => BayerPattern::Bggr,
                        2 => BayerPattern::Grbg,
                        3 => BayerPattern::Gbrg,
                        _ => BayerPattern::Rggb,
                    })
                } else {
                    None
                },
                saturation_adu: None,
            }
        } else {
            SensorInfo::default()
        }
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        // ZWO doesn't have readout modes
        Ok(Vec::new())
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        let mut features = VendorFeatures::default();

        // Get USB bandwidth - use async version with mutex
        if let Ok(bw) = self
            .get_control_async(ASIControlType::ASI_BANDWIDTHOVERLOAD)
            .await
        {
            features.usb_bandwidth = Some(bw as f64);
        }

        // ZWO-specific: Anti-dew heater - use async version with mutex
        if let Ok(heater) = self
            .get_control_async(ASIControlType::ASI_ANTI_DEW_HEATER)
            .await
        {
            features.anti_dew_heater = Some(heater != 0);
        }

        Ok(features)
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        self.get_control_range_async(ASIControlType::ASI_GAIN).await
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        self.get_control_range_async(ASIControlType::ASI_OFFSET)
            .await
    }

    /// `ASI_EXPOSURE`'s published range as read at connect, in seconds. A
    /// camera that does not publish the control answers `Ok(None)` rather
    /// than a fabricated range.
    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        Ok(self
            .exposure_range_us
            .map(|(min_us, max_us)| (min_us as f64 / 1_000_000.0, max_us as f64 / 1_000_000.0)))
    }

    /// Surface the SDK-advertised recommended settings.
    ///
    /// Sources:
    /// - `ASIControlCaps.default_value` for `ASI_GAIN` and `ASI_OFFSET`. ZWO's
    ///   SDK header documents this as "the value the SDK starts with" — for
    ///   gain this matches the per-camera unity-gain value ZWO publishes in
    ///   their official tables (e.g. ASI2600MM = 100, ASI533MC = 100,
    ///   ASI294MC = 120). For offset it matches their recommended default.
    /// - `ASICameraInfo.elec_per_adu` is reported at the camera's default gain;
    ///   we include it in the notes string so the user can see how the
    ///   recommendation was derived.
    ///
    /// ZWO does NOT expose the HCG transition point through the SDK — that's
    /// documented per-camera in the manual. We honestly return `None` for
    /// `hcg_gain` instead of fabricating a value.
    async fn get_recommended_settings(
        &self,
    ) -> Result<skotiq_device::camera::CameraRecommendedSettings, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let mut out = skotiq_device::camera::CameraRecommendedSettings::default();
        let mut notes: Vec<String> = Vec::new();

        // Unity gain: ZWO's documented "default gain" on the GAIN control.
        match self.get_control_caps_async(ASIControlType::ASI_GAIN).await {
            Ok((_min, _max, default)) => {
                out.unity_gain = Some(default);
                // Append ElecPerADU when the camera reports it (non-zero).
                if let Some(info) = &self.camera_info {
                    if info.elec_per_adu > 0.0 {
                        notes.push(format!(
                            "ZWO SDK reports default gain = {} (ElecPerADU at default = {:.3})",
                            default, info.elec_per_adu
                        ));
                    } else {
                        notes.push(format!("ZWO SDK reports default gain = {}", default));
                    }
                } else {
                    notes.push(format!("ZWO SDK reports default gain = {}", default));
                }
            }
            Err(DriverError::NotSupported) => {
                // Camera doesn't have a gain control (some very old ZWO cameras).
                // This is an honest "no recommendation available".
            }
            Err(e) => {
                tracing::warn!("ZWO: failed to query gain control caps: {:?}", e);
            }
        }

        // Recommended offset: same source.
        match self
            .get_control_caps_async(ASIControlType::ASI_OFFSET)
            .await
        {
            Ok((_min, _max, default)) => {
                out.default_offset = Some(default);
                notes.push(format!("ZWO SDK reports default offset = {}", default));
            }
            Err(DriverError::NotSupported) => {
                // Camera doesn't expose offset control.
            }
            Err(e) => {
                tracing::warn!("ZWO: failed to query offset control caps: {:?}", e);
            }
        }

        out.notes = notes.join("; ");
        Ok(out)
    }

    /// Report the achievable cooler setpoint range from the ZWO SDK.
    ///
    /// Source: the `ASI_TARGET_TEMP` control's min/max caps published via
    /// `ASIGetControlCaps`. Unlike `ASI_TEMPERATURE` (which returns
    /// `10 * degreesC`), `ASI_TARGET_TEMP` is expressed in **direct degrees
    /// Celsius** — see the `ASIControlType` definition comment — so the raw
    /// `(min, max)` values map straight to `(f64, f64)` with no scaling.
    ///
    /// Behavior:
    /// - Disconnected: `Err(NotConnected)` (we cannot query the SDK).
    /// - Camera exposes no `ASI_TARGET_TEMP` control (no regulated cooler):
    ///   `Ok(None)` — an honest "unknown", not an error.
    /// - Any other SDK failure: we `warn!` and return `Ok(None)` so a transient
    ///   query failure never blocks the broader capability probe (mirrors the
    ///   error handling in `get_recommended_settings`).
    ///
    /// Note on other vendors: QHY/PlayerOne/SVBony intentionally do NOT override
    /// this method. Their SDKs do not uniformly expose the cooler-target control
    /// caps, so the trait default (`Ok(None)`) is the honest answer there rather
    /// than a fabricated range.
    async fn get_cooler_temp_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        match self
            .get_control_caps_async(ASIControlType::ASI_TARGET_TEMP)
            .await
        {
            // ASI_TARGET_TEMP is direct degrees C (NOT multiplied by 10), so the
            // raw caps map straight to the achievable setpoint range.
            Ok((min, max, _default)) => Ok(Some((min as f64, max as f64))),
            // No regulated cooler / no target-temp control: honest unknown.
            Err(DriverError::NotSupported) => Ok(None),
            // Transient SDK failure: don't block the capability probe.
            Err(e) => {
                tracing::warn!("ZWO: failed to query ASI_TARGET_TEMP caps: {:?}", e);
                Ok(None)
            }
        }
    }
}
