//! `NativeDevice` / `NativeCamera` implementations for `QhyCamera`.

use super::*;

#[async_trait]
impl NativeDevice for QhyCamera {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.camera_id
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Qhy
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            return Ok(());
        }

        // Ensure SDK is initialized
        QhySdk::ensure_initialized()?;

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for SDK operations
        let _lock = qhy_mutex().lock().await;

        // Open the camera
        let id_cstring = CString::new(self.camera_id.clone())
            .map_err(|_| NativeError::InvalidDevice("Invalid camera ID".to_string()))?;

        // SAFETY: qhy_mutex held above; id_cstring is a valid NUL-terminated CString that
        // outlives the call (it lives until the end of this function). OpenQHYCCD returns a
        // handle that we null-check immediately below.
        let handle = unsafe { (sdk.open_qhyccd)(id_cstring.as_ptr()) };
        if handle.is_null() {
            return Err(NativeError::InvalidDevice(
                "Failed to open QHY camera".to_string(),
            ));
        }

        // Set single frame mode
        // SAFETY: qhy_mutex held; `handle` is the non-null pointer returned by OpenQHYCCD above;
        // mode=0 (single frame) is a documented constant per qhyccd.h.
        let result = unsafe { (sdk.set_qhyccd_stream_mode)(handle, 0) }; // 0 = single frame
        if result != 0 {
            // SAFETY: qhy_mutex held; handle was successfully opened above. CloseQHYCCD pairs
            // with OpenQHYCCD to release the handle on the error path.
            unsafe { (sdk.close_qhyccd)(handle) };
            self.handle = None;
            self.connected = false;
            return Err(NativeError::SdkError(format!(
                "Failed to set stream mode: {}",
                result
            )));
        }

        // Initialize the camera
        // SAFETY: qhy_mutex held; handle was successfully opened and stream-mode set above.
        let result = unsafe { (sdk.init_qhyccd)(handle) };
        if result != 0 {
            // SAFETY: qhy_mutex held; handle was successfully opened above. CloseQHYCCD pairs
            // with OpenQHYCCD on the error path.
            unsafe { (sdk.close_qhyccd)(handle) };
            self.handle = None;
            self.connected = false;
            return Err(NativeError::SdkError(format!(
                "Failed to init camera: {}",
                result
            )));
        }

        self.handle = Some(handle);

        // Load camera info (mutex is already held)
        if let Err(error) = self.load_camera_info() {
            // SAFETY: qhy_mutex held; handle was successfully opened and initialized above.
            // CloseQHYCCD pairs with OpenQHYCCD on the chip-info error path.
            unsafe { (sdk.close_qhyccd)(handle) };
            self.handle = None;
            self.connected = false;
            return Err(error);
        }

        // Set default settings
        // SAFETY: qhy_mutex held; handle valid (opened + initialized above); 16 is a documented
        // bit-depth value per qhyccd.h.
        // Why the result is captured rather than discarded: load_camera_info()
        // ran *before* this call, so its GetQHYCCDChipInfo `bpp` describes
        // whatever transfer mode the camera powered up in — on a model that
        // defaults to 8-bit it would have us publish a 255 ceiling for frames we
        // then download as 16-bit. Track what we actually negotiated.
        let bits_mode_result = unsafe { (sdk.set_qhyccd_bits_mode)(handle, 16) };
        self.output_container_bits = if bits_mode_result == 0 {
            16
        } else {
            tracing::warn!(
                "QHY camera {}: SetQHYCCDBitsMode(16) failed (error {}); keeping the SDK-reported {}-bit container",
                self.camera_id,
                bits_mode_result,
                self.bits_per_pixel
            );
            self.bits_per_pixel
        };
        // The ADC precision and the alignment of those bits inside the container
        // are separate, optional queries. Both are gated on
        // IsQHYCCDControlAvailable (0 == available) exactly as the SDK manual
        // prescribes; when unavailable we keep the documented default of high
        // alignment with unknown precision, which yields the container ceiling.
        // See [`container_max_adu`].
        self.actual_output_bits = self.probe_output_data_actual_bits(sdk, handle);
        self.output_high_aligned = self.probe_output_data_high_aligned(sdk, handle);
        // Assert the default geometry the driver then reports (`current_bin = 1`,
        // full-frame ROI). A camera that refuses either call keeps whatever geometry
        // InitQHYCCD left it in, so log the SDK code rather than dropping it: the
        // frame itself stays self-consistent (download_image reads width/height/bpp
        // back from GetQHYCCDSingleFrame), but the reported binning would not be.
        // SAFETY: qhy_mutex held; handle valid; (1,1) is the documented identity binning.
        let bin_result = unsafe { (sdk.set_qhyccd_binmode)(handle, 1, 1) };
        if bin_result != 0 {
            tracing::warn!(
                "QHY camera {}: SetQHYCCDBinMode(1, 1) failed (error {}); the camera keeps its post-InitQHYCCD binning while this driver reports 1x1",
                self.camera_id,
                bin_result
            );
        }
        // SAFETY: qhy_mutex held; handle valid; (0,0,image_width,image_height) is the full sensor
        // window that the SDK just reported via GetQHYCCDChipInfo in load_camera_info().
        let roi_result = unsafe {
            (sdk.set_qhyccd_resolution)(handle, 0, 0, self.image_width, self.image_height)
        };
        if roi_result != 0 {
            tracing::warn!(
                "QHY camera {}: SetQHYCCDResolution(0, 0, {}, {}) failed (error {}); the full-frame ROI was not applied",
                self.camera_id,
                self.image_width,
                self.image_height,
                roi_result
            );
        }

        self.connected = true;
        tracing::info!("Connected to QHY camera: {}", self.camera_id);
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        // Acquire mutex first to avoid Send issues with raw pointer
        let _lock = qhy_mutex().lock().await;
        if let Some(handle) = self.handle.take() {
            if let Some(sdk) = QhySdk::get() {
                // SAFETY: qhy_mutex held above; `handle` was successfully opened during
                // connect() and stored in self.handle (None case skipped via if-let).
                // CloseQHYCCD pairs with OpenQHYCCD.
                let result = unsafe { (sdk.close_qhyccd)(handle) };
                check_qhy_error(result, "CloseQHYCCD")?;
            }
        }
        self.connected = false;
        tracing::info!("Disconnected from QHY camera: {}", self.camera_id);
        Ok(())
    }
}

