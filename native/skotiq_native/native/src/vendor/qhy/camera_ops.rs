//! `DeviceDriver` / `CameraDriver` implementations for `QhyCamera`.

use super::*;
use crate::camera_core::{unpack_samples, Frame, SampleLayout, SdkHandle};

/// `ControlQHYCCDShutter` states (qhyccdstruct.h). Lights and flats leave the
/// shutter to the camera ("free"), as INDI does.
const SHUTTER_CLOSED: u8 = 1;
const SHUTTER_FREE: u8 = 2;

#[async_trait]
impl DeviceDriver for QhyCamera {
    fn id(&self) -> &str {
        &self.core.device_id
    }

    fn name(&self) -> &str {
        &self.core.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Qhy
    }

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.core.connected {
            return Ok(());
        }
        QhySdk::ensure_initialized()?;
        let sdk = QhySdk::lock().await?;
        let (handle, _) = session::join(&sdk, &self.camera_id)?;
        self.handle = Some(handle);
        self.core.begin_connection();
        let configured = self
            .configure(&sdk)
            .and_then(|()| self.settle_gain_and_offset(&sdk));
        if let Err(error) = configured {
            self.handle = None;
            session::leave(&sdk, &self.camera_id);
            return Err(error);
        }
        self.core.connected = true;
        tracing::info!(
            "Connected to QHY camera {}: {}x{} imaging area at ({}, {}), bins {:?}, {}",
            self.camera_id,
            self.sensor_area.width,
            self.sensor_area.height,
            self.sensor_area.x,
            self.sensor_area.y,
            self.supported_bins,
            self.core.sensor_info.bayer_pattern.map_or_else(
                || "mono".to_string(),
                |p| p.letters()
            )
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        self.keepalive.stop();
        let lock = QhySdk::slot().lock_before_load().await;
        if let Some(handle) = self.handle.take() {
            if let Ok(sdk) = lock.table() {
                if self.core.exposure_started_at.is_some() {
                    self.core.end_exposure();
                    // The wheel on this camera may keep the session open, so
                    // CloseQHYCCD may not run; end the exposure here.
                    // SAFETY: `handle` is still open in its session.
                    unsafe { (sdk.cancel_qhyccd_exposing_and_readout)(handle) };
                }
                session::leave(sdk, &self.camera_id);
            }
        }
        self.core.connected = false;
        tracing::info!("Disconnected from QHY camera: {}", self.camera_id);
        Ok(())
    }
}

