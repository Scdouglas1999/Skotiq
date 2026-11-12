//! `DeviceDriver` / `CameraDriver` / `Drop` implementations for `TouptekCamera`.

use super::*;
use crate::camera_core::{unpack_samples, Frame, SampleLayout};

/// What connect negotiated with the camera before the stream started.
struct StreamSetup {
    bayer_pattern: Option<BayerPattern>,
    bit_depth: u32,
    bytes_per_sample: usize,
    rows_reversed: bool,
    exposure_range_us: Option<(u32, u32)>,
    black_level_max: Option<i32>,
    cooler: Option<CoolerReadback>,
}

/// The cooler as the camera came up: the SDK opens a cooled camera with its
/// cooler on, aimed at the model's default set-point.
struct CoolerReadback {
    enabled: Option<bool>,
    target_c: Option<f64>,
    target_range: Option<(f64, f64)>,
    tec_voltage_max: Option<i32>,
}

/// Raw output, sample size, row order and software trigger, set while the
/// camera is stopped (the SDK refuses RAW and row order once it streams), then
/// the stream itself. Every setting a camera can keep from an earlier session
/// is set explicitly. On failure the caller closes the handle.
fn configure_stream(
    sdk: &TouptekSdk,
    handle: HOgmacam,
    name: &str,
    model_flags: u64,
    ctx: *mut c_void,
) -> Result<StreamSetup, DriverError> {
    let put = |option: c_uint, value: c_int| -> i32 {
        // SAFETY: the caller holds the SDK lock through `with_sdk`; `handle` is the camera
        // opened by this connect and not yet streaming. POD arguments only.
        unsafe { (sdk.put_option)(handle, option, value) }
    };
    let color = (model_flags & OGMACAM_FLAG_MONO) == 0;
    let deep = (model_flags & OGMACAM_FLAG_RAW_ABOVE_8_BITS) != 0;

    // SAFETY: as above; 0 turns auto exposure off.
    let rc = unsafe { (sdk.put_auto_expo_enable)(handle, 0) };
    if rc < 0 {
        tracing::warn!(
            "{name}: turning auto exposure off failed: {}",
            describe_hresult(rc)
        );
    }

    // INDI's toupbase runs ARM boards at the lowest readout speed: at full speed large
    // sensors drop frames over a Raspberry Pi's USB.
    if cfg!(all(
        target_os = "linux",
        any(target_arch = "arm", target_arch = "aarch64")
    )) {
        // SAFETY: as above; POD arguments.
        let rc = unsafe { (sdk.put_speed)(handle, 0) };
        if rc < 0 {
            tracing::warn!(
                "{name}: lowering the readout speed failed: {}",
                describe_hresult(rc)
            );
        }
    }

    let rc = put(OGMACAM_OPTION_UPSIDE_DOWN, 0);
    if rc < 0 {
        tracing::warn!(
            "{name}: asking for rows top first failed: {}",
            describe_hresult(rc)
        );
    }
    // An SDK that predates the option delivers Windows frames bottom row first.
    let rows_reversed = read_option(sdk, handle, OGMACAM_OPTION_UPSIDE_DOWN)
        .map(|value| value != 0)
        .unwrap_or(cfg!(windows));
    if rows_reversed {
        tracing::warn!("{name}: the SDK delivers rows bottom first; frames are flipped here");
    }

    if deep {
        let rc = put(OGMACAM_OPTION_ZERO_PADDING, 0);
        if rc < 0 {
            tracing::debug!(
                "{name}: setting high zero padding failed: {}",
                describe_hresult(rc)
            );
        }
    }

    let rc = put(OGMACAM_OPTION_RAW, 1);
    if rc < 0 {
        return Err(touptek_failure("switch to RAW output", name, rc));
    }
    let wanted_depth = c_int::from(deep);
    let rc = put(OGMACAM_OPTION_BITDEPTH, wanted_depth);
    if rc < 0 && deep {
        return Err(touptek_failure("select the full bit depth", name, rc));
    }
    let rc = put(OGMACAM_OPTION_TRIGGER, 1);
    if rc < 0 {
        return Err(touptek_failure("switch to software trigger", name, rc));
    }
    // A cancelled exposure must not come out later as a frame (a camera can keep cancel
    // mode 1 from another program); an SDK that predates the option always drops it.
    let rc = put(OGMACAM_OPTION_TRIGGER_CANCEL_MODE, 0);
    if rc < 0 && rc != OGMACAM_E_NOTIMPL {
        tracing::warn!(
            "{name}: asking for cancelled exposures to be dropped failed: {}",
            describe_hresult(rc)
        );
    }

    // The camera keeps the conversion gain another program left it in. Skotiq offers no
    // choice of it yet, so every frame is taken in low conversion gain, as NINA and INDI
    // do by default.
    if (model_flags & (OGMACAM_FLAG_CG | OGMACAM_FLAG_CGHDR)) != 0 {
        let rc = put(OGMACAM_OPTION_CG, 0);
        if rc < 0 {
            tracing::warn!(
                "{name}: selecting low conversion gain failed: {}",
                describe_hresult(rc)
            );
        }
    }

    let raw_mode = read_option(sdk, handle, OGMACAM_OPTION_RAW)
        .map_err(|rc| touptek_failure("read back the RAW output mode", name, rc))?;
    let depth_mode = match read_option(sdk, handle, OGMACAM_OPTION_BITDEPTH) {
        Ok(mode) => mode,
        // An 8-bit-only model may not know the option at all.
        Err(_) if !deep => 0,
        Err(rc) => return Err(touptek_failure("read back the bit depth", name, rc)),
    };
    if raw_mode != 1 || (depth_mode != 0) != deep {
        return Err(DriverError::SdkError(format!(
            "{name} did not take {} RAW output (RAW={raw_mode}, BITDEPTH={depth_mode})",
            if deep { "16-bit" } else { "8-bit" }
        )));
    }

    // Read after the bit depth is set: the raw format reports the current one.
    let (bayer_pattern, reported_bits) = read_touptek_raw_format(sdk, handle, name, color);
    let bit_depth = match (deep, reported_bits) {
        (false, _) => 8,
        (true, Some(bits)) if bits > 8 => bits,
        (true, _) => 16,
    };

    let mut range = (0 as c_uint, 0 as c_uint, 0 as c_uint);
    // SAFETY: as above; three distinct stack out-pointers.
    let rc = unsafe { (sdk.get_exp_time_range)(handle, &mut range.0, &mut range.1, &mut range.2) };
    let exposure_range_us =
        (rc >= 0 && range.0 <= range.1 && range.1 > 0).then_some((range.0, range.1));

    let black_level_max = ((model_flags & OGMACAM_FLAG_BLACKLEVEL) != 0)
        .then(|| 31 << (bit_depth.saturating_sub(8)).min(8));

    let cooler = ((model_flags & OGMACAM_FLAG_TEC) != 0
        && (model_flags & OGMACAM_FLAG_TEC_ONOFF) != 0)
        .then(|| CoolerReadback {
            enabled: read_option(sdk, handle, OGMACAM_OPTION_TEC)
                .ok()
                .map(|v| v != 0),
            // -2730 and below stand for "the model's default", not a temperature.
            target_c: read_option(sdk, handle, OGMACAM_OPTION_TECTARGET)
                .ok()
                .filter(|&tenths| tenths > -2730)
                .map(|tenths| f64::from(tenths) / 10.0),
            target_range: read_option(sdk, handle, OGMACAM_OPTION_TECTARGET_RANGE)
                .ok()
                .map(|packed| {
                    (
                        f64::from(packed as i16) / 10.0,
                        f64::from((packed >> 16) as i16) / 10.0,
                    )
                })
                .filter(|(low, high)| low < high),
            tec_voltage_max: read_option(sdk, handle, OGMACAM_OPTION_TEC_VOLTAGE_MAX)
                .ok()
                .filter(|&max| max > 0),
        });

    // SAFETY: `handle` valid; `touptek_event_callback` is an `extern "system"` fn matching
    // PTOUPCAM_EVENT_CALLBACK; `ctx` points to the caller's live `event_state` box (freed
    // only after Stop+Close, see disconnect/Drop).
    let rc = unsafe { (sdk.start_pull_mode_with_callback)(handle, touptek_event_callback, ctx) };
    if rc < 0 {
        return Err(touptek_failure("start the camera's stream", name, rc));
    }

    Ok(StreamSetup {
        bayer_pattern,
        bit_depth,
        bytes_per_sample: if deep { 2 } else { 1 },
        rows_reversed,
        exposure_range_us,
        black_level_max,
        cooler,
    })
}

