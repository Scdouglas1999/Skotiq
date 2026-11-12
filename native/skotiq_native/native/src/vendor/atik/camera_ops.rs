//! `CameraDriver` implementation for `AtikCamera`.

use super::*;

/// How long an exposure waits for the camera to report idle. After an abort
/// a CCD may still be clearing its sensor (SDK guide, CAMERA_FLUSHING); NINA
/// waits for idle without a limit and INDI for 100 s.
const IDLE_WAIT: std::time::Duration = std::time::Duration::from_secs(60);
const IDLE_POLL: std::time::Duration = std::time::Duration::from_millis(100);

impl AtikCamera {
    /// Fails when the SDK has lost the camera (unplugged, powered off).
    fn require_present(&self, sdk: &AtikSdk) -> Result<(), DriverError> {
        // SAFETY: the handle is open while `core.connected`; the lock is held.
        if unsafe { (sdk.is_connected)(self.handle()) } == 0 {
            return Err(DriverError::Disconnected);
        }
        Ok(())
    }

    fn sdk_state(&self, sdk: &AtikSdk) -> Option<c_int> {
        let state = sdk.camera_state?;
        // SAFETY: the handle is open and the lock is held.
        Some(unsafe { state(self.handle()) })
    }

    /// Whether a new exposure may start now. A camera in its error state is
    /// stopped so it can return to idle (INDI stops and restarts it).
    pub(crate) fn ready_to_expose(&self, sdk: &AtikSdk) -> Result<bool, DriverError> {
        self.require_present(sdk)?;
        match self.sdk_state(sdk) {
            None | Some(CAMERA_IDLE) => Ok(true),
            Some(CAMERA_ERROR) => {
                // SAFETY: the handle is open and the lock is held.
                let _ = unsafe { (sdk.abort_exposure)(self.handle()) };
                Ok(false)
            }
            Some(_) => Ok(false),
        }
    }

    /// Applies the exposure's settings and starts it. The caller holds the
    /// SDK lock and has seen the camera idle.
    pub(crate) fn begin_exposure(
        &mut self,
        sdk: &AtikSdk,
        params: &ExposureParams,
    ) -> Result<(), DriverError> {
        if !params.duration_secs.is_finite() || params.duration_secs < 0.0 {
            return Err(DriverError::InvalidParameter(format!(
                "Atik exposure of {} s",
                params.duration_secs
            )));
        }
        for (value, is_offset) in [(params.gain, false), (params.offset, true)] {
            let Some(value) = value else { continue };
            if self.facts.gain.takes(is_offset) {
                self.apply_gain(sdk, value, is_offset)?;
            } else {
                tracing::debug!(
                    "Atik camera '{}' has no {} setting; the requested {} is not applied",
                    self.core.name,
                    if is_offset { "offset" } else { "gain" },
                    value
                );
            }
        }
        self.apply_binning(sdk, params.bin_x, params.bin_y)?;
        self.apply_subframe(sdk, params.subframe.clone())?;

        // Only a camera with a mechanical shutter has a dark mode; the others
        // answer ARTEMIS_INVALID_FUNCTION and take darks with the lens capped.
        if self.facts.has_shutter {
            let dark = !params.frame_type.opens_shutter();
            // SAFETY: the handle is open and the lock is held.
            let result = unsafe { (sdk.set_dark_mode)(self.handle(), dark) };
            check_artemis_error(result, "keep the shutter closed for a dark frame")?;
        }

        // SAFETY: the handle is open and the lock is held; the duration is passed by value.
        let result =
            unsafe { (sdk.start_exposure)(self.handle(), params.duration_secs as c_float) };
        check_artemis_error(result, "start the exposure")?;

        self.core.exposure_duration = params.duration_secs;
        self.core.exposure_started_at = Some(std::time::Instant::now());
        self.core.state = CameraState::Exposing;
        Ok(())
    }