#[async_trait]
impl CameraDriver for QhyCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;
        let sdk = self.sdk().await?;
        let (state, exposure_remaining) = match self.core.exposure_remaining() {
            Some(left) if left > 0.0 => (CameraState::Exposing, Some(left)),
            Some(_) => (CameraState::Reading, Some(0.0)),
            None => (CameraState::Idle, None),
        };
        let cooler = self.core.cooler();
        Ok(CameraStatus {
            state,
            sensor_temp: self.temperature(&sdk),
            target_temp: cooler.target_c,
            cooler_on: if self.core.capabilities.can_cool {
                cooler.enabled
            } else {
                Some(false)
            },
            cooler_power: self.cooler_power(&sdk),
            gain: self.core.gain,
            offset: self.core.offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.connected_handle()?;
        let bin = self.check_bin(params.bin_x, params.bin_y)?;
        let exposure_us = params.duration_secs * 1_000_000.0;
        if exposure_us.is_nan() || exposure_us <= 0.0 {
            return Err(DriverError::InvalidParameter(format!(
                "An exposure must be longer than 0 s; {} s was asked",
                params.duration_secs
            )));
        }
        check_range(exposure_us, self.exposure_range_us, "exposure time", |us| {
            format!("{} s", us / 1_000_000.0)
        })?;
        if let Some(gain) = params.gain {
            check_range(f64::from(gain), self.gain_range, "gain", |g| g.to_string())?;
        }
        if let Some(offset) = params.offset {
            check_range(f64::from(offset), self.offset_range, "offset", |o| {
                o.to_string()
            })?;
        }
        readout_window(self.sensor_area, bin, params.subframe.as_ref())?;

        let sdk = self.sdk().await?;
        let handle = self.connected_handle()?;
        if self.core.exposure_started_at.is_some() {
            self.core.end_exposure();
            // A frame that was started and never read nor aborted would make
            // the SDK refuse the new one.
            tracing::warn!(
                "QHY camera {}: ending an exposure nobody read before starting the next",
                self.camera_id
            );
            // SAFETY: `handle` is open and the SDK lock is held.
            unsafe { (sdk.cancel_qhyccd_exposing_and_readout)(handle) };
        }
        self.check_sensor_power(&sdk)?;
        if self.core.capabilities.has_shutter {
            if let Some(control_shutter) = sdk.control_shutter {
                let state = if params.frame_type.opens_shutter() {
                    SHUTTER_FREE
                } else {
                    SHUTTER_CLOSED
                };
                check_qhy_error(
                    // SAFETY: `handle` is open and the SDK lock is held.
                    unsafe { control_shutter(handle, state) },
                    "move its shutter",
                )?;
            }
        }
        self.apply_roi(&sdk, bin, params.subframe.as_ref())?;
        self.write(
            &sdk,
            QhyControl::CONTROL_EXPOSURE,
            exposure_us,
            &format!("take an exposure time of {} s", params.duration_secs),
        )?;
        if let Some(gain) = params.gain {
            self.write(
                &sdk,
                QhyControl::CONTROL_GAIN,
                f64::from(gain),
                &format!("set the gain to {gain}"),
            )?;
            self.core.command_gain(gain);
        }
        if let Some(offset) = params.offset {
            self.write(
                &sdk,
                QhyControl::CONTROL_OFFSET,
                f64::from(offset),
                &format!("set the offset to {offset}"),
            )?;
            self.core.command_offset(offset);
        }

        // SAFETY: `handle` is open and the SDK lock is held.
        let result = unsafe { (sdk.exp_single_frame)(handle) };
        // Only QHYCCD_ERROR is a failure (INDI and NINA): old CCD and A-series
        // cameras answer QHYCCD_READ_DIRECTLY or QHYCCD_DELAY_200MS.
        if result == QHYCCD_ERROR {
            return Err(DriverError::SdkError(format!(
                "QHY camera {} did not start the exposure. If it keeps happening, check its USB \
                 cable and 12 V power, and that no other program uses the camera.",
                self.camera_id
            )));
        }
        self.core.begin_exposure(params.duration_secs);
        self.read_directly = result == QHYCCD_READ_DIRECTLY;
        tracing::info!(
            "Started {}s exposure on QHY camera {}",
            params.duration_secs,
            self.camera_id
        );
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.connected_handle()?;
        let sdk = self.sdk().await?;
        let handle = self.connected_handle()?;
        // SAFETY: `handle` is open and the SDK lock is held.
        let result = unsafe { (sdk.cancel_qhyccd_exposing_and_readout)(handle) };
        self.core.end_exposure();
        check_qhy_error(result, "stop the exposure")?;
        tracing::info!("Aborted exposure on QHY camera {}", self.camera_id);
        Ok(())
    }

    /// The SDK's frame read blocks until the frame is there; INDI and NINA
    /// both wait out the exposure first and then read. A camera that asked to
    /// be read directly is read at once.
    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.connected_handle()?;
        Ok(self
            .core
            .exposure_remaining()
            .is_none_or(|left| self.read_directly || left <= 0.0))
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.connected_handle()?;
        if self.core.exposure_started_at.is_none() {
            return Err(DriverError::InvalidParameter(format!(
                "QHY camera {} has no exposure to read",
                self.camera_id
            )));
        }
        let sdk = self.sdk().await?;
        let handle = self.connected_handle()?;
        // SAFETY: `handle` is open and the SDK lock is held.
        let buffer_len = unsafe { (sdk.get_qhyccd_memory_length)(handle) } as usize;
        if buffer_len == 0 || buffer_len == QHYCCD_ERROR as usize {
            self.core.end_exposure();
            return Err(DriverError::SdkError(format!(
                "QHY camera {} did not say how large its frame is",
                self.camera_id
            )));
        }
        let mut buffer = global_u8_pool().get_buffer(buffer_len);
        buffer.resize(buffer_len);
        let handle = SdkHandle(handle);
        // The read blocks for the readout (and for the whole exposure on a
        // camera read directly), so it runs off the async workers while this
        // task keeps the SDK lock.
        let (sdk, buffer, result, width, height, bpp, channels) =
            tokio::task::spawn_blocking(move || {
                let handle = handle;
                let mut buffer = buffer;
                let (mut width, mut height, mut bpp, mut channels) = (0, 0, 0, 0);
                // SAFETY: the handle is open, the guard `sdk` holds the SDK
                // lock, and `buffer` holds GetQHYCCDMemLength bytes, the most
                // the SDK writes.
                let result = unsafe {
                    (sdk.get_qhyccd_single_frame)(
                        handle.0,
                        &mut width,
                        &mut height,
                        &mut bpp,
                        &mut channels,
                        buffer.as_mut_ptr(),
                    )
                };
                (sdk, buffer, result, width, height, bpp, channels)
            })
            .await
            .map_err(|e| DriverError::SdkError(format!("QHY frame read stopped: {e}")))?;
        self.core.end_exposure();
        check_qhy_error(result, "deliver the frame")?;
        if channels > 1 {
            return Err(DriverError::SdkError(format!(
                "QHY camera {} delivered a {channels}-plane color image instead of the raw frame",
                self.camera_id
            )));
        }
        let bytes_per_sample = if bpp > 8 { 2 } else { 1 };
        let size = (width as usize)
            .checked_mul(height as usize)
            .and_then(|p| p.checked_mul(bytes_per_sample))
            .filter(|size| *size > 0 && *size <= buffer.len())
            .ok_or_else(|| {
                DriverError::SdkError(format!(
                    "QHY camera {} described its frame as {width}x{height} at {bpp} bits, \
                     which does not fit the {} bytes it asked for",
                    self.camera_id,
                    buffer.len()
                ))
            })?;
        // 16-bit samples are little-endian. An 8-bit frame keeps its 0..=255
        // values, the range `container_max_adu` reports for it.
        let layout = if bytes_per_sample == 2 {
            SampleLayout::U16Little
        } else {
            SampleLayout::U8Unscaled
        };
        let data = unpack_samples(&buffer[..size], layout);

        let temperature = self.temperature(&sdk);
        let mut vendor_data = VendorFeatures::default();
        vendor_data.usb_bandwidth = self.read(&sdk, QhyControl::CONTROL_USBTRAFFIC);
        vendor_data.sensor_chamber_humidity = self
            .read(&sdk, QhyControl::CAM_HUMIDITY)
            .filter(|h| (0.0..=100.0).contains(h));
        vendor_data.sensor_chamber_pressure = self
            .read(&sdk, QhyControl::CAM_PRESSURE)
            .filter(|p| *p > 0.0);
        drop(sdk);

        tracing::info!(
            "Downloaded {}x{} {}-bit frame from QHY camera {}",
            width,
            height,
            bpp,
            self.camera_id
        );
        Ok(Frame {
            temperature,
            vendor_data,
            ..self.core.frame(
                width,
                height,
                data,
                bpp,
                frame_bayer(
                    self.core
                        .sensor_info
                        .bayer_pattern
                        .and_then(|cfa| cfa.bayer()),
                    self.core.bin_x,
                    self.core.subframe.as_ref(),
                )
                .map(Into::into),
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
        if enabled {
            // CONTROL_COOLER is the set-point and switches regulation on, so a
            // target is needed; the last one commanded stands in for none.
            let target = target_temp.or(self.core.cooler().target_c).ok_or_else(|| {
                DriverError::InvalidParameter(format!(
                    "QHY cooler on {} needs a target temperature: CONTROL_COOLER is \
                     the setpoint and no previous setpoint is known for this camera",
                    self.core.device_id
                ))
            })?;
            if let Some((min_temp, max_temp)) = crate::quirks::get_cooler_range(&Vendor::Qhy, &self.camera_id) {
                if target < min_temp || target > max_temp {
                    return Err(DriverError::InvalidParameter(format!(
                        "QHY cooler target {target}C is outside the supported range {min_temp}C..={max_temp}C for {}",
                        self.core.device_id
                    )));
                }
            }
            let sdk = self.sdk().await?;
            self.start_cooling(&sdk, target)?;
            self.core.update_cooler(|cooler| {
                cooler.enabled = Some(true);
                cooler.target_c = Some(target);
            });
        } else {
            self.keepalive.stop();
            let sdk = self.sdk().await?;
            if self.has_manual_pwm {
                // Manual drive at zero power is how INDI and NINA switch the TEC off.
                self.write(
                    &sdk,
                    QhyControl::CONTROL_MANULPWM,
                    0.0,
                    "switch its cooler off",
                )?;
            } else {
                // A camera without manual drive warms up to a high set-point (INDI).
                self.write(
                    &sdk,
                    QhyControl::CONTROL_COOLER,
                    30.0,
                    "switch its cooler off",
                )?;
            }
            self.core.update_cooler(|cooler| {
                cooler.enabled = Some(false);
                cooler.target_c = None;
            });
        }
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.connected_handle()?;
        if !self.has_thermometer {
            return Err(DriverError::NotSupported);
        }
        if let Some(delay_ms) = crate::quirks::get_temperature_delay_ms(
            &Vendor::Qhy,
            DeviceKind::Camera,
            &self.camera_id,
        ) {
            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        }
        let sdk = self.sdk().await?;
        self.temperature(&sdk).ok_or_else(|| {
            DriverError::SdkError(format!(
                "QHY camera {} gave no sensor temperature",
                self.camera_id
            ))
        })
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.connected_handle()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }
        let sdk = self.sdk().await?;
        self.cooler_power(&sdk).ok_or_else(|| {
            DriverError::SdkError(format!(
                "QHY camera {} gave no cooler power",
                self.camera_id
            ))
        })
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        self.connected_handle()?;
        check_range(f64::from(gain), self.gain_range, "gain", |g| g.to_string())?;
        let sdk = self.sdk().await?;
        self.write(
            &sdk,
            QhyControl::CONTROL_GAIN,
            f64::from(gain),
            &format!("set the gain to {gain}"),
        )?;
        self.core.command_gain(gain);
        Ok(())
    }

    /// The gain Skotiq set, else the camera's reading: some models read their
    /// gain back divided by 10 or not at all (NINA's QuirkUnreliableGain).
    async fn get_gain(&self) -> Result<i32, DriverError> {
        self.connected_handle()?;
        if self.core.gain_commanded {
            return Ok(self.core.gain);
        }
        let sdk = self.sdk().await?;
        Ok(self
            .read(&sdk, QhyControl::CONTROL_GAIN)
            .map_or(self.core.gain, |g| g as i32))
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        self.connected_handle()?;
        check_range(f64::from(offset), self.offset_range, "offset", |o| {
            o.to_string()
        })?;
        let sdk = self.sdk().await?;
        self.write(
            &sdk,
            QhyControl::CONTROL_OFFSET,
            f64::from(offset),
            &format!("set the offset to {offset}"),
        )?;
        self.core.command_offset(offset);
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        self.connected_handle()?;
        if self.core.offset_commanded {
            return Ok(self.core.offset);
        }
        let sdk = self.sdk().await?;
        Ok(self
            .read(&sdk, QhyControl::CONTROL_OFFSET)
            .map_or(self.core.offset, |o| o as i32))
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.connected_handle()?;
        let bin = self.check_bin(bin_x, bin_y)?;
        let sdk = self.sdk().await?;
        self.apply_roi(&sdk, bin, None)?;
        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.connected_handle()?;
        let sdk = self.sdk().await?;
        let bin = self.core.bin_x;
        self.apply_roi(&sdk, bin, subframe.as_ref())?;
        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        self.connected_handle()?;
        let sdk = self.sdk().await?;
        let handle = self.connected_handle()?;

        let mut num_modes: c_uint = 0;
        // SAFETY: `handle` is open, the SDK lock is held, `num_modes` is a live local.
        let result = unsafe { (sdk.get_qhyccd_number_of_read_modes)(handle, &mut num_modes) };
        check_qhy_error(result, "list its read modes")?;

        let mut modes = Vec::new();
        for i in 0..num_modes {
            let mut name_buf = [0 as c_char; 256];
            // SAFETY: as above; `i` is below the count the SDK reported and the
            // buffer is larger than any read-mode name.
            let result =
                unsafe { (sdk.get_qhyccd_read_mode_name)(handle, i, name_buf.as_mut_ptr()) };
            if result == QHYCCD_SUCCESS {
                // SAFETY: the SDK wrote a NUL-terminated name.
                let name = unsafe { CStr::from_ptr(name_buf.as_ptr()) }
                    .to_string_lossy()
                    .to_string();
                modes.push(ReadoutMode {
                    // QHY cameras have at most 8 read modes (MAX_READMODE_NUMBER).
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

    /// A read mode only takes effect after re-initializing the camera, and
    /// the re-initialization resets the camera's settings (INDI: SetReadMode,
    /// InitQHYCCD, re-read the chip; NINA also restores gain and offset).
    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError> {
        self.connected_handle()?;
        let mode_index = c_uint::try_from(mode.index).map_err(|_| {
            DriverError::InvalidParameter(format!("QHY read mode {} does not exist", mode.index))
        })?;
        let sdk = self.sdk().await?;
        let handle = self.connected_handle()?;

        let mut prev_mode: c_uint = 0;
        // SAFETY: `handle` is open, the SDK lock is held, `prev_mode` is a live local.
        let prev_mode_result = unsafe { (sdk.get_qhyccd_read_mode)(handle, &mut prev_mode) };
        if prev_mode_result != QHYCCD_SUCCESS {
            tracing::warn!(
                "QHY camera {}: GetQHYCCDReadMode failed (error {}); a rollback would restore read mode 0 (SDK default), not the camera's current mode",
                self.camera_id,
                prev_mode_result
            );
        }

        // SAFETY: as above.
        let result = unsafe { (sdk.set_qhyccd_read_mode)(handle, mode_index) };
        check_qhy_error(result, &format!("switch to read mode {}", mode.name))?;

        // SAFETY: as above; stream mode 0 is single-frame mode.
        let reinit = unsafe {
            (sdk.set_qhyccd_stream_mode)(handle, 0);
            (sdk.init_qhyccd)(handle)
        };
        if reinit != QHYCCD_SUCCESS {
            let mut rollback_failures: Vec<String> = Vec::new();
            // SAFETY: as above; `prev_mode` is the mode read before the switch.
            let restore_mode = unsafe { (sdk.set_qhyccd_read_mode)(handle, prev_mode) };
            if restore_mode != QHYCCD_SUCCESS {
                rollback_failures.push(format!(
                    "SetQHYCCDReadMode({}) error {}",
                    prev_mode, restore_mode
                ));
            }
            // SAFETY: as above.
            let restore_init = unsafe { (sdk.init_qhyccd)(handle) };
            if restore_init != QHYCCD_SUCCESS {
                rollback_failures.push(format!("InitQHYCCD error {}", restore_init));
            }
            if let Err(e) = self
                .configure(&sdk)
                .and_then(|()| self.settle_gain_and_offset(&sdk))
            {
                rollback_failures.push(format!("settings refresh failed: {}", e));
            }
            if rollback_failures.is_empty() {
                return Err(DriverError::SdkError(format!(
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
            return Err(DriverError::SdkError(format!(
                "Failed to initialize QHY camera after switching to read mode {}, and the rollback to read mode {} also failed ({}); the camera is left un-initialized and must be reconnected",
                mode.index,
                prev_mode,
                rollback_failures.join("; ")
            )));
        }

        self.configure(&sdk)?;
        self.settle_gain_and_offset(&sdk)?;
        let cooler = self.core.cooler();
        if cooler.enabled == Some(true) {
            if let Some(target) = cooler.target_c {
                self.start_cooling(&sdk, target)?;
            }
        }
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        self.connected_handle()?;
        let sdk = self.sdk().await?;
        let mut features = VendorFeatures::default();
        features.usb_bandwidth = self.read(&sdk, QhyControl::CONTROL_USBTRAFFIC);
        features.sensor_chamber_humidity = self
            .read(&sdk, QhyControl::CAM_HUMIDITY)
            .filter(|h| (0.0..=100.0).contains(h));
        features.sensor_chamber_pressure = self
            .read(&sdk, QhyControl::CAM_PRESSURE)
            .filter(|p| *p > 0.0);
        Ok(features)
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        self.connected_handle()?;
        let (min, max) = self.gain_range.ok_or(DriverError::NotSupported)?;
        Ok((min as i32, max as i32))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.connected_handle()?;
        let (min, max) = self.offset_range.ok_or(DriverError::NotSupported)?;
        Ok((min as i32, max as i32))
    }

    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        self.connected_handle()?;
        Ok(self
            .exposure_range_us
            .map(|(min, max)| (min / 1_000_000.0, max / 1_000_000.0)))
    }

    /// Surface the SDK-advertised recommended settings.
    ///
    /// QHY exposes manufacturer-recommended values through two control IDs,
    /// `DefaultGain` (53) and `DefaultOffset` (54), on cameras whose firmware
    /// publishes them. We probe with `IsQHYCCDControlAvailable` and return
    /// `None` when the camera doesn't expose them. QHY does not expose the HCG
    /// transition point through the SDK.
    async fn get_recommended_settings(
        &self,
    ) -> Result<skotiq_device::camera::CameraRecommendedSettings, DriverError> {
        self.connected_handle()?;
        let sdk = self.sdk().await?;
        let mut out = skotiq_device::camera::CameraRecommendedSettings::default();
        let mut notes: Vec<String> = Vec::new();
        let recommended = |control| {
            self.available(&sdk, control)
                .then(|| self.read(&sdk, control))
                .flatten()
                .filter(|v| (0.0..10_000.0).contains(v))
                .map(|v| v as i32)
        };
        if let Some(gain) = recommended(QhyControl::DefaultGain) {
            out.unity_gain = Some(gain);
            notes.push(format!("QHY DefaultGain control reports {}", gain));
        }
        if let Some(offset) = recommended(QhyControl::DefaultOffset) {
            out.default_offset = Some(offset);
            notes.push(format!("QHY DefaultOffset control reports {}", offset));
        }
        out.notes = notes.join("; ");
        Ok(out)
    }
}
