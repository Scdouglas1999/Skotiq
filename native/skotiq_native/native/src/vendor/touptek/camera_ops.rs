//! `NativeDevice` / `NativeCamera` / `Drop` implementations for `TouptekCamera`.

use super::*;

#[async_trait]
impl NativeDevice for TouptekCamera {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Other("Touptek".to_string())
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            return Ok(());
        }

        // Ensure the brand's SDK is loaded
        get_sdk_for_brand(&self.brand)?;

        let brand = self.brand.clone();
        let device_index = self.device_index;
        let sdk_device_id = self.sdk_device_id.clone();

        // Refresh device metadata, but select and open by the stable SDK ID captured during
        // discovery. The legacy index is used only when callers construct a camera directly
        // without first running discovery; even then it is resolved to an ID before Open().
        let (device_info, serial_number, bayer_pattern, raw_bit_depth, sdk_size, gain_range) = {
            // Acquire global SDK mutex for thread safety
            let _lock = touptek_mutex().lock().await;

            let device_info = with_sdk(&brand, |sdk| {
                let devices = enumerate_brand_devices_from_sdk(sdk, &brand);
                match sdk_device_id.as_deref() {
                    Some(stable_id) => devices
                        .into_iter()
                        .find(|device| device.camera_id == stable_id)
                        .ok_or_else(|| {
                            NativeError::SdkError(format!(
                                "{} camera with SDK ID '{}' disappeared during connect",
                                brand, stable_id
                            ))
                        }),
                    None => devices.into_iter().nth(device_index).ok_or_else(|| {
                        NativeError::SdkError(format!(
                            "{} camera index {} disappeared during connect",
                            brand, device_index
                        ))
                    }),
                }
            })?;

            let handle = with_sdk(&brand, |sdk| {
                let h = open_touptek_device(sdk, &device_info.camera_id)?;
                if h.is_null() {
                    tracing::error!(
                        "Touptek ({}) Open() returned NULL for SDK ID '{}'. Check USB connection and driver installation.",
                        brand, device_info.camera_id
                    );
                    return Err(NativeError::SdkError(format!(
                        "Failed to open {} camera with SDK ID '{}' - SDK returned NULL. Ensure camera is connected and {} driver is installed.",
                        brand, device_info.camera_id, brand
                    )));
                }
                Ok(h)
            })?;

            // Store handle
            {
                let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
                *h = HandleWrapper(handle);
            }

            // Get serial number, resolution, gain range, and raw Bayer pattern
            // (all synchronous).
            let (serial_number, bayer_pattern, raw_bit_depth, sdk_size, gain_range) = {
                let handle_val = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

                with_sdk(&brand, |sdk| {
                    let mut sn_buf = [0 as c_char; 64];
                    let mut serial = None;
                    // SAFETY: touptek_mutex held above (in connect's outer scope); `handle_val` was just opened above (null-checked) and the per-camera `handle` mutex is held briefly during the load (handle.lock().unwrap_or_else); `sn_buf.as_mut_ptr()` points to a stack [i8; 64] buffer — Ogmacam_get_SerialNumber writes at most 64 bytes of a NUL-terminated ASCII serial per the SDK header.
                    if unsafe { (sdk.get_serial_number)(handle_val, sn_buf.as_mut_ptr()) } >= 0 {
                        // SAFETY: Ogmacam_get_SerialNumber populated `sn_buf` as a NUL-terminated C string above (return ≥ 0 confirms success); `sn_buf.as_ptr()` is valid for the duration of this stack [i8; 64] buffer and CStr::from_ptr reads up to the NUL.
                        let sn = unsafe { CStr::from_ptr(sn_buf.as_ptr()) }
                            .to_string_lossy()
                            .to_string();
                        if !sn.is_empty() {
                            serial = Some(sn);
                        }
                    }

                    let mut width: c_int = 0;
                    let mut height: c_int = 0;
                    // SAFETY: touptek_mutex held; `handle_val` valid (just opened); `&mut width` and `&mut height` are valid stack out-pointers to distinct c_int locals.
                    let size_result =
                        unsafe { (sdk.get_size)(handle_val, &mut width, &mut height) };
                    // The camera's own current output size supersedes the model table's
                    // resolution list; a failed read leaves it unknown, not zero.
                    let sdk_size = if size_result < 0 || width <= 0 || height <= 0 {
                        tracing::warn!(
                            "Touptek get_Size() gave no usable frame size for '{}' (SDK result {}, {}x{}); falling back to the model resolution",
                            device_info.name,
                            size_result,
                            width,
                            height
                        );
                        None
                    } else {
                        Some((width as u32, height as u32))
                    };

                    let mut gain_min: u16 = 0;
                    let mut gain_max: u16 = 0;
                    let mut gain_def: u16 = 0;
                    // SAFETY: touptek_mutex held; `handle_val` valid; the three `&mut u16` out-pointers reference distinct stack locals; Ogmacam_get_ExpoAGainRange writes (min, max, def) values per the SDK header.
                    let gain_result = unsafe {
                        (sdk.get_expo_again_range)(
                            handle_val,
                            &mut gain_min,
                            &mut gain_max,
                            &mut gain_def,
                        )
                    };
                    // Gain is reported in percent-steps where 100 == 1x. Widening
                    // u16 -> i32 is value-preserving.
                    let gain_range = if gain_result < 0 || gain_min > gain_max {
                        tracing::warn!(
                            "Touptek get_ExpoAGainRange() failed for '{}' (SDK result {}); gain bounds stay unknown",
                            device_info.name,
                            gain_result
                        );
                        None
                    } else {
                        self.current_gain = i32::from(gain_def);
                        Some((i32::from(gain_min), i32::from(gain_max)))
                    };
                    if gain_range.is_none() {
                        // Without a range the default gain is unknown too; the live
                        // value is the only thing the camera can still be asked for.
                        let mut gain: u16 = 0;
                        // SAFETY: touptek_mutex held; `handle_val` valid; `&mut gain` is a valid stack out-pointer for the SDK's unsigned-short gain value.
                        if unsafe { (sdk.get_expo_again)(handle_val, &mut gain) } >= 0 {
                            self.current_gain = i32::from(gain);
                        }
                    }

                    let (raw_bayer_pattern, raw_bit_depth) =
                        read_touptek_raw_format(sdk, handle_val, &device_info.name);
                    let bayer_pattern = if (device_info.model_flags & OGMACAM_FLAG_MONO) == 0 {
                        raw_bayer_pattern
                    } else {
                        None
                    };

                    Ok((serial, bayer_pattern, raw_bit_depth, sdk_size, gain_range))
                })?
            };

            (
                device_info,
                serial_number,
                bayer_pattern,
                raw_bit_depth,
                sdk_size,
                gain_range,
            )
        };

        self.sdk_device_id = Some(device_info.camera_id.clone());
        self.model_flags = device_info.model_flags;
        self.max_fan_speed = device_info.max_fan_speed;
        self.gain_range = gain_range;
        let bit_depth = raw_bit_depth.unwrap_or(16);
        let (sensor_width, sensor_height) =
            sdk_size.unwrap_or((device_info.width, device_info.height));
        self.sensor_info = SensorInfo {
            width: sensor_width,
            height: sensor_height,
            pixel_size_x: device_info.pixel_size_x as f64,
            pixel_size_y: device_info.pixel_size_y as f64,
            max_adu: max_adu_from_bit_depth(bit_depth),
            bit_depth,
            color: (device_info.model_flags & OGMACAM_FLAG_MONO) == 0,
            bayer_pattern,
        };
        self.name = match serial_number {
            Some(serial) => format!("{} ({})", device_info.name, serial),
            None => device_info.name.clone(),
        };

        // Set capabilities based on flags
        let can_cool = (self.model_flags & OGMACAM_FLAG_TEC) != 0;
        let can_set_temp = (self.model_flags & OGMACAM_FLAG_TEC_ONOFF) != 0;
        let has_st4 = (self.model_flags & OGMACAM_FLAG_ST4) != 0;
        let can_bin = (self.model_flags & OGMACAM_FLAG_BINSKIP_SUPPORTED) != 0;
        let can_subframe = (self.model_flags & OGMACAM_FLAG_ROI_HARDWARE) != 0;

        self.capabilities = CameraCapabilities {
            can_cool: can_cool && can_set_temp,
            can_set_gain: true,
            can_set_offset: false, // Touptek doesn't have separate offset
            can_set_binning: can_bin,
            can_subframe,
            has_shutter: false,
            has_guider_port: has_st4,
            max_bin_x: if can_bin { 4 } else { 1 },
            max_bin_y: if can_bin { 4 } else { 1 },
            supports_readout_modes: false,
        };

        let quirk_lookup_id = format!(
            "native:touptek:{}:{}",
            self.brand.to_lowercase(),
            self.device_index
        );
        if let Some(delay_ms) = crate::quirks::get_timing_delay(&quirk_lookup_id, "connect") {
            tracing::debug!(
                "Applying DelayAfterConnect quirk: sleeping {}ms before starting pull mode on {}",
                delay_ms,
                self.name
            );
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        // Configure RAW/16-bit/software-trigger, then start the pull-mode data pipeline with
        // an event callback. All option writes must precede StartPullModeWithCallback and run
        // on this (non-callback) thread (toupcam.h:411 forbids TRIGGER/BITDEPTH/BINNING/ROTATE
        // put_Option from the callback context). This mirrors indi_toupbase Connect ordering.
        let start_result: Result<(usize, usize), NativeError> = {
            let _lock = touptek_mutex().lock().await;
            let handle_val = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

            // Heap-stable state whose address we hand to the SDK as the callback context.
            // Boxing guarantees the pointee address survives `self` being moved into the
            // camera HashMap after connect.
            let event_state = Box::new(TouptekEventState {
                image_ready: AtomicBool::new(false),
                error: AtomicBool::new(false),
            });
            let ctx = &*event_state as *const TouptekEventState as *mut c_void;
            let name = self.name.clone();

            let r = with_sdk(&brand, |sdk| {
                let close_with_error = |operation: &str, rc: i32| {
                    // SAFETY: touptek_mutex held; pull mode has not started; `handle_val` is
                    // the live handle returned by Open(). Closing it prevents a failed
                    // negotiation from leaking a partially configured camera.
                    unsafe { (sdk.close)(handle_val) };
                    NativeError::SdkError(format!(
                        "Failed to {} on Touptek camera '{}'. SDK error: {}",
                        operation, name, rc
                    ))
                };

                // SAFETY: touptek_mutex held; `handle_val` re-loaded from `self.handle`.
                // OGMACAM_OPTION_RAW=0x04 value 1 enables raw output. POD args only.
                let rc = unsafe { (sdk.put_option)(handle_val, OGMACAM_OPTION_RAW, 1) };
                if rc < 0 {
                    return Err(close_with_error("enable RAW output", rc));
                }

                // SAFETY: as above; OGMACAM_OPTION_BITDEPTH=0x06 value 1 selects 16-bit output.
                let rc = unsafe { (sdk.put_option)(handle_val, OGMACAM_OPTION_BITDEPTH, 1) };
                if rc < 0 {
                    return Err(close_with_error("select 16-bit RAW output", rc));
                }

                // SAFETY: as above; OGMACAM_OPTION_TRIGGER=0x0b value 1 selects software trigger.
                let rc = unsafe { (sdk.put_option)(handle_val, OGMACAM_OPTION_TRIGGER, 1) };
                if rc < 0 {
                    return Err(close_with_error("enable software trigger mode", rc));
                }

                let mut raw_mode: c_int = 0;
                // SAFETY: touptek_mutex held; `handle_val` valid; `&mut raw_mode` is a valid
                // stack out-pointer for get_Option.
                let rc = unsafe { (sdk.get_option)(handle_val, OGMACAM_OPTION_RAW, &mut raw_mode) };
                if rc < 0 {
                    return Err(close_with_error("read back RAW output mode", rc));
                }

                let mut bit_depth_mode: c_int = 0;
                // SAFETY: as above; `&mut bit_depth_mode` is a distinct valid out-pointer.
                let rc = unsafe {
                    (sdk.get_option)(handle_val, OGMACAM_OPTION_BITDEPTH, &mut bit_depth_mode)
                };
                if rc < 0 {
                    return Err(close_with_error("read back RAW bit depth", rc));
                }
                if raw_mode != 1 || bit_depth_mode != 1 {
                    // SAFETY: touptek_mutex held; pull mode has not started; `handle_val`
                    // remains live. Do not start a stream whose pixel stride is ambiguous.
                    unsafe { (sdk.close)(handle_val) };
                    return Err(NativeError::SdkError(format!(
                        "Touptek camera '{}' did not negotiate 16-bit single-channel RAW output (RAW={}, BITDEPTH={})",
                        name, raw_mode, bit_depth_mode
                    )));
                }

                // SAFETY: touptek_mutex held; `handle_val` valid; `touptek_event_callback`
                // is an `extern "system"` fn matching PTOUPCAM_EVENT_CALLBACK; `ctx` points to
                // the live `event_state` box (freed only after Stop+Close, see disconnect/Drop).
                let rc = unsafe {
                    (sdk.start_pull_mode_with_callback)(handle_val, touptek_event_callback, ctx)
                };
                if rc < 0 {
                    // The stream never started, so the callback can never fire and `ctx` will
                    // dangle harmlessly once `event_state` drops at end of scope. Close the
                    // handle to avoid leaking it.
                    // SAFETY: touptek_mutex held; `handle_val` valid; Ogmacam_Close releases it.
                    unsafe { (sdk.close)(handle_val) };
                    return Err(NativeError::SdkError(format!(
                        "Failed to start pull mode on Touptek camera '{}'. SDK error: {}",
                        name, rc
                    )));
                }
                Ok((2, 1))
            });

            if r.is_ok() {
                // Pull mode is live; take ownership of the state so it outlives the callback.
                self.event_state = Some(event_state);
            }
            r
        };
        match start_result {
            Ok((bytes_per_pixel, channels)) => {
                self.pull_bytes_per_pixel = bytes_per_pixel;
                self.pull_channels = channels;
            }
            Err(e) => {
                // Handle was closed inside the closure; forget the now-dangling pointer.
                {
                    let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
                    *h = HandleWrapper(std::ptr::null_mut());
                }
                return Err(e);
            }
        }

        self.connected = true;
        self.state = CameraState::Idle;

        tracing::info!(
            "Connected to Touptek camera: {} ({}x{})",
            self.name,
            self.sensor_info.width,
            self.sensor_info.height
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Ok(());
        }

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Teardown order is load-bearing: stop the pull-mode stream, then close the handle,
        // and only THEN drop the event-state box. Stop()+Close() quiesce the SDK's internal
        // streaming thread, so after they return no callback can fire; freeing the box
        // afterwards means the callback can never observe freed memory.
        with_sdk(&brand, |sdk| {
            // SAFETY: touptek_mutex held; `handle` loaded from `self.handle`. Ogmacam_Stop
            // halts pull mode and joins the streaming thread; idempotent, handle-only arg.
            let _ = unsafe { (sdk.stop)(handle) };
            // SAFETY: touptek_mutex held; `handle` valid (connected==true checked at top).
            // Ogmacam_Close is the contractual release for Ogmacam_Open.
            unsafe { (sdk.close)(handle) };
            Ok(())
        })?;

        // Safe now: Stop()+Close() returned, so the SDK will not invoke the callback again.
        self.event_state = None;

        {
            let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            *h = HandleWrapper(std::ptr::null_mut());
        }
        self.connected = false;
        self.state = CameraState::Idle;
        self.exposure_started_at = None;
        self.pull_bytes_per_pixel = 0;
        self.pull_channels = 0;

        tracing::info!("Disconnected from Touptek camera: {}", self.name);

        Ok(())
    }
}