    fn apply_gain(
        &mut self,
        sdk: &AtikSdk,
        value: i32,
        is_offset: bool,
    ) -> Result<(), DriverError> {
        let current = (self.core.gain, self.core.offset);
        let (gain, offset) = gain::set(
            sdk,
            self.handle(),
            self.facts.gain,
            current,
            value,
            is_offset,
        )?;
        let applied = if is_offset { offset } else { gain };
        if applied != value {
            tracing::warn!(
                "Atik camera '{}' took {} {} when asked for {}",
                self.core.name,
                if is_offset { "offset" } else { "gain" },
                applied,
                value
            );
        }
        self.core.gain = gain;
        self.core.offset = offset;
        Ok(())
    }

    fn apply_binning(&mut self, sdk: &AtikSdk, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        let caps = &self.core.capabilities;
        if !(1..=caps.max_bin_x).contains(&bin_x) || !(1..=caps.max_bin_y).contains(&bin_y) {
            return Err(DriverError::InvalidParameter(format!(
                "Binning {}x{} is outside 1x1 to {}x{}",
                bin_x, bin_y, caps.max_bin_x, caps.max_bin_y
            )));
        }
        // SAFETY: the handle is open and the lock is held; plain arguments.
        let result = unsafe { (sdk.bin)(self.handle(), bin_x, bin_y) };
        check_artemis_error(result, &format!("bin {bin_x}x{bin_y}"))?;
        self.core.bin_x = bin_x;
        self.core.bin_y = bin_y;
        Ok(())
    }

    /// `subframe` is in binned pixels, as every Skotiq caller gives it;
    /// ArtemisSubframe takes unbinned sensor pixels at any binning.
    fn apply_subframe(
        &mut self,
        sdk: &AtikSdk,
        subframe: Option<SubFrame>,
    ) -> Result<(), DriverError> {
        let sensor = &self.core.sensor_info;
        let (bin_x, bin_y) = (self.core.bin_x as u32, self.core.bin_y as u32);
        let (x, y, w, h) = match &subframe {
            Some(sf) => (
                sf.start_x.checked_mul(bin_x),
                sf.start_y.checked_mul(bin_y),
                sf.width.checked_mul(bin_x),
                sf.height.checked_mul(bin_y),
            ),
            None => (Some(0), Some(0), Some(sensor.width), Some(sensor.height)),
        };
        let fits = |start: Option<u32>, size: Option<u32>, limit: u32| {
            let (start, size) = (start?, size?);
            (size > 0 && start.checked_add(size)? <= limit).then_some((start, size))
        };
        let (Some((x, w)), Some((y, h))) = (fits(x, w, sensor.width), fits(y, h, sensor.height))
        else {
            return Err(DriverError::InvalidParameter(format!(
                "Atik subframe {:?} at bin {}x{} does not fit the {}x{} sensor",
                subframe, bin_x, bin_y, sensor.width, sensor.height
            )));
        };
        let to_c = |v: u32| c_int::try_from(v).expect("bounded by the sensor size, a c_int");
        // SAFETY: the handle is open and the lock is held; plain arguments.
        let result = unsafe { (sdk.subframe)(self.handle(), to_c(x), to_c(y), to_c(w), to_c(h)) };
        check_artemis_error(result, &format!("set the subframe {x},{y} {w}x{h}"))?;

        self.core.subframe = subframe;
        self.frame_bayer = self
            .facts
            .cfa_offset
            .map(|(dx, dy)| rggb_cell_at(dx + i64::from(x), dy + i64::from(y)));
        Ok(())
    }

    pub(crate) fn exposure_done(&self, sdk: &AtikSdk) -> Result<bool, DriverError> {
        self.require_present(sdk)?;
        // SAFETY: the handle is open and the lock is held.
        if unsafe { (sdk.image_ready)(self.handle()) } != 0 {
            return Ok(true);
        }
        if self.sdk_state(sdk) == Some(CAMERA_ERROR) {
            return Err(DriverError::SdkError(format!(
                "Atik camera '{}' reported an error during the exposure",
                self.core.name
            )));
        }
        Ok(false)
    }

