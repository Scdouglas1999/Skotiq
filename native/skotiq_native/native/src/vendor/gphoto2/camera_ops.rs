//! `NativeDevice` / `NativeCamera` / `Drop` implementations for `GPhoto2Camera`.

use super::*;

// NativeDevice implementation

#[async_trait]
impl NativeDevice for GPhoto2Camera {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.model_name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::GPhoto2
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        tracing::info!(
            "Connecting to gPhoto2 camera: {} on {}",
            self.model_name,
            self.port_path
        );

        let sdk = GPhoto2Sdk::get().ok_or_else(|| {
            tracing::error!("Cannot connect to DSLR camera: libgphoto2 not loaded");
            NativeError::SdkNotLoaded
        })?;

        let _lock = gphoto2_mutex().lock().await;

        let detected = detect_gphoto2_cameras();
        if self.port_path.is_empty() {
            if detected.len() > 1 {
                return Err(NativeError::InvalidDevice(format!(
                    "gPhoto2 device '{}' does not encode a stable USB port and cannot be safely selected while multiple cameras are connected",
                    self.model_name
                )));
            }
        } else {
            let desired = detected
                .iter()
                .find(|camera| camera.port == self.port_path)
                .ok_or_else(|| {
                    NativeError::DeviceNotFound(format!(
                        "gPhoto2 camera '{}' on '{}' is no longer present",
                        self.model_name, self.port_path
                    ))
                })?;

            self.camera_index = desired.index;
            if detected.len() > 1 && desired.index != 0 {
                return Err(NativeError::InvalidDevice(format!(
                    "gPhoto2 cannot safely bind '{}' on '{}' while another camera is enumerated first",
                    self.model_name, self.port_path
                )));
            }
        }

        // SAFETY: caller holds gphoto2_mutex (this method is invoked from `connect`,
        // which acquires the lock). All `gp_*` allocations are paired with their
        // corresponding free/unref on every error path; on success the resources are
        // stored in `self.gp_camera` / `self.gp_context` and live until `disconnect`.
        // Out-pointer (`camera`) is a stack local.
        unsafe {
            // Create context
            let context = (sdk.context_new)();
            if context.is_null() {
                return Err(NativeError::SdkError(
                    "gPhoto2: Failed to create context".to_string(),
                ));
            }

            // Create camera
            let mut camera: *mut GPCamera = std::ptr::null_mut();
            let ret = (sdk.camera_new)(&mut camera);
            if ret < GP_OK || camera.is_null() {
                (sdk.context_unref)(context);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: Failed to create camera object: code {}",
                    ret
                )));
            }

            // Initialize camera (auto-detects and connects to first available camera)
            let ret = (sdk.camera_init)(camera, context);
            if ret < GP_OK {
                (sdk.camera_free)(camera);
                (sdk.context_unref)(context);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: Failed to initialize camera '{}': code {} - camera may be in use by another application or not connected via USB",
                    self.model_name, ret
                )));
            }

            self.gp_camera = camera;
            self.gp_context = context;
        }

        // Read camera info (ISO values, abilities, sensor dimensions)
        if let Err(e) = self.populate_camera_info() {
            tracing::warn!("gPhoto2: Failed to populate camera info: {}", e);
            // Non-fatal — we can still capture with defaults
        }

        self.connected = true;
        tracing::info!(
            "Successfully connected to gPhoto2 camera: {} ({}x{}, {}-bit)",
            self.model_name,
            self.sensor_width,
            self.sensor_height,
            self.bit_depth
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;
            let _lock = gphoto2_mutex().lock().await;

            // SAFETY: `_lock` (gphoto2_mutex guard) is held for the entire block. Each
            // raw pointer is non-null-checked before use and set to null after free so
            // a subsequent drop does not double-free. `camera_exit`+`camera_free` is
            // the libgphoto2-documented teardown sequence; `context_unref` releases
            // the context refcount.
            unsafe {
                if !self.gp_camera.is_null() {
                    let _ = (sdk.camera_exit)(self.gp_camera, self.gp_context);
                    (sdk.camera_free)(self.gp_camera);
                    self.gp_camera = std::ptr::null_mut();
                }

                if !self.gp_context.is_null() {
                    (sdk.context_unref)(self.gp_context);
                    self.gp_context = std::ptr::null_mut();
                }
            }

            self.connected = false;
            self.exposure_state = ExposureState::Idle;
            self.last_capture_path = None;
            self.last_raw_data = None;

            tracing::info!("Disconnected from gPhoto2 camera: {}", self.model_name);
        }
        Ok(())
    }
}

// NativeCamera implementation