#[async_trait]
impl NativeCamera for QhyCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities {
            can_cool: self.has_cooler,
            can_set_gain: true,
            can_set_offset: true,
            can_set_binning: true,
            can_subframe: true,
            has_shutter: false, // Would need to check MECHANICAL_SHUTTER control
            has_guider_port: self.has_st4_port,
            max_bin_x: 4,
            max_bin_y: 4,
            supports_readout_modes: true, // QHY supports readout modes
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // Use async versions with mutex protection
        let temp = self
            .get_control_async(QhyControl::CONTROL_CURTEMP)
            .await
            .ok();
        let cooler_power = if self.has_cooler {
            self.get_control_async(QhyControl::CONTROL_CURPWM)
                .await
                .ok()
        } else {
            None
        };

        Ok(CameraStatus {
            state: CameraState::Idle, // QHY doesn't have a simple exposure status query
            sensor_temp: temp,
            // Why: tracked locally because QHY SDK has no register to read
            // back cooler enable / target setpoint.
            target_temp: self.cooler_target_c,
            cooler_on: self.cooler_on,
            cooler_power,
            gain: self.current_gain,
            offset: self.current_offset,
            bin_x: self.current_bin,
            bin_y: self.current_bin,
            exposure_remaining: None,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // Set exposure time (in microseconds) - use sync version since we hold mutex
        let exposure_us = params.duration_secs * 1_000_000.0;
        self.set_control(QhyControl::CONTROL_EXPOSURE, exposure_us)?;

        // Track exposure time for timeout handling
        self.current_exposure_time = params.duration_secs;

        // Set gain
        if let Some(gain) = params.gain {
            self.set_control(QhyControl::CONTROL_GAIN, gain as f64)?;
            self.current_gain = gain;
        }

        // Set offset if provided
        if let Some(offset) = params.offset {
            self.set_control(QhyControl::CONTROL_OFFSET, offset as f64)?;
            self.current_offset = offset;
        }

        // Start exposure
        // SAFETY: qhy_mutex held above; handle was validated via Option::ok_or; self.connected
        // was true (checked at entry). ExpQHYCCDSingleFrame takes only the handle.
        let result = unsafe { (sdk.exp_single_frame)(handle) };
        // ExpQHYCCDSingleFrame does NOT return QHYCCD_SUCCESS(0) on every camera:
        // legacy CCD / A-series bodies (QHY9, QHY8L, QHY22, QHY23, QHY16200A)
        // return QHYCCD_READ_DIRECTLY (0x2001) or QHYCCD_DELAY_200MS (0x2000) to
        // signal their readout timing — these are NON-fatal mode signals, not
        // errors. Only QHYCCD_ERROR (0xFFFFFFFF) is a real failure. The reference
        // driver checks exactly this (qhy_ccd.cpp: `if (ExpQHYCCDSingleFrame(...)
        // == QHYCCD_ERROR)`); routing this through the generic error map instead
        // aborted every exposure on those cameras with a bogus "Direct read
        // failed". Match the reference: fail only on QHYCCD_ERROR.
        if result == 0xFFFF_FFFF {
            return Err(NativeError::SdkError(
                "ExpQHYCCDSingleFrame: General error - camera may be in use by another application or disconnected".to_string(),
            ));
        }
        if result == 0x2000 || result == 0x2001 {
            tracing::debug!(
                "QHY ExpQHYCCDSingleFrame returned readout-timing signal 0x{:X} (legacy CCD, non-fatal)",
                result
            );
        }

        tracing::info!("Started {}s exposure on QHY camera", params.duration_secs);
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // SAFETY: qhy_mutex held above; handle was validated via Option::ok_or; self.connected
        // was true (checked at entry). CancelQHYCCDExposingAndReadout takes only the handle.
        let result = unsafe { (sdk.cancel_qhyccd_exposing_and_readout)(handle) };
        check_qhy_error(result, "CancelExposure")?;

        tracing::info!("Aborted exposure");
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        // QHY SDK uses blocking exposure with GetQHYCCDSingleFrame
        // This is called after the exposure completes
        Ok(true)
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // Get required buffer size.
        // SAFETY: qhy_mutex held above; handle was validated via Option::ok_or; self.connected
        // was true. GetQHYCCDMemLength returns c_uint by value.
        // Why: c_uint (u32) -> usize is widening on every Tier 1 target (32- or 64-bit usize
        // each holds u32::MAX), so this is always safe.
        let buffer_len = unsafe { (sdk.get_qhyccd_memory_length)(handle) } as usize;
        // Use pooled buffer for efficient memory reuse
        let mut pooled_buffer = global_u8_pool().get_buffer(buffer_len);
        pooled_buffer.resize(buffer_len);

        let mut width: c_uint = 0;
        let mut height: c_uint = 0;
        let mut bpp: c_uint = 0;
        let mut channels: c_uint = 0;

        // SAFETY: qhy_mutex held; handle valid; four out-pointers are valid stack pointers;
        // pooled_buffer was just resized to buffer_len (the SDK's reported memory length above),
        // so the SDK can safely write up to buffer_len bytes through as_mut_ptr().
        let result = unsafe {
            (sdk.get_qhyccd_single_frame)(
                handle,
                &mut width,
                &mut height,
                &mut bpp,
                &mut channels,
                pooled_buffer.as_mut_ptr(),
            )
        };
        check_qhy_error(result, "GetQHYCCDSingleFrame")?;

        // Trim buffer to actual size.
        // Why: width/height/bpp/channels are c_uint (u32). On a hypothetical 32K x 32K
        // 16bpp 3-channel sensor we'd hit ~6.4 GB, overflowing u32 silently. Promote to
        // u64 before multiplying and surface overflow as an SdkError. This also rejects
        // pathological bpp=0 returns (channels.max(1) preserves the original guard).
        let width_u64 = u64::from(width);
        let height_u64 = u64::from(height);
        let bpp_bytes_u64 = u64::from(bpp / 8);
        let channels_u64 = u64::from(channels.max(1));
        let actual_size_u64 = width_u64
            .checked_mul(height_u64)
            .and_then(|p| p.checked_mul(bpp_bytes_u64))
            .and_then(|p| p.checked_mul(channels_u64))
            .ok_or_else(|| {
                NativeError::SdkError(format!(
                    "QHY frame size overflow: {}x{} bpp={} channels={}",
                    width, height, bpp, channels
                ))
            })?;
        let actual_size = usize::try_from(actual_size_u64).map_err(|_| {
            NativeError::SdkError(format!(
                "QHY frame size {} does not fit in usize",
                actual_size_u64
            ))
        })?;
        if actual_size > pooled_buffer.len() {
            return Err(NativeError::SdkError(format!(
                "QHY reported frame larger than allocated buffer: {} > {}",
                actual_size,
                pooled_buffer.len()
            )));
        }
        pooled_buffer.truncate(actual_size);

        // Why: GetQHYCCDSingleFrame writes raw sensor bytes into the SDK-owned byte buffer
        // we provided. QHY documents the on-wire framing as little-endian regardless of host
        // architecture, and the pooled buffer is *not* guaranteed to be u16-aligned (we
        // hand the SDK a u8 buffer from a pool). We decode each pixel via from_le_bytes so
        // alignment and host endianness are both irrelevant — only SDK length matters,
        // and we already truncated the buffer to actual_size = width*height*(bpp/8)*channels.
        let data: Vec<u16> = if bpp == 16 {
            pooled_buffer
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
                .collect()
        } else {
            // 8-bit to 16-bit scaling
            pooled_buffer.iter().map(|&x| (x as u16) * 256).collect()
        };

        // Get temperature and vendor features while still holding mutex
        let temperature = self.get_control(QhyControl::CONTROL_CURTEMP).ok();
        let vendor_data = {
            let mut features = VendorFeatures::default();
            if let Ok(usb_bw) = self.get_control(QhyControl::CONTROL_USBTRAFFIC) {
                features.usb_bandwidth = Some(usb_bw);
            }
            if let Ok(humidity) = self.get_control(QhyControl::CAM_HUMIDITY) {
                if (0.0..=100.0).contains(&humidity) {
                    features.sensor_chamber_humidity = Some(humidity);
                }
            }
            if let Ok(pressure) = self.get_control(QhyControl::CAM_PRESSURE) {
                if pressure > 0.0 {
                    features.sensor_chamber_pressure = Some(pressure);
                }
            }
            features
        };

        tracing::info!(
            "Downloaded {}x{} image ({} bytes, {} bpp)",
            width,
            height,
            actual_size,
            bpp
        );

        Ok(ImageData {
            width,
            height,
            data,
            bits_per_pixel: bpp,
            bayer_pattern: self.bayer_pattern,
            metadata: ImageMetadata {
                exposure_time: 0.0, // Need to track this
                gain: self.current_gain,
                offset: self.current_offset,
                bin_x: self.current_bin,
                bin_y: self.current_bin,
                temperature,
                timestamp: chrono::Utc::now(),
                subframe: None, // Need to track this
                readout_mode: None,
                vendor_data,
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

        if !self.has_cooler {
            return Err(NativeError::NotSupported);
        }

        // Use async versions with mutex protection
        let committed_target = if enabled {
            // CONTROL_COOLER carries the setpoint *and* engages the TEC, so a
            // target is genuinely required on this vendor. Fall back to the
            // last setpoint we commanded rather than inventing a temperature.
            let target = target_temp.or(self.cooler_target_c).ok_or_else(|| {
                NativeError::InvalidParameter(format!(
                    "QHY cooler on {} needs a target temperature: CONTROL_COOLER is \
                     the setpoint and no previous setpoint is known for this camera",
                    self.device_id
                ))
            })?;
            if let Some((min_temp, max_temp)) = crate::quirks::get_cooler_range(&self.device_id) {
                if target < min_temp || target > max_temp {
                    return Err(NativeError::InvalidParameter(format!(
                        "QHY cooler target {target}C is outside the supported range {min_temp}C..={max_temp}C for {}",
                        self.device_id
                    )));
                }
            }
            self.set_control_async(QhyControl::CONTROL_MANULPWM, 0.0)
                .await?;
            self.set_control_async(QhyControl::CONTROL_COOLER, target)
                .await?;
            Some(target)
        } else {
            // Switching off needs no setpoint: park the PWM registers only.
            self.set_control_async(QhyControl::CONTROL_MANULPWM, 0.0)
                .await?;
            self.set_control_async(QhyControl::CONTROL_CURPWM, 0.0)
                .await?;
            None
        };

        // Why: only commit tracked state after SDK calls succeed so a failed
        // setpoint write leaves the previous state intact (no silent fallback).
        // QHY SDK has no register to read cooler enable back — CONTROL_COOLER
        // is the target setpoint, not an on/off flag — so we mirror locally.
        self.cooler_on = enabled;
        self.cooler_target_c = committed_target;

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
        self.get_control_async(QhyControl::CONTROL_CURTEMP).await
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        if !self.has_cooler {
            return Err(NativeError::NotSupported);
        }
        self.get_control_async(QhyControl::CONTROL_CURPWM).await
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        self.set_control_async(QhyControl::CONTROL_GAIN, gain as f64)
            .await?;
        self.current_gain = gain;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        // Why: QHY gain is a small non-negative integer (0..=~1000 across all current
        // models; range-clamped by SDK). f64 -> i32 with saturation is well-defined for
        // finite values, and only the integer portion is meaningful for a gain step.
        Ok(self.get_control_async(QhyControl::CONTROL_GAIN).await? as i32)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), NativeError> {
        self.set_control_async(QhyControl::CONTROL_OFFSET, offset as f64)
            .await?;
        self.current_offset = offset;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        // Why: QHY offset is a small non-negative integer (0..=~1000) clamped by the SDK.
        // f64 -> i32 with saturation is well-defined for finite values in this range.
        Ok(self.get_control_async(QhyControl::CONTROL_OFFSET).await? as i32)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // Why: bin must be >= 1 (you cannot bin by zero or a negative factor). We use
        // try_from to surface a caller error rather than silently wrapping a negative i32
        // into a giant c_uint that would underflow image_width/bin on the next line.
        let bin_max = bin_x.max(bin_y);
        if bin_max < 1 {
            return Err(NativeError::InvalidParameter(format!(
                "QHY binning must be >= 1, got bin_x={} bin_y={}",
                bin_x, bin_y
            )));
        }
        let bin = c_uint::try_from(bin_max).map_err(|_| {
            NativeError::InvalidParameter(format!(
                "QHY binning does not fit in c_uint: {}",
                bin_max
            ))
        })?;
        // SAFETY: qhy_mutex held above; handle was validated via Option::ok_or; self.connected
        // was true. bin is pass-by-value c_uint and the SDK validates the value.
        let result = unsafe { (sdk.set_qhyccd_binmode)(handle, bin, bin) };
        check_qhy_error(result, "SetQHYCCDBinMode")?;

        // Update resolution for new binning
        let new_width = self.image_width / bin;
        let new_height = self.image_height / bin;
        // SAFETY: qhy_mutex held; handle valid; new_width/new_height are derived from
        // self.image_width/height (loaded by GetQHYCCDChipInfo at connect time) divided by the
        // just-applied bin factor — both ≤ original sensor dimensions.
        let result = unsafe { (sdk.set_qhyccd_resolution)(handle, 0, 0, new_width, new_height) };
        check_qhy_error(result, "SetQHYCCDResolution")?;

        // Why: bin was already validated >= 1 above; c_uint -> i32 only fails when value
        // exceeds i32::MAX. A bin > 2^31 is meaningless physically, but propagate the error
        // rather than wrap.
        self.current_bin = i32::try_from(bin).map_err(|_| {
            NativeError::InvalidParameter(format!("QHY bin {} does not fit in i32", bin))
        })?;
        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        Ok((self.current_bin, self.current_bin))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        let (x, y, width, height) = if let Some(sf) = subframe {
            (sf.start_x, sf.start_y, sf.width, sf.height)
        } else {
            // Why: current_bin is i32 validated >= 1 inside set_binning(). A corrupt
            // negative value would wrap to a giant u32 here and crash the division below
            // with image_width/0. Fail loudly instead.
            let bin_u32 = u32::try_from(self.current_bin.max(1)).map_err(|_| {
                NativeError::InvalidParameter(format!(
                    "QHY current_bin not representable as u32: {}",
                    self.current_bin
                ))
            })?;
            (
                0,
                0,
                self.image_width / bin_u32,
                self.image_height / bin_u32,
            )
        };

        // SAFETY: qhy_mutex held above; handle was validated via Option::ok_or; self.connected
        // was true. x/y/width/height come from the user-supplied SubFrame or from sensor
        // dimensions / current bin — both branches produce in-sensor coordinates the SDK clips.
        let result = unsafe { (sdk.set_qhyccd_resolution)(handle, x, y, width, height) };
        check_qhy_error(result, "SetQHYCCDResolution")
    }

    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo {
            width: self.image_width,
            height: self.image_height,
            pixel_size_x: self.pixel_width,
            pixel_size_y: self.pixel_height,
            // `max_adu` is the pixel-container full scale and `bit_depth` the
            // ADC precision — two different quantities that QHY exposes through
            // two different SDK queries. See [`container_max_adu`] and the
            // `SensorInfo::max_adu` contract. `(1 << bits_per_pixel) - 1` used
            // both the wrong query (GetQHYCCDChipInfo's container `bpp`) and a
            // value read before connect() forced 16-bit transfer mode.
            max_adu: container_max_adu(
                self.output_container_bits,
                self.actual_output_bits,
                self.output_high_aligned,
            ),
            bit_depth: self.actual_output_bits.unwrap_or(self.bits_per_pixel),
            color: self.is_color,
            bayer_pattern: self.bayer_pattern,
        }
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        let mut num_modes: c_uint = 0;
        // SAFETY: qhy_mutex held above; handle was validated via Option::ok_or; self.connected
        // was true; &mut num_modes is a valid stack pointer to c_uint.
        let result = unsafe { (sdk.get_qhyccd_number_of_read_modes)(handle, &mut num_modes) };
        check_qhy_error(result, "GetQHYCCDNumberOfReadModes")?;

        let mut modes = Vec::new();
        for i in 0..num_modes {
            let mut name_buf = [0 as c_char; 256];
            // SAFETY: qhy_mutex held; handle valid; `i` is in `0..num_modes` reported by the
            // SDK above so it is a valid read-mode index; name_buf is a 256-byte stack array.
            let result =
                unsafe { (sdk.get_qhyccd_read_mode_name)(handle, i, name_buf.as_mut_ptr()) };
            if result == 0 {
                // SAFETY: name_buf is 256 bytes; SDK guarantees NUL-termination on success
                // (result == 0).
                let name = unsafe { CStr::from_ptr(name_buf.as_ptr()) }
                    .to_string_lossy()
                    .to_string();
                modes.push(ReadoutMode {
                    // Why: `i` ranges over `0..num_modes` where num_modes is a c_uint
                    // populated by GetQHYCCDNumberOfReadModes. QHY cameras advertise a
                    // small handful of readout modes (<= 8 across all known SKUs), so
                    // i fits trivially in i32 and `as i32` is well-defined.
                    index: i as i32,
                    name,
                    description: "QHY Readout Mode".to_string(),
                    gain_min: None,
                    gain_max: None,
                    offset_min: None,
                    offset_max: None,
                });
            }
        }

        Ok(modes)
    }

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // Read the current read mode first so we can restore it if the re-init
        // below fails, leaving the camera in its prior working state.
        let mut prev_mode: c_uint = 0;
        // SAFETY: qhy_mutex is held (acquired above) so no other task is inside the
        // QHY SDK. `handle` was opened by OpenQHYCCD during connect() and is still
        // open: it is only ever taken/closed by disconnect(), which needs both the
        // same mutex and the `&mut self` this method already holds exclusively.
        // `&mut prev_mode` is a live stack local of exactly the c_uint the SDK writes.
        let prev_mode_result = unsafe { (sdk.get_qhyccd_read_mode)(handle, &mut prev_mode) };
        if prev_mode_result != 0 {
            // The rollback target below is then read mode 0 (the SDK's power-on
            // default), not a mode we observed. Say so rather than let a silent 0
            // masquerade as a reading.
            tracing::warn!(
                "QHY camera {}: GetQHYCCDReadMode failed (error {}); a rollback would restore read mode 0 (SDK default), not the camera's current mode",
                self.camera_id,
                prev_mode_result
            );
        }

        // SAFETY: qhy_mutex held above; handle was validated via Option::ok_or; self.connected
        // was true. mode.index originated from a ReadoutMode this driver produced in
        // get_readout_modes() above, so it is a valid SDK read-mode index.
        let result = unsafe { (sdk.set_qhyccd_read_mode)(handle, mode.index as c_uint) };
        check_qhy_error(result, "SetQHYCCDReadMode")?;

        // A read-mode change only takes effect after RE-INITIALIZING the camera,
        // and different read modes can expose different sensor geometry, gain and
        // full-well. Without the re-init + geometry refresh, SetQHYCCDReadMode
        // silently no-ops (frames keep read-mode-0 characteristics) or leaves the
        // SDK geometry inconsistent with our cached dimensions → misframed frames.
        // The reference driver does SetReadMode -> InitQHYCCD -> re-read chip info
        // -> reset ROI, reverting on failure (qhy_ccd.cpp:2069-2088).
        // SAFETY: qhy_mutex held; handle valid. InitQHYCCD takes only the handle.
        let init_result = unsafe { (sdk.init_qhyccd)(handle) };
        if check_qhy_error(init_result, "InitQHYCCD (after read-mode change)").is_err() {
            // Restore the previous read mode + re-init so the camera stays usable, and
            // report what the rollback actually achieved: a rollback that itself fails
            // leaves the camera un-initialized in an unknown read mode, and claiming
            // "reverted" would send the caller straight back into a capture.
            let mut rollback_failures: Vec<String> = Vec::new();
            // SAFETY: qhy_mutex held; handle valid; prev_mode is the mode read above.
            let restore_mode = unsafe { (sdk.set_qhyccd_read_mode)(handle, prev_mode) };
            if restore_mode != 0 {
                rollback_failures.push(format!(
                    "SetQHYCCDReadMode({}) error {}",
                    prev_mode, restore_mode
                ));
            }
            // SAFETY: same held mutex and same still-open handle as the restore call
            // immediately above; InitQHYCCD takes only that handle, no pointers.
            let restore_init = unsafe { (sdk.init_qhyccd)(handle) };
            if restore_init != 0 {
                rollback_failures.push(format!("InitQHYCCD error {}", restore_init));
            }
            if let Err(e) = self.load_camera_info() {
                rollback_failures.push(format!("chip-info refresh failed: {}", e));
            }
            // SAFETY: qhy_mutex held; handle valid; full-frame ROI from refreshed dims.
            let restore_roi = unsafe {
                (sdk.set_qhyccd_resolution)(handle, 0, 0, self.image_width, self.image_height)
            };
            if restore_roi != 0 {
                rollback_failures.push(format!("SetQHYCCDResolution error {}", restore_roi));
            }

            if rollback_failures.is_empty() {
                return Err(NativeError::SdkError(format!(
                    "Failed to initialize QHY camera after switching to read mode {}; reverted to read mode {}",
                    mode.index, prev_mode
                )));
            }
            tracing::error!(
                "QHY camera {}: rollback to read mode {} failed after a failed read-mode switch: {}",
                self.camera_id,
                prev_mode,
                rollback_failures.join("; ")
            );
            return Err(NativeError::SdkError(format!(
                "Failed to initialize QHY camera after switching to read mode {}, and the rollback to read mode {} also failed ({}); the camera is left un-initialized and must be reconnected",
                mode.index,
                prev_mode,
                rollback_failures.join("; ")
            )));
        }

        // Refresh cached geometry for the new read mode and reset the full-frame ROI.
        self.load_camera_info()?;
        // SAFETY: qhy_mutex held; handle valid; dimensions just refreshed by load_camera_info().
        let res_result = unsafe {
            (sdk.set_qhyccd_resolution)(handle, 0, 0, self.image_width, self.image_height)
        };
        check_qhy_error(res_result, "SetQHYCCDResolution (after read-mode change)")
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        let mut features = VendorFeatures::default();

        // QHY-specific features - use async versions with mutex protection
        if let Ok(usb_bw) = self.get_control_async(QhyControl::CONTROL_USBTRAFFIC).await {
            features.usb_bandwidth = Some(usb_bw);
        }

        // QHY-specific: Sensor chamber humidity and pressure (if available)
        if let Ok(humidity) = self.get_control_async(QhyControl::CAM_HUMIDITY).await {
            if (0.0..=100.0).contains(&humidity) {
                features.sensor_chamber_humidity = Some(humidity);
            }
        }

        if let Ok(pressure) = self.get_control_async(QhyControl::CAM_PRESSURE).await {
            if pressure > 0.0 {
                features.sensor_chamber_pressure = Some(pressure);
            }
        }

        Ok(features)
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let (min, max, _step) = self
            .get_control_range_async(QhyControl::CONTROL_GAIN)
            .await?;
        // Why: gain min/max are small non-negative integers in practice (<= ~1000),
        // returned as f64 by QHY's range API. f64 -> i32 with saturation is sound here.
        Ok((min as i32, max as i32))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let (min, max, _step) = self
            .get_control_range_async(QhyControl::CONTROL_OFFSET)
            .await?;
        // Why: offset min/max are small non-negative integers (<= ~1000) returned as
        // f64 by QHY's range API. f64 -> i32 with saturation is sound here.
        Ok((min as i32, max as i32))
    }

    /// Surface the SDK-advertised recommended settings.
    ///
    /// QHY exposes manufacturer-recommended values through two dedicated
    /// control IDs:
    /// - `DefaultGain` (control 53): per-camera recommended unity-gain value.
    /// - `DefaultOffset` (control 54): per-camera recommended offset.
    ///
    /// These are only present on cameras whose firmware publishes them
    /// (modern QHY CMOS cameras like QHY183/268/600/MiniGuider series do; older
    /// CCD cameras do not). We probe with `IsQHYCCDControlAvailable` and
    /// honestly return `None` when the camera doesn't expose them.
    ///
    /// QHY does NOT expose the HCG transition point through the SDK — it's
    /// documented per-camera in the manual.
    async fn get_recommended_settings(
        &self,
    ) -> Result<crate::camera::CameraRecommendedSettings, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        let mut out = crate::camera::CameraRecommendedSettings::default();
        let mut notes: Vec<String> = Vec::new();

        // QHY returns 0 (QHYCCD_SUCCESS) from IsQHYCCDControlAvailable when the
        // control is present. Anything else means "not available" — that is an
        // honest "no recommendation", not an error.

        // DefaultGain (control 53)
        // SAFETY: qhy_mutex held; handle validated; IsQHYCCDControlAvailable takes (handle, c_int).
        let default_gain_available =
            unsafe { (sdk.is_qhyccd_control_available)(handle, QhyControl::DefaultGain as c_int) };
        if default_gain_available == 0 {
            // SAFETY: qhy_mutex held; handle validated; GetQHYCCDParam returns c_double by value.
            let val = unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::DefaultGain as c_int) };
            // QHY returns a sentinel (0xFFFFFFFF as f64) on failure for some
            // firmware versions. Reject obviously bogus values.
            if val.is_finite() && (0.0..10_000.0).contains(&val) {
                let gain = val as i32;
                out.unity_gain = Some(gain);
                notes.push(format!("QHY DefaultGain control reports {}", gain));
            } else {
                tracing::warn!("QHY: DefaultGain returned out-of-range value {}", val);
            }
        }

        // DefaultOffset (control 54)
        // SAFETY: qhy_mutex held; handle validated; same FFI shape as above.
        let default_offset_available = unsafe {
            (sdk.is_qhyccd_control_available)(handle, QhyControl::DefaultOffset as c_int)
        };
        if default_offset_available == 0 {
            // SAFETY: qhy_mutex held; handle validated; GetQHYCCDParam returns c_double by value.
            let val = unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::DefaultOffset as c_int) };
            if val.is_finite() && (0.0..10_000.0).contains(&val) {
                let off = val as i32;
                out.default_offset = Some(off);
                notes.push(format!("QHY DefaultOffset control reports {}", off));
            } else {
                tracing::warn!("QHY: DefaultOffset returned out-of-range value {}", val);
            }
        }

        out.notes = notes.join("; ");
        Ok(out)
    }
}
