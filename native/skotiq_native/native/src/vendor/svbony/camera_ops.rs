//! `CameraDriver` implementation for `SvbonyCamera`.

use super::*;

#[async_trait]
impl CameraDriver for SvbonyCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;

        // Get sensor temperature and cooler power using async methods that take the SDK lock
        let sensor_temp = if self.core.capabilities.can_cool {
            self.get_control_value_async(SvbControlType::CurrentTemperature)
                .await
                .map(|v| v as f64 / 10.0)
                .ok()
        } else {
            None
        };

        let cooler_power = if self.core.capabilities.can_cool && self.core.cooler.enabled {
            self.get_control_value_async(SvbControlType::CoolerPower)
                .await
                .map(|v| v as f64)
                .ok()
        } else {
            None
        };

        let exposure_remaining = if self.core.state == CameraState::Exposing {
            self.core.exposure_started_at.map(|start| {
                let elapsed = start.elapsed().as_secs_f64();
                (self.core.exposure_duration - elapsed).max(0.0)
            })
        } else {
            None
        };
        let gain = self.get_gain().await?;
        let offset = self.get_offset().await?;

        Ok(CameraStatus {
            state: self.core.state,
            sensor_temp,
            cooler_power,
            target_temp: if self.core.capabilities.can_cool {
                Some(self.core.cooler.target_c)
            } else {
                None
            },
            cooler_on: self.core.cooler.enabled,
            gain,
            offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let sdk = SvbonySdk::installed()?;

        // Set gain if provided (these methods take the SDK lock internally)
        if let Some(gain) = params.gain {
            self.set_gain(gain).await?;
        }

        // Set offset if provided
        if let Some(offset) = params.offset {
            self.set_offset(offset).await?;
        }

        // Set binning
        self.set_binning(params.bin_x, params.bin_y).await?;

        // Set subframe/ROI
        self.set_subframe(params.subframe.clone()).await?;

        // Acquire the SDK lock for exposure start operations
        let sdk = sdk.lock().await;

        // Set exposure time (in microseconds).
        // Why: max exposure is configured well below 1 hour (3.6e9 us); f64 -> i64 with
        // saturation handles negative or NaN duration as 0 / i64::MAX respectively, both
        // of which the SDK rejects safely. Real astrophotography exposures cap at ~hours.
        let exposure_us = (params.duration_secs * 1_000_000.0) as i64;
        self.set_control_value(&sdk, SvbControlType::Exposure, exposure_us)?;

        // Start video capture mode (SVBony uses video mode for exposures)
        // SAFETY: `self.camera_id` validated by SVBOpenCamera in connect(); SVBStartVideoCapture takes a single c_int and is the contractual entry point to begin capture per SVBCameraSDK.h.
        let result = unsafe { (sdk.start_video_capture)(self.camera_id) };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("start exposure"));
        }

        self.core.exposure_started_at = Some(std::time::Instant::now());
        self.core.exposure_duration = params.duration_secs;
        self.core.state = CameraState::Exposing;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // Acquire the SDK lock for SDK operations
        let sdk = SvbonySdk::lock().await?;

        // SAFETY: `self.camera_id` validated by SVBOpenCamera in connect(); SVBStopVideoCapture takes a single c_int and is idempotent.
        let result = unsafe { (sdk.stop_video_capture)(self.camera_id) };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("abort exposure"));
        }

        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.core.require_connected()?;

        match self.core.state {
            CameraState::Idle => Ok(true),
            CameraState::Exposing => {
                if let Some(start) = self.core.exposure_started_at {
                    let elapsed = start.elapsed().as_secs_f64();
                    Ok(elapsed >= self.core.exposure_duration)
                } else {
                    Ok(false)
                }
            }
            _ => Ok(false),
        }
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.core.require_connected()?;

        // Acquire the SDK lock for all SDK operations in this method
        let sdk = SvbonySdk::lock().await?;

        // Get current ROI
        let mut start_x: c_int = 0;
        let mut start_y: c_int = 0;
        let mut width: c_int = 0;
        let mut height: c_int = 0;
        let mut bin: c_int = 0;
        // SAFETY: `self.camera_id` validated; all five `&mut` out-pointers reference distinct c_int stack locals, matching SVBGetROIFormat's signature.
        let result = unsafe {
            (sdk.get_roi_format)(
                self.camera_id,
                &mut start_x,
                &mut start_y,
                &mut width,
                &mut height,
                &mut bin,
            )
        };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("get ROI format"));
        }

        // Confirm the current wire format. If the SDK cannot answer, retain the
        // format that connect successfully negotiated.
        let mut image_type = self.image_type as c_int;
        // SAFETY: `self.camera_id` is connected and
        // `&mut image_type` is a valid c_int out-pointer.
        let image_type_result =
            unsafe { (sdk.get_output_image_type)(self.camera_id, &mut image_type) };
        if SvbError::from_i32(image_type_result) == SvbError::Success {
            self.image_type = match image_type {
                value if value == SvbImgType::Raw8 as c_int => SvbImgType::Raw8,
                value if value == SvbImgType::Raw16 as c_int => SvbImgType::Raw16,
                value => {
                    return Err(DriverError::SdkError(format!(
                        "SVBony reported unsupported output image type: {}",
                        value
                    )));
                }
            };
        } else {
            tracing::warn!(
                "Could not confirm SVBony output image type; using negotiated {:?}",
                self.image_type
            );
        }

        // Size and decode according to the actual negotiated wire format.
        let bytes_per_pixel = match self.image_type {
            SvbImgType::Raw8 => 1,
            SvbImgType::Raw16 => 2,
        };
        let buffer_size = calculate_buffer_size_i32(width, height, bytes_per_pixel)?;

        // Resize buffer if needed
        if self.image_buffer.len() < buffer_size {
            self.image_buffer.resize(buffer_size, 0);
        }

        // Get image data with timeout
        self.core.state = CameraState::Downloading;
        // SAFETY: `self.camera_id` validated; `self.image_buffer.as_mut_ptr()` points to at least `buffer_size` bytes (resized above via `image_buffer.resize(buffer_size, 0)`), which is what we pass as the third argument so SVBGetVideoData will not write past the allocation. The 5000 ms timeout is documented as block-with-deadline behavior in SVBCameraSDK.h.
        let result = unsafe {
            (sdk.get_video_data)(
                self.camera_id,
                self.image_buffer.as_mut_ptr(),
                buffer_size as c_long,
                5000, // 5 second timeout
            )
        };

        if SvbError::from_i32(result) != SvbError::Success {
            self.core.state = CameraState::Error;
            return Err(SvbError::from_i32(result).to_native_error("download image"));
        }

        // Stop video capture
        // SAFETY: `self.camera_id` valid; SVBStopVideoCapture is idempotent and takes a single c_int.
        let _ = unsafe { (sdk.stop_video_capture)(self.camera_id) };

        // Convert the negotiated wire format to the pipeline's u16 pixels.
        // RAW8 samples keep their own value here (no scaling to 16 bits).
        let data = unpack_samples(
            &self.image_buffer[..buffer_size],
            match self.image_type {
                SvbImgType::Raw8 => SampleLayout::U8Unscaled,
                SvbImgType::Raw16 => SampleLayout::U16Little,
            },
        );

        // Get temperature for metadata (while we hold the SDK lock)
        let temperature = if self.core.capabilities.can_cool {
            self.get_control_value(&sdk, SvbControlType::CurrentTemperature)
                .map(|v| v as f64 / 10.0)
                .ok()
        } else {
            None
        };
        let gain =
            svb_control_value_to_i32(self.get_control_value(&sdk, SvbControlType::Gain)?, "gain")?;
        let offset = svb_control_value_to_i32(
            self.get_control_value(&sdk, SvbControlType::BlackLevel)?,
            "offset",
        )?;

        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;

        let width = roi_dimension("SVBony", "width", width)?;
        let height = roi_dimension("SVBony", "height", height)?;
        let bits_per_pixel = match self.image_type {
            SvbImgType::Raw8 => 8,
            SvbImgType::Raw16 => self.core.sensor_info.bit_depth,
        };
        Ok(Frame {
            gain,
            offset,
            temperature,
            ..self.core.frame(
                width,
                height,
                data,
                bits_per_pixel,
                self.core.sensor_info.bayer_pattern,
            )
        }
        .into_image())
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }

        // Use async methods that take the SDK lock
        self.set_control_value_async(SvbControlType::CoolerEnable, if enabled { 1 } else { 0 })
            .await?;
        // Only when the caller named a setpoint, and only while cooling:
        // switching off needs no target temperature.
        if let Some(target) = target_temp.filter(|_| enabled) {
            // SVBony uses temperature * 10.
            // Why: target is f64 Celsius typically in [-50.0, 50.0]; multiplied by 10
            // it fits trivially in i64. f64 -> i64 saturating cast is well-defined for
            // finite values in this range; NaN sentinel would be clamped to 0.
            self.set_control_value_async(SvbControlType::TargetTemperature, (target * 10.0) as i64)
                .await?;
            self.core.cooler.target_c = target;
        }

        self.core.cooler.enabled = enabled;
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }

        // Use async method that takes the SDK lock
        let value = self
            .get_control_value_async(SvbControlType::CurrentTemperature)
            .await?;
        Ok(value as f64 / 10.0)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }

        // Use async method that takes the SDK lock
        let value = self
            .get_control_value_async(SvbControlType::CoolerPower)
            .await?;
        Ok(value as f64)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        // Use async method that takes the SDK lock.
        // Why: i32 -> i64 is widening (sign-extended); always safe.
        self.set_control_value_async(SvbControlType::Gain, gain as i64)
            .await?;
        self.core.gain = gain;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        let value = self.get_control_value_async(SvbControlType::Gain).await?;
        svb_control_value_to_i32(value, "gain")
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        // Use async method that takes the SDK lock.
        // Why: i32 -> i64 is widening (sign-extended); always safe.
        self.set_control_value_async(SvbControlType::BlackLevel, offset as i64)
            .await?;
        self.core.offset = offset;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        let value = self
            .get_control_value_async(SvbControlType::BlackLevel)
            .await?;
        svb_control_value_to_i32(value, "offset")
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // SVBony only supports symmetric binning
        let bin = bin_x.min(bin_y);
        if bin > self.core.capabilities.max_bin_x {
            return Err(DriverError::InvalidParameter(format!(
                "Binning {} exceeds max {}",
                bin, self.core.capabilities.max_bin_x
            )));
        }

        if bin < 1 {
            return Err(DriverError::InvalidParameter(format!(
                "SVBony binning must be >= 1, got bin_x={} bin_y={}",
                bin_x, bin_y
            )));
        }
        let sdk = SvbonySdk::installed()?;

        // Why: sensor_info.width/height are u32 (<= 16k on SVBony hardware); converting
        // to i32 via try_from is the right way to fail closed on any pathological value.
        // bin is already validated > 0.
        let width_i32 = i32::try_from(self.core.sensor_info.width).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony sensor width does not fit in i32: {}",
                self.core.sensor_info.width
            ))
        })?;
        let height_i32 = i32::try_from(self.core.sensor_info.height).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony sensor height does not fit in i32: {}",
                self.core.sensor_info.height
            ))
        })?;
        let width = width_i32 / bin;
        let height = height_i32 / bin;

        // Acquire the SDK lock for SDK operations
        let sdk = sdk.lock().await;

        // SAFETY: `self.camera_id` validated; all six arguments are POD c_int (no out-pointers). `width`/`height` were computed from sensor_info divided by `bin` which is ≥ 1 (bin_x.min(bin_y)) and clamped by capabilities.max_bin_x, so dimensions stay within the sensor.
        let result = unsafe {
            (sdk.set_roi_format)(
                self.camera_id,
                0,
                0,
                width as c_int,
                height as c_int,
                bin as c_int,
            )
        };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("set binning"));
        }

        self.core.bin_x = bin;
        self.core.bin_y = bin;
        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let sdk = SvbonySdk::installed()?;

        // Why: SubFrame coordinates are u32, SDK wants c_int (i32). Surface a too-large
        // u32 as InvalidParameter rather than wrap. current_bin_{x,y} must be > 0; we
        // validated this at set_binning entry but defend here in case caller skipped it.
        let (start_x, start_y, width, height) = match &subframe {
            Some(sf) => (
                c_int::try_from(sf.start_x).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "SVBony subframe start_x exceeds c_int: {}",
                        sf.start_x
                    ))
                })?,
                c_int::try_from(sf.start_y).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "SVBony subframe start_y exceeds c_int: {}",
                        sf.start_y
                    ))
                })?,
                c_int::try_from(sf.width).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "SVBony subframe width exceeds c_int: {}",
                        sf.width
                    ))
                })?,
                c_int::try_from(sf.height).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "SVBony subframe height exceeds c_int: {}",
                        sf.height
                    ))
                })?,
            ),
            None => {
                let bin_x_u32 = u32::try_from(self.core.bin_x.max(1)).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "SVBony current_bin_x not representable as u32: {}",
                        self.core.bin_x
                    ))
                })?;
                let bin_y_u32 = u32::try_from(self.core.bin_y.max(1)).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "SVBony current_bin_y not representable as u32: {}",
                        self.core.bin_y
                    ))
                })?;
                let binned_w = self.core.sensor_info.width / bin_x_u32;
                let binned_h = self.core.sensor_info.height / bin_y_u32;
                let w_ci = c_int::try_from(binned_w).map_err(|_| {
                    DriverError::SdkError(format!(
                        "SVBony binned width does not fit in c_int: {}",
                        binned_w
                    ))
                })?;
                let h_ci = c_int::try_from(binned_h).map_err(|_| {
                    DriverError::SdkError(format!(
                        "SVBony binned height does not fit in c_int: {}",
                        binned_h
                    ))
                })?;
                (0, 0, w_ci, h_ci)
            }
        };

        // Acquire the SDK lock for SDK operations
        let sdk = sdk.lock().await;

        // SAFETY: `self.camera_id` validated; all six arguments are POD c_int (no out-pointers). `start_x/start_y/width/height` come from either the caller-supplied SubFrame (validated by upstream subframe logic) or default to full-sensor dimensions scaled by current binning, so the SDK clamps to sensor bounds.
        let result = unsafe {
            (sdk.set_roi_format)(
                self.camera_id,
                start_x,
                start_y,
                width,
                height,
                self.core.bin_x as c_int,
            )
        };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("set subframe"));
        }

        self.core.subframe = subframe;
        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        // SVBony cameras don't have distinct readout modes
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

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError> {
        // SVBony cameras expose a single fixed readout mode.
        if mode.index == 0 || mode.name.eq_ignore_ascii_case("normal") {
            return Ok(());
        }
        Err(DriverError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;

        // Use async method that takes the SDK lock.
        // Why: gain min/max are small non-negative integers (<= ~720 per SVBony spec)
        // returned as i64 from the control range API. `as i32` saturating truncation is
        // safe in this range.
        let (min, max) = self.get_control_range_async(SvbControlType::Gain).await?;
        Ok((min as i32, max as i32))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;

        // SVBony uses BlackLevel as the offset control (use async method that takes the SDK lock).
        // Why: BlackLevel min/max are small non-negative integers (<= ~512) returned as
        // i64. `as i32` saturating truncation is safe in this range.
        let (min, max) = self
            .get_control_range_async(SvbControlType::BlackLevel)
            .await?;
        Ok((min as i32, max as i32))
    }

    /// Surface the SDK-advertised recommended settings.
    ///
    /// SVBony's `SvbControlCaps` includes a per-control `default_value` field.
    /// For the Gain control this is the value the SDK's auto-exposure logic
    /// starts at — SVBony's per-camera documentation lists this as the
    /// recommended unity-gain starting point. For BlackLevel (offset) it is
    /// the manufacturer-recommended bias value.
    ///
    /// SVBony does not expose an HCG transition through the SDK.
    async fn get_recommended_settings(
        &self,
    ) -> Result<skotiq_device::camera::CameraRecommendedSettings, DriverError> {
        self.core.require_connected()?;

        let mut out = skotiq_device::camera::CameraRecommendedSettings::default();
        let mut notes: Vec<String> = Vec::new();

        match self.get_control_caps_async(SvbControlType::Gain).await {
            Ok((_min, _max, default)) => {
                // i64 -> i32 saturating: SVBony gain caps fit in i32 (<= ~720).
                let gain = default.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                out.unity_gain = Some(gain);
                notes.push(format!("SVBony SDK reports default gain = {}", gain));
            }
            Err(DriverError::NotSupported) => {
                // Camera doesn't expose this control. Honest "no recommendation".
            }
            Err(e) => {
                tracing::warn!("SVBony: failed to query gain control caps: {:?}", e);
            }
        }

        match self
            .get_control_caps_async(SvbControlType::BlackLevel)
            .await
        {
            Ok((_min, _max, default)) => {
                let off = default.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                out.default_offset = Some(off);
                notes.push(format!("SVBony SDK reports default offset = {}", off));
            }
            Err(DriverError::NotSupported) => {
                // Camera doesn't expose offset control.
            }
            Err(e) => {
                tracing::warn!("SVBony: failed to query offset control caps: {:?}", e);
            }
        }

        out.notes = notes.join("; ");
        Ok(out)
    }
}
