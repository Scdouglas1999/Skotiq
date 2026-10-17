//! `NativeDevice` / `NativeCamera` implementations for `FujifilmCamera`.

use super::*;

#[async_trait]
impl NativeDevice for FujifilmCamera {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Fujifilm
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // 1. Initialize SDK
        // SAFETY: fujifilm_mutex held above (in connect()); XSDK_Init accepts a NULL reserved-parameter per XAPI.h. May return XSDK_ERRCODE_LOADLIB if already initialized — handled below.
        let result = unsafe { (sdk.init)(std::ptr::null_mut()) };
        if result != XSDK_COMPLETE {
            let mut api_code: c_long = 0;
            let mut err_code: c_long = 0;
            // SAFETY: fujifilm_mutex held; XSDK_GetErrorNumber accepts NULL for the handle when retrieving the last init-time error per XAPI.h; out-pointers reference valid c_long stack locals.
            unsafe { (sdk.get_error_number)(std::ptr::null_mut(), &mut api_code, &mut err_code) };
            if err_code != XSDK_ERRCODE_LOADLIB {
                return Err(NativeError::SdkError(format!(
                    "XSDK_Init failed: 0x{:08X}",
                    err_code
                )));
            }
        }

        // 2. Open connection (using blocking sleep to avoid raw pointer across await)
        let serial_cstr = CString::new(self.serial_number.clone())
            .map_err(|_| NativeError::InvalidParameter("Invalid serial number".into()))?;

        let camera_handle = {
            let mut handle: XsdkHandle = std::ptr::null_mut();
            let mut camera_mode: c_long = 0;

            for attempt in 1..=3 {
                // SAFETY: fujifilm_mutex held above; `serial_cstr.as_ptr()` is a non-null pointer to a NUL-terminated CString owned by `serial_cstr` for the duration of this loop iteration; `&mut handle` and `&mut camera_mode` are valid stack out-pointers; the trailing NULL is the documented "use defaults for options" sentinel per XAPI.h.
                let result = unsafe {
                    (sdk.open_ex)(
                        serial_cstr.as_ptr(),
                        &mut handle,
                        &mut camera_mode,
                        std::ptr::null_mut(),
                    )
                };
                if result == XSDK_COMPLETE {
                    break;
                }
                if attempt == 3 {
                    return Err(NativeError::SdkError(
                        "XSDK_OpenEx failed after 3 attempts".into(),
                    ));
                }
                // Use blocking sleep here to avoid raw pointer across await
                std::thread::sleep(Duration::from_millis(100 * (1 << attempt)));
            }
            handle
        };
        self.camera_handle = HandleWrapper(camera_handle);

        // 3. Set PC priority mode
        // SAFETY: fujifilm_mutex held; `camera_handle` was just opened via XSDK_OpenEx above (XSDK_COMPLETE was checked); XSDK_SetPriorityMode takes (handle, c_long) POD per XAPI.h. XSDK_PRIORITY_PC is the documented constant for granting PC exclusive control.
        unsafe { (sdk.set_priority_mode)(camera_handle, XSDK_PRIORITY_PC) };
        std::thread::sleep(Duration::from_millis(100));

        // 4. CRITICAL: Set dynamic range to 100 BEFORE ISO operations
        // SAFETY: fujifilm_mutex held; `camera_handle` valid; XSDK_SetDynamicRange takes (handle, c_long) POD per XAPI.h. Must precede ISO operations per the module header's "Important SDK Behaviors" §1.
        unsafe { (sdk.set_dynamic_range)(camera_handle, XSDK_DR_100) };
        std::thread::sleep(Duration::from_millis(100));

        // 5. Query device information
        let mut dev_info = XsdkDeviceInformation::default();
        // SAFETY: fujifilm_mutex held; `camera_handle` valid; `&mut dev_info` is a valid stack out-pointer to a `#[repr(C, packed)]` XsdkDeviceInformation that the SDK populates. We use `cstr_to_string` helpers to read packed [c_char; N] fields via slice references (avoiding misaligned pointer reads).
        unsafe { (sdk.get_device_info)(camera_handle, &mut dev_info) };
        self.firmware_version = cstr_to_string(&dev_info.str_firmware);

