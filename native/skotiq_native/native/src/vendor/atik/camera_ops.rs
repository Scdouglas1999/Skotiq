//! `NativeCamera` implementation for `AtikCamera`.

use super::*;

#[async_trait]
impl NativeCamera for AtikCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Get temperature
        let sensor_temp = {
            let mut temp: c_int = 0;
            // Sensor 1 is the CCD temperature
            // SAFETY: atik_mutex held; self.connected was true (checked above); handle is valid;
            // `temp` is a valid stack pointer. Sensor index 1 is documented as CCD temperature.
            if unsafe { (sdk.temperature_sensor_info)(handle, 1, &mut temp) } == 0 {
                Some(temp as f64 / 100.0)
            } else {
                None
            }
        };

        // Get cooler info
        let (cooler_power, target_temp) = if self.capabilities.can_cool {
            let mut flags: c_int = 0;
            let mut level: c_int = 0;
            let mut minlvl: c_int = 0;
            let mut maxlvl: c_int = 0;
            let mut setpoint: c_int = 0;
            // SAFETY: atik_mutex held; handle is valid (connected=true); all five out-pointers
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
        let exposure_remaining = if self.state == CameraState::Exposing {
            // SAFETY: atik_mutex held; handle is valid (connected=true); ArtemisExposureTimeRemaining
            // takes only the handle and returns a c_float by value.
            let remaining = unsafe { (sdk.exposure_time_remaining)(handle) };
            Some(remaining as f64)
        } else {
            None
        };

        Ok(CameraStatus {
            state: self.state,
            sensor_temp,
            cooler_power,
            target_temp,
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
        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let dark_mode = if params.frame_type.opens_shutter() {
            0
        } else {
            1
        };
        // Dark, bias, and dark-flat frames must keep a mechanical shutter closed.
        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // ArtemisSetDarkMode takes pass-by-value c_int with no out-pointers.
        let result = unsafe { (sdk.set_dark_mode)(handle, dark_mode) };
        check_artemis_error(result, "set dark mode")?;

        // Start exposure
        // SAFETY: atik_mutex held; handle is valid (connected=true); duration is pass-by-value
        // c_float — the SDK validates the duration internally and returns an ArtemisError on
        // out-of-range values.
        let result = unsafe { (sdk.start_exposure)(handle, params.duration_secs as c_float) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("start exposure"));
        }

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
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // ArtemisAbortExposure takes only the handle.
        let result = unsafe { (sdk.abort_exposure)(handle) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("abort exposure"));
        }

        self.state = CameraState::Idle;
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // ArtemisImageReady takes only the handle and returns a c_int flag.
        let ready = unsafe { (sdk.image_ready)(handle) };
        Ok(ready != 0)
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        self.state = CameraState::Downloading;

        // Get image info
        let mut x: c_int = 0;
        let mut y: c_int = 0;
        let mut w: c_int = 0;
        let mut h: c_int = 0;
        let mut binx: c_int = 0;
        let mut biny: c_int = 0;

        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // all six out-pointers are valid stack pointers to c_int.
        let result = unsafe {
            (sdk.get_image_data)(handle, &mut x, &mut y, &mut w, &mut h, &mut binx, &mut biny)
        };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            self.state = CameraState::Error;
            return Err(ArtemisError::from_i32(result).to_native_error("get image data"));
        }

        // Get image buffer
        // SAFETY: atik_mutex held; handle is valid (connected=true); ArtemisImageBuffer returns
        // a pointer to the SDK-owned image buffer (we null-check immediately below).
        let buffer_ptr = unsafe { (sdk.image_buffer)(handle) };
        if buffer_ptr.is_null() {
            tracing::error!(
                "Atik ArtemisImageBuffer() returned NULL for camera '{}'. Image: {}x{}, bin: {}x{}",
                self.name,
                w,
                h,
                binx,
                biny
            );
            self.state = CameraState::Error;
            return Err(NativeError::SdkError(format!(
                "Image buffer is NULL on Atik camera '{}'. Image download failed after successful exposure.",
                self.name
            )));
        }

        // Copy image data (16-bit, little-endian on the wire).
        // Why: `w` / `h` are c_int (i32). A negative value here means ArtemisGetImageData
        // returned success but populated junk dimensions — fail fast instead of casting a
        // negative i32 to a giant usize (which would later trip pool allocation).
        let w_usize = usize::try_from(w).map_err(|_| {
            NativeError::SdkError(format!("Atik returned non-positive image width: {}", w))
        })?;
        let h_usize = usize::try_from(h).map_err(|_| {
            NativeError::SdkError(format!("Atik returned non-positive image height: {}", h))
        })?;
        let pixel_count = w_usize
            .checked_mul(h_usize)
            .ok_or_else(|| NativeError::SdkError("Atik image dimensions overflow usize".into()))?;
        let byte_count = pixel_count
            .checked_mul(2)
            .ok_or_else(|| NativeError::SdkError("Atik image dimensions overflow usize".into()))?;
        // Why: ArtemisImageBuffer() returns *mut c_void with pixel_count * 2 valid bytes,
        // but Artemis does not guarantee u16 alignment of that pointer. Reading through
        // *const u16 would be UB on archs that trap unaligned loads (and is technically UB
        // even on x86). We take the buffer as bytes and decode each pixel via from_le_bytes,
        // which is well-defined regardless of source alignment and pins the SDK's documented
        // little-endian framing.
        // SAFETY: buffer_ptr is non-null (verified above), atik_mutex held so the SDK won't
        // mutate the buffer concurrently, and byte_count = w*h*2 matches the SDK's documented
        // buffer size for ArtemisImageBuffer (pixel_count * sizeof(u16) bytes). We read as
        // bytes to avoid alignment UB — see the Why comment above. The slice's lifetime is
        // scoped to this block and the buffer remains owned by the SDK after we copy.
        let byte_slice = unsafe { std::slice::from_raw_parts(buffer_ptr as *const u8, byte_count) };
        let data: Vec<u16> = byte_slice
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
            .collect();

        // Get temperature for metadata
        let temperature = {
            let mut temp: c_int = 0;
            // SAFETY: atik_mutex held; handle is valid (connected=true); `temp` is a valid stack
            // pointer; sensor index 1 is the documented CCD temperature sensor.
            if unsafe { (sdk.temperature_sensor_info)(handle, 1, &mut temp) } == 0 {
                Some(temp as f64 / 100.0)
            } else {
                None
            }
        };

        let metadata = ImageMetadata {
            exposure_time: self.exposure_duration,
            gain: self.current_gain,
            offset: self.current_offset,
            bin_x: binx,
            bin_y: biny,
            temperature,
            timestamp: chrono::Utc::now(),
            subframe: self.subframe.clone(),
            readout_mode: None,
            vendor_data: VendorFeatures::default(),
        };

        self.state = CameraState::Idle;

        // Why: w/h were validated non-negative via the TryFrom::<i32> -> usize above; that
        // checks i32 < 0 which is the only path producing a wrap. usize -> u32 needs a second
        // check because on 64-bit hosts usize is wider than u32; we surface overflow rather
        // than truncating an absurd dimension. Real Atik sensors top out under 16k pixels.
        let width_u32 = u32::try_from(w_usize).map_err(|_| {
            NativeError::SdkError(format!("Atik image width does not fit in u32: {}", w_usize))
        })?;
        let height_u32 = u32::try_from(h_usize).map_err(|_| {
            NativeError::SdkError(format!(
                "Atik image height does not fit in u32: {}",
                h_usize
            ))
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
        if !self.capabilities.can_cool {
            return Err(NativeError::NotSupported);
        }

        // ArtemisSetCooling *is* the enable on this SDK, so cooling needs a
        // setpoint; when the caller names none we reuse the one this driver
        // already holds rather than inventing a temperature. Switching off
        // goes through ArtemisCoolerWarmUp and needs no setpoint at all.
        let setpoint_c = if enabled {
            Some(target_temp.unwrap_or(self.target_temp))
        } else {
            None
        };

        if let Some(target) = setpoint_c {
            let quirk_lookup_id = format!("native:atik:{}", self.name);
            if let Some((min_temp, max_temp)) = crate::quirks::get_cooler_range(&quirk_lookup_id) {
                if target < min_temp || target > max_temp {
                    return Err(NativeError::InvalidParameter(format!(
                        "Atik cooler target {target}C is outside the supported range {min_temp}C..={max_temp}C for {}",
                        self.name
                    )));
                }
            }
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        if let Some(target) = setpoint_c {
            // Temperature in hundredths of degrees
            let setpoint = (target * 100.0) as c_int;
            // SAFETY: atik_mutex held; self.connected and can_cool checked at entry; handle is
            // valid; setpoint is pass-by-value c_int (hundredths of degrees per AtikCameras.h).
            let result = unsafe { (sdk.set_cooling)(handle, setpoint) };
            if ArtemisError::from_i32(result) != ArtemisError::Ok {
                return Err(ArtemisError::from_i32(result).to_native_error("set cooling"));
            }
        } else {
            // SAFETY: atik_mutex held; handle is valid (connected=true); ArtemisCoolerWarmUp
            // takes only the handle.
            let result = unsafe { (sdk.cooler_warm_up)(handle) };
            if ArtemisError::from_i32(result) != ArtemisError::Ok {
                return Err(ArtemisError::from_i32(result).to_native_error("warm up cooler"));
            }
        }

        self.cooler_on = enabled;
        if let Some(target) = setpoint_c {
            self.target_temp = target;
        }
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        let mut temp: c_int = 0;

        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // sensor index 1 is the documented CCD temperature sensor; `temp` is a valid stack pointer.
        let result = unsafe { (sdk.temperature_sensor_info)(handle, 1, &mut temp) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("get temperature"));
        }

        Ok(temp as f64 / 100.0)
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        if !self.capabilities.can_cool {
            return Err(NativeError::NotSupported);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        let mut flags: c_int = 0;
        let mut level: c_int = 0;
        let mut minlvl: c_int = 0;
        let mut maxlvl: c_int = 0;
        let mut setpoint: c_int = 0;

        // SAFETY: atik_mutex held; self.connected and can_cool both checked at entry; handle is
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

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // preview=0 is a valid mode constant; gain/offset are pass-by-value c_int.
        let result =
            unsafe { (sdk.set_gain)(handle, 0, gain as c_int, self.current_offset as c_int) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set gain"));
        }

        self.current_gain = gain;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        Ok(self.current_gain)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // preview=0 is a valid mode constant; gain/offset are pass-by-value c_int. Atik SDK
        // sets gain and offset together via ArtemisSetGain.
        let result =
            unsafe { (sdk.set_gain)(handle, 0, self.current_gain as c_int, offset as c_int) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set offset"));
        }

        self.current_offset = offset;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        Ok(self.current_offset)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if bin_x > self.capabilities.max_bin_x || bin_y > self.capabilities.max_bin_y {
            return Err(NativeError::InvalidParameter(format!(
                "Binning {}x{} exceeds max {}x{}",
                bin_x, bin_y, self.capabilities.max_bin_x, self.capabilities.max_bin_y
            )));
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // bin_x/bin_y bounds were checked against capabilities.max_bin_{x,y} above.
        let result = unsafe { (sdk.bin)(handle, bin_x as c_int, bin_y as c_int) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set binning"));
        }

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
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Why: SubFrame fields are u32 (sensor coordinates) and we need c_int (i32) for the
        // Atik SDK. A u32 > i32::MAX would mean the caller asked for a subframe larger than
        // 2 GPixels in one dimension; reject it instead of wrapping into a negative c_int.
        // current_bin_{x,y} are i32 validated at set_binning() >= 1.
        let (x, y, w, h) = match &subframe {
            Some(sf) => (
                c_int::try_from(sf.start_x).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "Atik subframe start_x exceeds i32: {}",
                        sf.start_x
                    ))
                })?,
                c_int::try_from(sf.start_y).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "Atik subframe start_y exceeds i32: {}",
                        sf.start_y
                    ))
                })?,
                c_int::try_from(sf.width).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "Atik subframe width exceeds i32: {}",
                        sf.width
                    ))
                })?,
                c_int::try_from(sf.height).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "Atik subframe height exceeds i32: {}",
                        sf.height
                    ))
                })?,
            ),
            None => {
                // Why: bin >= 1 per set_binning() guard; sensor_info.width/height are u32. We
                // try_into u32 first (current_bin_x is i32, so a corrupt negative bin would
                // wrap), then convert the binned dim back to c_int.
                let bin_x_u32 = u32::try_from(self.current_bin_x).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "Atik current_bin_x not representable as u32: {}",
                        self.current_bin_x
                    ))
                })?;
                let bin_y_u32 = u32::try_from(self.current_bin_y).map_err(|_| {
                    NativeError::InvalidParameter(format!(
                        "Atik current_bin_y not representable as u32: {}",
                        self.current_bin_y
                    ))
                })?;
                let binned_w = self.sensor_info.width / bin_x_u32.max(1);
                let binned_h = self.sensor_info.height / bin_y_u32.max(1);
                let w_ci = c_int::try_from(binned_w).map_err(|_| {
                    NativeError::SdkError(format!(
                        "Atik binned width does not fit in c_int: {}",
                        binned_w
                    ))
                })?;
                let h_ci = c_int::try_from(binned_h).map_err(|_| {
                    NativeError::SdkError(format!(
                        "Atik binned height does not fit in c_int: {}",
                        binned_h
                    ))
                })?;
                (0, 0, w_ci, h_ci)
            }
        };

        // SAFETY: atik_mutex held; self.connected was true (checked at entry); handle is valid;
        // x/y/w/h are computed from the user-provided subframe or from sensor_info / current
        // binning above — both branches produce in-sensor coordinates the SDK can clip.
        let result = unsafe { (sdk.subframe)(handle, x, y, w, h) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            return Err(ArtemisError::from_i32(result).to_native_error("set subframe"));
        }

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

        // The Atik SDK publishes no gain bounds, and a fixed-gain CCD has none to
        // publish; report the absence rather than a range the hardware never stated.
        Err(NativeError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // Same as gain: the SDK reports no offset bounds.
        Err(NativeError::NotSupported)
    }
}