impl Drop for TouptekCamera {
    fn drop(&mut self) {
        // Best-effort teardown for the forgot-to-disconnect path. The `event_state` box is a
        // struct field, so the compiler drops (frees) it immediately AFTER this body returns.
        // We MUST stop pull mode + close the handle here first, otherwise the SDK's streaming
        // thread could dispatch the callback into freed state. The normal path (disconnect)
        // has cleared the handle and `event_state`, so this is a no-op then. Checking the
        // handle rather than `connected` also covers cancellation during the pre-stream delay.
        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        if !handle.is_null() {
            let mut quiesced = false;
            // Drop cannot await the async vendor mutex. Only touch the SDK if try_lock
            // proves no other Touptek-family call is in flight.
            if let Ok(_sdk_lock) = touptek_mutex().try_lock() {
                if get_sdk_for_brand(&self.brand).is_ok() {
                    quiesced = with_sdk(&self.brand, |sdk| {
                        // SAFETY: global touptek_mutex held; `handle` is the live handle
                        // owned by this camera. Stop then Close quiesces callbacks before
                        // the event-state box is allowed to drop.
                        unsafe { (sdk.stop)(handle) };
                        // SAFETY: same held touptek_mutex and same handle as the Stop
                        // above, which has already returned (so the SDK's streaming
                        // thread is quiesced). Close is the contractual release for the
                        // Open that produced this handle, and it has not been closed
                        // yet: disconnect() nulls `self.handle` after closing, and this
                        // branch only runs because the handle is still non-null.
                        unsafe { (sdk.close)(handle) };
                        Ok(())
                    })
                    .is_ok();
                }
            } else {
                tracing::warn!(
                    "Could not acquire Touptek SDK mutex while dropping '{}'; leaking callback state for memory safety",
                    self.name
                );
            }

            if !quiesced {
                // Without Stop+Close under the global SDK mutex the callback may still run.
                // Leak its tiny context rather than let field drop free memory the SDK can use.
                if let Some(event_state) = self.event_state.take() {
                    std::mem::forget(event_state);
                }
            }
        }
        self.connected = false;
    }
}