        // Update model from actual device info
        let actual_name = cstr_to_string(&dev_info.str_product);
        if !actual_name.is_empty() {
            self.model = FujifilmModel::from_product_name(&actual_name);
            // Depth deliberately dropped here: `refresh_raw_depth` below picks
            // it from the highest-authority source available.
            let (width, height, pixel_size, _) = self.model.sensor_specs();
            self.sensor_info.width = width;
            self.sensor_info.height = height;
            self.sensor_info.pixel_size_x = pixel_size;
            self.sensor_info.pixel_size_y = pixel_size;
        }

        // 5b. Ask the body which RAW output depth it is set to. A GFX switched
        //     to SDK_RAWOUTPUTDEPTH_16BIT (XAPIOpt.H:585) delivers samples that
        //     reach 65535, four times the model table's 16383 estimate, and a
        //     max_adu that low makes every such frame look saturated. Only the
        //     bodies whose capability header declares support are asked; the
        //     rest answer XSDK_ERRCODE_API_NOTFOUND, and we keep the estimate.
        if self.model.supports_16bit_raw() {
            let mut raw_output_depth: c_long = 0;
            // SAFETY: fujifilm_mutex held above (in connect); `camera_handle` was opened via XSDK_OpenEx earlier in this function; `&mut raw_output_depth` is a valid stack out-pointer to a c_long. The `API_CODE_GetRAWOutputDepth` variant of XSDK_GetProp takes a single c_long out-pointer, the same shape as the `API_CODE_GET_FOCUS_POS` call in `get_focus_position`.
            let result = unsafe {
                (sdk.get_prop)(
                    camera_handle,
                    API_CODE_GET_RAW_OUTPUT_DEPTH,
                    0, // lApiParam
                    &mut raw_output_depth,
                )
            };

            if result == XSDK_COMPLETE {
                self.sdk_reported_bit_depth = raw_output_depth_to_bits(raw_output_depth);
                tracing::info!(
                    "Fujifilm: camera reports RAW output depth code {} -> {:?} bits",
                    raw_output_depth,
                    self.sdk_reported_bit_depth
                );
            } else {
                tracing::debug!(
                    "Fujifilm: XSDK_GetProp(GetRAWOutputDepth) returned {}; keeping the model-table depth estimate",
                    result
                );
            }
        }

        self.refresh_raw_depth();

        // 6. Query ISO capabilities
        let mut iso_count: c_long = 0;
        let mut iso_values: [c_long; 64] = [0; 64];
        // SAFETY: fujifilm_mutex held; `camera_handle` valid; `iso_values.as_mut_ptr()` points to a stack array of exactly 64 c_long entries — XSDK_CapSensitivity writes at most that many values and updates `*iso_count` to the actual count per XAPI.h. The 64-entry cap is generous: documented max sensitivity table is ~50 entries.
        unsafe { (sdk.cap_sensitivity)(camera_handle, &mut iso_count, iso_values.as_mut_ptr()) };
        self.supported_isos = iso_values[..iso_count as usize].to_vec();

        // 7. Query shutter speed capabilities
        let mut ss_count: c_long = 0;
        let mut ss_values: [c_long; 128] = [0; 128];
        let mut bulb_capable: c_long = 0;
        // SAFETY: fujifilm_mutex held; `camera_handle` valid; `ss_values.as_mut_ptr()` points to a stack array of exactly 128 c_long entries (XAPI.h max shutter table ~80 entries, 128 is generous); `&mut ss_count` and `&mut bulb_capable` are valid stack out-pointers. SDK writes at most ss_values.len() entries and updates *ss_count.
        unsafe {
            (sdk.cap_shutter_speed)(
                camera_handle,
                &mut ss_count,
                ss_values.as_mut_ptr(),
                &mut bulb_capable,
            )
        };
        self.supports_bulb = bulb_capable != 0;

        // 8. Get current ISO
        let mut current_iso: c_long = 0;
        // SAFETY: fujifilm_mutex held; `camera_handle` valid; `&mut current_iso` is a valid stack out-pointer to c_long; XSDK_GetSensitivity writes the current ISO value per XAPI.h.
        unsafe { (sdk.get_sensitivity)(camera_handle, &mut current_iso) };
        self.current_iso = current_iso as i32;

