//! `CameraDriver` implementation for `SvbonyCamera`.

use super::*;
use std::time::{Duration, Instant};

/// How long one SVBGetVideoData call may hold the SDK lock while a frame is
/// awaited. A second SVBony camera on the same SDK (a guide camera beside the
/// main one) gets the lock between calls.
const FRAME_POLL_MS: c_int = 200;

/// How long after the exposure ends the frame may take to arrive (readout and
/// USB transfer). INDI retries for about 50 s (svbony_base.cpp:255-350).
const READOUT_ALLOWANCE: Duration = Duration::from_secs(30);

/// Wait for a frame left from an exposure that was not read. INDI reads one
/// with a 1 s wait before each exposure (svbony_base.cpp:84-89, 190-193).
const UNREAD_FRAME_WAIT_MS: c_int = 1000;

/// Wait for a frame already in the SDK's buffer before triggering.
const BUFFERED_FRAME_WAIT_MS: c_int = 50;

/// SVBSendSoftTrigger tries, 100 ms apart (svbony_base.cpp:204-220).
const TRIGGER_TRIES: u32 = 3;

/// The frame size the SDK will deliver, under a lock the caller holds.
fn sdk_roi_size(sdk: &SvbonySdk, camera_id: c_int) -> Result<(c_int, c_int), DriverError> {
    let (mut start_x, mut start_y, mut width, mut height, mut bin) = (0, 0, 0, 0, 0);
    // SAFETY: the camera is open; all five out-pointers are distinct c_int stack locals.
    let result = unsafe {
        (sdk.get_roi_format)(
            camera_id,
            &mut start_x,
            &mut start_y,
            &mut width,
            &mut height,
            &mut bin,
        )
    };
    check(result, "read the readout region")?;
    Ok((width, height))
}

impl SvbonyCamera {
    fn buffer_for(&mut self, roi: Roi) -> Result<usize, DriverError> {
        let size =
            calculate_buffer_size_i32(roi.width, roi.height, self.image_type.bytes_per_sample())?;
        if self.image_buffer.len() < size {
            self.image_buffer.resize(size, 0);
        }
        Ok(size)
    }

    /// One SVBGetVideoData call into the frame buffer, under a lock the
    /// caller holds. The buffer must hold `size` bytes.
    fn read_frame(&mut self, sdk: &SvbonySdk, size: usize, wait_ms: c_int) -> SvbError {
        let size = c_long::try_from(size).unwrap_or(c_long::MAX);
        // SAFETY: `image_buffer` holds at least `size` bytes (buffer_for), which
        // is what the SDK is told it may write; the camera is open.
        let result = unsafe {
            (sdk.get_video_data)(
                self.camera_id,
                self.image_buffer.as_mut_ptr(),
                size,
                wait_ms,
            )
        };
        SvbError::from_i32(result)
    }

    /// Read and drop frames left in the SDK's buffer, under a lock the caller
    /// holds, with capture running.
    fn drain_frames(&mut self, sdk: &SvbonySdk, size: usize) {
        let mut wait_ms = if self.unread_frame {
            UNREAD_FRAME_WAIT_MS
        } else {
            BUFFERED_FRAME_WAIT_MS
        };
        let mut dropped = 0;
        while dropped < 4 && self.read_frame(sdk, size, wait_ms) == SvbError::Success {
            dropped += 1;
            wait_ms = BUFFERED_FRAME_WAIT_MS;
        }
        if dropped > 0 {
            tracing::info!(
                "SVBony {}: dropped {} frame(s) left from an earlier exposure",
                self.core.name,
                dropped
            );
        }
        self.unread_frame = false;
    }

    fn send_trigger(&self, sdk: &SvbonySdk) -> Result<(), DriverError> {
        let trigger = sdk.send_soft_trigger.ok_or(DriverError::NotSupported)?;
        let mut last = SvbError::Success;
        for attempt in 0..TRIGGER_TRIES {
            if attempt > 0 {
                std::thread::sleep(Duration::from_millis(100));
            }
            // SAFETY: the camera is open, in soft-trigger mode and capturing.
            last = SvbError::from_i32(unsafe { trigger(self.camera_id) });
            if last == SvbError::Success {
                return Ok(());
            }
        }
        Err(last.to_native_error("start the exposure (soft trigger)"))
    }

    /// Stop capture after a failed exposure step and leave the camera ready
    /// for the next one.
    fn end_failed_exposure(&mut self, sdk: &SvbonySdk) {
        stop_capture(sdk, self.camera_id);
        self.unread_frame = self.capture == Capture::SoftTrigger;
        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;
    }
}

#[async_trait]
impl CameraDriver for SvbonyCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    fn exposure_abort(&self) -> Option<std::sync::Arc<dyn skotiq_device::ExposureAbort>> {
        Some(self.core.abort_handle())
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;