#[async_trait]
impl NativeCamera for GPhoto2Camera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities {
            can_cool: false,        // DSLRs don't have coolers
            can_set_gain: true,     // ISO mapped to gain
            can_set_offset: false,  // DSLRs don't have offset control
            can_set_binning: false, // DSLRs don't support binning
            can_subframe: false,    // DSLRs capture full frame only
            has_shutter: true,      // DSLRs have mechanical shutters
            has_guider_port: false, // DSLRs don't have ST-4 ports
            max_bin_x: 1,
            max_bin_y: 1,
            supports_readout_modes: false,
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let state = match self.exposure_state {
            ExposureState::Idle => CameraState::Idle,
            ExposureState::Exposing {
                start,
                duration_secs,
            } => {
                let elapsed = start.elapsed().as_secs_f64();
                if elapsed >= duration_secs {
                    CameraState::Downloading
                } else {
                    CameraState::Exposing
                }
            }
            ExposureState::BulbExposing { .. } => CameraState::Exposing,
            ExposureState::Complete => CameraState::Idle,
            ExposureState::Failed => CameraState::Error,
        };

        let exposure_remaining = match self.exposure_state {
            ExposureState::Exposing {
                start,
                duration_secs,
            }
            | ExposureState::BulbExposing {
                start,
                duration_secs,
            } => {
                let remaining = duration_secs - start.elapsed().as_secs_f64();
                Some(remaining.max(0.0))
            }
            _ => None,
        };