        self.connected = true;
        tracing::info!(
            "Connected to Fujifilm {} ({})",
            self.name,
            self.firmware_version
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Ok(());
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // Stop any ongoing exposure. We still close the handle if this fails — the
        // handle must be released — but a failed bulb stop means the shutter may be
        // left open on a camera we are about to stop talking to, which the operator
        // has to be told about.
        if self.is_bulb_mode {
            if let Err(e) = self.stop_bulb_exposure().await {
                tracing::error!(
                    "Fujifilm {}: failed to close the bulb shutter before disconnect: {}. The shutter may still be open; power-cycle the camera if the exposure does not end.",
                    self.id,
                    e
                );
            }
        }

        // Close camera connection
        // SAFETY: fujifilm_mutex held above (in disconnect()); `self.camera_handle.0` is the connected XSDK handle (verified by `connected == true` early-return above). XSDK_Close is the contractual release for XSDK_OpenEx per XAPI.h.
        unsafe { (sdk.close)(self.camera_handle.0) };

        self.camera_handle = HandleWrapper(std::ptr::null_mut());
        self.connected = false;
        self.is_exposing = false;
        self.is_bulb_mode = false;

        tracing::info!("Disconnected from Fujifilm {}", self.name);

        Ok(())
    }
}

#[async_trait]
impl NativeCamera for FujifilmCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities {
            can_cool: false,        // No cooling in mirrorless
            can_set_gain: true,     // ISO control
            can_set_offset: false,  // No offset control
            can_set_binning: false, // No binning in DSLR/mirrorless
            can_subframe: false,    // Full sensor only
            has_shutter: true,      // Mechanical shutter
            has_guider_port: false, // No ST-4
            max_bin_x: 1,
            max_bin_y: 1,
            supports_readout_modes: false,
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        let state = if self.is_exposing {
            CameraState::Exposing
        } else {
            CameraState::Idle
        };

        let exposure_remaining = if self.is_exposing {
            self.exposure_start.map(|start| {
                let elapsed = start.elapsed();
                (self.exposure_duration.as_secs_f64() - elapsed.as_secs_f64()).max(0.0)
            })
        } else {
            None
        };