#[async_trait]
impl DeviceDriver for TouptekCamera {
    fn id(&self) -> &str {
        &self.core.device_id
    }

    fn name(&self) -> &str {
        &self.core.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Touptek
    }

    fn serial_number(&self) -> Option<String> {
        self.serial_number.clone()
    }

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.core.connected {
            return Ok(());
        }

        get_sdk_for_brand(&self.brand)?;

        let brand = self.brand.clone();
        let device_index = self.device_index;
        let sdk_device_id = self.sdk_device_id.clone();

        // Refresh device metadata, but select and open by the stable SDK ID captured during
        // discovery. The legacy index is used only when callers construct a camera directly
        // without first running discovery; even then it is resolved to an ID before Open().
        let (device_info, serial_number, sdk_size, gain_range) = {
            let lock = TOUPTEK_SDK_LOCK.lock().await;

            let device_info = with_sdk(&lock, &brand, |sdk| {
                let devices = enumerate_brand_devices_from_sdk(sdk, &brand);
                match sdk_device_id.as_deref() {
                    Some(stable_id) => devices
                        .into_iter()
                        .find(|device| device.camera_id == stable_id)
                        .ok_or_else(|| {
                            DriverError::DeviceNotFound(format!(
                                "the {} camera '{}' is no longer connected; check its USB cable and search for devices again",
                                brand, stable_id
                            ))
                        }),
                    None => devices.into_iter().nth(device_index).ok_or_else(|| {
                        DriverError::DeviceNotFound(format!(
                            "no {} camera at position {} is connected",
                            brand, device_index
                        ))
                    }),
                }
            })?;

            let handle = with_sdk(&lock, &brand, |sdk| {
                let h = open_touptek_device(sdk, &device_info.camera_id)?;
                if h.is_null() {
                    return Err(DriverError::SdkError(format!(
                        "Could not open {}: the {} SDK refused it. Close any other program using the camera (its ASCOM driver, SharpCap, NINA), replug it, and on Linux make sure its udev rules are installed",
                        device_info.name, brand
                    )));
                }
                Ok(h)
            })?;

            self.handle = SdkHandle(handle);

            let (serial_number, sdk_size, gain_range) = {
                let handle_val = self.handle.0;

                with_sdk(&lock, &brand, |sdk| {
                    let mut sn_buf = [0 as c_char; 64];
                    let mut serial = None;
                    // SAFETY: `handle_val` was just opened above (null-checked) and the per-camera `handle` mutex is held briefly during the load (handle.lock().unwrap_or_else); `sn_buf.as_mut_ptr()` points to a stack [i8; 64] buffer — Ogmacam_get_SerialNumber writes at most 64 bytes of a NUL-terminated ASCII serial per the SDK header.
                    if unsafe { (sdk.get_serial_number)(handle_val, sn_buf.as_mut_ptr()) } >= 0 {
                        // SAFETY: Ogmacam_get_SerialNumber populated `sn_buf` as a NUL-terminated C string above (return ≥ 0 confirms success); `sn_buf.as_ptr()` is valid for the duration of this stack [i8; 64] buffer and CStr::from_ptr reads up to the NUL.
                        let sn = unsafe { CStr::from_ptr(sn_buf.as_ptr()) }
                            .to_string_lossy()
                            .trim()
                            .to_string();
                        if !sn.is_empty() {
                            serial = Some(sn);
                        }
                    }

                    let mut width: c_int = 0;
                    let mut height: c_int = 0;
                    // SAFETY: `handle_val` valid (just opened); `&mut width` and `&mut height` are valid stack out-pointers to distinct c_int locals.
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
                    // SAFETY: `handle_val` valid; the three `&mut u16` out-pointers reference distinct stack locals; Ogmacam_get_ExpoAGainRange writes (min, max, def) values per the SDK header.
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
                        self.core.gain = i32::from(gain_def);
                        Some((i32::from(gain_min), i32::from(gain_max)))
                    };
                    if gain_range.is_none() {
                        // Without a range the default gain is unknown too; the live
                        // value is the only thing the camera can still be asked for.
                        let mut gain: u16 = 0;
                        // SAFETY: `handle_val` valid; `&mut gain` is a valid stack out-pointer for the SDK's unsigned-short gain value.
                        if unsafe { (sdk.get_expo_again)(handle_val, &mut gain) } >= 0 {
                            self.core.gain = i32::from(gain);
                        }
                    }

                    Ok((serial, sdk_size, gain_range))
                })?
            };