#[async_trait]
impl NativeCamera for TouptekCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities.clone()
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.sensor_info.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Get current temperature
        let current_temp = with_sdk(&brand, |sdk| {
            let mut temp: i16 = 0;
            // SAFETY: touptek_mutex held above (in get_status); `handle` was just loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid Ogmacam_Open handle; `&mut temp` is a valid stack out-pointer to i16. Ogmacam_get_Temperature writes temperature in 0.1°C units per the SDK header.
            let result = unsafe { (sdk.get_temperature)(handle, &mut temp) };
            touptek_temperature_result(&self.name, result, temp)
        })?;

        // Touptek's common SDK surface used here does not expose an
        // authoritative TEC duty-cycle readback. Do not fabricate cooler power
        // from target/current temperature deltas; callers use this value as
        // telemetry, not as a control hint.
        let cooler_power = None;

        // Calculate exposure remaining
        let exposure_remaining = if self.state == CameraState::Exposing {
            self.exposure_started_at.map(|started_at| {
                (self.exposure_duration - started_at.elapsed().as_secs_f64()).max(0.0)
            })
        } else {
            None
        };
        let gain = self.read_gain_locked(handle)?;

        Ok(CameraStatus {
            state: self.state,
            sensor_temp: Some(current_temp),
            cooler_power,
            target_temp: Some(self.target_temp),
            cooler_on: self.cooler_on,
            gain,
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

        // Set binning
        self.set_binning(params.bin_x, params.bin_y).await?;

        // Set subframe
        self.set_subframe(params.subframe.clone()).await?;

        // Now get SDK and handle after all awaits
        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Set exposure time and fire ONE software-triggered frame, all within the SDK lock.
        let name = self.name.clone();
        with_sdk(&brand, |sdk| {
            // Clear the frame-arrival flags for THIS exposure BEFORE triggering, so the poll
            // in download_image only observes the frame produced by the trigger below (and not
            // a stale/late frame from a previous exposure).
            if let Some(es) = self.event_state.as_ref() {
                es.image_ready.store(false, Ordering::SeqCst);
                es.error.store(false, Ordering::SeqCst);
            }

            let exposure_us = (params.duration_secs * 1_000_000.0) as c_uint;
            // SAFETY: touptek_mutex held above (in start_exposure); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid Ogmacam_Open handle. Ogmacam_put_ExpoTime takes (handle, c_uint microseconds) POD per the SDK header.
            let result = unsafe { (sdk.put_expo_time)(handle, exposure_us) };
            if result < 0 {
                tracing::error!(
                    "Touptek put_ExpoTime() failed for camera '{}'. Requested: {}µs ({:.3}s), error code: {}",
                    name, exposure_us, params.duration_secs, result
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to set exposure time {:.3}s on Touptek camera '{}'. SDK error: {}",
                    params.duration_secs, name, result
                )));
            }

            // Software trigger: nNumber = 1 requests exactly one frame, delivered as
            // EVENT_IMAGE and pulled in download_image(). OPTION_TRIGGER=1 was set in connect().
            // SAFETY: touptek_mutex held; `handle` valid; Ogmacam_Trigger takes (handle, c_ushort) POD.
            let result = unsafe { (sdk.trigger)(handle, 1) };
            if result < 0 {
                tracing::error!(
                    "Touptek Trigger() failed for camera '{}'. Duration: {:.3}s, error code: {}",
                    name,
                    params.duration_secs,
                    result
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to start exposure on Touptek camera '{}'. SDK error: {}",
                    name, result
                )));
            }
            Ok(())
        })?;

        self.exposure_duration = params.duration_secs;
        self.exposure_started_at = Some(std::time::Instant::now());
        self.state = CameraState::Exposing;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let name = self.name.clone();
        with_sdk(&brand, |sdk| {
            // Cancel the software trigger with Trigger(0) — NOT Stop(), which would tear down
            // the pull-mode stream and break all subsequent exposures. This matches
            // indi_toupbase AbortExposure (Trigger(m_Handle, 0)) and keeps pull mode running.
            // SAFETY: touptek_mutex held above (in abort_exposure); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid handle; Ogmacam_Trigger takes (handle, c_ushort) POD per the SDK header.
            let result = unsafe { (sdk.trigger)(handle, 0) };
            if result < 0 {
                tracing::error!(
                    "Touptek Trigger(0) (cancel) failed for camera '{}'. Error code: {}",
                    name,
                    result
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to abort exposure on Touptek camera '{}'. SDK error: {}",
                    name, result
                )));
            }
            Ok(())
        })?;

        // Clear frame-arrival flags so the next exposure starts from a clean slate.
        if let Some(es) = self.event_state.as_ref() {
            es.image_ready.store(false, Ordering::SeqCst);
            es.error.store(false, Ordering::SeqCst);
        }

        self.state = CameraState::Idle;
        self.exposure_started_at = None;
        tracing::info!("Aborted exposure on Touptek camera '{}'", self.name);
        Ok(())
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // Wait for the software-triggered frame to arrive. The SDK's pull-mode callback flips
        // `image_ready` on EVENT_IMAGE and `error` on EVENT_ERROR/DISCONNECTED/NOFRAMETIMEOUT.
        // We poll the atomics WITHOUT holding touptek_mutex so unrelated SDK calls aren't
        // blocked for the whole exposure. Timeout = exposure + margin (>= the SDK frame timeout).
        let timeout_secs = self.exposure_duration * 1.1 + 5.0;
        let poll_start = std::time::Instant::now();
        loop {
            let (ready, errored) = {
                let es = self.event_state.as_ref().ok_or_else(|| {
                    NativeError::SdkError(
                        "Touptek pull mode not started (event state missing)".to_string(),
                    )
                })?;
                (
                    es.image_ready.load(Ordering::SeqCst),
                    es.error.load(Ordering::SeqCst),
                )
            };
            if errored {
                self.state = CameraState::Idle;
                self.exposure_started_at = None;
                return Err(NativeError::SdkError(format!(
                    "Touptek camera '{}' reported an error/disconnect during exposure",
                    self.name
                )));
            }
            if ready {
                break;
            }
            if poll_start.elapsed().as_secs_f64() > timeout_secs {
                self.state = CameraState::Idle;
                self.exposure_started_at = None;
                return Err(NativeError::Timeout(format!(
                    "Touptek camera '{}' did not deliver a frame within {:.1}s",
                    self.name, timeout_secs
                )));
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let output_pixel_stride = self
            .pull_bytes_per_pixel
            .checked_mul(self.pull_channels)
            .ok_or_else(|| {
                NativeError::SdkError("Touptek negotiated pixel stride overflow".to_string())
            })?;
        if self.pull_bytes_per_pixel != 2 || self.pull_channels != 1 {
            return Err(NativeError::SdkError(format!(
                "Touptek camera '{}' is not configured for 16-bit single-channel RAW output ({} bytes/channel, {} channels)",
                self.name, self.pull_bytes_per_pixel, self.pull_channels
            )));
        }

        // Size the buffer from the ACTUAL current output resolution, not the full sensor: a
        // subframe/binned frame is smaller and would otherwise be mis-sized/skewed.
        // `get_FinalSize` reports the exact size after ROI + rotate + binning. If a white-label
        // SDK lacks the symbol we fall back to the ROI (or full sensor) dims, which are an
        // UPPER BOUND on the delivered frame (binning only shrinks), so the buffer is never
        // too small. The delivered frame is then sliced to `info.width`/`info.height`.
        let fallback_dims: (usize, usize) = match &self.subframe {
            Some(sf) => (sf.width as usize, sf.height as usize),
            None => (
                self.sensor_info.width as usize,
                self.sensor_info.height as usize,
            ),
        };

        let name = self.name.clone();
        let (data, out_width, out_height) = with_sdk(&brand, |sdk| {
            let (buf_w, buf_h) = if let Some(get_final) = sdk.get_final_size {
                let mut fw: c_int = 0;
                let mut fh: c_int = 0;
                // SAFETY: touptek_mutex held; `handle` valid; two distinct stack out-pointers
                // as required by Ogmacam_get_FinalSize.
                let rc = unsafe { get_final(handle, &mut fw, &mut fh) };
                if rc >= 0 && fw > 0 && fh > 0 {
                    (fw as usize, fh as usize)
                } else {
                    fallback_dims
                }
            } else {
                fallback_dims
            };

            let buf_pixels = buf_w.checked_mul(buf_h).ok_or_else(|| {
                NativeError::SdkError(format!("Touptek buffer size overflow: {}x{}", buf_w, buf_h))
            })?;
            let buffer_size = buf_pixels.checked_mul(output_pixel_stride).ok_or_else(|| {
                NativeError::SdkError(format!(
                    "Touptek buffer size overflow: {}x{} * {} bytes",
                    buf_w, buf_h, output_pixel_stride
                ))
            })?;

            let mut buffer = vec![0u8; buffer_size];
            // SAFETY: OgmacamFrameInfoV3 is `#[repr(C)]` POD (c_uint/u64/u16); zero-init is the
            // valid empty state before Ogmacam_PullImageV3 overwrites it.
            let mut info: OgmacamFrameInfoV3 = unsafe { std::mem::zeroed() };

            // SAFETY: touptek_mutex held; `handle` valid; `buffer` is sized from the negotiated
            // bytes-per-channel and channel count for every output pixel; connect() verified
            // that layout is single-channel RAW in a 16-bit container. `&mut info` is a valid
            // `#[repr(C)]` out-pointer. bStill=0 pulls the live (software-triggered) image
            // signalled by EVENT_IMAGE; in RAW mode `bits` is ignored and row_pitch=0 is tight.
            let result = unsafe {
                (sdk.pull_image_v3)(
                    handle,
                    buffer.as_mut_ptr() as *mut c_void,
                    0,  // bStill = false (live/triggered image)
                    16, // 16 bits (ignored in RAW mode)
                    0,  // default row pitch = tight Width*2 for RAW-16
                    &mut info,
                )
            };
            if result < 0 {
                tracing::error!(
                    "Touptek PullImageV3() failed for camera '{}'. Buffer: {}x{} pixels, error code: {}",
                    name, buf_w, buf_h, result
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to download image from Touptek camera '{}'. SDK error: {}",
                    name, result
                )));
            }

            // Build the pixel Vec from the ACTUAL frame dims the SDK reported, guarding against
            // a frame that would not fit the allocated buffer.
            let pulled_w = info.width as usize;
            let pulled_h = info.height as usize;
            let pulled_pixels = pulled_w.checked_mul(pulled_h).ok_or_else(|| {
                NativeError::SdkError(format!(
                    "Touptek frame size overflow: {}x{}",
                    pulled_w, pulled_h
                ))
            })?;
            let pulled_bytes = pulled_pixels
                .checked_mul(output_pixel_stride)
                .ok_or_else(|| {
                    NativeError::SdkError(format!(
                        "Touptek frame byte size overflow: {}x{} * {} bytes",
                        pulled_w, pulled_h, output_pixel_stride
                    ))
                })?;
            if pulled_pixels == 0 || pulled_bytes > buffer.len() {
                return Err(NativeError::SdkError(format!(
                    "Touptek camera '{}' delivered a {}x{} frame that does not fit the {}x{} buffer",
                    name, pulled_w, pulled_h, buf_w, buf_h
                )));
            }

            let data: Vec<u16> = buffer[..pulled_bytes]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
                .collect();

            Ok((data, info.width, info.height))
        })?;

        self.state = CameraState::Idle;
        self.exposure_started_at = None;
        let gain = self.read_gain_locked(handle)?;

        let metadata = ImageMetadata {
            exposure_time: self.exposure_duration,
            gain,
            offset: self.current_offset,
            bin_x: self.current_bin_x,
            bin_y: self.current_bin_y,
            temperature: None,
            timestamp: chrono::Utc::now(),
            subframe: self.subframe.clone(),
            readout_mode: None,
            vendor_data: VendorFeatures::default(),
        };

        Ok(ImageData {
            width: out_width,
            height: out_height,
            data,
            bits_per_pixel: self.sensor_info.bit_depth,
            bayer_pattern: self.sensor_info.bayer_pattern,
            metadata,
        })
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        // The pull-mode event callback flips these when the SDK delivers a frame (image_ready)
        // or reports a fault (error). Reflecting them here lets the shared poll loop
        // (`wait_for_exposure`) actually complete; returning `true` on error lets the
        // subsequent `download_image` surface the real error. Reading atomics needs no lock.
        if let Some(es) = self.event_state.as_ref() {
            if es.image_ready.load(Ordering::SeqCst) || es.error.load(Ordering::SeqCst) {
                return Ok(true);
            }
        }
        Ok(self.state != CameraState::Exposing)
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

        // Only while cooling, and only when the caller named a setpoint:
        // switching the TEC off needs no target temperature.
        let target_temp = target_temp.filter(|_| enabled);

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Enable/disable TEC
        let name = self.name.clone();
        with_sdk(&brand, |sdk| {
            // SAFETY: touptek_mutex held above (in set_cooler); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid handle. Ogmacam_put_Option takes (handle, c_uint option_id, c_int value) POD — OGMACAM_OPTION_TEC=0x08 with 0/1 toggles the thermoelectric cooler per the SDK header.
            let result = unsafe {
                (sdk.put_option)(handle, OGMACAM_OPTION_TEC, if enabled { 1 } else { 0 })
            };
            if result < 0 {
                tracing::error!(
                    "Touptek put_Option(TEC) failed for camera '{}'. Enabled: {}, error code: {}",
                    name,
                    enabled,
                    result
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to {} cooler on Touptek camera '{}'. SDK error: {}",
                    if enabled { "enable" } else { "disable" },
                    name,
                    result
                )));
            }

            // Set target temperature (in 0.1 degrees Celsius).
            // Why: target_temp is f64 Celsius typically in [-50.0, 50.0]; * 10 fits in
            // i16's range [-32768, 32767] with plenty of room. f64 -> i16 saturating
            // truncation is well-defined for finite values; NaN saturates to 0 which the
            // SDK rejects.
            if let Some(target) = target_temp {
                let temp = (target * 10.0) as i16;
                // SAFETY: touptek_mutex held; `handle` valid; Ogmacam_put_Temperature takes (handle, i16 in 0.1°C units) POD per the SDK header. Range clamping is the SDK's responsibility.
                let result = unsafe { (sdk.put_temperature)(handle, temp) };
                if result < 0 {
                    tracing::error!(
                        "Touptek put_Temperature() failed for camera '{}'. Target: {:.1}°C, error code: {}",
                        name, target, result
                    );
                    return Err(NativeError::SdkError(format!(
                        "Failed to set cooler temperature to {:.1}°C on Touptek camera '{}'. SDK error: {}",
                        target, name, result
                    )));
                }
            }
            Ok(())
        })?;

        self.cooler_on = enabled;
        if let Some(target) = target_temp {
            self.target_temp = target;
        }
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        with_sdk(&brand, |sdk| {
            let mut temp: i16 = 0;
            // SAFETY: touptek_mutex held above (in get_temperature trait method); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid handle; `&mut temp` is a valid stack out-pointer to i16. Ogmacam_get_Temperature writes the sensor reading in 0.1°C units per the SDK header.
            let result = unsafe { (sdk.get_temperature)(handle, &mut temp) };
            touptek_temperature_result(&self.name, result, temp)
        })
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        Err(NativeError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // Why: Touptek gain is a u16 (range 100..=10000 per the SDK header). A negative
        // i32 or one > u16::MAX is a caller bug, so we surface InvalidParameter rather
        // than silently truncate to a wrap-around gain that could destroy a frame.
        let gain_u16 = u16::try_from(gain).map_err(|_| {
            NativeError::InvalidParameter(format!(
                "Touptek gain {} out of u16 range (100..=10000 nominal)",
                gain
            ))
        })?;

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let name = self.name.clone();
        with_sdk(&brand, |sdk| {
            // SAFETY: touptek_mutex held above (in set_gain); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid handle. Ogmacam_put_ExpoAGain takes (handle, u16 gain) POD per the SDK header. SDK clamps to its supported range.
            let result = unsafe { (sdk.put_expo_again)(handle, gain_u16) };
            if result < 0 {
                tracing::error!(
                    "Touptek put_ExpoAGain() failed for camera '{}'. Requested gain: {}, error code: {}",
                    name, gain, result
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to set gain to {} on Touptek camera '{}'. SDK error: {}. Value may be out of range.",
                    gain, name, result
                )));
            }
            Ok(())
        })?;

        self.current_gain = gain;
        Ok(())
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), NativeError> {
        // Touptek doesn't have a separate offset control
        self.current_offset = offset;
        Ok(())
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.capabilities.can_set_binning && (bin_x > 1 || bin_y > 1) {
            return Err(NativeError::NotSupported);
        }

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Touptek uses combined binning value
        let bin_mode = bin_x.max(bin_y);
        let name = self.name.clone();
        let max_bx = self.capabilities.max_bin_x;
        let max_by = self.capabilities.max_bin_y;
        with_sdk(&brand, |sdk| {
            // SAFETY: touptek_mutex held above (in set_binning); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid handle; Ogmacam_put_Option takes (handle, c_uint option_id, c_int value) POD — OGMACAM_OPTION_BINNING=0x01 with the symmetric bin factor per the SDK header. `bin_mode` is already validated (≤ capabilities.max_bin_x).
            let result = unsafe { (sdk.put_option)(handle, OGMACAM_OPTION_BINNING, bin_mode) };
            if result < 0 {
                tracing::error!(
                    "Touptek put_Option(BINNING) failed for camera '{}'. Requested: {}x{}, error code: {}",
                    name, bin_x, bin_y, result
                );
                return Err(NativeError::SdkError(format!(
                    "Failed to set binning to {}x{} on Touptek camera '{}'. SDK error: {}. Max: {}x{}",
                    bin_x, bin_y, name, result, max_bx, max_by
                )));
            }
            Ok(())
        })?;

        self.current_bin_x = bin_x;
        self.current_bin_y = bin_y;
        Ok(())
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let brand = self.brand.clone();

        // Acquire global SDK mutex for thread safety
        let _lock = touptek_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        let name = self.name.clone();
        let sensor_w = self.sensor_info.width;
        let sensor_h = self.sensor_info.height;

        if let Some(sf) = &subframe {
            if !self.capabilities.can_subframe {
                return Err(NativeError::NotSupported);
            }

            let sx = sf.start_x;
            let sy = sf.start_y;
            let sw = sf.width;
            let sh = sf.height;
            with_sdk(&brand, |sdk| {
                // SAFETY: touptek_mutex held above (in set_subframe); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid handle; Ogmacam_put_Roi takes (handle, c_uint x, c_uint y, c_uint width, c_uint height) POD per the SDK header. The caller-supplied SubFrame values are validated by the SDK against sensor bounds (returns < 0 on out-of-range).
                let result = unsafe { (sdk.put_roi)(handle, sx, sy, sw, sh) };
                if result < 0 {
                    tracing::error!(
                        "Touptek put_Roi() failed for camera '{}'. Requested: ({}, {}) {}x{}, sensor: {}x{}, error code: {}",
                        name, sx, sy, sw, sh, sensor_w, sensor_h, result
                    );
                    return Err(NativeError::SdkError(format!(
                        "Failed to set ROI ({}, {}) {}x{} on Touptek camera '{}'. SDK error: {}",
                        sx, sy, sw, sh, name, result
                    )));
                }
                Ok(())
            })?;
        } else {
            // Reset to full frame
            with_sdk(&brand, |sdk| {
                // SAFETY: touptek_mutex held above (in set_subframe full-frame reset branch); `handle` was loaded from `self.handle` under its Mutex with `connected == true` guaranteeing a valid handle; (0, 0, sensor_w, sensor_h) is the full sensor area from SensorInfo populated by connect() via get_size, so it is within the SDK's accepted range.
                let result = unsafe { (sdk.put_roi)(handle, 0, 0, sensor_w, sensor_h) };
                if result < 0 {
                    tracing::error!(
                        "Touptek put_Roi() failed to reset to full frame for camera '{}'. Error code: {}",
                        name, result
                    );
                    return Err(NativeError::SdkError(format!(
                        "Failed to reset ROI to full frame on Touptek camera '{}'. SDK error: {}",
                        name, result
                    )));
                }
                Ok(())
            })?;
        }

        self.subframe = subframe;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let _lock = touptek_mutex().lock().await;
        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        self.read_gain_locked(handle)
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        Ok(self.current_offset)
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        Ok((self.current_bin_x, self.current_bin_y))
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        // Touptek cameras don't have distinct readout modes
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

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), NativeError> {
        // Touptek cameras expose a single fixed readout mode.
        if mode.index == 0 || mode.name.eq_ignore_ascii_case("normal") {
            return Ok(());
        }
        Err(NativeError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let _lock = touptek_mutex().lock().await;
        let handle_val = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        with_sdk(&self.brand, |sdk| {
            // Each probe leaves its field `None` when the camera declines it, so an
            // unreported control is never rendered as a measured zero.
            let read_option = |option: c_uint| -> Option<c_int> {
                let mut value: c_int = 0;
                // SAFETY: touptek_mutex held above; `handle_val` belongs to this connected camera; `&mut value` is a valid stack out-pointer for the SDK's get_Option signature.
                let result = unsafe { (sdk.get_option)(handle_val, option, &mut value) };
                (result >= 0).then_some(value)
            };

            let mut features = VendorFeatures {
                hardware_binning: (self.model_flags & OGMACAM_FLAG_BINSKIP_SUPPORTED) != 0,
                ..VendorFeatures::default()
            };

            features.usb_bandwidth = read_option(OGMACAM_OPTION_BANDWIDTH).map(f64::from);

            if (self.model_flags & OGMACAM_FLAG_HEAT) != 0 {
                features.anti_dew_heater = read_option(OGMACAM_OPTION_HEAT).map(|level| level > 0);
            }

            // Fan speed is a step on the closed interval [0, max_fan_speed]; a
            // percentage is only meaningful once the model reports that ceiling.
            if (self.model_flags & OGMACAM_FLAG_FAN) != 0 && self.max_fan_speed > 0 {
                features.fan_power = read_option(OGMACAM_OPTION_FAN)
                    .map(|speed| f64::from(speed) * 100.0 / f64::from(self.max_fan_speed));
            }

            Ok(features)
        })
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // Bounds captured from get_ExpoAGainRange at connect, in the SDK's percent-step
        // units where 100 == 1x.
        self.gain_range.ok_or_else(|| {
            NativeError::SdkError(format!(
                "Touptek camera '{}' did not report a gain range at connect",
                self.name
            ))
        })
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // The ToupTek-family SDK exposes no offset control, so there is no range to
        // report — black level is set through put_Option, not a gain-style bound.
        Err(NativeError::NotSupported)
    }
}
