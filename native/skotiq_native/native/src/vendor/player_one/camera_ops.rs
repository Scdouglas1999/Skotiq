//! `DeviceDriver` / `CameraDriver` implementations for `PlayerOneCamera`.

use super::*;
use crate::camera_core::{roi_dimension, unpack_samples, Frame, SampleLayout};

#[async_trait]
impl DeviceDriver for PlayerOneCamera {
    fn id(&self) -> &str {
        &self.core.device_id
    }

    fn name(&self) -> &str {
        &self.core.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::PlayerOne
    }

    fn serial_number(&self) -> Option<String> {
        self.serial()
    }

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        let sdk = PoaSdk::lock().await?;
        self.find_in_scan(&sdk)?;

        // SAFETY: the scan above listed `self.camera_id`; POAOpenCamera takes it by value.
        let result = unsafe { (sdk.open_camera)(self.camera_id) };
        check_poa_error(result, "OpenCamera")?;

        let camera_id = self.camera_id;
        let locked_sdk: &PoaSdk = &sdk;
        let cleanup_guard = CleanupGuard::new(|| {
            // SAFETY: the cleanup borrows the lock guard, so it runs while connect() still holds the lock;
            // camera_id was successfully opened immediately before the guard was created.
            let _ = unsafe { (locked_sdk.close_camera)(camera_id) };
        });

        // SAFETY: camera was just successfully opened above so POAInitCamera is the required next call per PlayerOneCamera.h; takes the camera ID by value.
        let result = unsafe { (sdk.init_camera)(self.camera_id) };
        check_poa_error(result, "InitCamera")?;

        self.load_camera_info(&sdk)?;

        // SAFETY: camera was opened and initialized successfully above; POASetImageFormat takes the camera ID and a POAImgFormat discriminant (Raw16=1) by value.
        let result =
            unsafe { (sdk.set_image_format)(self.camera_id, POAImgFormat::Raw16 as c_int) };
        check_poa_error(result, "SetImageFormat")?;

        // Bin 1, whole sensor, checked: the driver reports the geometry it reads
        // back (get_binning, and BIN/XBINNING on every frame), so a camera that
        // refused it fails the connect and the cleanup guard closes the handle.
        self.geometry_applied = false;
        self.apply_geometry(&sdk, 1, None)?;

        self.core.capabilities.supports_readout_modes = match self.sensor_modes(&sdk) {
            Ok(modes) => !modes.is_empty(),
            Err(e) => {
                tracing::warn!(
                    "Player One {}: sensor modes could not be read ({}); offering none",
                    self.core.device_id,
                    e
                );
                false
            }
        };

        // Seed the gain/offset the driver reports when a later read-back fails, so the
        // fallback is the camera's own power-on value rather than a literal 0.
        //
        // `core.gain`/`core.offset` start at 0, and both
        // `get_status` and `download_image` fall back to them — the second of those
        // writes the FITS GAIN/OFFSET cards. So a failed seed is precisely the case
        // that reintroduces the literal 0 these fallbacks exist to avoid, and it must
        // not pass silently: log which control refused and what the driver will report
        // until the first successful set/read replaces it. The connect itself stays
        // alive — a camera whose gain register is momentarily unreadable still images,
        // and `CameraStatus`/`ImageMetadata` have no "unknown" for these two i32 fields.
        match self.get_control_int(&sdk, POAConfig::POA_GAIN) {
            Ok(gain) => self.core.gain = gain as i32,
            Err(e) => tracing::warn!(
                "Player One {}: POA_GAIN could not be read at connect ({}); gain is reported as {} until a set_gain or a later read-back succeeds",
                self.core.device_id,
                e,
                self.core.gain
            ),
        }
        match self.get_control_int(&sdk, POAConfig::POA_OFFSET) {
            Ok(offset) => self.core.offset = offset as i32,
            Err(e) => tracing::warn!(
                "Player One {}: POA_OFFSET could not be read at connect ({}); offset is reported as {} until a set_offset or a later read-back succeeds",
                self.core.device_id,
                e,
                self.core.offset
            ),
        }