        Ok(CameraStatus {
            state,
            sensor_temp: None,
            cooler_power: None,
            target_temp: None,
            cooler_on: false,
            gain: self.current_iso,
            offset: self.current_offset,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // 1. Set ISO if specified
        if let Some(gain) = params.gain {
            // SAFETY: fujifilm_mutex held above (in start_exposure); `self.camera_handle.0` valid (connected==true was checked); XSDK_SetSensitivity takes (handle, c_long) POD per XAPI.h. The 100ms sleep below honours the module header's "Important SDK Behaviors" §2 settling delay.
            unsafe { (sdk.set_sensitivity)(self.camera_handle.0, gain as c_long) };
            self.current_iso = gain;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        // 2. Determine if bulb mode needed (> 60s)
        if params.duration_secs > 60.0 {
            // Need to drop the lock before calling start_bulb_exposure
            drop(_lock);
            return self.start_bulb_exposure(params.duration_secs).await;
        }

        // 3. Set shutter speed code
        let shutter_code = find_shutter_code(params.duration_secs);
        // SAFETY: fujifilm_mutex held above; `self.camera_handle.0` valid; XSDK_SetShutterSpeed takes (handle, c_long, c_long) POD per XAPI.h. `shutter_code` was looked up via `find_shutter_code` from the known shutter-speed table.
        unsafe { (sdk.set_shutter_speed)(self.camera_handle.0, shutter_code, 0) };
        tokio::time::sleep(Duration::from_millis(100)).await;

        // 4. Trigger capture
        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;
        // SAFETY: fujifilm_mutex held; `self.camera_handle.0` valid; out-pointers reference distinct c_long stack locals; XSDK_RELEASE_SHOOT_S1OFF is the documented "one-shot full-press-and-release" trigger flag from XAPI.h for non-bulb exposures.
        let result = unsafe {
            (sdk.release)(
                self.camera_handle.0,
                XSDK_RELEASE_SHOOT_S1OFF,
                &mut shot_opt,
                &mut af_status,
            )
        };

        if result != XSDK_COMPLETE {
            return check_xapi_error(self.camera_handle.0, sdk);
        }

        self.exposure_start = Some(Instant::now());
        self.exposure_duration = Duration::from_secs_f64(params.duration_secs);
        self.is_exposing = true;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        if self.is_bulb_mode {
            self.stop_bulb_exposure().await?;
        }

        self.is_exposing = false;
        self.exposure_start = None;

        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        if !self.is_exposing {
            return Ok(true);
        }

        if let Some(start) = self.exposure_start {
            Ok(start.elapsed() >= self.exposure_duration)
        } else {
            Ok(true)
        }
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // End bulb if active
        if self.is_bulb_mode {
            // Need to drop the lock temporarily
            drop(_lock);
            self.stop_bulb_exposure().await?;
            let _lock = fujifilm_mutex().lock().await;
        }

        // Poll for image ready (using blocking sleep to avoid packed struct across await)
        let mut img_info = XsdkImageInformation::default();
        for attempt in 1..=30 {
            // SAFETY: fujifilm_mutex held above (in download_image); `self.camera_handle.0` valid; `&mut img_info` is a valid stack out-pointer to a `#[repr(C, packed)]` XsdkImageInformation that the SDK populates per XAPI.h. We copy packed fields into locals (`data_size` on next line) before reading to avoid misaligned-reference UB.
            let result = unsafe { (sdk.read_image_info)(self.camera_handle.0, &mut img_info) };
            // Copy fields from packed struct before checking
            let data_size = img_info.l_data_size;
            if result == XSDK_COMPLETE && data_size > 0 {
                break;
            }
            if attempt == 30 {
                return Err(NativeError::Timeout(
                    "Image not ready after 15 seconds".into(),
                ));
            }
            std::thread::sleep(Duration::from_millis(500));
        }

        // Copy packed fields to local variables for safe access
        let img_format = img_info.l_format;
        let data_size = img_info.l_data_size as usize;

        // Require RAW. The download path always LibRaw-decodes the bytes as a
        // RAF, so a JPEG (or any non-RAW) frame would either fail opaquely in
        // LibRaw or, worse, be mis-decoded. The X Acquire SDK exposes no still-
        // image quality setter we can drive to force RAW, so we fail here with
        // an actionable message rather than shipping a corrupt/failed frame.
        if img_format != XSDK_IMAGEFORMAT_RAW {
            return Err(NativeError::SdkError(format!(
                "Fujifilm: camera returned a non-RAW frame (format code {}, expected RAW={}). \
                 Set the camera's Image Quality to RAW (not JPEG or RAW+JPEG) — astro capture \
                 requires the linear RAW sensor data.",
                img_format, XSDK_IMAGEFORMAT_RAW
            )));
        }

        // The SDK fills lImageBitDepth (XAPI.H:123) on every XSDK_ReadImageInfo
        // and it tracks the body's live RAW output depth, so a GFX switched to
        // SDK_RAWOUTPUTDEPTH_16BIT reports 16 here while the model table still
        // says 14. Read only after the RAW guard above: a live-view or JPEG
        // frame describes a different pipeline and must not redefine the
        // sensor's container. Implausible values are ignored, not adopted.
        let sdk_bit_depth = img_info.l_image_bit_depth;
        if (8..=16).contains(&sdk_bit_depth) {
            self.sdk_reported_bit_depth = Some(sdk_bit_depth as u32);
            self.refresh_raw_depth();
        }

        // Download image data (RAF format)
        let mut buffer = vec![0u8; data_size];
        // SAFETY: fujifilm_mutex held; `self.camera_handle.0` valid; `buffer.as_mut_ptr()` points to a Vec<u8> of exactly `data_size` bytes (just allocated above); we pass that same size as the third argument so XSDK_ReadImage will not write past the allocation per XAPI.h.
        let result = unsafe {
            (sdk.read_image)(
                self.camera_handle.0,
                buffer.as_mut_ptr(),
                data_size as c_ulong,
            )
        };

        if result != XSDK_COMPLETE {
            check_xapi_error(self.camera_handle.0, sdk)?;
            return Err(NativeError::SdkError("Image download failed".into()));
        }

        // Clear camera buffer
        // SAFETY: fujifilm_mutex held; `self.camera_handle.0` valid; XSDK_DeleteImage takes only the handle and clears the SDK-side image queue entry per XAPI.h.
        unsafe { (sdk.delete_image)(self.camera_handle.0) };

        self.is_exposing = false;

        // Decode the RAF into its native linear CFA mosaic (single channel).
        let cfa = process_raf_buffer(&buffer, self.model.is_xtrans())?;

        // Adopt the decoder's ground truth — the highest-authority source.
        // `max_value` IS LibRaw's `color.maximum` (the saturation level) and
        // `bits_per_pixel` is derived from it. The RAF is decoded with `unpack`
        // + `raw2image` and never `dcraw_process` (imaging/src/raw.rs:1097-1108,
        // contract in imaging/src/libraw_shim.c:98-102), so the mosaic is
        // RIGHT-JUSTIFIED at its native depth: the white level is already the
        // container full scale and must not be scaled up into 16 bits.
        if (8..=16).contains(&cfa.bits_per_pixel) {
            self.measured_bit_depth = Some(cfa.bits_per_pixel);
        }
        if cfa.max_value > 0 {
            self.measured_white_level = Some(cfa.max_value);
        }
        self.refresh_raw_depth();

        // Bayer orientation: X-Trans (6×6) has no valid 2×2 pattern → None
        // (downstream then treats the mosaic as luminance rather than double-
        // debayering it as if it were Bayer). GFX bodies are true Bayer → use
        // LibRaw's detected orientation, falling back to the sensor default.
        let bayer_pattern = if cfa.is_xtrans {
            None
        } else {
            match cfa.cfa_pattern {
                Some(skotiq_imaging::CfaPattern::Rggb) => Some(BayerPattern::Rggb),
                Some(skotiq_imaging::CfaPattern::Grbg) => Some(BayerPattern::Grbg),
                Some(skotiq_imaging::CfaPattern::Gbrg) => Some(BayerPattern::Gbrg),
                Some(skotiq_imaging::CfaPattern::Bggr) => Some(BayerPattern::Bggr),
                None => self.sensor_info.bayer_pattern,
            }
        };

        let metadata = ImageMetadata {
            exposure_time: self.exposure_duration.as_secs_f64(),
            gain: self.current_iso,
            offset: self.current_offset,
            bin_x: 1,
            bin_y: 1,
            temperature: None,
            timestamp: chrono::Utc::now(),
            subframe: None,
            readout_mode: None,
            vendor_data: VendorFeatures::default(),
        };

        Ok(ImageData {
            width: cfa.width,
            height: cfa.height,
            data: cfa.data,
            // Truthful sensor bit depth derived from LibRaw's saturation level.
            bits_per_pixel: cfa.bits_per_pixel,
            bayer_pattern,
            metadata,
        })
    }

    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // SAFETY: fujifilm_mutex held above (in set_gain); `self.camera_handle.0` valid (connected==true was checked); XSDK_SetSensitivity takes (handle, c_long) POD per XAPI.h. The 100ms tokio sleep below honours the module header's "Important SDK Behaviors" §2.
        unsafe { (sdk.set_sensitivity)(self.camera_handle.0, gain as c_long) };
        self.current_iso = gain;
        tokio::time::sleep(Duration::from_millis(100)).await;

        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        Ok(self.current_iso)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        Ok(0)
    }

    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.sensor_info.clone()
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        Ok((1, 1)) // Fujifilm cameras don't support binning
    }

    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), NativeError> {
        Err(NativeError::NotSupported) // Full frame only
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        Ok(vec![])
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        // Return ISO range based on supported ISOs
        if self.supported_isos.is_empty() {
            // Default Fujifilm ISO range if not queried
            Ok((100, 12800))
        } else {
            let min = self.supported_isos.iter().min().copied().unwrap_or(100);
            let max = self.supported_isos.iter().max().copied().unwrap_or(12800);
            Ok((min, max))
        }
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        Err(NativeError::NotSupported) // Fujifilm cameras don't support offset
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, NativeError> {
        if !self.is_live_view_active() {
            return Err(NativeError::SdkError(
                "Fujifilm live view is not active — start live view on the camera first"
                    .to_string(),
            ));
        }
        self.read_live_view_frame().await
    }
}
