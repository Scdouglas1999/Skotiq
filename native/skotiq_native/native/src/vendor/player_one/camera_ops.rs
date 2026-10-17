//! `NativeDevice` / `NativeCamera` implementations for `PlayerOneCamera`.

use super::*;

#[async_trait]
impl NativeDevice for PlayerOneCamera {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.device_id
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::PlayerOne
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for SDK operations
        let _lock = player_one_mutex().lock().await;

        // Load camera info first
        self.load_camera_info()?;

        // Open camera
        // SAFETY: player_one_mutex held above; `self.camera_id` was populated at construction and verified by load_camera_info (which succeeded above); POAOpenCamera takes the camera ID by value with no pointer arguments.
        let result = unsafe { (sdk.open_camera)(self.camera_id) };
        check_poa_error(result, "OpenCamera")?;

        let camera_id = self.camera_id;
        let cleanup_guard = CleanupGuard::new(|| {
            // SAFETY: player_one_mutex remains held for the lifetime of this guard;
            // camera_id was successfully opened immediately before the guard was created.
            let _ = unsafe { (sdk.close_camera)(camera_id) };
        });

        // Initialize camera
        // SAFETY: player_one_mutex held; camera was just successfully opened above so POAInitCamera is the required next call per PlayerOneCamera.h; takes the camera ID by value.
        let result = unsafe { (sdk.init_camera)(self.camera_id) };
        check_poa_error(result, "InitCamera")?;

        // Set default format (Raw16)
        // SAFETY: player_one_mutex held; camera was opened and initialized successfully above; POASetImageFormat takes the camera ID and a POAImgFormat discriminant (Raw16=1) by value.
        let result =
            unsafe { (sdk.set_image_format)(self.camera_id, POAImgFormat::Raw16 as c_int) };
        check_poa_error(result, "SetImageFormat")?;

        // Set default binning and ROI. These are checked, not fire-and-forget: the
        // driver reports `current_bin = 1` / `current_width|height = max` from here
        // on (get_binning, and the BIN/XBINNING metadata on every frame), so a camera
        // that refused the default geometry would make every one of those answers a
        // lie. Failing the connect leaves the cleanup guard to close the handle.
        if let Some(info) = &self.camera_info {
            // SAFETY: player_one_mutex held; camera is open+initialized; POASetImageBin takes the camera ID and bin factor (1) by value.
            let result = unsafe { (sdk.set_image_bin)(self.camera_id, 1) };
            check_poa_error(result, "SetImageBin(1)")?;
            // SAFETY: player_one_mutex held; camera is open+initialized; POASetImageStartPos takes the camera ID and (0, 0) origin by value.
            let result = unsafe { (sdk.set_image_start_pos)(self.camera_id, 0, 0) };
            check_poa_error(result, "SetImageStartPos(0, 0)")?;
            // SAFETY: player_one_mutex held; camera is open+initialized; max_width/max_height come from the SDK-populated POACameraProperties so they are guaranteed valid for this device.
            let result =
                unsafe { (sdk.set_image_size)(self.camera_id, info.max_width, info.max_height) };
            check_poa_error(result, "SetImageSize(full frame)")?;
        }

        // Seed the gain/offset the driver reports when a later read-back fails, so the
        // fallback is the camera's own power-on value rather than a literal 0.
        //
        // `current_gain`/`current_offset` start at 0 (camera.rs:46), and both
        // `get_status` and `download_image` fall back to them — the second of those
        // writes the FITS GAIN/OFFSET cards. So a failed seed is precisely the case
        // that reintroduces the literal 0 these fallbacks exist to avoid, and it must
        // not pass silently: log which control refused and what the driver will report
        // until the first successful set/read replaces it. The connect itself stays
        // alive — a camera whose gain register is momentarily unreadable still images,
        // and `CameraStatus`/`ImageMetadata` have no "unknown" for these two i32 fields.
        match self.get_control_int(POAConfig::POA_GAIN) {
            Ok(gain) => self.current_gain = gain as i32,
            Err(e) => tracing::warn!(
                "Player One {}: POA_GAIN could not be read at connect ({}); gain is reported as {} until a set_gain or a later read-back succeeds",
                self.device_id,
                e,
                self.current_gain
            ),
        }
        match self.get_control_int(POAConfig::POA_OFFSET) {
            Ok(offset) => self.current_offset = offset as i32,
            Err(e) => tracing::warn!(
                "Player One {}: POA_OFFSET could not be read at connect ({}); offset is reported as {} until a set_offset or a later read-back succeeds",
                self.device_id,
                e,
                self.current_offset
            ),
        }