        let sensor_temp = if self.controls.has(SvbControlType::CurrentTemperature) {
            self.control(SvbControlType::CurrentTemperature)
                .await
                .map(|v| v as f64 / 10.0)
                .ok()
        } else {
            None
        };

        let cooler_power = if self.core.capabilities.can_cool && self.core.cooler().enabled {
            self.control(SvbControlType::CoolerPower)
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
                Some(self.core.cooler().target_c)
            } else {
                None
            },
            cooler_on: self.core.cooler().enabled,
            gain,
            offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.core.require_connected()?;
        self.core.clear_abort();
        let micros = exposure_micros(
            params.duration_secs,
            self.controls.get(SvbControlType::Exposure),
        )?;
        let roi = self.roi_for(params.bin_x, params.bin_y, params.subframe.as_ref())?;
        let size = self.buffer_for(roi)?;

        let sdk = self.sdk().await?;
        stop_capture(&sdk, self.camera_id);
        if let Some(gain) = params.gain {
            self.core.gain =
                self.set_and_read_back(&sdk, SvbControlType::Gain, i64::from(gain))? as i32;
        }
        if let Some(offset) = params.offset {
            self.core.offset =
                self.set_and_read_back(&sdk, SvbControlType::BlackLevel, i64::from(offset))? as i32;
        }
        self.apply_roi(&sdk, roi, params.subframe.is_some())?;
        let micros = self.set_and_read_back(&sdk, SvbControlType::Exposure, micros)?;

        // SAFETY: the camera is open and its region and format are set.
        let result = unsafe { (sdk.start_video_capture)(self.camera_id) };
        check(result, "start capture")?;

        if self.capture == Capture::SoftTrigger {
            self.drain_frames(&sdk, size);
            if let Err(e) = self.send_trigger(&sdk) {
                self.end_failed_exposure(&sdk);
                return Err(e);
            }
            self.unread_frame = true;
        }

        self.core.exposure_started_at = Some(Instant::now());
        self.core.exposure_duration = micros as f64 / 1_000_000.0;
        self.core.state = CameraState::Exposing;
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let sdk = self.sdk().await?;
        // SAFETY: the camera is open; SVBStopVideoCapture takes a single c_int.
        let result = unsafe { (sdk.stop_video_capture)(self.camera_id) };
        check(result, "abort the exposure")?;

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
        let (width, height) = {
            let sdk = self.sdk().await?;
            sdk_roi_size(&sdk, self.camera_id)?
        };
        let size = calculate_buffer_size_i32(width, height, self.image_type.bytes_per_sample())?;
        if self.image_buffer.len() < size {
            self.image_buffer.resize(size, 0);
        }
        let exposure_end = self
            .core
            .exposure_started_at
            .map(|start| start + Duration::from_secs_f64(self.core.exposure_duration))
            .unwrap_or_else(Instant::now);
        let deadline = exposure_end.max(Instant::now()) + READOUT_ALLOWANCE;

        self.core.state = CameraState::Downloading;
        let sdk = loop {
            let sdk = self.sdk().await?;
            if self.core.abort_requested() {
                self.end_failed_exposure(&sdk);
                return Err(self.core.read_given_up());
            }
            match self.read_frame(&sdk, size, FRAME_POLL_MS) {
                SvbError::Success => break sdk,
                SvbError::Timeout if Instant::now() < deadline => {
                    drop(sdk);
                    tokio::task::yield_now().await;
                }
                SvbError::Timeout => {
                    self.end_failed_exposure(&sdk);
                    return Err(DriverError::Timeout(format!(
                        "{} sent no frame within {} s after the {} s exposure ended. Check the USB cable and hub, and that no other program has the camera open",
                        self.core.name,
                        READOUT_ALLOWANCE.as_secs(),
                        self.core.exposure_duration
                    )));
                }
                error => {
                    self.end_failed_exposure(&sdk);
                    return Err(error.to_native_error("download the frame"));
                }
            }
        };
        stop_capture(&sdk, self.camera_id);
        self.unread_frame = false;

        let data = unpack_samples(&self.image_buffer[..size], self.image_type.sample_layout());
        let temperature = if self.controls.has(SvbControlType::CurrentTemperature) {
            read_control(&sdk, self.camera_id, SvbControlType::CurrentTemperature)
                .map(|v| v as f64 / 10.0)
                .ok()
        } else {
            None
        };
        let gain = svb_control_value_to_i32(
            read_control(&sdk, self.camera_id, SvbControlType::Gain)?,
            "gain",
        )?;
        let offset = svb_control_value_to_i32(
            read_control(&sdk, self.camera_id, SvbControlType::BlackLevel)?,
            "offset",
        )?;

        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;