    pub(crate) fn take_frame(&mut self, sdk: &AtikSdk) -> Result<ImageData, DriverError> {
        let handle = self.handle();
        if let Some(failed) = sdk.image_failed {
            // SAFETY: the handle is open and the lock is held.
            if unsafe { failed(handle) } != 0 {
                self.core.state = CameraState::Error;
                return Err(DriverError::SdkError(format!(
                    "Atik camera '{}' reported that the image download failed",
                    self.core.name
                )));
            }
        }
        self.core.state = CameraState::Downloading;

        let (mut x, mut y, mut w, mut h, mut bin_x, mut bin_y) = (0, 0, 0, 0, 0, 0);
        // SAFETY: all six out-pointers are valid.
        let result = unsafe {
            (sdk.get_image_data)(
                handle, &mut x, &mut y, &mut w, &mut h, &mut bin_x, &mut bin_y,
            )
        };
        if let Err(error) = check_artemis_error(result, "read the image size") {
            self.core.state = CameraState::Error;
            return Err(error);
        }
        let width = image_dimension("Atik", "width", usize::try_from(w).unwrap_or(0))?;
        let height = image_dimension("Atik", "height", usize::try_from(h).unwrap_or(0))?;
        if width == 0 || height == 0 {
            self.core.state = CameraState::Error;
            return Err(DriverError::SdkError(format!(
                "Atik camera '{}' reported a {}x{} image",
                self.core.name, w, h
            )));
        }

        // SAFETY: the handle is open and the lock is held; null-checked below.
        let buffer = unsafe { (sdk.image_buffer)(handle) };
        if buffer.is_null() {
            self.core.state = CameraState::Error;
            return Err(DriverError::SdkError(format!(
                "Atik camera '{}' finished the exposure but has no image",
                self.core.name
            )));
        }
        let byte_count = width as usize * height as usize * 2;
        // SAFETY: the SDK's buffer holds width * height 16-bit samples (the
        // camera is never in 8-bit mode) and stays put while the lock is held;
        // it is read as bytes, so its alignment does not matter.
        let bytes = unsafe { std::slice::from_raw_parts(buffer as *const u8, byte_count) };
        let data = unpack_samples(bytes, SampleLayout::U16Little);

        let temperature = sensor_temperature(sdk, handle);
        self.core.state = CameraState::Idle;
        Ok(Frame {
            bin_x,
            bin_y,
            temperature,
            ..self.core.frame(
                width,
                height,
                data,
                self.core.sensor_info.bit_depth,
                self.frame_bayer,
            )
        }
        .into_image())
    }

