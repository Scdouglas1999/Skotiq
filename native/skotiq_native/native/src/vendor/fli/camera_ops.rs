//! `NativeCamera` implementation for `FliCamera`.

use super::*;

#[async_trait]
impl NativeCamera for FliCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // Get temperature
        let sensor_temp = {
            let mut temp: c_double = 0.0;
            // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `temp` is a valid stack pointer.
            if unsafe { (sdk.get_temperature)(self.handle, &mut temp) } == 0 {
                Some(temp)
            } else {
                None
            }
        };

        // Get cooler power
        let cooler_power = {
            let mut power: c_double = 0.0;
            // SAFETY: fli_mutex held; self.handle is valid (connected=true checked); `power` is a valid stack pointer.
            if unsafe { (sdk.get_cooler_power)(self.handle, &mut power) } == 0 {
                Some(power)
            } else {
                None
            }
        };

        // Get exposure remaining
        let exposure_remaining = if self.state == CameraState::Exposing {
            let mut timeleft: c_long = 0;
            // SAFETY: fli_mutex held; self.handle is valid; `timeleft` is a valid stack pointer.
            if unsafe { (sdk.get_exposure_status)(self.handle, &mut timeleft) } == 0 {
                Some(timeleft as f64 / 1000.0) // Convert from ms to seconds
            } else {
                None
            }
        } else {
            None
        };

        Ok(CameraStatus {
            state: self.state,
            sensor_temp,
            cooler_power,
            target_temp: Some(self.target_temp),
            cooler_on: self.cooler_on,
            gain: 0,
            offset: 0,
            bin_x: self.current_bin_x,
            bin_y: self.current_bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // Set binning (has its own mutex lock)
        self.set_binning(params.bin_x, params.bin_y).await?;

        // Set subframe (has its own mutex lock)
        self.set_subframe(params.subframe.clone()).await?;

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // Dark/bias frames must keep the mechanical shutter CLOSED
        // (FLI_FRAME_TYPE_DARK); light/flat frames open it (FLI_FRAME_TYPE_NORMAL).
        // A dark exposed as NORMAL is light-contaminated, and the calibration
        // master built from it is worthless.
        let fli_frame_type = if params.frame_type.opens_shutter() {
            FLI_FRAME_TYPE_NORMAL
        } else {
            FLI_FRAME_TYPE_DARK
        };
        // SAFETY: fli_mutex held; self.handle is valid (connected=true checked at function start); frame type is a valid FLI frame-type constant.
        let result = unsafe { (sdk.set_frame_type)(self.handle, fli_frame_type) };
        check_fli_error(result, "set frame type")?;

        // Set exposure time (in milliseconds)
        let exposure_ms = (params.duration_secs * 1000.0) as c_long;
        // SAFETY: fli_mutex held; self.handle is valid; `exposure_ms` is a pass-by-value c_long.
        let result = unsafe { (sdk.set_exposure_time)(self.handle, exposure_ms) };
        check_fli_error(result, "set exposure time")?;

        // Start exposure
        // SAFETY: fli_mutex held; self.handle is valid; FLIExposeFrame takes only the device handle.
        let result = unsafe { (sdk.expose_frame)(self.handle) };
        check_fli_error(result, "expose frame")?;

        self.exposure_duration = params.duration_secs;
        self.state = CameraState::Exposing;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked).
        let result = unsafe { (sdk.cancel_exposure)(self.handle) };
        check_fli_error(result, "cancel exposure")?;

        self.state = CameraState::Idle;
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // Check device status
        let mut status: c_long = 0;
        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `status` is a valid stack pointer.
        let result = unsafe { (sdk.get_device_status)(self.handle, &mut status) };
        check_fli_error(result, "get device status")?;

        // Check if data is ready
        Ok((status & FLI_CAMERA_DATA_READY) != 0)
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        self.state = CameraState::Downloading;

        // Calculate image dimensions based on subframe and binning.
        // Why: current_bin_{x,y} are i32; a negative or zero value would divide-by-zero
        // or wrap to a giant usize. Reject explicitly. SubFrame.width/height are u32
        // sensor coords and widening to usize is value-preserving on every Tier 1 target.
        let bin_x_usize = usize::try_from(self.current_bin_x).map_err(|_| {
            NativeError::InvalidParameter(format!(
                "FLI current_bin_x not representable as usize: {}",
                self.current_bin_x
            ))
        })?;
        let bin_y_usize = usize::try_from(self.current_bin_y).map_err(|_| {
            NativeError::InvalidParameter(format!(
                "FLI current_bin_y not representable as usize: {}",
                self.current_bin_y
            ))
        })?;
        if bin_x_usize == 0 || bin_y_usize == 0 {
            return Err(NativeError::InvalidParameter(
                "FLI binning must be >= 1".into(),
            ));
        }
        let (width, height) = if let Some(sf) = &self.subframe {
            // Why: sf.width/height are u32 sensor dims (<= 16k on FLI hardware); widening
            // to usize via `as` is always safe.
            (
                sf.width as usize / bin_x_usize,
                sf.height as usize / bin_y_usize,
            )
        } else {
            // Why: visible_lr_x/y >= visible_ul_x/y by the SDK contract enforced at
            // connect (FLIGetVisibleArea returns lower-right strictly bottom-right).
            // Both deltas are non-negative i32 values within sensor bounds.
            let dx = self.visible_lr_x - self.visible_ul_x;
            let dy = self.visible_lr_y - self.visible_ul_y;
            let dx_usize = usize::try_from(dx).map_err(|_| {
                NativeError::SdkError(format!("FLI visible width is negative: {}", dx))
            })?;
            let dy_usize = usize::try_from(dy).map_err(|_| {
                NativeError::SdkError(format!("FLI visible height is negative: {}", dy))
            })?;
            (dx_usize / bin_x_usize, dy_usize / bin_y_usize)
        };

        // Allocate raw byte buffer (16-bit = 2 bytes per pixel).
        // Why: FLIGrabRow() writes `width` u16 pixels (= width*2 bytes) of little-endian pixel data into a *mut u8
        // sink. Allocating Vec<u16> and casting through *mut u8 would force the caller to
        // assume the host is little-endian for the resulting u16 values; allocating a Vec<u8>
        // and decoding via from_le_bytes pins the SDK's documented LE framing and removes
        // the alignment hazard entirely (Vec<u8> is u8-aligned, no transmute needed).
        let row_bytes = width
            .checked_mul(2)
            .ok_or_else(|| NativeError::SdkError("FLI image width overflows usize".into()))?;
        let total_bytes = row_bytes
            .checked_mul(height)
            .ok_or_else(|| NativeError::SdkError("FLI image height overflows usize".into()))?;
        let mut byte_buffer: Vec<u8> = vec![0u8; total_bytes];

        // Read image row by row (FLI style)
        for row in 0..height {
            let row_offset = row * row_bytes;
            // SAFETY: row_offset = row * row_bytes is strictly less than total_bytes = height * row_bytes (row < height), so the resulting pointer remains within byte_buffer's allocation (in-bounds, single allocated object); both row and row_bytes are usize derived from validated overflow-checked multiplications above.
            let row_ptr = unsafe { byte_buffer.as_mut_ptr().add(row_offset) };
            // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `row_ptr` points to `row_bytes` bytes inside byte_buffer (verified above). FLIGrabRow's third argument is a PIXEL count, not a byte count — it writes exactly `width` u16 elements = `width * 2` = `row_bytes` bytes into `row_ptr`. Passing `row_bytes` here (the previous bug) told the SDK to write `row_bytes` u16 pixels = 2x the row slot, overrunning the buffer on every bin>=2 frame (bin=1 was masked by the SDK's internal width clamp). Matches the reference (fli_ccd.cpp:667 passes pixel `width`).
            let result = unsafe { (sdk.grab_row)(self.handle, row_ptr, width) };
            if result != 0 {
                tracing::error!(
                    "FLI GrabRow() failed for camera '{}'. Row: {}/{}, width: {} bytes, error code: {}",
                    self.name, row, height, row_bytes, result
                );
                self.state = CameraState::Error;
                return Err(NativeError::SdkError(format!(
                    "Failed to grab row {} of {} from FLI camera '{}'. SDK error: {}. Image download interrupted.",
                    row, height, self.name, result
                )));
            }
        }

        // Decode the byte buffer into u16 pixels with explicit little-endian framing.
        let data: Vec<u16> = byte_buffer
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
            .collect();

        // End exposure
        // SAFETY: fli_mutex held above; self.handle is valid; FLIEndExposure takes only the handle.
        let _ = unsafe { (sdk.end_exposure)(self.handle) };

        // Get temperature for metadata
        let temperature = {
            let mut temp: c_double = 0.0;
            // SAFETY: fli_mutex held; self.handle is valid; `temp` is a valid stack pointer.
            if unsafe { (sdk.get_temperature)(self.handle, &mut temp) } == 0 {
                Some(temp)
            } else {
                None
            }
        };

        let metadata = ImageMetadata {
            exposure_time: self.exposure_duration,
            gain: 0,
            offset: 0,
            bin_x: self.current_bin_x,
            bin_y: self.current_bin_y,
            temperature,
            timestamp: chrono::Utc::now(),
            subframe: self.subframe.clone(),
            readout_mode: None,
            vendor_data: VendorFeatures::default(),
        };

        self.state = CameraState::Idle;

        // Why: width/height were derived from validated non-negative values divided by
        // bins >= 1, so they are sensor-bounded. On 64-bit hosts usize is wider than u32;
        // surface overflow rather than truncate if dimensions ever exceed u32::MAX.
        let width_u32 = u32::try_from(width).map_err(|_| {
            NativeError::SdkError(format!("FLI image width does not fit in u32: {}", width))
        })?;
        let height_u32 = u32::try_from(height).map_err(|_| {
            NativeError::SdkError(format!("FLI image height does not fit in u32: {}", height))
        })?;
        Ok(ImageData {
            width: width_u32,
            height: height_u32,
            data,
            bits_per_pixel: self.sensor_info.bit_depth,
            bayer_pattern: self.sensor_info.bayer_pattern,
            metadata,
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

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // FLISetTemperature *is* the enable on this SDK: cooling needs a
        // setpoint, so when the caller names none we reuse the one this driver
        // already holds instead of inventing a temperature.
        let setpoint_c = if enabled {
            target_temp.unwrap_or(self.target_temp)
        } else {
            // Disabling needs no setpoint from the caller — a high target is
            // simply how this SDK parks the TEC.
            25.0
        };

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `setpoint_c` is a pass-by-value c_double.
        let result = unsafe { (sdk.set_temperature)(self.handle, setpoint_c) };
        check_fli_error(result, "set temperature")?;

        self.cooler_on = enabled;
        if enabled {
            self.target_temp = setpoint_c;
        }
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let mut temp: c_double = 0.0;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `temp` is a valid stack pointer.
        let result = unsafe { (sdk.get_temperature)(self.handle, &mut temp) };
        check_fli_error(result, "get temperature")?;

        Ok(temp)
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let mut power: c_double = 0.0;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `power` is a valid stack pointer.
        let result = unsafe { (sdk.get_cooler_power)(self.handle, &mut power) };
        check_fli_error(result, "get cooler power")?;

        Ok(power)
    }

    async fn set_gain(&mut self, _gain: i32) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); bin_x is a pass-by-value c_long bounded by max_bin_x=16 in capabilities.
        let result = unsafe { (sdk.set_hbin)(self.handle, bin_x as c_long) };
        check_fli_error(result, "set horizontal binning")?;

        // SAFETY: fli_mutex held; self.handle is valid; bin_y is bounded by max_bin_y=16.
        let result = unsafe { (sdk.set_vbin)(self.handle, bin_y as c_long) };
        check_fli_error(result, "set vertical binning")?;

        self.current_bin_x = bin_x;
        self.current_bin_y = bin_y;
        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        Ok((self.current_bin_x, self.current_bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // Why: SubFrame.start_x/y/width/height are u32. We convert to i32 with overflow
        // detection (a u32 > i32::MAX would wrap to negative) and add to the validated
        // visible-area origin with checked_add so the sum cannot overflow i32 either.
        let (ul_x, ul_y, lr_x, lr_y) = match &subframe {
            Some(sf) => {
                let sx = i32::try_from(sf.start_x).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "FLI subframe start_x exceeds i32: {}",
                        sf.start_x
                    ))
                })?;
                let sy = i32::try_from(sf.start_y).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "FLI subframe start_y exceeds i32: {}",
                        sf.start_y
                    ))
                })?;
                let sw = i32::try_from(sf.width).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "FLI subframe width exceeds i32: {}",
                        sf.width
                    ))
                })?;
                let sh = i32::try_from(sf.height).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "FLI subframe height exceeds i32: {}",
                        sf.height
                    ))
                })?;
                let ul_x = self.visible_ul_x.checked_add(sx).ok_or_else(|| {
                    NativeError::InvalidParameter("FLI subframe ul_x overflows i32".into())
                })?;
                let ul_y = self.visible_ul_y.checked_add(sy).ok_or_else(|| {
                    NativeError::InvalidParameter("FLI subframe ul_y overflows i32".into())
                })?;
                let lr_x = ul_x.checked_add(sw).ok_or_else(|| {
                    NativeError::InvalidParameter("FLI subframe lr_x overflows i32".into())
                })?;
                let lr_y = ul_y.checked_add(sh).ok_or_else(|| {
                    NativeError::InvalidParameter("FLI subframe lr_y overflows i32".into())
                })?;
                (ul_x, ul_y, lr_x, lr_y)
            }
            None => (
                self.visible_ul_x,
                self.visible_ul_y,
                self.visible_lr_x,
                self.visible_lr_y,
            ),
        };

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); the coordinates are computed from SDK-reported visible area bounds and the subframe parameters validated by upper layer.
        let result = unsafe {
            (sdk.set_image_area)(
                self.handle,
                ul_x as c_long,
                ul_y as c_long,
                lr_x as c_long,
                lr_y as c_long,
            )
        };
        check_fli_error(result, "set image area")?;

        self.subframe = subframe;
        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.sensor_info.clone()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        Ok(vec![ReadoutMode {
            name: "Normal".to_string(),
            description: "Standard readout mode".to_string(),
            index: 0,
            gain_min: None,
            gain_max: None,
            offset_min: None,
            offset_max: None,
        }])
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), NativeError> {
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // libfli exposes no gain control and no gain bounds to report.
        Err(NativeError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // libfli exposes no offset control and no offset bounds to report.
        Err(NativeError::NotSupported)
    }
}