        let bits_per_pixel = match self.image_type.bytes_per_sample() {
            1 => 8,
            _ => self.core.sensor_info.bit_depth,
        };
        Ok(Frame {
            gain,
            offset,
            temperature,
            ..self.core.frame(
                roi_dimension("SVBony", "width", width)?,
                roi_dimension("SVBony", "height", height)?,
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

        let sdk = self.sdk().await?;
        write_control(
            &sdk,
            self.camera_id,
            SvbControlType::CoolerEnable as c_int,
            i64::from(enabled),
        )?;
        // Only when the caller named a setpoint, and only while cooling:
        // switching off needs no target temperature.
        if let Some(target) = target_temp.filter(|_| enabled) {
            if !target.is_finite() {
                return Err(DriverError::InvalidParameter(format!(
                    "SVBony cooler target must be a temperature, got {}",
                    target
                )));
            }
            // SVB_TARGET_TEMPERATURE is in 0.1 C (SVBCameraSDK.h).
            let tenths = self.set_and_read_back(
                &sdk,
                SvbControlType::TargetTemperature,
                (target * 10.0).round() as i64,
            )?;
            self.core
                .update_cooler(|cooler| cooler.target_c = tenths as f64 / 10.0);
        }

        self.core.update_cooler(|cooler| cooler.enabled = enabled);
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        if !self.controls.has(SvbControlType::CurrentTemperature) {
            return Err(DriverError::NotSupported);
        }
        let value = self.control(SvbControlType::CurrentTemperature).await?;
        Ok(value as f64 / 10.0)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }
        let value = self.control(SvbControlType::CoolerPower).await?;
        Ok(value as f64)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = self.sdk().await?;
        self.core.gain =
            self.set_and_read_back(&sdk, SvbControlType::Gain, i64::from(gain))? as i32;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        let value = self.control(SvbControlType::Gain).await?;
        svb_control_value_to_i32(value, "gain")
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = self.sdk().await?;
        self.core.offset =
            self.set_and_read_back(&sdk, SvbControlType::BlackLevel, i64::from(offset))? as i32;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        let value = self.control(SvbControlType::BlackLevel).await?;
        svb_control_value_to_i32(value, "offset")
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if self.core.state == CameraState::Exposing {
            return Err(DriverError::InvalidParameter(format!(
                "{} is exposing; binning changes after the frame",
                self.core.name
            )));
        }
        let roi = self.roi_for(bin_x, bin_y, None)?;
        let sdk = self.sdk().await?;
        self.apply_roi(&sdk, roi, false)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if self.core.state == CameraState::Exposing {
            return Err(DriverError::InvalidParameter(format!(
                "{} is exposing; the subframe changes after the frame",
                self.core.name
            )));
        }
        let roi = self.roi_for(self.core.bin_x, self.core.bin_y, subframe.as_ref())?;
        let sdk = self.sdk().await?;
        self.apply_roi(&sdk, roi, subframe.is_some())
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
        let gain = self
            .controls
            .get(SvbControlType::Gain)
            .ok_or(DriverError::NotSupported)?;
        Ok((
            svb_control_value_to_i32(gain.min, "gain minimum")?,
            svb_control_value_to_i32(gain.max, "gain maximum")?,
        ))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        let offset = self
            .controls
            .get(SvbControlType::BlackLevel)
            .ok_or(DriverError::NotSupported)?;
        Ok((
            svb_control_value_to_i32(offset.min, "offset minimum")?,
            svb_control_value_to_i32(offset.max, "offset maximum")?,
        ))
    }

    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        self.core.require_connected()?;
        Ok(self
            .controls
            .get(SvbControlType::Exposure)
            .map(|c| (c.min as f64 / 1_000_000.0, c.max as f64 / 1_000_000.0)))
    }

    async fn get_cooler_temp_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Ok(None);
        }
        Ok(self
            .controls
            .get(SvbControlType::TargetTemperature)
            .map(|c| (c.min as f64 / 10.0, c.max as f64 / 10.0)))
    }

    /// The default values SVBGetControlCaps reports for Gain and BlackLevel.
    /// SVBony does not expose an HCG transition through the SDK.
    async fn get_recommended_settings(
        &self,
    ) -> Result<skotiq_device::camera::CameraRecommendedSettings, DriverError> {
        self.core.require_connected()?;

        let mut out = skotiq_device::camera::CameraRecommendedSettings::default();
        let mut notes: Vec<String> = Vec::new();
        if let Some(gain) = self.controls.get(SvbControlType::Gain) {
            let gain = svb_control_value_to_i32(gain.default, "default gain")?;
            out.unity_gain = Some(gain);
            notes.push(format!("SVBony SDK reports default gain = {}", gain));
        }
        if let Some(offset) = self.controls.get(SvbControlType::BlackLevel) {
            let offset = svb_control_value_to_i32(offset.default, "default offset")?;
            out.default_offset = Some(offset);
            notes.push(format!("SVBony SDK reports default offset = {}", offset));
        }
        out.notes = notes.join("; ");
        Ok(out)
    }
}