        cleanup_guard.defuse();
        self.connected = true;
        tracing::info!("Connected to {}", self.camera_name());
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;
            let _lock = player_one_mutex().lock().await;
            // SAFETY: player_one_mutex held above (single-threaded SDK access); we only enter this branch when `self.connected == true`, so the camera was previously opened via POAOpenCamera; POACloseCamera pairs with it.
            let result = unsafe { (sdk.close_camera)(self.camera_id) };
            check_poa_error(result, "CloseCamera")?;
            self.connected = false;
            tracing::info!("Disconnected from {}", self.camera_name());
        }
        Ok(())
    }
}

#[async_trait]
impl NativeCamera for PlayerOneCamera {
    fn capabilities(&self) -> CameraCapabilities {
        if let Some(info) = &self.camera_info {
            CameraCapabilities {
                can_cool: info.is_has_cooler != 0,
                can_set_gain: true,
                can_set_offset: true,
                can_set_binning: true,
                can_subframe: true,
                has_shutter: false,
                has_guider_port: info.is_has_st4_port != 0,
                max_bin_x: 4,
                max_bin_y: 4,
                supports_readout_modes: false, // Player One doesn't have readout modes
            }
        } else {
            CameraCapabilities::default()
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for all SDK operations in this method
        let _lock = player_one_mutex().lock().await;

        let mut camera_state: c_int = 0;
        // SAFETY: player_one_mutex held above (single-threaded SDK access); self.connected was checked above so the camera ID is open; `&mut camera_state` is a valid stack out-pointer to a POD c_int.
        let result = unsafe { (sdk.get_camera_state)(self.camera_id, &mut camera_state) };
        check_poa_error(result, "GetCameraState")?;

        // POACameraState (PlayerOneCamera.h): 0=STATE_CLOSED, 1=STATE_OPENED
        // (opened, NOT exposing = idle/ready), 2=STATE_EXPOSING. The previous
        // mapping used ZWO's ASIGetExpStatus codes (0=Idle,1=Exposing,2=
        // Downloading), so a connected idle camera (OPENED=1) was reported
        // "Exposing" and true Idle was never reported while connected — hanging
        // any automation gate that polls for state==Idle. Frame-ready is tracked
        // separately via POAImageReady, so this need not report Downloading.
        let state = match camera_state {
            0 => CameraState::Idle,     // STATE_CLOSED (not exposing)
            1 => CameraState::Idle,     // STATE_OPENED (idle, ready)
            2 => CameraState::Exposing, // STATE_EXPOSING
            _ => CameraState::Error,
        };

        // Get temperature (POA_TEMPERATURE is a float value, unit C). A failed read
        // is reported as "unknown" (None), never as 0 C: `sensor_temp` is republished
        // as `ccd_temperature` on the capability snapshot and as the ASCOM
        // CCDTemperature property, so a fabricated 0 C reads as a real sensor value
        // and can pick the wrong dark-library temperature bucket.
        let sensor_temp = self.get_control_float(POAConfig::POA_TEMPERATURE).ok();

        let has_cooler = self
            .camera_info
            .as_ref()
            .map(|i| i.is_has_cooler != 0)
            .unwrap_or(false);

        let cooler_power = if has_cooler {
            self.get_control_int(POAConfig::POA_COOLER_POWER)
                .ok()
                .map(|v| v as f64)
        } else {
            None
        };

        // Resolve cooler_on / target_temp.
        //
        // Priority: SDK read-back of `POA_COOLER` / `POA_TARGET_TEMP` — that is
        // the authoritative register on the device. If either succeeds we
        // refresh the cached state so future reads stay consistent. If the SDK
        // path is unsupported by this camera/firmware we fall back to the
        // tracked state written by `set_cooler`. Cameras without a cooler at
        // all report `cooler_on = false` and `target_temp = None`.
        let (cooler_on, target_temp) = if has_cooler {
            let cached = self
                .cooler_state
                .lock()
                .map(|g| *g)
                .unwrap_or_else(|e| *e.into_inner());

            let live_enabled = self.get_control_bool(POAConfig::POA_COOLER).ok();
            let live_target_c = self
                .get_control_int(POAConfig::POA_TARGET_TEMP)
                .ok()
                .map(|v| v as f64);

            // Refresh cached state with whatever the SDK gave us so subsequent
            // `&self` reads converge on the device's truth.
            if live_enabled.is_some() || live_target_c.is_some() {
                if let Ok(mut guard) = self.cooler_state.lock() {
                    if let Some(e) = live_enabled {
                        guard.enabled = e;
                    }
                    if let Some(t) = live_target_c {
                        guard.target_c = t;
                    }
                }
            }

            let enabled = live_enabled.unwrap_or(cached.enabled);
            let target = Some(live_target_c.unwrap_or(cached.target_c));
            (enabled, target)
        } else {
            (false, None)
        };

        Ok(CameraStatus {
            state,
            sensor_temp,
            target_temp,
            cooler_on,
            cooler_power,
            // get_control_int returns c_long (i64 on Linux); CameraStatus stores i32.
            // A failed poll reports the last value this driver applied, not 0 — the
            // same rule the frame metadata follows in download_image.
            gain: self
                .get_control_int(POAConfig::POA_GAIN)
                .map(|v| v as i32)
                .unwrap_or(self.current_gain),
            offset: self
                .get_control_int(POAConfig::POA_OFFSET)
                .map(|v| v as i32)
                .unwrap_or(self.current_offset),
            bin_x: self.current_bin,
            bin_y: self.current_bin,
            exposure_remaining: None, // Not directly available from POA SDK
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for all SDK operations in this method
        let _lock = player_one_mutex().lock().await;

        // Set exposure time (in microseconds)
        let exposure_us = (params.duration_secs * 1_000_000.0) as c_long;
        self.set_control_int(POAConfig::POA_EXPOSURE, exposure_us, false)?;

        // Set gain
        if let Some(gain) = params.gain {
            self.set_control_int(POAConfig::POA_GAIN, gain as c_long, false)?;
            self.current_gain = gain;
        }

        // Set offset if provided
        if let Some(offset) = params.offset {
            self.set_control_int(POAConfig::POA_OFFSET, offset as c_long, false)?;
            self.current_offset = offset;
        }

        // Start exposure (false = not snap mode, single frame)
        // SAFETY: player_one_mutex held above (single-threaded SDK access); self.connected was checked at entry; POAStartExposure takes the camera ID and the snap-mode POABool by value.
        let result = unsafe { (sdk.start_exposure)(self.camera_id, POA_FALSE) };
        check_poa_error(result, "StartExposure")?;

        // Track exposure time for metadata
        self.exposure_time = params.duration_secs;

        tracing::info!("Started {}s exposure", params.duration_secs);
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for SDK operations
        let _lock = player_one_mutex().lock().await;

        // SAFETY: player_one_mutex held above (single-threaded SDK access); self.connected was checked at entry; POAStopExposure takes the camera ID by value.
        let result = unsafe { (sdk.stop_exposure)(self.camera_id) };
        check_poa_error(result, "StopExposure")?;

        tracing::info!("Aborted exposure");
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for SDK operations
        let _lock = player_one_mutex().lock().await;

        // Use POAImageReady to check if image data is available
        let mut is_ready: POABool = POA_FALSE;
        // SAFETY: player_one_mutex held above (single-threaded SDK access); self.connected was checked at entry; `&mut is_ready` is a valid stack out-pointer to a POD c_int.
        let result = unsafe { (sdk.image_ready)(self.camera_id, &mut is_ready) };
        check_poa_error(result, "POAImageReady")?;

        Ok(is_ready == POA_TRUE)
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for all SDK operations in this method
        let _lock = player_one_mutex().lock().await;

        // Get current image dimensions
        let mut width: c_int = 0;
        let mut height: c_int = 0;
        // SAFETY: player_one_mutex held above; self.connected was checked at entry; both `&mut width` and `&mut height` are valid stack out-pointers to POD c_int values.
        let result = unsafe { (sdk.get_image_size)(self.camera_id, &mut width, &mut height) };
        check_poa_error(result, "GetImageSize")?;

        // Calculate buffer size (Raw16 = 2 bytes per pixel) with overflow protection
        let bytes_per_pixel = if matches!(self.image_format, POAImgFormat::Raw16) {
            2
        } else {
            1
        };
        let buffer_size = calculate_buffer_size_i32(width, height, bytes_per_pixel)?;

        let mut pooled_buffer = global_u8_pool().get_buffer(buffer_size);

        // Get image data with 30 second timeout
        // SAFETY: player_one_mutex held above; self.connected was checked at entry; `pooled_buffer` was sized via calculate_buffer_size_i32(width, height, bytes_per_pixel) which uses the SDK-reported dimensions from POAGetImageSize and matches the configured POAImgFormat — we pass the same length as buffer_len so the SDK cannot overrun; pool returns a non-null buffer.
        let result = unsafe {
            (sdk.get_image_data)(
                self.camera_id,
                pooled_buffer.as_mut_ptr(),
                buffer_size as c_long,
                30000,
            )
        };
        check_poa_error(result, "GetImageData")?;

        // Convert to u16
        // Why: 8-bit -> 16-bit promotion (u8 -> u16 is always lossless; * 256 stays
        // within u16 because the max product is 255 * 256 = 65280 < u16::MAX).
        let data: Vec<u16> = if bytes_per_pixel == 2 {
            pooled_buffer
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_ne_bytes([chunk[0], chunk[1]]))
                .collect()
        } else {
            // 8-bit to 16-bit scaling
            pooled_buffer.iter().map(|&x| (x as u16) * 256).collect()
        };

        tracing::info!(
            "Downloaded {}x{} image ({} bytes)",
            width,
            height,
            buffer_size
        );

        // Get metadata while still holding the mutex.
        // get_control_int returns c_long (i64 on Linux); gain/offset fit in i32,
        // which is what ImageMetadata stores. A failed read-back falls back to the
        // value this driver last applied — these two numbers become the FITS
        // GAIN/OFFSET cards of the frame we are holding, and a literal 0 there would
        // send calibration to the wrong dark library.
        let gain = match self.get_control_int(POAConfig::POA_GAIN) {
            Ok(value) => {
                self.current_gain = value as i32;
                self.current_gain
            }
            Err(e) => {
                tracing::warn!(
                    "Player One {}: POA_GAIN read-back failed while building frame metadata ({}); recording the last applied gain {}",
                    self.device_id,
                    e,
                    self.current_gain
                );
                self.current_gain
            }
        };
        let offset = match self.get_control_int(POAConfig::POA_OFFSET) {
            Ok(value) => {
                self.current_offset = value as i32;
                self.current_offset
            }
            Err(e) => {
                tracing::warn!(
                    "Player One {}: POA_OFFSET read-back failed while building frame metadata ({}); recording the last applied offset {}",
                    self.device_id,
                    e,
                    self.current_offset
                );
                self.current_offset
            }
        };
        let temperature = self.get_control_float(POAConfig::POA_TEMPERATURE).ok();
        let usb_bandwidth = self
            .get_control_int(POAConfig::POA_USB_BANDWIDTH_LIMIT)
            .ok()
            .map(|v| v as f64);
        let heater_power = self.get_control_int(POAConfig::POA_HEATER_POWER).ok();
        let fan_power = self
            .get_control_int(POAConfig::POA_FAN_POWER)
            .ok()
            .map(|v| v as f64);

        // Build vendor features
        let mut vendor_features = VendorFeatures::default();
        vendor_features.usb_bandwidth = usb_bandwidth;
        if let Some(hp) = heater_power {
            vendor_features.anti_dew_heater = Some(hp > 0);
        }
        vendor_features.fan_power = fan_power;

        // Why: width/height came from POAGetImageSize (c_int) and are non-negative for
        // a connected camera with valid ROI; surface SDK corruption via try_into.
        let width_u32 = u32::try_from(width).map_err(|_| {
            NativeError::SdkError(format!("Player One returned negative ROI width: {}", width))
        })?;
        let height_u32 = u32::try_from(height).map_err(|_| {
            NativeError::SdkError(format!(
                "Player One returned negative ROI height: {}",
                height
            ))
        })?;
        Ok(ImageData {
            width: width_u32,
            height: height_u32,
            data,
            bits_per_pixel: self
                .camera_info
                .as_ref()
                .and_then(|info| u32::try_from(info.bit_depth).ok())
                .filter(|bits| (1..=32).contains(bits))
                .unwrap_or(if bytes_per_pixel == 2 { 16 } else { 8 }),
            bayer_pattern: self
                .camera_info
                .as_ref()
                .filter(|i| i.is_color_camera != 0)
                .map(|i| match i.bayer_pattern {
                    0 => BayerPattern::Rggb,
                    1 => BayerPattern::Bggr,
                    2 => BayerPattern::Grbg,
                    3 => BayerPattern::Gbrg,
                    _ => BayerPattern::Rggb,
                }),
            metadata: ImageMetadata {
                exposure_time: self.exposure_time,
                gain,
                offset,
                bin_x: self.current_bin,
                bin_y: self.current_bin,
                temperature,
                timestamp: chrono::Utc::now(),
                subframe: self.current_subframe.clone(),
                readout_mode: None, // Player One doesn't support readout modes
                vendor_data: vendor_features,
            },
        })
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self
            .camera_info
            .as_ref()
            .map(|i| i.is_has_cooler != 0)
            .unwrap_or(false)
        {
            return Err(NativeError::NotSupported);
        }

        // Acquire mutex for SDK operations
        let _lock = player_one_mutex().lock().await;

        // Set target temperature (POA_TARGET_TEMP is in C, int value) only
        // when the caller named one — a "cooler off" carries no setpoint.
        if let Some(target) = target_temp {
            self.set_control_int(POAConfig::POA_TARGET_TEMP, target as c_long, false)?;
        }

        // Enable/disable cooler (POA_COOLER is a bool)
        self.set_control_bool(POAConfig::POA_COOLER, enabled, false)?;

        // Record the accepted state so `get_status` can report cooler_on
        // accurately on cameras whose firmware doesn't expose POA_COOLER for
        // read-back. Only update after both SDK calls above succeeded.
        let mut guard = self
            .cooler_state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.enabled = enabled;
        if let Some(target) = target_temp {
            guard.target_c = target;
        }

        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        if let Some(delay_ms) = crate::quirks::get_temperature_delay_ms(&self.device_id) {
            tracing::debug!(
                "Applying temperature RequiresDelayMs quirk: sleeping {}ms before reading {}",
                delay_ms,
                self.device_id
            );
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        // POA_TEMPERATURE is a float value in Celsius (uses async version with mutex)
        self.get_control_float_async(POAConfig::POA_TEMPERATURE)
            .await
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        if !self
            .camera_info
            .as_ref()
            .map(|i| i.is_has_cooler != 0)
            .unwrap_or(false)
        {
            return Err(NativeError::NotSupported);
        }
        // Uses async version with mutex
        let value = self
            .get_control_int_async(POAConfig::POA_COOLER_POWER)
            .await?;
        Ok(value as f64)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        // Uses async version with mutex
        self.set_control_int_async(POAConfig::POA_GAIN, gain as c_long, false)
            .await?;
        self.current_gain = gain;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        // Uses async version with mutex. get_control_int_async returns c_long
        // (i64 on Linux LP64); gain fits in i32.
        self.get_control_int_async(POAConfig::POA_GAIN)
            .await
            .map(|v| v as i32)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), NativeError> {
        // Uses async version with mutex
        self.set_control_int_async(POAConfig::POA_OFFSET, offset as c_long, false)
            .await?;
        self.current_offset = offset;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        // Uses async version with mutex. get_control_int_async returns c_long
        // (i64 on Linux LP64); offset fits in i32.
        self.get_control_int_async(POAConfig::POA_OFFSET)
            .await
            .map(|v| v as i32)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Player One only supports symmetric binning
        let bin = bin_x.max(bin_y);

        // Acquire mutex for SDK operations
        let _lock = player_one_mutex().lock().await;

        // SAFETY: player_one_mutex held above (single-threaded SDK access); self.connected was checked at entry; POASetImageBin takes the camera ID and bin factor by value.
        let result = unsafe { (sdk.set_image_bin)(self.camera_id, bin as c_int) };
        check_poa_error(result, "SetImageBin")?;

        // Update dimensions
        let info = self.camera_info.as_ref().ok_or(NativeError::NotConnected)?;
        let new_width = info.max_width / bin;
        let new_height = info.max_height / bin;

        // SAFETY: player_one_mutex held; self.connected was checked at entry; new_width/new_height are derived from the SDK-populated max dimensions divided by the bin factor — within sensor bounds.
        let result = unsafe { (sdk.set_image_size)(self.camera_id, new_width, new_height) };
        check_poa_error(result, "SetImageSize")?;

        self.current_bin = bin;
        self.current_width = new_width;
        self.current_height = new_height;

        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        Ok((self.current_bin, self.current_bin))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let info = self.camera_info.as_ref().ok_or(NativeError::NotConnected)?;

        let (x, y, width, height) = if let Some(ref sf) = subframe {
            (
                sf.start_x as c_int,
                sf.start_y as c_int,
                sf.width as c_int,
                sf.height as c_int,
            )
        } else {
            (
                0,
                0,
                info.max_width / self.current_bin,
                info.max_height / self.current_bin,
            )
        };

        // Acquire mutex for SDK operations
        let _lock = player_one_mutex().lock().await;

        // SAFETY: player_one_mutex held above (single-threaded SDK access); self.connected was checked at entry; x/y are caller-provided subframe origin or (0,0) — POA SDK validates against current image format/binning.
        let result = unsafe { (sdk.set_image_start_pos)(self.camera_id, x, y) };
        check_poa_error(result, "SetImageStartPos")?;

        // SAFETY: player_one_mutex held; self.connected was checked at entry; width/height are either caller-provided subframe size or info.max_width/height divided by current_bin, all within sensor bounds.
        let result = unsafe { (sdk.set_image_size)(self.camera_id, width, height) };
        check_poa_error(result, "SetImageSize")?;

        self.current_width = width;
        self.current_height = height;
        // Track subframe for metadata
        self.current_subframe = subframe;

        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        if let Some(info) = &self.camera_info {
            // Why: max_width/max_height/bit_depth are c_int sensor properties populated
            // by POAGetCameraProperties. They are always non-negative for a connected
            // camera, but we saturate to 0 on negative as defense-in-depth (this
            // synchronous accessor can't surface an error).
            SensorInfo {
                width: u32::try_from(info.max_width).unwrap_or(0),
                height: u32::try_from(info.max_height).unwrap_or(0),
                pixel_size_x: info.pixel_size,
                pixel_size_y: info.pixel_size,
                // `max_adu` is the pixel-container full scale, NOT the ADC
                // range: connect() hard-fails unless POASetImageFormat(Raw16)
                // succeeds, so every frame this driver delivers is a 16-bit
                // container whose samples span [0, 65535]. See
                // [`raw16_container_max_adu`] and the `SensorInfo::max_adu`
                // contract.
                max_adu: raw16_container_max_adu(u32::try_from(info.bit_depth).unwrap_or(0)),
                bit_depth: u32::try_from(info.bit_depth).unwrap_or(0),
                color: info.is_color_camera != 0,
                bayer_pattern: if info.is_color_camera != 0 {
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
            }
        } else {
            SensorInfo::default()
        }
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        // Player One doesn't have readout modes
        Ok(Vec::new())
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        let mut features = VendorFeatures::default();

        // Get USB bandwidth (uses async version with mutex)
        if let Ok(bw) = self
            .get_control_int_async(POAConfig::POA_USB_BANDWIDTH_LIMIT)
            .await
        {
            features.usb_bandwidth = Some(bw as f64);
        }

        // Player One specific: Anti-dew heater power (uses async version with mutex)
        if let Ok(heater_power) = self
            .get_control_int_async(POAConfig::POA_HEATER_POWER)
            .await
        {
            features.anti_dew_heater = Some(heater_power > 0);
        }

        // Player One specific: Fan power (uses async version with mutex)
        if let Ok(fan_power) = self.get_control_int_async(POAConfig::POA_FAN_POWER).await {
            features.fan_power = Some(fan_power as f64);
        }

        Ok(features)
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        self.config_int_bounds(POAConfig::POA_GAIN).await
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        self.config_int_bounds(POAConfig::POA_OFFSET).await
    }
}