        Ok(CameraStatus {
            state,
            sensor_temp: None, // DSLRs don't report sensor temp
            cooler_power: None,
            target_temp: None,
            cooler_on: false,
            gain: self.current_gain,
            offset: self.current_offset,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let _lock = gphoto2_mutex().lock().await;

        // Set ISO (gain) if provided
        if let Some(gain) = params.gain {
            if gain >= 0 && (gain as usize) < self.iso_values.len() {
                let iso_str = &self.iso_values[gain as usize].clone();
                self.set_config_value_str("iso", iso_str)?;
                self.current_gain = gain;
                self.current_iso_index = gain;
                tracing::info!("gPhoto2: Set ISO to {} (gain index {})", iso_str, gain);
            } else {
                return Err(NativeError::InvalidParameter(format!(
                    "gPhoto2: Invalid gain/ISO index {}. Valid range: 0-{}",
                    gain,
                    self.iso_values.len().saturating_sub(1)
                )));
            }
        }

        // Force RAW capture format. We always LibRaw-decode the downloaded
        // file, so a body left in JPEG / RAW+JPEG must be switched to RAW or
        // every frame fails to decode. Best-effort (warns if unsupported).
        self.apply_raw_format();

        self.exposure_time = params.duration_secs;
        let use_bulb = params.duration_secs > 30.0;

        if use_bulb {
            // Bulb mode for long exposures
            if !self.can_bulb {
                return Err(NativeError::SdkError(
                    "gPhoto2: Camera does not support Bulb mode for exposures > 30s".to_string(),
                ));
            }

            self.do_bulb_start()?;
            self.exposure_state = ExposureState::BulbExposing {
                start: Instant::now(),
                duration_secs: params.duration_secs,
            };

            tracing::info!(
                "gPhoto2: Started bulb exposure for {:.1}s",
                params.duration_secs
            );
        } else {
            // Standard capture: set shutter speed first, then capture
            if let Some(speed_str) = self.find_shutter_speed(params.duration_secs) {
                // Write to whichever shutter widget the body exposes. Some cameras
                // (notably Nikon) present the setting as "shutterspeed2", and the
                // read path (get_config_choices) already falls back to it — so the
                // WRITE must fall back too, otherwise on those bodies set_config
                // fails, is only warned, and the exposure time silently never
                // changes (wrong sub-30s subs).
                let set_res = self
                    .set_config_value_str("shutterspeed", &speed_str)
                    .or_else(|_| self.set_config_value_str("shutterspeed2", &speed_str));
                if let Err(e) = set_res {
                    tracing::warn!(
                        "gPhoto2: Could not set shutter speed to '{}': {}. Camera will use current setting.",
                        speed_str, e
                    );
                } else {
                    tracing::info!("gPhoto2: Set shutter speed to {}", speed_str);
                }
            }

            self.exposure_state = ExposureState::Exposing {
                start: Instant::now(),
                duration_secs: params.duration_secs,
            };

            // gp_camera_capture blocks until the exposure completes and the image is saved
            // on the camera's storage card. We run it in a blocking task so we don't block
            // the async runtime.
            //
            // Note: We need to release the mutex before spawning the blocking task,
            // then re-acquire it inside. However, since gp_camera_capture is a blocking
            // call that needs the mutex, we handle this by keeping the mutex and running
            // synchronously. The exposure polling system will check is_exposure_complete.
            self.do_capture()?;
            self.exposure_state = ExposureState::Complete;

            tracing::info!(
                "gPhoto2: Capture complete for {:.3}s exposure",
                params.duration_secs
            );
        }

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let _lock = gphoto2_mutex().lock().await;

        match self.exposure_state {
            ExposureState::BulbExposing { .. } => {
                self.do_bulb_stop()?;
                self.exposure_state = ExposureState::Idle;
                tracing::info!("gPhoto2: Bulb exposure aborted");
            }
            ExposureState::Exposing { .. } => {
                // Standard captures can't be interrupted mid-exposure on most DSLRs
                tracing::warn!("gPhoto2: Cannot abort a standard (non-bulb) exposure in progress");
                return Err(NativeError::SdkError(
                    "gPhoto2: Standard exposures cannot be aborted. Use Bulb mode for interruptible long exposures.".to_string(),
                ));
            }
            _ => {
                tracing::debug!("gPhoto2: No exposure in progress to abort");
            }
        }

        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        match self.exposure_state {
            ExposureState::Idle => Ok(true),
            ExposureState::Complete => Ok(true),
            ExposureState::Failed => Err(NativeError::SdkError(
                "gPhoto2: Previous exposure failed".to_string(),
            )),
            ExposureState::Exposing {
                start,
                duration_secs,
            } => {
                // For standard captures, the capture already completed synchronously
                // in start_exposure. If we're still in Exposing state, it means
                // the duration hasn't elapsed yet (for UI progress tracking).
                Ok(start.elapsed().as_secs_f64() >= duration_secs)
            }
            ExposureState::BulbExposing {
                start,
                duration_secs,
            } => {
                // Check if the bulb exposure duration has elapsed
                Ok(start.elapsed().as_secs_f64() >= duration_secs)
            }
        }
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let _lock = gphoto2_mutex().lock().await;

        // If bulb exposure is complete, we need to stop it and wait for the file
        if let ExposureState::BulbExposing {
            start,
            duration_secs,
        } = self.exposure_state
        {
            if start.elapsed().as_secs_f64() >= duration_secs {
                self.do_bulb_stop()?;

                // After bulb stop, wait for the camera to save the file
                // and send us the file-added event
                let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;
                let wait_start = Instant::now();
                let max_wait = Duration::from_secs(30);

                loop {
                    if wait_start.elapsed() > max_wait {
                        return Err(NativeError::Timeout(
                            "gPhoto2: Timed out waiting for camera to save image after bulb exposure".to_string(),
                        ));
                    }

                    // SAFETY: caller holds gphoto2_mutex (acquired in the outer
                    // method that contains this loop). `gp_camera`/`gp_context` are
                    // valid non-null. `event_data` is libgphoto2-owned and only
                    // dereferenced after both (a) `event_type == 2` confirms it is a
                    // GP_EVENT_FILE_ADDED payload (i.e. `*CameraFilePath`) and (b)
                    // the non-null guard passes; the borrow is then cloned into
                    // `self.last_capture_path` before the next loop iteration.
                    unsafe {
                        let mut event_type: c_int = 0;
                        let mut event_data: *mut c_void = std::ptr::null_mut();
                        let ret = (sdk.camera_wait_for_event)(
                            self.gp_camera,
                            1000, // 1 second timeout per poll
                            &mut event_type,
                            &mut event_data,
                            self.gp_context,
                        );

                        if ret < GP_OK {
                            tracing::warn!("gPhoto2: wait_for_event returned {}", ret);
                            break;
                        }

                        // Event type 2 = GP_EVENT_FILE_ADDED
                        if event_type == 2 && !event_data.is_null() {
                            // event_data points to a CameraFilePath
                            let path = &*(event_data as *const CameraFilePath);
                            self.last_capture_path = Some(path.clone());
                            tracing::info!(
                                "gPhoto2: Bulb image saved: {}/{}",
                                cstr_from_array(&path.folder),
                                cstr_from_array(&path.name)
                            );
                            break;
                        }
                    }
                }

                self.exposure_state = ExposureState::Complete;
            }
        }

        if self.exposure_state != ExposureState::Complete {
            return Err(NativeError::SdkError(
                "gPhoto2: No completed exposure to download".to_string(),
            ));
        }

        // Download the raw file from camera
        let raw_bytes = self.download_from_camera()?;

        // Reset state
        self.exposure_state = ExposureState::Idle;
        self.last_capture_path = None;

        // Decode the RAW file to 16-bit image data
        self.decode_raw_to_image_data(&raw_bytes)
    }

    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if gain < 0 || (gain as usize) >= self.iso_values.len() {
            return Err(NativeError::InvalidParameter(format!(
                "gPhoto2: Invalid gain/ISO index {}. Valid range: 0-{}",
                gain,
                self.iso_values.len().saturating_sub(1)
            )));
        }

        let _lock = gphoto2_mutex().lock().await;
        let iso_str = self.iso_values[gain as usize].clone();
        self.set_config_value_str("iso", &iso_str)?;
        self.current_gain = gain;
        self.current_iso_index = gain;

        tracing::info!("gPhoto2: Set ISO to {} (gain index {})", iso_str, gain);
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        Ok(self.current_gain)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        Ok(0) // DSLRs don't have offset control
    }

    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        Ok((1, 1))
    }

    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo {
            width: self.sensor_width,
            height: self.sensor_height,
            pixel_size_x: self.pixel_size,
            pixel_size_y: self.pixel_size,
            max_adu: resolve_max_adu(self.measured_white_level, self.bit_depth),
            bit_depth: self.bit_depth,
            color: self.is_color,
            bayer_pattern: Some(BayerPattern::Rggb),
        }
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        Ok(vec![ReadoutMode {
            name: "Standard".to_string(),
            description: "Standard DSLR readout".to_string(),
            index: 0,
            gain_min: Some(0),
            gain_max: Some(self.iso_values.len().saturating_sub(1) as i32),
            offset_min: None,
            offset_max: None,
        }])
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), NativeError> {
        // DSLRs only have one readout mode
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        let mut features = VendorFeatures::default();
        let mut custom = std::collections::HashMap::new();

        custom.insert(
            "camera_model".to_string(),
            serde_json::Value::String(self.model_name.clone()),
        );

        if let Some(iso_str) = self.iso_values.get(self.current_gain as usize) {
            custom.insert(
                "iso".to_string(),
                serde_json::Value::String(iso_str.clone()),
            );
        }

        custom.insert(
            "can_bulb".to_string(),
            serde_json::Value::Bool(self.can_bulb),
        );
        custom.insert(
            "can_preview".to_string(),
            serde_json::Value::Bool(self.can_preview),
        );

        if !self.iso_values.is_empty() {
            custom.insert(
                "available_isos".to_string(),
                serde_json::Value::Array(
                    self.iso_values
                        .iter()
                        .map(|s| serde_json::Value::String(s.clone()))
                        .collect(),
                ),
            );
        }

        features.custom_data = custom;
        Ok(features)
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        if self.iso_values.is_empty() {
            return Err(NativeError::NotSupported);
        }
        Ok((0, self.iso_values.len().saturating_sub(1) as i32))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        if !self.can_preview {
            return Err(NativeError::NotSupported);
        }

        let _lock = gphoto2_mutex().lock().await;
        let sdk = GPhoto2Sdk::get()
            .ok_or_else(|| NativeError::SdkError("gPhoto2 SDK not loaded".to_string()))?;

        // SAFETY: gphoto2_mutex held; gp_camera/gp_context valid while connected.
        // gp_file is stack-allocated out-pointer freed on every exit path.
        unsafe {
            let mut gp_file: *mut CameraFile = std::ptr::null_mut();
            let ret = (sdk.file_new)(&mut gp_file);
            check_gp_error(ret, "file_new")?;

            let ret = (sdk.camera_capture_preview)(self.gp_camera, gp_file, self.gp_context);
            if ret < GP_OK {
                (sdk.file_free)(gp_file);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: capture_preview failed with code {}",
                    ret
                )));
            }

            let mut data_ptr: *const c_char = std::ptr::null();
            let mut data_size: u64 = 0;
            let ret = (sdk.file_get_data_and_size)(gp_file, &mut data_ptr, &mut data_size);
            if ret < GP_OK || data_ptr.is_null() || data_size == 0 {
                (sdk.file_free)(gp_file);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: Failed to read preview data: code {}",
                    ret
                )));
            }

            let data = std::slice::from_raw_parts(data_ptr as *const u8, data_size as usize);
            let jpeg = data.to_vec();
            (sdk.file_free)(gp_file);
            Ok(jpeg)
        }
    }
}

impl Drop for GPhoto2Camera {
    fn drop(&mut self) {
        // Ensure camera resources are cleaned up
        if self.connected {
            if let Some(sdk) = GPhoto2Sdk::get() {
                // SAFETY: Drop is best-effort cleanup. We do NOT acquire gphoto2_mutex
                // here because (a) Drop cannot await, and (b) Drop only runs when the
                // last owner is releasing the camera, so no other thread should be
                // touching `gp_camera`/`gp_context`. Each pointer is non-null-checked
                // before its corresponding free/unref. This is the same defensive
                // teardown pattern used by other vendor Drop impls.
                unsafe {
                    if !self.gp_camera.is_null() {
                        let _ = (sdk.camera_exit)(self.gp_camera, self.gp_context);
                        (sdk.camera_free)(self.gp_camera);
                    }
                    if !self.gp_context.is_null() {
                        (sdk.context_unref)(self.gp_context);
                    }
                }
            }
        }
    }
}