        cleanup_guard.defuse();
        self.core.connected = true;
        tracing::info!(
            "Connected to {} (serial {:?})",
            self.camera_name(),
            self.serial()
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if self.core.connected {
            let sdk = PoaSdk::lock().await?;
            // SAFETY: we only enter this branch when connected, so the camera was previously opened via POAOpenCamera; POACloseCamera pairs with it.
            let result = unsafe { (sdk.close_camera)(self.camera_id) };
            check_poa_error(result, "CloseCamera")?;
            self.core.connected = false;
            tracing::info!("Disconnected from {}", self.camera_name());
        }
        Ok(())
    }
}

#[async_trait]
impl CameraDriver for PlayerOneCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;

        let sdk = PoaSdk::lock().await?;

        let mut camera_state: c_int = 0;
        // SAFETY: the connection was checked above so the camera ID is open; `&mut camera_state` is a valid stack out-pointer to a POD c_int.
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
        let sensor_temp = self
            .get_control_float(&sdk, POAConfig::POA_TEMPERATURE)
            .ok();

        let has_cooler = self.core.capabilities.can_cool;

        let cooler_power = if has_cooler {
            self.get_control_int(&sdk, POAConfig::POA_COOLER_POWER)
                .ok()
                .map(|v| v as f64)
        } else {
            None
        };

        // The camera's `POA_COOLER` / `POA_TARGET_TEMP` registers, kept in the
        // core; when a read fails, the last read-back or command answers, and
        // with neither the state is unknown. Cameras without a cooler report
        // it off with no set-point.
        let (cooler_on, target_temp) = if has_cooler {
            let cached = self.core.cooler();

            let live_enabled = self.get_control_bool(&sdk, POAConfig::POA_COOLER).ok();
            let live_target_c = self
                .get_control_int(&sdk, POAConfig::POA_TARGET_TEMP)
                .ok()
                .map(|v| v as f64);

            // Refresh cached state with whatever the SDK gave us so subsequent
            // `&self` reads converge on the device's truth.
            if live_enabled.is_some() || live_target_c.is_some() {
                self.core.update_cooler(|cooler| {
                    if live_enabled.is_some() {
                        cooler.enabled = live_enabled;
                    }
                    if live_target_c.is_some() {
                        cooler.target_c = live_target_c;
                    }
                });
            }

            (
                live_enabled.or(cached.enabled),
                live_target_c.or(cached.target_c),
            )
        } else {
            (Some(false), None)
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
                .get_control_int(&sdk, POAConfig::POA_GAIN)
                .map(|v| v as i32)
                .unwrap_or(self.core.gain),
            offset: self
                .get_control_int(&sdk, POAConfig::POA_OFFSET)
                .map(|v| v as i32)
                .unwrap_or(self.core.offset),
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining: None, // Not directly available from POA SDK
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let bin = self.supported_bin(params.bin_x, params.bin_y)?;

        let sdk = PoaSdk::lock().await?;

        // A frame still exposing was abandoned by the caller; the SDK refuses
        // geometry changes and a new start until it is stopped.
        let mut camera_state: c_int = 0;
        // SAFETY: the connection was checked above; `&mut camera_state` is a valid out-pointer.
        let result = unsafe { (sdk.get_camera_state)(self.camera_id, &mut camera_state) };
        check_poa_error(result, "GetCameraState")?;
        if camera_state == POA_STATE_EXPOSING {
            tracing::warn!(
                "Player One {}: stopping the exposure still running before the next one",
                self.core.device_id
            );
            // SAFETY: the camera is open; POAStopExposure takes the id by value.
            let result = unsafe { (sdk.stop_exposure)(self.camera_id) };
            check_poa_error(result, "StopExposure")?;
        }

        self.apply_geometry(&sdk, bin, params.subframe.as_ref())?;
        let seconds = self.set_exposure_time(&sdk, params.duration_secs)?;

        // Cache what the camera holds after the set, not what was asked for:
        // these become the frame's GAIN/OFFSET when the download read-back fails.
        if let Some(gain) = params.gain {
            self.set_control_int(&sdk, POAConfig::POA_GAIN, gain as c_long, false)?;
            self.core.gain = self
                .get_control_int(&sdk, POAConfig::POA_GAIN)
                .map(|v| v as i32)
                .unwrap_or(gain);
        }
        if let Some(offset) = params.offset {
            self.set_control_int(&sdk, POAConfig::POA_OFFSET, offset as c_long, false)?;
            self.core.offset = self
                .get_control_int(&sdk, POAConfig::POA_OFFSET)
                .map(|v| v as i32)
                .unwrap_or(offset);
        }

        // POA_TRUE is a single frame (snap mode). POA_FALSE is video mode: the
        // camera keeps exposing after the frame and refuses the next start.
        // SAFETY: the connection was checked at entry; POAStartExposure takes the camera ID and the POABool by value.
        let result = unsafe { (sdk.start_exposure)(self.camera_id, POA_TRUE) };
        check_poa_error(result, "StartExposure")?;

        self.core.exposure_duration = seconds;

        tracing::info!("Started {}s exposure", seconds);
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let sdk = PoaSdk::lock().await?;

        // SAFETY: the connection was checked at entry; POAStopExposure takes the camera ID by value.
        let result = unsafe { (sdk.stop_exposure)(self.camera_id) };
        check_poa_error(result, "StopExposure")?;

        tracing::info!("Aborted exposure");
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.core.require_connected()?;

        let sdk = PoaSdk::lock().await?;

        let mut is_ready: POABool = POA_FALSE;
        // SAFETY: the connection was checked at entry; `&mut is_ready` is a valid stack out-pointer to a POD c_int.
        let result = unsafe { (sdk.image_ready)(self.camera_id, &mut is_ready) };
        check_poa_error(result, "POAImageReady")?;

        Ok(is_ready == POA_TRUE)
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.core.require_connected()?;

        let sdk = PoaSdk::lock().await?;

        let mut width: c_int = 0;
        let mut height: c_int = 0;
        // SAFETY: the connection was checked at entry; both `&mut width` and `&mut height` are valid stack out-pointers to POD c_int values.
        let result = unsafe { (sdk.get_image_size)(self.camera_id, &mut width, &mut height) };
        check_poa_error(result, "GetImageSize")?;

        // Calculate buffer size (Raw16 = 2 bytes per pixel) with overflow protection
        let bytes_per_pixel = if matches!(self.image_format, POAImgFormat::Raw16) {
            2
        } else {
            1
        };
        let buffer_size = calculate_buffer_size_i32(width, height, bytes_per_pixel)?;

        // A pooled buffer is at least `buffer_size` long, often a whole size bucket
        // longer; the frame is exactly `buffer_size` bytes.
        let mut pooled_buffer = global_u8_pool().get_buffer(buffer_size);
        pooled_buffer.resize(buffer_size);

        // Get image data with 30 second timeout
        // SAFETY: the connection was checked at entry; `pooled_buffer` was sized via calculate_buffer_size_i32(width, height, bytes_per_pixel) which uses the SDK-reported dimensions from POAGetImageSize and matches the configured POAImgFormat — we pass the same length as buffer_len so the SDK cannot overrun; pool returns a non-null buffer.
        let result = unsafe {
            (sdk.get_image_data)(
                self.camera_id,
                pooled_buffer.as_mut_ptr(),
                buffer_size as c_long,
                30000,
            )
        };
        check_poa_error(result, "GetImageData")?;

        // Why: 8-bit -> 16-bit promotion (u8 -> u16 is always lossless; * 256 stays
        // within u16 because the max product is 255 * 256 = 65280 < u16::MAX).
        let layout = if bytes_per_pixel == 2 {
            SampleLayout::U16Native
        } else {
            SampleLayout::U8Scaled
        };
        let data = unpack_samples(&pooled_buffer[..], layout);

        tracing::info!(
            "Downloaded {}x{} image ({} bytes)",
            width,
            height,
            buffer_size
        );

        // Get metadata while still holding the SDK lock.
        // get_control_int returns c_long (i64 on Linux); gain/offset fit in i32,
        // which is what ImageMetadata stores. A failed read-back falls back to the
        // value this driver last applied — these two numbers become the FITS
        // GAIN/OFFSET cards of the frame we are holding, and a literal 0 there would
        // send calibration to the wrong dark library.
        let gain = match self.get_control_int(&sdk, POAConfig::POA_GAIN) {
            Ok(value) => {
                self.core.gain = value as i32;
                self.core.gain
            }
            Err(e) => {
                tracing::warn!(
                    "Player One {}: POA_GAIN read-back failed while building frame metadata ({}); recording the last applied gain {}",
                    self.core.device_id,
                    e,
                    self.core.gain
                );
                self.core.gain
            }
        };
        let offset = match self.get_control_int(&sdk, POAConfig::POA_OFFSET) {
            Ok(value) => {
                self.core.offset = value as i32;
                self.core.offset
            }
            Err(e) => {
                tracing::warn!(
                    "Player One {}: POA_OFFSET read-back failed while building frame metadata ({}); recording the last applied offset {}",
                    self.core.device_id,
                    e,
                    self.core.offset
                );
                self.core.offset
            }
        };
        let temperature = self
            .get_control_float(&sdk, POAConfig::POA_TEMPERATURE)
            .ok();
        let usb_bandwidth = self
            .get_control_int(&sdk, POAConfig::POA_USB_BANDWIDTH_LIMIT)
            .ok()
            .map(|v| v as f64);
        let heater_power = self.get_control_int(&sdk, POAConfig::POA_HEATER_POWER).ok();
        let fan_power = self
            .get_control_int(&sdk, POAConfig::POA_FAN_POWER)
            .ok()
            .map(|v| v as f64);

        let mut vendor_features = VendorFeatures::default();
        vendor_features.usb_bandwidth = usb_bandwidth;
        if let Some(hp) = heater_power {
            vendor_features.anti_dew_heater = Some(hp > 0);
        }
        vendor_features.fan_power = fan_power;

        // With POA_MONO_BIN on, a color camera bins neighbouring pixels and the
        // binned frame has no Bayer pattern (PlayerOneCamera.h).
        let bayer_pattern = self.core.sensor_info.bayer_pattern.filter(|_| {
            self.core.bin_x == 1
                || !self
                    .get_control_bool(&sdk, POAConfig::POA_MONO_BIN)
                    .unwrap_or(false)
        });

        let bits_per_pixel = self
            .camera_info
            .as_ref()
            .and_then(|info| u32::try_from(info.bit_depth).ok())
            .filter(|bits| (1..=32).contains(bits))
            .unwrap_or(if bytes_per_pixel == 2 { 16 } else { 8 });
        let readout_mode = self.current_sensor_mode(&sdk);
        Ok(Frame {
            gain,
            offset,
            temperature,
            readout_mode,
            vendor_data: vendor_features,
            ..self.core.frame(
                roi_dimension("Player One", "width", width)?,
                roi_dimension("Player One", "height", height)?,
                data,
                bits_per_pixel,
                bayer_pattern,
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

        let sdk = PoaSdk::lock().await?;

        // Set target temperature (POA_TARGET_TEMP is in C, int value) only
        // when the caller named one — a "cooler off" carries no setpoint.
        if let Some(target) = target_temp {
            // POA_TARGET_TEMP is whole degrees.
            let whole = target.round();
            self.set_control_int(&sdk, POAConfig::POA_TARGET_TEMP, whole as c_long, false)?;
        }

        // Enable/disable cooler (POA_COOLER is a bool)
        self.set_control_bool(&sdk, POAConfig::POA_COOLER, enabled, false)?;

        // Record the accepted state so `get_status` can report cooler_on
        // accurately on cameras whose firmware doesn't expose POA_COOLER for
        // read-back. Only update after both SDK calls above succeeded.
        self.core.update_cooler(|cooler| {
            cooler.enabled = Some(enabled);
            if let Some(target) = target_temp {
                cooler.target_c = Some(target.round());
            }
        });

        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        if let Some(delay_ms) = crate::quirks::get_temperature_delay_ms(&self.core.device_id) {
            tracing::debug!(
                "Applying temperature RequiresDelayMs quirk: sleeping {}ms before reading {}",
                delay_ms,
                self.core.device_id
            );
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        // POA_TEMPERATURE is a float value in Celsius (uses the async version, which takes the SDK lock)
        self.get_control_float_async(POAConfig::POA_TEMPERATURE)
            .await
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }
        // Uses the async version, which takes the SDK lock
        let value = self
            .get_control_int_async(POAConfig::POA_COOLER_POWER)
            .await?;
        Ok(value as f64)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        // Uses the async version, which takes the SDK lock
        self.set_control_int_async(POAConfig::POA_GAIN, gain as c_long, false)
            .await?;
        self.core.gain = gain;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        // Uses the async version, which takes the SDK lock. get_control_int_async returns c_long
        // (i64 on Linux LP64); gain fits in i32.
        self.get_control_int_async(POAConfig::POA_GAIN)
            .await
            .map(|v| v as i32)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        // Uses the async version, which takes the SDK lock
        self.set_control_int_async(POAConfig::POA_OFFSET, offset as c_long, false)
            .await?;
        self.core.offset = offset;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        // Uses the async version, which takes the SDK lock. get_control_int_async returns c_long
        // (i64 on Linux LP64); offset fits in i32.
        self.get_control_int_async(POAConfig::POA_OFFSET)
            .await
            .map(|v| v as i32)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let bin = self.supported_bin(bin_x, bin_y)?;
        let sdk = PoaSdk::lock().await?;
        self.apply_geometry(&sdk, bin, None)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = PoaSdk::lock().await?;
        self.apply_geometry(&sdk, self.core.bin_x, subframe.as_ref())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        self.core.require_connected()?;
        let sdk = PoaSdk::lock().await?;
        self.sensor_modes(&sdk)
    }

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = PoaSdk::lock().await?;
        let Some(set_mode) = sdk
            .set_sensor_mode
            .filter(|_| self.core.capabilities.supports_readout_modes)
        else {
            return Err(DriverError::NotSupported);
        };
        check_poa_error(
            // SAFETY: the camera is open; POASetSensorMode takes the id and index by value
            // and answers POA_ERROR_INVALID_ARGU for an index out of range.
            unsafe { set_mode(self.camera_id, mode.index) },
            "SetSensorMode",
        )?;
        tracing::info!(
            "Player One {}: sensor mode {}",
            self.core.device_id,
            mode.index
        );
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        let mut features = VendorFeatures::default();

        // Get USB bandwidth (uses the async version, which takes the SDK lock)
        if let Ok(bw) = self
            .get_control_int_async(POAConfig::POA_USB_BANDWIDTH_LIMIT)
            .await
        {
            features.usb_bandwidth = Some(bw as f64);
        }

        // Player One specific: Anti-dew heater power (uses the async version, which takes the SDK lock)
        if let Ok(heater_power) = self
            .get_control_int_async(POAConfig::POA_HEATER_POWER)
            .await
        {
            features.anti_dew_heater = Some(heater_power > 0);
        }

        // Player One specific: Fan power (uses the async version, which takes the SDK lock)
        if let Ok(fan_power) = self.get_control_int_async(POAConfig::POA_FAN_POWER).await {
            features.fan_power = Some(fan_power as f64);
        }

        Ok(features)
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        let sdk = PoaSdk::lock().await?;
        self.config_int_bounds(&sdk, POAConfig::POA_GAIN)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        let sdk = PoaSdk::lock().await?;
        self.config_int_bounds(&sdk, POAConfig::POA_OFFSET)
    }

    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        self.core.require_connected()?;
        let sdk = PoaSdk::lock().await?;
        self.exposure_bounds(&sdk)
    }

    async fn get_cooler_temp_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Ok(None);
        }

        let sdk = PoaSdk::lock().await?;
        match self.config_int_bounds(&sdk, POAConfig::POA_TARGET_TEMP) {
            Ok((min, max)) => Ok(Some((f64::from(min), f64::from(max)))),
            Err(DriverError::NotSupported) => Ok(None),
            Err(e) => Err(e),
        }
    }
}
