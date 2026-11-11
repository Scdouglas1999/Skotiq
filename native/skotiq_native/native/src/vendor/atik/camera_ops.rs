//! `CameraDriver` implementation for `AtikCamera`.

use super::*;

#[async_trait]
impl CameraDriver for AtikCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Get temperature
        let sensor_temp = {
            let mut temp: c_int = 0;
            // Sensor 1 is the CCD temperature
            // SAFETY: self.core.connected was true (checked above); handle is valid;
            // `temp` is a valid stack pointer. Sensor index 1 is documented as CCD temperature.
            if unsafe { (sdk.temperature_sensor_info)(handle, 1, &mut temp) } == 0 {
                Some(temp as f64 / 100.0)
            } else {
                None
            }
        };

        // Get cooler info
        let (cooler_power, target_temp) = if self.core.capabilities.can_cool {
            let mut flags: c_int = 0;
            let mut level: c_int = 0;
            let mut minlvl: c_int = 0;
            let mut maxlvl: c_int = 0;
            let mut setpoint: c_int = 0;
            // SAFETY: handle is valid (connected=true); all five out-pointers
            // are valid stack pointers to c_int.
            if unsafe {
                (sdk.cooling_info)(
                    handle,
                    &mut flags,
                    &mut level,
                    &mut minlvl,
                    &mut maxlvl,
                    &mut setpoint,
                )
            } == 0
            {
                let power = if maxlvl > 0 {
                    Some((level as f64 / maxlvl as f64) * 100.0)
                } else {
                    None
                };
                let target = Some(setpoint as f64 / 100.0);
                (power, target)
            } else {
                (None, None)
            }
        } else {
            (None, None)
        };

        // Get exposure remaining
        let exposure_remaining = if self.core.state == CameraState::Exposing {
            // SAFETY: handle is valid (connected=true); ArtemisExposureTimeRemaining
            // takes only the handle and returns a c_float by value.
            let remaining = unsafe { (sdk.exposure_time_remaining)(handle) };
            Some(remaining as f64)
        } else {
            None
        };

        Ok(CameraStatus {
            state: self.core.state,
            sensor_temp,
            cooler_power,
            target_temp,
            cooler_on: self.core.cooler.enabled,
            gain: self.core.gain,
            offset: self.core.offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // Set gain if provided
        if let Some(gain) = params.gain {
            self.set_gain(gain).await?;
        }

        // Set offset if provided
        if let Some(offset) = params.offset {
            self.set_offset(offset).await?;
        }

        // Set binning
        self.set_binning(params.bin_x, params.bin_y).await?;

        // Set subframe
        self.set_subframe(params.subframe.clone()).await?;

        // Now get SDK and handle after all awaits are complete
        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let dark_mode = if params.frame_type.opens_shutter() {
            0
        } else {
            1
        };
        // Dark, bias, and dark-flat frames must keep a mechanical shutter closed.
        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // ArtemisSetDarkMode takes pass-by-value c_int with no out-pointers.
        let result = unsafe { (sdk.set_dark_mode)(handle, dark_mode) };
        check_artemis_error(result, "set dark mode")?;

        // Start exposure
        // SAFETY: handle is valid (connected=true); duration is pass-by-value
        // c_float — the SDK validates the duration internally and returns an ArtemisError on
        // out-of-range values.
        let result = unsafe { (sdk.start_exposure)(handle, params.duration_secs as c_float) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("start exposure"));
        }

        self.core.exposure_duration = params.duration_secs;
        self.core.state = CameraState::Exposing;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // ArtemisAbortExposure takes only the handle.
        let result = unsafe { (sdk.abort_exposure)(handle) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("abort exposure"));
        }

        self.core.state = CameraState::Idle;
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // ArtemisImageReady takes only the handle and returns a c_int flag.
        let ready = unsafe { (sdk.image_ready)(handle) };
        Ok(ready != 0)
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        self.core.state = CameraState::Downloading;

        // Get image info
        let mut x: c_int = 0;
        let mut y: c_int = 0;
        let mut w: c_int = 0;
        let mut h: c_int = 0;
        let mut binx: c_int = 0;
        let mut biny: c_int = 0;

        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // all six out-pointers are valid stack pointers to c_int.
        let result = unsafe {
            (sdk.get_image_data)(handle, &mut x, &mut y, &mut w, &mut h, &mut binx, &mut biny)
        };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            self.core.state = CameraState::Error;
            return Err(ArtemisError::from_i32(result).to_native_error("get image data"));
        }

        // Get image buffer
        // SAFETY: handle is valid (connected=true); ArtemisImageBuffer returns
        // a pointer to the SDK-owned image buffer (we null-check immediately below).
        let buffer_ptr = unsafe { (sdk.image_buffer)(handle) };
        if buffer_ptr.is_null() {
            tracing::error!(
                "Atik ArtemisImageBuffer() returned NULL for camera '{}'. Image: {}x{}, bin: {}x{}",
                self.core.name,
                w,
                h,
                binx,
                biny
            );
            self.core.state = CameraState::Error;
            return Err(DriverError::SdkError(format!(
                "Image buffer is NULL on Atik camera '{}'. Image download failed after successful exposure.",
                self.core.name
            )));
        }

        // Copy image data (16-bit, little-endian on the wire).
        // Why: `w` / `h` are c_int (i32). A negative value here means ArtemisGetImageData
        // returned success but populated junk dimensions — fail fast instead of casting a
        // negative i32 to a giant usize (which would later trip pool allocation).
        let w_usize = usize::try_from(w).map_err(|_| {
            DriverError::SdkError(format!("Atik returned non-positive image width: {}", w))
        })?;
        let h_usize = usize::try_from(h).map_err(|_| {
            DriverError::SdkError(format!("Atik returned non-positive image height: {}", h))
        })?;
        let pixel_count = w_usize
            .checked_mul(h_usize)
            .ok_or_else(|| DriverError::SdkError("Atik image dimensions overflow usize".into()))?;
        let byte_count = pixel_count
            .checked_mul(2)
            .ok_or_else(|| DriverError::SdkError("Atik image dimensions overflow usize".into()))?;
        // Why: ArtemisImageBuffer() returns *mut c_void with pixel_count * 2 valid bytes,
        // but Artemis does not guarantee u16 alignment of that pointer. Reading through
        // *const u16 would be UB on archs that trap unaligned loads (and is technically UB
        // even on x86). We take the buffer as bytes and decode each pixel via from_le_bytes,
        // which is well-defined regardless of source alignment and pins the SDK's documented
        // little-endian framing.
        // SAFETY: buffer_ptr is non-null (verified above), the Atik SDK guard is held so the SDK won't
        // mutate the buffer concurrently, and byte_count = w*h*2 matches the SDK's documented
        // buffer size for ArtemisImageBuffer (pixel_count * sizeof(u16) bytes). We read as
        // bytes to avoid alignment UB — see the Why comment above. The slice's lifetime is
        // scoped to this block and the buffer remains owned by the SDK after we copy.
        let byte_slice = unsafe { std::slice::from_raw_parts(buffer_ptr as *const u8, byte_count) };
        let data = unpack_samples(byte_slice, SampleLayout::U16Little);

        // Get temperature for metadata
        let temperature = {
            let mut temp: c_int = 0;
            // SAFETY: handle is valid (connected=true); `temp` is a valid stack
            // pointer; sensor index 1 is the documented CCD temperature sensor.
            if unsafe { (sdk.temperature_sensor_info)(handle, 1, &mut temp) } == 0 {
                Some(temp as f64 / 100.0)
            } else {
                None
            }
        };

        self.core.state = CameraState::Idle;

        // w/h were checked non-negative above; usize is wider than u32 on 64-bit hosts.
        let width = image_dimension("Atik", "width", w_usize)?;
        let height = image_dimension("Atik", "height", h_usize)?;
        // Binning in the metadata is what ArtemisGetImageData reported for this frame.
        Ok(Frame {
            bin_x: binx,
            bin_y: biny,
            temperature,
            ..self.core.frame(
                width,
                height,
                data,
                self.core.sensor_info.bit_depth,
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

        // ArtemisSetCooling *is* the enable on this SDK, so cooling needs a
        // setpoint; when the caller names none we reuse the one this driver
        // already holds rather than inventing a temperature. Switching off
        // goes through ArtemisCoolerWarmUp and needs no setpoint at all.
        let setpoint_c = if enabled {
            Some(target_temp.unwrap_or(self.core.cooler.target_c))
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

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        if let Some(target) = setpoint_c {
            // Temperature in hundredths of degrees
            let setpoint = (target * 100.0) as c_int;
            // SAFETY: self.core.connected and can_cool checked at entry; handle is
            // valid; setpoint is pass-by-value c_int (hundredths of degrees per AtikCameras.h).
            let result = unsafe { (sdk.set_cooling)(handle, setpoint) };
            if ArtemisError::from_i32(result) != ArtemisError::Ok {
                return Err(ArtemisError::from_i32(result).to_native_error("set cooling"));
            }
        } else {
            // SAFETY: handle is valid (connected=true); ArtemisCoolerWarmUp
            // takes only the handle.
            let result = unsafe { (sdk.cooler_warm_up)(handle) };
            if ArtemisError::from_i32(result) != ArtemisError::Ok {
                return Err(ArtemisError::from_i32(result).to_native_error("warm up cooler"));
            }
        }

        self.core.cooler.enabled = enabled;
        if let Some(target) = setpoint_c {
            self.core.cooler.target_c = target;
        }
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        let mut temp: c_int = 0;

        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // sensor index 1 is the documented CCD temperature sensor; `temp` is a valid stack pointer.
        let result = unsafe { (sdk.temperature_sensor_info)(handle, 1, &mut temp) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("get temperature"));
        }

        Ok(temp as f64 / 100.0)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        let mut flags: c_int = 0;
        let mut level: c_int = 0;
        let mut minlvl: c_int = 0;
        let mut maxlvl: c_int = 0;
        let mut setpoint: c_int = 0;

        // SAFETY: self.core.connected and can_cool both checked at entry; handle is
        // valid; all five out-pointers are valid stack pointers to c_int.
        let result = unsafe {
            (sdk.cooling_info)(
                handle,
                &mut flags,
                &mut level,
                &mut minlvl,
                &mut maxlvl,
                &mut setpoint,
            )
        };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("get cooler power"));
        }

        if maxlvl > 0 {
            Ok((level as f64 / maxlvl as f64) * 100.0)
        } else {
            Ok(0.0)
        }
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // preview=0 is a valid mode constant; gain/offset are pass-by-value c_int.
        let result = unsafe { (sdk.set_gain)(handle, 0, gain as c_int, self.core.offset as c_int) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set gain"));
        }

        self.core.gain = gain;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(self.core.gain)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // preview=0 is a valid mode constant; gain/offset are pass-by-value c_int. Atik SDK
        // sets gain and offset together via ArtemisSetGain.
        let result = unsafe { (sdk.set_gain)(handle, 0, self.core.gain as c_int, offset as c_int) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set offset"));
        }

        self.core.offset = offset;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(self.core.offset)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;

        if bin_x > self.core.capabilities.max_bin_x || bin_y > self.core.capabilities.max_bin_y {
            return Err(DriverError::InvalidParameter(format!(
                "Binning {}x{} exceeds max {}x{}",
                bin_x, bin_y, self.core.capabilities.max_bin_x, self.core.capabilities.max_bin_y
            )));
        }

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // bin_x/bin_y bounds were checked against capabilities.max_bin_{x,y} above.
        let result = unsafe { (sdk.bin)(handle, bin_x as c_int, bin_y as c_int) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set binning"));
        }

        self.core.bin_x = bin_x;
        self.core.bin_y = bin_y;
        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // Acquire global SDK mutex for thread safety
        let sdk = AtikSdk::lock().await?;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Why: SubFrame fields are u32 (sensor coordinates) and we need c_int (i32) for the
        // Atik SDK. A u32 > i32::MAX would mean the caller asked for a subframe larger than
        // 2 GPixels in one dimension; reject it instead of wrapping into a negative c_int.
        // current_bin_{x,y} are i32 validated at set_binning() >= 1.
        let (x, y, w, h) = match &subframe {
            Some(sf) => (
                c_int::try_from(sf.start_x).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "Atik subframe start_x exceeds i32: {}",
                        sf.start_x
                    ))
                })?,
                c_int::try_from(sf.start_y).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "Atik subframe start_y exceeds i32: {}",
                        sf.start_y
                    ))
                })?,
                c_int::try_from(sf.width).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "Atik subframe width exceeds i32: {}",
                        sf.width
                    ))
                })?,
                c_int::try_from(sf.height).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "Atik subframe height exceeds i32: {}",
                        sf.height
                    ))
                })?,
            ),
            None => {
                // Why: bin >= 1 per set_binning() guard; sensor_info.width/height are u32. We
                // try_into u32 first (current_bin_x is i32, so a corrupt negative bin would
                // wrap), then convert the binned dim back to c_int.
                let bin_x_u32 = u32::try_from(self.core.bin_x).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "Atik current_bin_x not representable as u32: {}",
                        self.core.bin_x
                    ))
                })?;
                let bin_y_u32 = u32::try_from(self.core.bin_y).map_err(|_| {
                    DriverError::InvalidParameter(format!(
                        "Atik current_bin_y not representable as u32: {}",
                        self.core.bin_y
                    ))
                })?;
                let binned_w = self.core.sensor_info.width / bin_x_u32.max(1);
                let binned_h = self.core.sensor_info.height / bin_y_u32.max(1);
                let w_ci = c_int::try_from(binned_w).map_err(|_| {
                    DriverError::SdkError(format!(
                        "Atik binned width does not fit in c_int: {}",
                        binned_w
                    ))
                })?;
                let h_ci = c_int::try_from(binned_h).map_err(|_| {
                    DriverError::SdkError(format!(
                        "Atik binned height does not fit in c_int: {}",
                        binned_h
                    ))
                })?;
                (0, 0, w_ci, h_ci)
            }
        };

        // SAFETY: self.core.connected was true (checked at entry); handle is valid;
        // x/y/w/h are computed from the user-provided subframe or from sensor_info / current
        // binning above — both branches produce in-sensor coordinates the SDK can clip.
        let result = unsafe { (sdk.subframe)(handle, x, y, w, h) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set subframe"));
        }

        self.core.subframe = subframe;
        Ok(())
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

        // The Atik SDK publishes no gain bounds, and a fixed-gain CCD has none to
        // publish; report the absence rather than a range the hardware never stated.
        Err(DriverError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;

        // Same as gain: the SDK reports no offset bounds.
        Err(DriverError::NotSupported)
    }
}