            (device_info, serial_number, sdk_size, gain_range)
        };

        self.sdk_device_id = Some(device_info.camera_id.clone());
        self.model_flags = device_info.model_flags;
        self.max_fan_speed = device_info.max_fan_speed;
        self.gain_range = gain_range;
        self.serial_number = serial_number.clone();
        let (sensor_width, sensor_height) =
            sdk_size.unwrap_or((device_info.width, device_info.height));
        self.core.name = match serial_number {
            Some(serial) => format!("{} ({})", device_info.name, serial),
            None => device_info.name.clone(),
        };

        self.core.capabilities = model_capabilities(self.model_flags);

        let quirk_lookup_id = format!(
            "native:touptek:{}:{}",
            self.brand.to_lowercase(),
            self.device_index
        );
        if let Some(delay_ms) = crate::quirks::get_connect_delay_ms(&quirk_lookup_id) {
            tracing::debug!(
                "Applying DelayAfterConnect quirk: sleeping {}ms before starting pull mode on {}",
                delay_ms,
                self.core.name
            );
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        // All option writes precede StartPullModeWithCallback and run on this
        // (non-callback) thread: the SDK refuses TRIGGER/BITDEPTH/BINNING/ROTATE from the
        // callback context.
        let setup = {
            let lock = TOUPTEK_SDK_LOCK.lock().await;
            let handle_val = self.handle.0;

            // Heap-stable state whose address we hand to the SDK as the callback context.
            // Boxing guarantees the pointee address survives `self` being moved into the
            // camera HashMap after connect.
            let event_state = Box::new(TouptekEventState::new());
            let ctx = &*event_state as *const TouptekEventState as *mut c_void;
            let name = self.core.name.clone();
            let model_flags = self.model_flags;

            let setup = with_sdk(&lock, &brand, |sdk| {
                configure_stream(sdk, handle_val, &name, model_flags, ctx).inspect_err(|_| {
                    // SAFETY: the stream did not start, so the callback can never fire;
                    // `handle_val` is the live handle Open() returned. Closing it keeps a
                    // failed negotiation from leaking a half-configured camera.
                    unsafe { (sdk.close)(handle_val) };
                })
            });
            match setup {
                Ok(setup) => {
                    // Pull mode is live; take ownership of the state so it outlives the callback.
                    self.event_state = Some(event_state);
                    setup
                }
                Err(e) => {
                    self.handle = SdkHandle(std::ptr::null_mut());
                    return Err(e);
                }
            }
        };

        self.core.sensor_info = SensorInfo {
            width: sensor_width,
            height: sensor_height,
            pixel_size_x: device_info.pixel_size_x as f64,
            pixel_size_y: device_info.pixel_size_y as f64,
            max_adu: max_adu_from_bit_depth(setup.bit_depth),
            bit_depth: setup.bit_depth,
            color: (self.model_flags & OGMACAM_FLAG_MONO) == 0,
            bayer_pattern: setup.bayer_pattern,
            saturation_adu: None,
        };
        self.bytes_per_sample = setup.bytes_per_sample;
        self.rows_reversed = setup.rows_reversed;
        self.exposure_range_us = setup.exposure_range_us;
        self.black_level_max = setup.black_level_max;
        self.core.subframe = None;
        self.core.bin_x = 1;
        self.core.bin_y = 1;
        self.forget_cooler_power();
        match setup.cooler {
            Some(cooler) => {
                self.cooler_target_range = cooler.target_range;
                self.tec_voltage_max = cooler.tec_voltage_max;
                self.core.update_cooler(|state| {
                    if let Some(enabled) = cooler.enabled {
                        state.enabled = enabled;
                    }
                    if let Some(target) = cooler.target_c {
                        state.target_c = target;
                    }
                });
            }
            None => {
                self.cooler_target_range = None;
                self.tec_voltage_max = None;
            }
        }

        self.core.connected = true;
        self.core.state = CameraState::Idle;

        tracing::info!(
            "Connected to Touptek camera: {} ({}x{}, {}-bit{})",
            self.core.name,
            self.core.sensor_info.width,
            self.core.sensor_info.height,
            self.core.sensor_info.bit_depth,
            if self.core.cooler().enabled {
                ", cooler on"
            } else {
                ""
            }
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.core.connected {
            return Ok(());
        }

        let brand = self.brand.clone();

        let lock = TOUPTEK_SDK_LOCK.lock().await;

        let handle = self.handle.0;

        // Teardown order is load-bearing: stop the pull-mode stream, then close the handle,
        // and only THEN drop the event-state box. Stop()+Close() quiesce the SDK's internal
        // streaming thread, so after they return no callback can fire; freeing the box
        // afterwards means the callback can never observe freed memory.
        with_sdk(&lock, &brand, |sdk| {
            // SAFETY: `handle` loaded from `self.handle`. Ogmacam_Stop
            // halts pull mode and joins the streaming thread; idempotent, handle-only arg.
            let _ = unsafe { (sdk.stop)(handle) };
            // SAFETY: `handle` valid (the camera is connected, checked at top).
            // Ogmacam_Close is the contractual release for Ogmacam_Open.
            unsafe { (sdk.close)(handle) };
            Ok(())
        })?;

        // Safe now: Stop()+Close() returned, so the SDK will not invoke the callback again.
        self.event_state = None;

        self.handle = SdkHandle(std::ptr::null_mut());
        self.core.connected = false;
        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;
        self.bytes_per_sample = 0;

        tracing::info!("Disconnected from Touptek camera: {}", self.core.name);

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
        let handle = self.handle.0;
        if !handle.is_null() {
            let mut quiesced = false;
            // Drop cannot await the async vendor lock. Only touch the SDK if try_lock
            // proves no other Touptek-family call is in flight.
            if let Some(lock) = TOUPTEK_SDK_LOCK.try_lock() {
                if get_sdk_for_brand(&self.brand).is_ok() {
                    quiesced = with_sdk(&lock, &self.brand, |sdk| {
                        // SAFETY: `handle` is the live handle
                        // owned by this camera. Stop then Close quiesces callbacks before
                        // the event-state box is allowed to drop.
                        unsafe { (sdk.stop)(handle) };
                        // SAFETY: same held lock and same handle as the Stop
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
                    self.core.name
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
        self.core.connected = false;
    }
}

impl TouptekCamera {
    /// `Disconnected` once the SDK has reported the camera gone.
    fn require_present(&self) -> Result<(), DriverError> {
        self.core.require_connected()?;
        match self.event_state.as_ref() {
            Some(es) if es.disconnected.load(Ordering::SeqCst) => Err(DriverError::Disconnected),
            _ => Ok(()),
        }
    }
}

#[async_trait]
impl CameraDriver for TouptekCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.require_present()?;

        let lock = TOUPTEK_SDK_LOCK.lock().await;
        let handle = self.handle.0;

        // The gain read is the liveness check: every model answers it, while a
        // thermometer, a cooler and a black level are model options.
        let gain = self.read_gain_locked(&lock, handle)?;
        let sensor_temp = self.read_temperature_locked(&lock, handle)?;
        let (cooler_on, cooler_power) = if self.core.capabilities.can_cool {
            (
                self.refresh_cooler_locked(&lock, handle),
                self.cooler_power_locked(&lock, handle),
            )
        } else {
            (false, None)
        };

        let exposure_remaining = if self.core.state == CameraState::Exposing {
            self.core.exposure_started_at.map(|started_at| {
                (self.core.exposure_duration - started_at.elapsed().as_secs_f64()).max(0.0)
            })
        } else {
            None
        };

        Ok(CameraStatus {
            state: self.core.state,
            sensor_temp,
            cooler_power,
            target_temp: self
                .core
                .capabilities
                .can_cool
                .then(|| self.core.cooler().target_c),
            cooler_on,
            gain,
            offset: self.core.offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.require_present()?;

        if let Some(gain) = params.gain {
            self.set_gain(gain).await?;
        }
        if let Some(offset) = params.offset {
            if self.core.capabilities.can_set_offset {
                self.set_offset(offset).await?;
            } else {
                tracing::debug!(
                    "{} has no black level control; offset {} not applied",
                    self.core.name,
                    offset
                );
            }
        }

        self.set_binning(params.bin_x, params.bin_y).await?;

        self.set_subframe(params.subframe.clone()).await?;

        // Shorter than the sensor's minimum (a bias frame) runs at the minimum, which the
        // frame then records; longer than its maximum is refused, never cut short.
        let (min_us, max_us) = self.exposure_range_us.unwrap_or((1, c_uint::MAX));
        let requested_us = (params.duration_secs * 1_000_000.0).round();
        if requested_us.is_nan() || requested_us > f64::from(max_us) {
            return Err(DriverError::InvalidParameter(format!(
                "{} takes exposures up to {} s, not {} s",
                self.core.name,
                f64::from(max_us) / 1_000_000.0,
                params.duration_secs
            )));
        }
        let exposure_us = (requested_us as c_uint).max(min_us);

        let brand = self.brand.clone();
        let lock = TOUPTEK_SDK_LOCK.lock().await;
        let handle = self.handle.0;

        // Set exposure time and fire ONE software-triggered frame, all within the SDK lock.
        let name = self.core.name.clone();
        with_sdk(&lock, &brand, |sdk| {
            // Forget the last exposure's events, and drop any frame the camera or the SDK
            // still holds (one read out after a cancel, or never downloaded), so the frame
            // pulled next is the one this trigger takes.
            if let Some(es) = self.event_state.as_ref() {
                es.clear_exposure();
            }
            // SAFETY: `handle` is this connected camera's live handle; POD arguments.
            let flushed = unsafe { (sdk.put_option)(handle, OGMACAM_OPTION_FLUSH, 3) };
            if flushed > 0 {
                tracing::info!(
                    "{name}: discarded {flushed} frame(s) left from an earlier exposure"
                );
            }

            // SAFETY: `handle` was loaded from `self.handle` while connected, guaranteeing a valid Ogmacam_Open handle. Ogmacam_put_ExpoTime takes (handle, c_uint microseconds) POD per the SDK header.
            let result = unsafe { (sdk.put_expo_time)(handle, exposure_us) };
            if result < 0 {
                return Err(touptek_failure(
                    &format!("set a {} s exposure", params.duration_secs),
                    &name,
                    result,
                ));
            }

            // Software trigger: nNumber = 1 requests exactly one frame, delivered as
            // EVENT_IMAGE and pulled in download_image(). OPTION_TRIGGER=1 was set in connect().
            // SAFETY: `handle` valid; Ogmacam_Trigger takes (handle, c_ushort) POD.
            let result = unsafe { (sdk.trigger)(handle, 1) };
            if result < 0 {
                return Err(touptek_failure("start the exposure", &name, result));
            }
            Ok(())
        })?;

        self.core.exposure_duration = params.duration_secs;
        self.core.exposure_started_at = Some(std::time::Instant::now());
        self.core.state = CameraState::Exposing;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.require_present()?;

        let brand = self.brand.clone();

        let lock = TOUPTEK_SDK_LOCK.lock().await;

        let handle = self.handle.0;

        let name = self.core.name.clone();
        with_sdk(&lock, &brand, |sdk| {
            // Cancel the software trigger with Trigger(0) — NOT Stop(), which would tear down
            // the pull-mode stream and break all subsequent exposures. This matches
            // indi_toupbase AbortExposure (Trigger(m_Handle, 0)) and keeps pull mode running.
            // SAFETY: `handle` was loaded from `self.handle` while connected, guaranteeing a valid handle; Ogmacam_Trigger takes (handle, c_ushort) POD per the SDK header.
            let result = unsafe { (sdk.trigger)(handle, 0) };
            if result < 0 {
                return Err(touptek_failure("cancel the exposure", &name, result));
            }
            Ok(())
        })?;

        if let Some(es) = self.event_state.as_ref() {
            es.clear_exposure();
        }

        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;
        tracing::info!("Aborted exposure on Touptek camera '{}'", self.core.name);
        Ok(())
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.require_present()?;

        // Wait for the software-triggered frame to arrive. The SDK's pull-mode callback flips
        // `image_ready` on EVENT_IMAGE and records EVENT_ERROR/NOFRAMETIMEOUT/DISCONNECTED.
        // We poll the atomics WITHOUT holding the Touptek SDK lock so unrelated SDK calls aren't
        // blocked for the whole exposure. Timeout = exposure + margin (>= the SDK frame timeout).
        let timeout_secs = self.core.exposure_duration * 1.1 + 5.0;
        let poll_start = std::time::Instant::now();
        loop {
            let es = self.event_state.as_ref().ok_or_else(|| {
                DriverError::SdkError(
                    "Touptek pull mode not started (event state missing)".to_string(),
                )
            })?;
            if es.disconnected.load(Ordering::SeqCst) {
                self.core.state = CameraState::Idle;
                self.core.exposure_started_at = None;
                return Err(DriverError::Disconnected);
            }
            match es.fault.load(Ordering::SeqCst) {
                0 => {}
                OGMACAM_EVENT_NOFRAMETIMEOUT => {
                    self.core.state = CameraState::Idle;
                    self.core.exposure_started_at = None;
                    return Err(DriverError::Timeout(format!(
                        "{} reported that no frame arrived from the sensor",
                        self.core.name
                    )));
                }
                OGMACAM_EVENT_TRIGGERFAIL => {
                    self.core.state = CameraState::Idle;
                    self.core.exposure_started_at = None;
                    return Err(DriverError::SdkError(format!(
                        "{} could not read out the frame (bad frame data or a timeout); check its USB cable and power",
                        self.core.name
                    )));
                }
                _ => {
                    self.core.state = CameraState::Idle;
                    self.core.exposure_started_at = None;
                    return Err(DriverError::SdkError(format!(
                        "{} reported an error during the exposure; check its USB cable and power",
                        self.core.name
                    )));
                }
            }
            if es.image_ready.load(Ordering::SeqCst) {
                break;
            }
            if poll_start.elapsed().as_secs_f64() > timeout_secs {
                self.core.state = CameraState::Idle;
                self.core.exposure_started_at = None;
                return Err(DriverError::Timeout(format!(
                    "Touptek camera '{}' did not deliver a frame within {:.1}s",
                    self.core.name, timeout_secs
                )));
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let brand = self.brand.clone();

        let lock = TOUPTEK_SDK_LOCK.lock().await;

        let handle = self.handle.0;

        let bytes_per_sample = self.bytes_per_sample;
        let layout = match bytes_per_sample {
            2 => SampleLayout::U16Little,
            1 => SampleLayout::U8Unscaled,
            other => {
                return Err(DriverError::SdkError(format!(
                    "Touptek camera '{}' has no negotiated sample size ({} bytes)",
                    self.core.name, other
                )))
            }
        };

        // Size the buffer from the ACTUAL current output resolution, not the full sensor: a
        // subframe/binned frame is smaller and would otherwise be mis-sized/skewed.
        // `get_FinalSize` reports the exact size after ROI + rotate + binning. If a white-label
        // SDK lacks the symbol we fall back to the ROI (or full sensor) dims, which are an
        // UPPER BOUND on the delivered frame (binning only shrinks), so the buffer is never
        // too small. The delivered frame is then sliced to `info.width`/`info.height`.
        let fallback_dims: (usize, usize) = match &self.core.subframe {
            Some(sf) => (
                sf.width as usize * self.core.bin_x.max(1) as usize,
                sf.height as usize * self.core.bin_y.max(1) as usize,
            ),
            None => (
                self.core.sensor_info.width as usize,
                self.core.sensor_info.height as usize,
            ),
        };

        let name = self.core.name.clone();
        let (mut data, info) = with_sdk(&lock, &brand, |sdk| {
            let (buf_w, buf_h) = if let Some(get_final) = sdk.get_final_size {
                let mut fw: c_int = 0;
                let mut fh: c_int = 0;
                // SAFETY: `handle` valid; two distinct stack out-pointers
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

            let buffer_size = buf_w
                .checked_mul(buf_h)
                .and_then(|pixels| pixels.checked_mul(bytes_per_sample))
                .ok_or_else(|| {
                    DriverError::SdkError(format!(
                        "Touptek buffer size overflow: {}x{} * {} bytes",
                        buf_w, buf_h, bytes_per_sample
                    ))
                })?;

            let mut buffer = vec![0u8; buffer_size];
            // SAFETY: OgmacamFrameInfoV3 is `#[repr(C)]` POD (c_uint/u64/u16); zero-init is the
            // valid empty state before Ogmacam_PullImageV3 overwrites it.
            let mut info: OgmacamFrameInfoV3 = unsafe { std::mem::zeroed() };

            // SAFETY: `handle` valid; `buffer` holds every output pixel at the negotiated
            // sample size (connect() set single-channel RAW). `&mut info` is a valid
            // `#[repr(C)]` out-pointer. bStill=0 pulls the live (software-triggered) image
            // signalled by EVENT_IMAGE; in RAW mode `bits` is ignored, and row pitch -1 asks
            // for rows without padding.
            let result = unsafe {
                (sdk.pull_image_v3)(
                    handle,
                    buffer.as_mut_ptr() as *mut c_void,
                    0,
                    16,
                    -1,
                    &mut info,
                )
            };
            if result < 0 {
                return Err(touptek_failure("download the frame", &name, result));
            }

            // Build the pixel Vec from the ACTUAL frame dims the SDK reported, guarding against
            // a frame that would not fit the allocated buffer.
            let pulled_bytes = (info.width as usize)
                .checked_mul(info.height as usize)
                .and_then(|pixels| pixels.checked_mul(bytes_per_sample))
                .filter(|&bytes| bytes > 0 && bytes <= buffer.len())
                .ok_or_else(|| {
                    DriverError::SdkError(format!(
                        "{} delivered a {}x{} frame that does not fit the {}x{} buffer",
                        name, info.width, info.height, buf_w, buf_h
                    ))
                })?;

            Ok((unpack_samples(&buffer[..pulled_bytes], layout), info))
        })?;
        if self.rows_reversed {
            flip_rows(&mut data, info.width as usize);
        }

        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;

        // What the camera did for this frame: the frame info when the model fills it,
        // else the camera's current setting.
        let exposure_time =
            if (info.flag & OGMACAM_FRAMEINFO_FLAG_EXPOTIME) != 0 && info.expotime > 0 {
                f64::from(info.expotime) / 1_000_000.0
            } else {
                self.core.exposure_duration
            };
        let gain = if (info.flag & OGMACAM_FRAMEINFO_FLAG_EXPOGAIN) != 0 {
            i32::from(info.expogain)
        } else {
            self.read_gain_locked(&lock, handle)?
        };
        let offset = if !self.core.capabilities.can_set_offset {
            0
        } else if (info.flag & OGMACAM_FRAMEINFO_FLAG_BLACKLEVEL) != 0 {
            i32::from(info.blacklevel)
        } else {
            self.read_option_locked(&lock, handle, OGMACAM_OPTION_BLACKLEVEL)
                .unwrap_or(self.core.offset)
        };
        let temperature = self
            .read_temperature_locked(&lock, handle)
            .unwrap_or_else(|e| {
                tracing::warn!("{e}; the frame carries no sensor temperature");
                None
            });

        Ok(Frame {
            exposure_time,
            gain,
            offset,
            temperature,
            ..self.core.frame(
                info.width,
                info.height,
                data,
                self.core.sensor_info.bit_depth,
                self.core.sensor_info.bayer_pattern,
            )
        }
        .into_image())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.core.require_connected()?;
        // The pull-mode event callback flips these when the SDK delivers a frame or reports a
        // fault. Reflecting them here lets the shared poll loop (`wait_for_exposure`) complete;
        // returning `true` on a fault lets the following `download_image` surface it.
        if let Some(es) = self.event_state.as_ref() {
            if es.image_ready.load(Ordering::SeqCst)
                || es.fault.load(Ordering::SeqCst) != 0
                || es.disconnected.load(Ordering::SeqCst)
            {
                return Ok(true);
            }
        }
        Ok(self.core.state != CameraState::Exposing)
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        self.require_present()?;

        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }

        // Only while cooling, and only when the caller named a setpoint:
        // switching the TEC off needs no target temperature.
        let target_temp = target_temp.filter(|_| enabled);

        let brand = self.brand.clone();

        let lock = TOUPTEK_SDK_LOCK.lock().await;

        let handle = self.handle.0;

        let name = self.core.name.clone();
        with_sdk(&lock, &brand, |sdk| {
            // SAFETY: `handle` was loaded from `self.handle` while connected, guaranteeing a valid handle. Ogmacam_put_Option takes (handle, c_uint option_id, c_int value) POD — OGMACAM_OPTION_TEC=0x08 with 0/1 toggles the thermoelectric cooler per the SDK header.
            let result = unsafe {
                (sdk.put_option)(handle, OGMACAM_OPTION_TEC, if enabled { 1 } else { 0 })
            };
            if result < 0 {
                return Err(touptek_failure(
                    if enabled {
                        "turn the cooler on"
                    } else {
                        "turn the cooler off"
                    },
                    &name,
                    result,
                ));
            }

            // Set target temperature (in 0.1 degrees Celsius).
            // Why: target_temp is f64 Celsius typically in [-50.0, 50.0]; * 10 fits in
            // i16's range [-32768, 32767] with plenty of room. f64 -> i16 saturating
            // truncation is well-defined for finite values; NaN saturates to 0 which the
            // SDK rejects.
            if let Some(target) = target_temp {
                let temp = (target * 10.0).round() as i16;
                // SAFETY: `handle` valid; Ogmacam_put_Temperature takes (handle, i16 in 0.1°C units) POD per the SDK header. Range clamping is the SDK's responsibility.
                let result = unsafe { (sdk.put_temperature)(handle, temp) };
                if result < 0 {
                    return Err(touptek_failure(
                        &format!("set the cooler to {:.1} C", target),
                        &name,
                        result,
                    ));
                }
            }
            Ok(())
        })?;

        self.core.update_cooler(|cooler| {
            cooler.enabled = enabled;
            if let Some(target) = target_temp {
                cooler.target_c = target;
            }
        });
        self.forget_cooler_power();
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.require_present()?;

        let lock = TOUPTEK_SDK_LOCK.lock().await;
        self.read_temperature_locked(&lock, self.handle.0)?
            .ok_or(DriverError::NotSupported)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.require_present()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }

        let lock = TOUPTEK_SDK_LOCK.lock().await;
        self.cooler_power_locked(&lock, self.handle.0)
            .ok_or(DriverError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        self.require_present()?;

        // Why: Touptek gain is a u16 (range 100..=10000 per the SDK header). A negative
        // i32 or one > u16::MAX is a caller bug, so we surface InvalidParameter rather
        // than silently truncate to a wrap-around gain that could destroy a frame.
        let gain_u16 = u16::try_from(gain).map_err(|_| {
            DriverError::InvalidParameter(format!(
                "Touptek gain {} out of u16 range (100..=10000 nominal)",
                gain
            ))
        })?;

        let brand = self.brand.clone();

        let lock = TOUPTEK_SDK_LOCK.lock().await;

        let handle = self.handle.0;

        let name = self.core.name.clone();
        let action = match self.gain_range {
            Some((min, max)) => format!("set gain {gain} (the camera takes {min} to {max})"),
            None => format!("set gain {gain}"),
        };
        with_sdk(&lock, &brand, |sdk| {
            // SAFETY: `handle` was loaded from `self.handle` while connected, guaranteeing a valid handle. Ogmacam_put_ExpoAGain takes (handle, u16 gain) POD per the SDK header.
            let result = unsafe { (sdk.put_expo_again)(handle, gain_u16) };
            if result < 0 {
                return Err(touptek_failure(&action, &name, result));
            }
            Ok(())
        })?;

        self.core.gain = gain;
        Ok(())
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        self.require_present()?;
        let max = self.black_level_max.ok_or(DriverError::NotSupported)?;
        if !(0..=max).contains(&offset) {
            return Err(DriverError::InvalidParameter(format!(
                "{} takes an offset from 0 to {}, not {}",
                self.core.name, max, offset
            )));
        }

        let lock = TOUPTEK_SDK_LOCK.lock().await;
        let handle = self.handle.0;
        let name = self.core.name.clone();
        with_sdk(&lock, &self.brand, |sdk| {
            // SAFETY: `handle` is this connected camera's live handle; POD arguments. The
            // black level can be changed while the camera streams.
            let result = unsafe { (sdk.put_option)(handle, OGMACAM_OPTION_BLACKLEVEL, offset) };
            if result < 0 {
                return Err(touptek_failure(
                    &format!("set offset {offset}"),
                    &name,
                    result,
                ));
            }
            Ok(())
        })?;

        self.core.offset = offset;
        Ok(())
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.require_present()?;

        if !self.core.capabilities.can_set_binning && (bin_x > 1 || bin_y > 1) {
            return Err(DriverError::NotSupported);
        }

        let brand = self.brand.clone();

        let lock = TOUPTEK_SDK_LOCK.lock().await;

        let handle = self.handle.0;

        // The SDK bins square only; the larger factor is the one applied.
        let bin_mode = bin_x.max(bin_y);
        let name = self.core.name.clone();
        let max_bx = self.core.capabilities.max_bin_x;
        let max_by = self.core.capabilities.max_bin_y;
        with_sdk(&lock, &brand, |sdk| {
            // SAFETY: `handle` was loaded from `self.handle` while connected, guaranteeing a valid handle; Ogmacam_put_Option takes (handle, c_uint option_id, c_int value) POD — OGMACAM_OPTION_BINNING=0x17 with the bin factor n (saturating add of n x n).
            let result = unsafe { (sdk.put_option)(handle, OGMACAM_OPTION_BINNING, bin_mode) };
            if result < 0 {
                return Err(touptek_failure(
                    &format!("bin {bin_x}x{bin_y} (at most {max_bx}x{max_by})"),
                    &name,
                    result,
                ));
            }
            Ok(())
        })?;

        self.core.bin_x = bin_mode;
        self.core.bin_y = bin_mode;
        Ok(())
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.require_present()?;

        if subframe.is_some() && !self.core.capabilities.can_subframe {
            return Err(DriverError::NotSupported);
        }

        let bin = self.core.bin_x.max(self.core.bin_y).max(1) as u32;
        let sensor_w = self.core.sensor_info.width;
        let sensor_h = self.core.sensor_info.height;
        let region = subframe
            .as_ref()
            .map(|sf| sensor_roi(sf, bin, sensor_w, sensor_h));
        // The SDK counts ROI rows in the order the rows arrive.
        let sdk_roi = region.map(|(x, y, w, h)| {
            if self.rows_reversed {
                (x, (sensor_h & !1) - y - h, w, h)
            } else {
                (x, y, w, h)
            }
        });

        let lock = TOUPTEK_SDK_LOCK.lock().await;
        let handle = self.handle.0;
        let name = self.core.name.clone();
        with_sdk(&lock, &self.brand, |sdk| {
            // (0, 0, 0, 0) restores the full sensor.
            let (x, y, w, h) = sdk_roi.unwrap_or((0, 0, 0, 0));
            // SAFETY: `handle` is this connected camera's live handle; Ogmacam_put_Roi takes
            // four c_uint values in unbinned sensor pixels.
            let result = unsafe { (sdk.put_roi)(handle, x, y, w, h) };
            if result < 0 {
                return Err(touptek_failure(
                    &format!("read out the region ({x}, {y}) {w}x{h} of the {sensor_w}x{sensor_h} sensor"),
                    &name,
                    result,
                ));
            }
            Ok(())
        })?;

        if let (Some(requested), Some((x, y, w, h))) = (&subframe, region) {
            let applied = SubFrame {
                start_x: x / bin,
                start_y: y / bin,
                width: w / bin,
                height: h / bin,
            };
            if (
                applied.start_x,
                applied.start_y,
                applied.width,
                applied.height,
            ) != (
                requested.start_x,
                requested.start_y,
                requested.width,
                requested.height,
            ) {
                tracing::debug!(
                    "{}: subframe {:?} read out as {:?}, the nearest region the sensor takes",
                    self.core.name,
                    requested,
                    applied
                );
            }
            self.core.subframe = Some(applied);
        } else {
            self.core.subframe = None;
        }
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        self.require_present()?;

        let lock = TOUPTEK_SDK_LOCK.lock().await;
        let handle = self.handle.0;
        self.read_gain_locked(&lock, handle)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        if !self.core.capabilities.can_set_offset {
            return Ok(0);
        }
        self.require_present()?;
        let lock = TOUPTEK_SDK_LOCK.lock().await;
        Ok(self
            .read_option_locked(&lock, self.handle.0, OGMACAM_OPTION_BLACKLEVEL)
            .unwrap_or(self.core.offset))
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
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

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError> {
        // Touptek cameras expose a single fixed readout mode.
        if mode.index == 0 || mode.name.eq_ignore_ascii_case("normal") {
            return Ok(());
        }
        Err(DriverError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        self.require_present()?;

        let lock = TOUPTEK_SDK_LOCK.lock().await;
        let handle_val = self.handle.0;

        with_sdk(&lock, &self.brand, |sdk| {
            // Each probe leaves its field `None` when the camera declines it, so an
            // unreported control is never rendered as a measured zero.
            let read = |option: c_uint| read_option(sdk, handle_val, option).ok();

            let mut features = VendorFeatures {
                hardware_binning: (self.model_flags & OGMACAM_FLAG_BINSKIP_SUPPORTED) != 0,
                ..VendorFeatures::default()
            };

            features.usb_bandwidth = read(OGMACAM_OPTION_BANDWIDTH).map(f64::from);

            if (self.model_flags & OGMACAM_FLAG_HEAT) != 0 {
                features.anti_dew_heater = read(OGMACAM_OPTION_HEAT).map(|level| level > 0);
            }

            // Fan speed is a step on the closed interval [0, max_fan_speed]; a
            // percentage is only meaningful once the model reports that ceiling.
            if (self.model_flags & OGMACAM_FLAG_FAN) != 0 && self.max_fan_speed > 0 {
                features.fan_power = read(OGMACAM_OPTION_FAN)
                    .map(|speed| f64::from(speed) * 100.0 / f64::from(self.max_fan_speed));
            }

            Ok(features)
        })
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;

        // Bounds captured from get_ExpoAGainRange at connect, in the SDK's percent-step
        // units where 100 == 1x.
        self.gain_range.ok_or_else(|| {
            DriverError::SdkError(format!(
                "Touptek camera '{}' did not report a gain range at connect",
                self.core.name
            ))
        })
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        self.black_level_max
            .map(|max| (0, max))
            .ok_or(DriverError::NotSupported)
    }

    async fn get_cooler_temp_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        Ok(self.cooler_target_range)
    }

    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        Ok(self
            .exposure_range_us
            .map(|(min, max)| (f64::from(min) / 1_000_000.0, f64::from(max) / 1_000_000.0)))
    }
}
