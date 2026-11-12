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

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        let sdk = PoaSdk::lock().await?;

        // Load camera info first
        self.load_camera_info(&sdk)?;

        // SAFETY: `self.camera_id` was populated at construction and verified by load_camera_info (which succeeded above); POAOpenCamera takes the camera ID by value with no pointer arguments.
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

        // Set default format (Raw16)
        // SAFETY: camera was opened and initialized successfully above; POASetImageFormat takes the camera ID and a POAImgFormat discriminant (Raw16=1) by value.
        let result =
            unsafe { (sdk.set_image_format)(self.camera_id, POAImgFormat::Raw16 as c_int) };
        check_poa_error(result, "SetImageFormat")?;

        // Set default binning and ROI. These are checked, not fire-and-forget: the
        // driver reports bin 1 / the full frame from here
        // on (get_binning, and the BIN/XBINNING metadata on every frame), so a camera
        // that refused the default geometry would make every one of those answers a
        // lie. Failing the connect leaves the cleanup guard to close the handle.
        if let Some(info) = &self.camera_info {
            // SAFETY: camera is open+initialized; POASetImageBin takes the camera ID and bin factor (1) by value.
            let result = unsafe { (sdk.set_image_bin)(self.camera_id, 1) };
            check_poa_error(result, "SetImageBin(1)")?;
            // SAFETY: camera is open+initialized; POASetImageStartPos takes the camera ID and (0, 0) origin by value.
            let result = unsafe { (sdk.set_image_start_pos)(self.camera_id, 0, 0) };
            check_poa_error(result, "SetImageStartPos(0, 0)")?;
            // SAFETY: camera is open+initialized; max_width/max_height come from the SDK-populated POACameraProperties so they are guaranteed valid for this device.
            let result =
                unsafe { (sdk.set_image_size)(self.camera_id, info.max_width, info.max_height) };
            check_poa_error(result, "SetImageSize(full frame)")?;
        }

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
        tracing::info!("Connected to {}", self.camera_name());
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

        // Resolve cooler_on / target_temp.
        //
        // Priority: SDK read-back of `POA_COOLER` / `POA_TARGET_TEMP` — that is
        // the authoritative register on the device. If either succeeds we
        // refresh the cached state so future reads stay consistent. If the SDK
        // path is unsupported by this camera/firmware we fall back to the
        // tracked state written by `set_cooler`. Cameras without a cooler at
        // all report `cooler_on = false` and `target_temp = None`.
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
                    if let Some(e) = live_enabled {
                        cooler.enabled = e;
                    }
                    if let Some(t) = live_target_c {
                        cooler.target_c = t;
                    }
                });
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

        let sdk = PoaSdk::lock().await?;

        // Set exposure time (in microseconds)
        let exposure_us = (params.duration_secs * 1_000_000.0) as c_long;
        self.set_control_int(&sdk, POAConfig::POA_EXPOSURE, exposure_us, false)?;

        if let Some(gain) = params.gain {
            self.set_control_int(&sdk, POAConfig::POA_GAIN, gain as c_long, false)?;
            self.core.gain = gain;
        }

        if let Some(offset) = params.offset {
            self.set_control_int(&sdk, POAConfig::POA_OFFSET, offset as c_long, false)?;
            self.core.offset = offset;
        }

        // Start exposure (false = not snap mode, single frame)
        // SAFETY: the connection was checked at entry; POAStartExposure takes the camera ID and the snap-mode POABool by value.
        let result = unsafe { (sdk.start_exposure)(self.camera_id, POA_FALSE) };
        check_poa_error(result, "StartExposure")?;

        self.core.exposure_duration = params.duration_secs;

        tracing::info!("Started {}s exposure", params.duration_secs);
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

        let mut pooled_buffer = global_u8_pool().get_buffer(buffer_size);

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

        let bits_per_pixel = self
            .camera_info
            .as_ref()
            .and_then(|info| u32::try_from(info.bit_depth).ok())
            .filter(|bits| (1..=32).contains(bits))
            .unwrap_or(if bytes_per_pixel == 2 { 16 } else { 8 });
        Ok(Frame {
            gain,
            offset,
            temperature,
            vendor_data: vendor_features,
            ..self.core.frame(
                roi_dimension("Player One", "width", width)?,
                roi_dimension("Player One", "height", height)?,
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

        let sdk = PoaSdk::lock().await?;

        // Set target temperature (POA_TARGET_TEMP is in C, int value) only
        // when the caller named one — a "cooler off" carries no setpoint.
        if let Some(target) = target_temp {
            self.set_control_int(&sdk, POAConfig::POA_TARGET_TEMP, target as c_long, false)?;
        }

        // Enable/disable cooler (POA_COOLER is a bool)
        self.set_control_bool(&sdk, POAConfig::POA_COOLER, enabled, false)?;

        // Record the accepted state so `get_status` can report cooler_on
        // accurately on cameras whose firmware doesn't expose POA_COOLER for
        // read-back. Only update after both SDK calls above succeeded.
        self.core.update_cooler(|cooler| {
            cooler.enabled = enabled;
            if let Some(target) = target_temp {
                cooler.target_c = target;
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

        let sdk = PoaSdk::installed()?;

        // Player One only supports symmetric binning
        let bin = bin_x.max(bin_y);

        let sdk = sdk.lock().await;

        // SAFETY: the connection was checked at entry; POASetImageBin takes the camera ID and bin factor by value.
        let result = unsafe { (sdk.set_image_bin)(self.camera_id, bin as c_int) };
        check_poa_error(result, "SetImageBin")?;

        let info = self.camera_info.as_ref().ok_or(DriverError::NotConnected)?;
        let new_width = info.max_width / bin;
        let new_height = info.max_height / bin;

        // SAFETY: the connection was checked at entry; new_width/new_height are derived from the SDK-populated max dimensions divided by the bin factor — within sensor bounds.
        let result = unsafe { (sdk.set_image_size)(self.camera_id, new_width, new_height) };
        check_poa_error(result, "SetImageSize")?;

        self.core.bin_x = bin;
        self.core.bin_y = bin;

        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let sdk = PoaSdk::installed()?;
        let info = self.camera_info.as_ref().ok_or(DriverError::NotConnected)?;

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
                info.max_width / self.core.bin_x,
                info.max_height / self.core.bin_y,
            )
        };

        let sdk = sdk.lock().await;

        // SAFETY: the connection was checked at entry; x/y are caller-provided subframe origin or (0,0) — POA SDK validates against current image format/binning.
        let result = unsafe { (sdk.set_image_start_pos)(self.camera_id, x, y) };
        check_poa_error(result, "SetImageStartPos")?;

        // SAFETY: the connection was checked at entry; width/height are either caller-provided subframe size or info.max_width/height divided by the bin factor, all within sensor bounds.
        let result = unsafe { (sdk.set_image_size)(self.camera_id, width, height) };
        check_poa_error(result, "SetImageSize")?;

        self.core.subframe = subframe;

        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        // Player One doesn't have readout modes
        Ok(Vec::new())
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
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

        self.config_int_bounds(POAConfig::POA_GAIN).await
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;

        self.config_int_bounds(POAConfig::POA_OFFSET).await
    }
}