    pub(crate) fn status(&self, sdk: &AtikSdk) -> Result<CameraStatus, DriverError> {
        self.require_present(sdk)?;
        let handle = self.handle();
        let cooling = self
            .facts
            .has_cooling
            .then(|| cooling_info(sdk, handle))
            .flatten();
        let exposure_remaining = (self.core.state == CameraState::Exposing).then(|| {
            // SAFETY: the handle is open and the lock is held.
            f64::from(unsafe { (sdk.exposure_time_remaining)(handle) })
        });
        Ok(CameraStatus {
            state: self.core.state,
            sensor_temp: sensor_temperature(sdk, handle),
            cooler_power: cooling.and_then(|c| c.power_percent()),
            target_temp: cooling.map(|c| c.setpoint_c()),
            cooler_on: if self.facts.has_cooling {
                cooling.map_or(self.core.cooler().enabled, |c| Some(c.is_cooling()))
            } else {
                Some(false)
            },
            gain: self.core.gain,
            offset: self.core.offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }
}

/// Sensor 1 is the sensor temperature, in hundredths of a degree (INDI and
/// NINA read it the same way).
fn sensor_temperature(sdk: &AtikSdk, handle: ArtemisHandle) -> Option<f64> {
    let mut temp: c_int = 0;
    // SAFETY: `temp` is a valid out-pointer; the handle is open and the lock is held.
    (unsafe { (sdk.temperature_sensor_info)(handle, 1, &mut temp) } == ArtemisError::Ok as c_int)
        .then(|| f64::from(temp) / 100.0)
}

#[async_trait]
impl CameraDriver for AtikCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;
        let sdk = AtikSdk::lock().await?;
        self.status(&sdk)
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let deadline = std::time::Instant::now() + IDLE_WAIT;
        loop {
            {
                let sdk = AtikSdk::lock().await?;
                if self.ready_to_expose(&sdk)? {
                    return self.begin_exposure(&sdk, &params);
                }
            }
            if std::time::Instant::now() >= deadline {
                return Err(DriverError::Timeout(format!(
                    "Atik camera '{}' was still busy {} s after the last exposure",
                    self.core.name,
                    IDLE_WAIT.as_secs()
                )));
            }
            tokio::time::sleep(IDLE_POLL).await;
        }
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = AtikSdk::lock().await?;
        // SAFETY: the handle is open and the lock is held.
        let result = unsafe { (sdk.abort_exposure)(self.handle()) };
        check_artemis_error(result, "abort the exposure")?;
        self.core.state = CameraState::Idle;
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.core.require_connected()?;
        let sdk = AtikSdk::lock().await?;
        self.exposure_done(&sdk)
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.core.require_connected()?;
        let sdk = AtikSdk::lock().await?;
        self.take_frame(&sdk)
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

        // ArtemisSetCooling *is* the enable on this SDK, so cooling needs a
        // setpoint; when the caller names none, the one this connection last
        // set, never an invented temperature. Switching off goes through
        // ArtemisCoolerWarmUp and needs no setpoint at all.
        let setpoint_c = if enabled {
            Some(target_temp.or(self.core.cooler().target_c).ok_or_else(|| {
                DriverError::InvalidParameter(format!(
                    "Atik camera '{}' needs a target temperature to cool",
                    self.core.name
                ))
            })?)
        } else {
            None
        };

        if let Some(target) = setpoint_c {
            let quirk_lookup_id = format!("native:atik:{}", self.core.name);
            if let Some((min_temp, max_temp)) = crate::quirks::get_cooler_range(&quirk_lookup_id) {
                if target < min_temp || target > max_temp {
                    return Err(DriverError::InvalidParameter(format!(
                        "Atik cooler target {target}C is outside the supported range {min_temp}C..={max_temp}C for {}",
                        self.core.name
                    )));
                }
            }
        }

        let sdk = AtikSdk::lock().await?;
        let handle = self.handle();
        if let Some(target) = setpoint_c {
            // SAFETY: the handle is open and the lock is held; hundredths of a degree.
            let result = unsafe { (sdk.set_cooling)(handle, (target * 100.0).round() as c_int) };
            check_artemis_error(result, &format!("cool to {target} C"))?;
        } else {
            // SAFETY: the handle is open and the lock is held.
            let result = unsafe { (sdk.cooler_warm_up)(handle) };
            check_artemis_error(result, "warm up the cooler")?;
        }

        self.core.update_cooler(|cooler| {
            cooler.enabled = Some(enabled);
            if let Some(target) = setpoint_c {
                cooler.target_c = Some(target);
            }
        });
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        let sdk = AtikSdk::lock().await?;
        let mut temp: c_int = 0;
        // SAFETY: `temp` is a valid out-pointer; the handle is open and the lock is held.
        let result = unsafe { (sdk.temperature_sensor_info)(self.handle(), 1, &mut temp) };
        check_artemis_error(result, "read the sensor temperature")?;
        Ok(f64::from(temp) / 100.0)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        if !self.facts.has_cooling {
            return Err(DriverError::NotSupported);
        }
        let sdk = AtikSdk::lock().await?;
        let cooling = cooling_info(&sdk, self.handle())
            .ok_or_else(|| DriverError::SdkError("could not read the Atik cooler".to_string()))?;
        Ok(cooling.power_percent().unwrap_or(0.0))
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if !self.facts.gain.takes(false) {
            return Err(DriverError::NotSupported);
        }
        let sdk = AtikSdk::lock().await?;
        self.apply_gain(&sdk, gain, false)
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(self.core.gain)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if !self.facts.gain.takes(true) {
            return Err(DriverError::NotSupported);
        }
        let sdk = AtikSdk::lock().await?;
        self.apply_gain(&sdk, offset, true)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(self.core.offset)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = AtikSdk::lock().await?;
        self.apply_binning(&sdk, bin_x, bin_y)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = AtikSdk::lock().await?;
        self.apply_subframe(&sdk, subframe)
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
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

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        self.facts
            .gain
            .gain_range()
            .ok_or(DriverError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        self.facts
            .gain
            .offset_range()
            .ok_or(DriverError::NotSupported)
    }
}
