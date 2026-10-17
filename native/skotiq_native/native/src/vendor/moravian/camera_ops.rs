//! `NativeCamera` implementation for `MoravianCamera`.

use super::*;

#[async_trait]
impl NativeCamera for MoravianCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities.clone()
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.sensor_info.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Get temperature
        let current_temp = {
            let mut value: c_float = 0.0;
            // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); self.connected was checked at entry so the handle is open; `&mut value` is a valid stack out-pointer to a c_float.
            if unsafe { (sdk.get_value)(handle, GV_CHIP_TEMPERATURE, &mut value) } >= 0 {
                Some(value as f64)
            } else {
                None
            }
        };

        // Get cooler power
        let cooler_power = {
            let mut value: c_float = 0.0;
            // SAFETY: moravian_mutex held; self.connected was checked at entry; `&mut value` is a valid stack out-pointer to a c_float.
            if unsafe { (sdk.get_value)(handle, GV_POWER_UTILIZATION, &mut value) } >= 0 {
                Some(value as f64)
            } else {
                None
            }
        };

        // Calculate exposure remaining from elapsed time when exposing.
        let exposure_remaining = if self.state == CameraState::Exposing {
            match self.exposure_started_at {
                Some(started) => {
                    let elapsed_secs = started.elapsed().as_secs_f64();
                    Some((self.exposure_duration - elapsed_secs).max(0.0))
                }
                None => {
                    tracing::warn!(
                        "Moravian camera is exposing but exposure start timestamp is unavailable; cannot compute remaining exposure time."
                    );
                    None
                }
            }
        } else {
            None
        };

        Ok(CameraStatus {
            state: self.state,
            sensor_temp: current_temp,
            cooler_power,
            target_temp: Some(self.target_temp),
            cooler_on: self.cooler_on,
            gain: self.current_gain,
            offset: self.current_offset,
            bin_x: self.current_bin_x,
            bin_y: self.current_bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if self.state == CameraState::Exposing {
            return Err(NativeError::SdkError("Camera is already exposing".into()));
        }

        let sdk = get_sdk()?;

        // Compute the binned, y-flipped ROI the current SDK expects on
        // start_exposure (the legacy SDK applied the ROI at download time).
        let bin_x = u32::try_from(self.current_bin_x).map_err(|_| {
            NativeError::InvalidParameter(format!(
                "Moravian current_bin_x not representable as u32: {}",
                self.current_bin_x
            ))
        })?;
        let bin_y = u32::try_from(self.current_bin_y).map_err(|_| {
            NativeError::InvalidParameter(format!(
                "Moravian current_bin_y not representable as u32: {}",
                self.current_bin_y
            ))
        })?;
        let subframe = self
            .subframe
            .as_ref()
            .map(|sf| (sf.start_x, sf.start_y, sf.width, sf.height));
        let roi = compute_binned_roi(
            self.sensor_info.width,
            self.sensor_info.height,
            bin_x,
            bin_y,
            subframe,
        )
        .map_err(NativeError::InvalidParameter)?;

        // Shutter policy lives on this ONE line: Light/Flat open the mechanical
        // shutter; Dark/Bias/DarkFlat keep it closed so calibration frames are not
        // contaminated (camera.rs `FrameType::opens_shutter`, whose doc names the
        // Moravian G-series). Bodies without a shutter simply ignore the flag.
        let use_shutter: GxBool = params.frame_type.opens_shutter() as GxBool;

        {
            // Acquire global SDK mutex for thread safety
            let _lock = moravian_mutex().lock().await;

            let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

            // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); self.connected was checked at entry so the handle is open; exp_time/use_shutter/x/y/w/h are passed by value and the ROI was bounds-checked by compute_binned_roi against the binned sensor extent.
            let ret = unsafe {
                (sdk.start_exposure)(
                    handle,
                    params.duration_secs,
                    use_shutter,
                    roi.x,
                    roi.y,
                    roi.w,
                    roi.h,
                )
            };
            if ret < 0 {
                // SAFETY: moravian_mutex held; handle is the open camera handle.
                let msg = unsafe { sdk_last_error(sdk, handle) };
                tracing::error!(
                    "Moravian gxccd_start_exposure() failed for camera '{}': {} (duration {:.3}s, ROI {}x{}+{}+{})",
                    self.name, msg, params.duration_secs, roi.w, roi.h, roi.x, roi.y
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to start exposure on Moravian camera '{}': {}",
                    self.name, msg
                )));
            }

            self.exposure_duration = params.duration_secs;
            self.exposure_started_at = Some(std::time::Instant::now());
            self.last_frame_dims = Some((roi.w as u32, roi.h as u32));
            self.state = CameraState::Exposing;

            tracing::info!(
                "Started {:.3}s exposure on Moravian camera '{}' (ROI {}x{})",
                params.duration_secs,
                self.name,
                roi.w,
                roi.h
            );
        } // Mutex released here BEFORE sleeping

        // Wait for the exposure integration (mutex is NOT held during this sleep).
        // The chip readout that follows is awaited via gxccd_image_ready in
        // download_image.
        tokio::time::sleep(tokio::time::Duration::from_secs_f64(
            params.duration_secs.max(0.0),
        ))
        .await;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Abort, discarding the frame (download = false), matching the reference
        // (mi_ccd.cpp:534). Abort is a best-effort cleanup path: log a failure
        // but still reset local state so the orchestrator is not wedged.
        // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); self.connected was checked at entry so the handle is open; gxccd_abort_exposure takes the handle plus a GxBool (download=0) by value.
        let ret = unsafe { (sdk.abort_exposure)(handle, 0) };
        if ret < 0 {
            // SAFETY: moravian_mutex held; handle is the open camera handle.
            let msg = unsafe { sdk_last_error(sdk, handle) };
            tracing::warn!(
                "Moravian gxccd_abort_exposure() failed for camera '{}': {}",
                self.name,
                msg
            );
        }

        self.state = CameraState::Idle;
        self.exposure_started_at = None;
        self.last_frame_dims = None;
        tracing::info!("Aborted exposure on Moravian camera '{}'", self.name);

        Ok(())
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Binned dimensions requested at start_exposure. gxccd_read_image takes
        // no ROI of its own; the buffer must match exactly what start_exposure
        // requested.
        let (binned_width, binned_height) = self.last_frame_dims.ok_or_else(|| {
            NativeError::SdkError(
                "Moravian download_image called without an active exposure".into(),
            )
        })?;

        // Buffer sizing, overflow-guarded. size is a size_t (usize); on 64-bit
        // targets the pixel/byte counts fit comfortably.
        let pixel_count_u64 = u64::from(binned_width)
            .checked_mul(u64::from(binned_height))
            .ok_or_else(|| {
                NativeError::SdkError(format!(
                    "Moravian buffer dimensions overflow u64: {}x{}",
                    binned_width, binned_height
                ))
            })?;
        let byte_count_u64 = pixel_count_u64
            .checked_mul(2)
            .ok_or_else(|| NativeError::SdkError("Moravian byte count overflow u64".into()))?;
        let buffer_size = usize::try_from(pixel_count_u64).map_err(|_| {
            NativeError::SdkError(format!(
                "Moravian buffer pixel count {} does not fit in usize",
                pixel_count_u64
            ))
        })?;
        let byte_count = usize::try_from(byte_count_u64).map_err(|_| {
            NativeError::SdkError(format!(
                "Moravian byte count {} does not fit in usize",
                byte_count_u64
            ))
        })?;

        // Wait for the chip to finish digitizing (readout follows the exposure
        // integration). gxccd_read_image fails if called before the image is
        // ready, so we poll gxccd_image_ready with a bounded timeout, releasing
        // the SDK mutex between polls (mi_ccd.cpp:682-700).
        let deadline =
            std::time::Instant::now() + std::time::Duration::from_secs(READOUT_TIMEOUT_SECS);
        loop {
            let ready = {
                let _lock = moravian_mutex().lock().await;
                let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
                let mut ready: GxBool = 0;
                // SAFETY: moravian_mutex held; self.connected was checked at entry so the handle is open; `&mut ready` is a valid stack out-pointer to a GxBool.
                let ret = unsafe { (sdk.image_ready)(handle, &mut ready) };
                if ret < 0 {
                    // SAFETY: moravian_mutex held; handle is the open camera handle.
                    let msg = unsafe { sdk_last_error(sdk, handle) };
                    self.state = CameraState::Error;
                    return Err(NativeError::SdkError(format!(
                        "Moravian gxccd_image_ready() failed for camera '{}': {}",
                        self.name, msg
                    )));
                }
                ready != 0
            };
            if ready {
                break;
            }
            if std::time::Instant::now() >= deadline {
                self.state = CameraState::Error;
                return Err(NativeError::SdkError(format!(
                    "Timed out after {}s waiting for Moravian camera '{}' image readout",
                    READOUT_TIMEOUT_SECS, self.name
                )));
            }
            tokio::time::sleep(tokio::time::Duration::from_millis(READOUT_POLL_MS)).await;
        }

        self.state = CameraState::Downloading;

        // Read the frame and capture temperature under a single mutex hold.
        let _lock = moravian_mutex().lock().await;
        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Allocate the exact buffer (binned_w * binned_h pixels, 16-bit each).
        let mut data: Vec<u16> = vec![0u16; buffer_size];

        // Download image.
        // SAFETY: moravian_mutex held above; handle is open (self.connected checked at entry); `data` is `vec![0u16; buffer_size]` where buffer_size = binned_width * binned_height, so `byte_count = buffer_size * 2` is the exact byte length passed as `size_t` — the SDK cannot overrun; `data.as_mut_ptr() as *mut c_void` provides a valid non-null buffer pointer.
        let ret = unsafe { (sdk.read_image)(handle, data.as_mut_ptr() as *mut c_void, byte_count) };
        if ret < 0 {
            // SAFETY: moravian_mutex held; handle is the open camera handle.
            let msg = unsafe { sdk_last_error(sdk, handle) };
            tracing::error!(
                "Moravian gxccd_read_image() failed for camera '{}': {} ({}x{} pixels, {} bytes)",
                self.name,
                msg,
                binned_width,
                binned_height,
                byte_count
            );
            self.state = CameraState::Error;
            return Err(NativeError::SdkError(format!(
                "Failed to download image from Moravian camera '{}': {}",
                self.name, msg
            )));
        }

        // gxccd_read_image returns rows bottom-up (gxccd.h:416-434). Flip to
        // top-down so orientation matches the sky and every other vendor
        // (mi_ccd.cpp:657 `mirror_image`).
        mirror_vertical_u16(&mut data, binned_width as usize, binned_height as usize);

        self.state = CameraState::Idle;
        self.exposure_started_at = None;
        self.last_frame_dims = None;

        // Get temperature while we still hold the mutex.
        let temperature = {
            let mut value: c_float = 0.0;
            // SAFETY: moravian_mutex still held (same scope as the download above); handle is still open; `&mut value` is a valid stack out-pointer to a c_float.
            if unsafe { (sdk.get_value)(handle, GV_CHIP_TEMPERATURE, &mut value) } >= 0 {
                Some(value as f64)
            } else {
                None
            }
        };

        let metadata = ImageMetadata {
            exposure_time: self.exposure_duration,
            gain: self.current_gain,
            offset: self.current_offset,
            bin_x: self.current_bin_x,
            bin_y: self.current_bin_y,
            temperature,
            timestamp: chrono::Utc::now(),
            subframe: self.subframe.clone(),
            readout_mode: None,
            vendor_data: VendorFeatures::default(),
        };

        Ok(ImageData {
            width: binned_width,
            height: binned_height,
            data,
            bits_per_pixel: self.sensor_info.bit_depth,
            bayer_pattern: self.sensor_info.bayer_pattern,
            metadata,
        })
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if self.state != CameraState::Exposing {
            return Ok(true);
        }

        let started_at = match self.exposure_started_at {
            Some(started) => started,
            None => return Ok(false),
        };
        Ok(started_at.elapsed().as_secs_f64() >= self.exposure_duration.max(0.0))
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.capabilities.can_cool {
            return Err(NativeError::NotSupported);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        if enabled {
            // gxccd_set_temperature *is* the enable here, so cooling needs a
            // setpoint; when the caller names none we reuse the one this
            // driver already holds rather than inventing a temperature.
            let target = target_temp.unwrap_or(self.target_temp);
            // Set target temperature.
            // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); self.connected was checked at entry so handle is open; gxccd_set_temperature takes the handle plus a c_float by value.
            let ret = unsafe { (sdk.set_temperature)(handle, target as c_float) };
            if ret < 0 {
                // SAFETY: moravian_mutex held; handle is the open camera handle.
                let msg = unsafe { sdk_last_error(sdk, handle) };
                tracing::error!(
                    "Moravian gxccd_set_temperature() failed for camera '{}': {} (target {:.1} C)",
                    self.name,
                    msg,
                    target
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to set cooler temperature to {:.1} C on Moravian camera '{}': {}",
                    target, self.name, msg
                )));
            }
            self.cooler_on = true;
            self.target_temp = target;
            tracing::info!("Moravian cooler enabled: target {} C", target);
        } else {
            // Warm up: a high setpoint turns the cooler fully off (mi_ccd.cpp:35).
            // No caller setpoint is involved or needed.
            // SAFETY: moravian_mutex held above; handle is open (self.connected checked at entry); gxccd_set_temperature accepts the handle and a c_float by value.
            unsafe { (sdk.set_temperature)(handle, TEMP_COOLER_OFF) };
            self.cooler_on = false;
            tracing::info!("Moravian cooler disabled");
        }

        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let mut value: c_float = 0.0;
        // SAFETY: moravian_mutex held above; self.connected was checked at entry so handle is open; `&mut value` is a valid stack out-pointer to a c_float.
        if unsafe { (sdk.get_value)(handle, GV_CHIP_TEMPERATURE, &mut value) } >= 0 {
            Ok(value as f64)
        } else {
            // SAFETY: moravian_mutex held; handle is the open camera handle.
            let msg = unsafe { sdk_last_error(sdk, handle) };
            Err(NativeError::SdkError(format!(
                "Failed to get temperature: {}",
                msg
            )))
        }
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let mut value: c_float = 0.0;
        // SAFETY: moravian_mutex held above; self.connected was checked at entry so handle is open; `&mut value` is a valid stack out-pointer to a c_float.
        if unsafe { (sdk.get_value)(handle, GV_POWER_UTILIZATION, &mut value) } >= 0 {
            Ok(value as f64)
        } else {
            // SAFETY: moravian_mutex held; handle is the open camera handle.
            let msg = unsafe { sdk_last_error(sdk, handle) };
            Err(NativeError::SdkError(format!(
                "Failed to get cooler power: {}",
                msg
            )))
        }
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.capabilities.can_set_gain {
            return Err(NativeError::NotSupported);
        }

        // gxccd_set_gain takes a uint16_t register value (gxccd.h:472-478).
        let gain_u16 = u16::try_from(gain).map_err(|_| {
            NativeError::InvalidParameter(format!("Moravian gain {} out of range 0..=65535", gain))
        })?;

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); self.connected and capabilities.can_set_gain were checked at entry so the handle is open and the camera supports gain; gxccd_set_gain takes the handle and a u16 by value.
        let ret = unsafe { (sdk.set_gain)(handle, gain_u16) };
        if ret < 0 {
            // SAFETY: moravian_mutex held; handle is the open camera handle.
            let msg = unsafe { sdk_last_error(sdk, handle) };
            tracing::error!(
                "Moravian gxccd_set_gain() failed for camera '{}': {} (requested {})",
                self.name,
                msg,
                gain
            );
            return Err(NativeError::SdkError(format!(
                "Failed to set gain to {} on Moravian camera '{}': {}",
                gain, self.name, msg
            )));
        }

        self.current_gain = gain;
        Ok(())
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.capabilities.can_set_binning && (bin_x > 1 || bin_y > 1) {
            return Err(NativeError::NotSupported);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); self.connected was checked at entry so the handle is open; gxccd_set_binning takes the handle plus two c_int values by value.
        let ret = unsafe { (sdk.set_binning)(handle, bin_x as c_int, bin_y as c_int) };
        if ret < 0 {
            // SAFETY: moravian_mutex held; handle is the open camera handle.
            let msg = unsafe { sdk_last_error(sdk, handle) };
            tracing::error!(
                "Moravian gxccd_set_binning() failed for camera '{}': {} (requested {}x{}, max {}x{})",
                self.name,
                msg,
                bin_x,
                bin_y,
                self.capabilities.max_bin_x,
                self.capabilities.max_bin_y
            );
            return Err(NativeError::SdkError(format!(
                "Failed to set binning to {}x{} on Moravian camera '{}': {} (max {}x{})",
                bin_x,
                bin_y,
                self.name,
                msg,
                self.capabilities.max_bin_x,
                self.capabilities.max_bin_y
            )));
        }

        self.current_bin_x = bin_x;
        self.current_bin_y = bin_y;
        Ok(())
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // The current SDK validates the ROI on gxccd_start_exposure, so there is
        // no separate "adjust subframe" call. We validate the top-down, unbinned
        // request against the sensor extent and store it; the binned, y-flipped
        // ROI is derived at start_exposure (compute_binned_roi).
        match subframe {
            Some(sf) => {
                if !self.capabilities.can_subframe {
                    return Err(NativeError::NotSupported);
                }
                if sf.width == 0 || sf.height == 0 {
                    return Err(NativeError::InvalidParameter(
                        "Moravian subframe width/height must be > 0".into(),
                    ));
                }
                let x_end = sf.start_x.checked_add(sf.width).ok_or_else(|| {
                    NativeError::InvalidParameter("Moravian subframe x extent overflow".into())
                })?;
                let y_end = sf.start_y.checked_add(sf.height).ok_or_else(|| {
                    NativeError::InvalidParameter("Moravian subframe y extent overflow".into())
                })?;
                if x_end > self.sensor_info.width || y_end > self.sensor_info.height {
                    return Err(NativeError::InvalidParameter(format!(
                        "Moravian subframe ({}, {}) {}x{} exceeds sensor {}x{}",
                        sf.start_x,
                        sf.start_y,
                        sf.width,
                        sf.height,
                        self.sensor_info.width,
                        self.sensor_info.height
                    )));
                }
                self.subframe = Some(sf);
            }
            None => {
                self.subframe = None;
            }
        }

        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        Ok(self.current_gain)
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        Ok((self.current_bin_x, self.current_bin_y))
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Number of read modes.
        let num_modes = {
            let mut value: c_int = 0;
            // SAFETY: moravian_mutex held above; self.connected was checked at entry so handle is open; `&mut value` is a valid stack out-pointer to a c_int.
            if unsafe { (sdk.get_integer_parameter)(handle, GIP_READ_MODES, &mut value) } >= 0 {
                value
            } else {
                1
            }
        };

        let mut modes = Vec::new();
        for i in 0..num_modes.max(0) {
            let mut desc_buf = [0 as c_char; 256];
            // SAFETY: moravian_mutex held; handle is open; `i` is in [0, num_modes) as reported above; desc_buf is 256 bytes and its truthful length is passed as `size_t`. gxccd_enumerate_read_modes returns -1 once the index is past the end.
            if unsafe {
                (sdk.enumerate_read_modes)(handle, i, desc_buf.as_mut_ptr(), desc_buf.len())
            } >= 0
            {
                // SAFETY: desc_buf is 256 bytes; the SDK guarantees NUL-termination within the buffer on success.
                let description = unsafe { std::ffi::CStr::from_ptr(desc_buf.as_ptr()) }
                    .to_string_lossy()
                    .trim()
                    .to_string();

                modes.push(ReadoutMode {
                    name: if description.is_empty() {
                        format!("Mode {}", i)
                    } else {
                        description.clone()
                    },
                    description,
                    index: i,
                    gain_min: None,
                    gain_max: None,
                    offset_min: None,
                    offset_max: None,
                });
            }
        }

        if modes.is_empty() {
            modes.push(ReadoutMode {
                name: "Normal".to_string(),
                description: "Standard readout mode".to_string(),
                index: 0,
                gain_min: None,
                gain_max: None,
                offset_min: None,
                offset_max: None,
            });
        }

        Ok(modes)
    }

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); self.connected was checked at entry so the handle is open; gxccd_set_read_mode takes the handle plus a c_int index by value.
        let ret = unsafe { (sdk.set_read_mode)(handle, mode.index as c_int) };
        if ret < 0 {
            // SAFETY: moravian_mutex held; handle is the open camera handle.
            let msg = unsafe { sdk_last_error(sdk, handle) };
            tracing::error!(
                "Moravian gxccd_set_read_mode() failed for camera '{}': {} (mode {} '{}')",
                self.name,
                msg,
                mode.index,
                mode.name
            );
            return Err(NativeError::SdkError(format!(
                "Failed to set readout mode '{}' (index {}) on Moravian camera '{}': {}",
                mode.name, mode.index, self.name, msg
            )));
        }

        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        // Moravian has hot side temp available but VendorFeatures doesn't have this field
        // Could use custom_data in future if needed
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // The gX SDK publishes no gain bounds, and the range genuinely differs between
        // the CCD and CMOS model lines; report the absence rather than one invented
        // range for both.
        Err(NativeError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        Err(NativeError::NotSupported)
    }
}
