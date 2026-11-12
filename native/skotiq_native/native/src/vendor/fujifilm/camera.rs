//! `FujifilmCamera` state and inherent helpers.

use super::*;

/// Wrapper for camera handle to implement Send/Sync
/// SAFETY: The SDK mutex ensures exclusive access, making it safe to send between threads
pub(crate) struct HandleWrapper(pub(crate) XsdkHandle);
// SAFETY: The XsdkHandle raw pointer is never dereferenced or modified outside sections that hold the `FujifilmSdk` lock guard, apart from the bulb helpers below (see all call sites in this module — every `unsafe { (sdk.<fn>)(self.camera_handle.0, ...) }` block is inside an acquired-mutex scope). Marking Send is therefore equivalent to a hand-serialized capability.
unsafe impl Send for HandleWrapper {}
// SAFETY: Same justification as Send — every shared-reference use of HandleWrapper goes through the `FujifilmSdk` lock guard (bulb helpers excepted, see above), which serializes SDK access. The wrapper has no interior mutability.
unsafe impl Sync for HandleWrapper {}

impl std::fmt::Debug for HandleWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "HandleWrapper({:p})", self.0)
    }
}

#[derive(Debug)]
pub struct FujifilmCamera {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) serial_number: String,
    pub(crate) model: FujifilmModel,

    pub(crate) connected: bool,
    pub(crate) camera_handle: HandleWrapper,

    pub(crate) firmware_version: String,
    pub(crate) sensor_info: SensorInfo,

    // RAW sample-depth provenance. `refresh_raw_depth` folds these into
    // `sensor_info.bit_depth` / `sensor_info.max_adu`, preferring
    // measured-from-frame over SDK-reported over the model table.
    /// Bit depth the camera reports for itself: `XSDK_GetProp` with
    /// `API_CODE_GetRAWOutputDepth` (XAPIOpt.H:229) at connect, then
    /// `XSDK_ImageInformation::lImageBitDepth` (XAPI.H:123) for every RAW frame
    /// `XSDK_ReadImageInfo` describes.
    pub(crate) sdk_reported_bit_depth: Option<u32>,
    /// True bit depth of the last decoded RAF: `RawFrame::bits_per_pixel`.
    pub(crate) measured_bit_depth: Option<u32>,
    /// Container full scale of the last decoded RAF: `RawFrame::white_level`,
    /// i.e. LibRaw's `color.maximum` saturation level.
    pub(crate) measured_white_level: Option<u32>,

    pub(crate) is_exposing: bool,
    pub(crate) is_bulb_mode: bool,
    pub(crate) exposure_start: Option<Instant>,
    pub(crate) exposure_duration: Duration,

    pub(crate) live_view_active: bool,

    pub(crate) has_focus_control: bool,
    pub(crate) focus_min: i32,
    pub(crate) focus_max: i32,

    pub(crate) current_iso: i32,
    pub(crate) current_offset: i32,
    /// The fixed ISO values the body reported, lowest first.
    pub(crate) supported_isos: Vec<i32>,
    /// Whether long exposure noise reduction is still on after connect tried
    /// to switch it off: the body then shoots a dark after every frame.
    pub(crate) long_exposure_nr: bool,
}

/// Live view JPEG quality (`SDK_LIVEVIEW_QUALITY_*`).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum LiveViewQuality {
    /// The default: a GFX100S II refuses `Normal` outright (owner's NINA plugin,
    /// 3.1.0.0), and every body tested accepts `Fine`.
    #[default]
    Fine,
    Normal,
    /// Lowest bandwidth.
    Basic,
}

impl LiveViewQuality {
    pub(crate) fn to_sdk_code(self) -> c_long {
        match self {
            LiveViewQuality::Fine => SDK_LIVEVIEW_QUALITY_FINE,
            LiveViewQuality::Normal => SDK_LIVEVIEW_QUALITY_NORMAL,
            LiveViewQuality::Basic => SDK_LIVEVIEW_QUALITY_BASIC,
        }
    }
}

impl FujifilmCamera {
    pub fn new(device_info: &FujifilmDeviceInfo) -> Self {
        let serial = device_info
            .serial_number
            .clone()
            .unwrap_or_else(|| device_info.name.clone());
        let (width, height, pixel_size, bit_depth) = device_info.model.sensor_specs();

        Self {
            id: format!("native:fujifilm:{}", serial),
            name: device_info.name.clone(),
            serial_number: serial,
            model: device_info.model,
            connected: false,
            camera_handle: HandleWrapper(std::ptr::null_mut()),
            firmware_version: String::new(),
            sensor_info: SensorInfo {
                width,
                height,
                pixel_size_x: pixel_size,
                pixel_size_y: pixel_size,
                // Pre-first-frame estimate. Superseded by the camera-reported
                // depth at connect and by the decoded frame's measured white
                // level thereafter — see `refresh_raw_depth`.
                max_adu: resolve_max_adu(None, bit_depth),
                bit_depth,
                color: true,
                bayer_pattern: if device_info.model.is_xtrans() {
                    None // X-Trans is not Bayer
                } else {
                    Some(BayerPattern::Rggb) // GFX uses standard Bayer
                },
            },
            sdk_reported_bit_depth: None,
            measured_bit_depth: None,
            measured_white_level: None,
            is_exposing: false,
            is_bulb_mode: false,
            exposure_start: None,
            exposure_duration: Duration::ZERO,
            live_view_active: false,
            has_focus_control: false,
            focus_min: 0,
            focus_max: 0,
            current_iso: 800,
            current_offset: 0,
            supported_isos: Vec::new(),
            long_exposure_nr: false,
        }
    }

    /// Recompute the published sample depth from the best evidence available.
    ///
    /// Authority order, highest first:
    ///
    /// 1. **Measured from the frame** — `RawFrame::bits_per_pixel` and
    ///    `RawFrame::white_level` (LibRaw `color.maximum`) for the RAF this
    ///    driver last decoded. Exact, and the only source that survives the
    ///    user changing the body's RAW settings behind our back.
    /// 2. **Reported by the camera** — `XSDK_ImageInformation::lImageBitDepth`
    ///    (XAPI.H:123), populated by `XSDK_ReadImageInfo` for every frame, and
    ///    `XSDK_GetProp(API_CODE_GetRAWOutputDepth)` (XAPIOpt.H:229) at connect.
    ///    This is the only pre-decode source that tracks a GFX body switched to
    ///    `SDK_RAWOUTPUTDEPTH_16BIT` (XAPIOpt.H:585).
    /// 3. **Model table** — [`FujifilmModel::sensor_specs`], a static estimate.
    pub(crate) fn refresh_raw_depth(&mut self) {
        let bit_depth = resolve_bit_depth(
            self.measured_bit_depth,
            self.sdk_reported_bit_depth,
            self.model.sensor_specs().3,
        );
        self.sensor_info.bit_depth = bit_depth;
        self.sensor_info.max_adu = resolve_max_adu(self.measured_white_level, bit_depth);
    }

    /// Set the shutter speed (`code`, or bulb when `bulb` is 1), repeating
    /// while the camera reports itself busy: three more tries 250 ms apart, as
    /// the owner's drivers do.
    pub(crate) async fn set_shutter(
        &self,
        sdk: &FujifilmSdk,
        code: c_long,
        bulb: c_long,
        seconds: f64,
    ) -> Result<(), DriverError> {
        let mut retries_left = 3;
        loop {
            // SAFETY: `self.camera_handle.0` is the connected XSDK handle; XSDK_SetShutterSpeed takes (handle, c_long, c_long) POD arguments per XAPI.h.
            let result = unsafe { (sdk.set_shutter_speed)(self.camera_handle.0, code, bulb) };
            if result == XSDK_COMPLETE {
                return Ok(());
            }
            let (api_code, err_code) = last_error(self.camera_handle.0, sdk);
            if retries_left == 0 || !is_busy(err_code) {
                return Err(sdk_failure(
                    &format!("setting the shutter for a {seconds} s exposure"),
                    api_code,
                    err_code,
                ));
            }
            retries_left -= 1;
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }

    /// Select the supported ISO nearest to `requested` and record what the
    /// camera accepted.
    pub(crate) async fn apply_iso(
        &mut self,
        sdk: &FujifilmSdk,
        requested: i32,
    ) -> Result<(), DriverError> {
        let iso = nearest_sensitivity(&self.supported_isos, requested);
        if iso != requested {
            tracing::info!(
                "Fujifilm {}: ISO {} is not one of the camera's fixed values; using ISO {}",
                self.id,
                requested,
                iso
            );
        }
        // SAFETY: `self.camera_handle.0` is the connected XSDK handle; XSDK_SetSensitivity takes (handle, c_long) POD per XAPI.h.
        let result = unsafe { (sdk.set_sensitivity)(self.camera_handle.0, iso as c_long) };
        if result != XSDK_COMPLETE {
            return Err(sdk_error(
                self.camera_handle.0,
                sdk,
                &format!("setting ISO {iso}"),
            ));
        }
        self.current_iso = iso;
        tokio::time::sleep(Duration::from_millis(100)).await;
        Ok(())
    }

    /// The shutter codes the body offers in its current mode and ISO.
    pub(crate) fn shutter_speeds(&self, sdk: &FujifilmSdk) -> ShutterSpeeds {
        let mut count: c_long = 0;
        let mut bulb_capable: c_long = 0;
        // SAFETY: `self.camera_handle.0` is the connected XSDK handle; a NULL code buffer asks only for the count (SDK Programming Reference 4.1.9.4); both out-pointers are valid stack c_long locals.
        let result = unsafe {
            (sdk.cap_shutter_speed)(
                self.camera_handle.0,
                &mut count,
                std::ptr::null_mut(),
                &mut bulb_capable,
            )
        };
        if result != XSDK_COMPLETE || count <= 0 {
            tracing::warn!(
                "Fujifilm {}: the camera reported no shutter speeds (result {}); exposures of a second or more use bulb",
                self.id,
                result
            );
            return ShutterSpeeds::default();
        }
        let mut codes: Vec<c_long> = vec![0; count as usize];
        // SAFETY: `codes` holds exactly the `count` entries the first call reported, and `count` tells the SDK that capacity.
        let result = unsafe {
            (sdk.cap_shutter_speed)(
                self.camera_handle.0,
                &mut count,
                codes.as_mut_ptr(),
                &mut bulb_capable,
            )
        };
        if result != XSDK_COMPLETE {
            return ShutterSpeeds::default();
        }
        codes.truncate(count.max(0) as usize);
        ShutterSpeeds::from_reported(&codes)
    }

    pub(crate) async fn start_bulb_exposure(
        &mut self,
        duration_secs: f64,
    ) -> Result<(), DriverError> {
        // Unlocked on purpose: the bulb helpers sleep while the shutter is held, so
        // their callers release the SDK lock first (download_image, abort_exposure,
        // start_exposure) and only disconnect() still holds it. Taking the lock here
        // would deadlock in disconnect(), so these calls stay unserialized as before.
        let sdk = FujifilmSdk::installed()?.unlocked();
        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;

        // lBulb = 1 selects bulb; the shutter code is then ignored (SDK
        // Programming Reference 4.1.9.5).
        self.set_shutter(sdk, BULB_CODE as c_long, 1, duration_secs)
            .await?;
        tokio::time::sleep(Duration::from_millis(100)).await;

        // SAFETY: `self.camera_handle.0` was opened via XSDK_OpenEx in connect() and is still valid (connected==true); `&mut shot_opt` and `&mut af_status` are valid stack out-pointers to c_long; XSDK_RELEASE_S1ON is the documented half-press release flag from XAPI.h.
        let result = unsafe {
            (sdk.release)(
                self.camera_handle.0,
                XSDK_RELEASE_S1ON,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            return Err(sdk_error(
                self.camera_handle.0,
                sdk,
                "half-pressing the shutter for a bulb exposure",
            ));
        }
        // Both owner drivers wait 500 ms between the half press and the full
        // press; shorter pauses left bodies without an exposure.
        tokio::time::sleep(Duration::from_millis(500)).await;

        // SAFETY: `self.camera_handle.0` still valid; out-pointers valid c_long stack locals; XSDK_RELEASE_BULBS2_ON opens the shutter in bulb mode per XAPI.h's mandatory S1ON→BULBS2_ON sequence.
        let result = unsafe {
            (sdk.release)(
                self.camera_handle.0,
                XSDK_RELEASE_BULBS2_ON,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            let error = sdk_error(
                self.camera_handle.0,
                sdk,
                "opening the shutter for a bulb exposure",
            );
            // SAFETY: as above; N_S1OFF releases the half press so the body is not left holding it.
            unsafe {
                (sdk.release)(
                    self.camera_handle.0,
                    XSDK_RELEASE_N_S1OFF,
                    &mut shot_opt,
                    &mut af_status,
                )
            };
            return Err(error);
        }

        self.is_bulb_mode = true;
        self.exposure_start = Some(Instant::now());
        self.exposure_duration = Duration::from_secs_f64(duration_secs);
        self.is_exposing = true;

        Ok(())
    }

    /// Close the bulb shutter. The exposure the frame records becomes the time
    /// the shutter was actually held open.
    pub(crate) async fn stop_bulb_exposure(&mut self) -> Result<(), DriverError> {
        // Unlocked on purpose: the bulb helpers sleep while the shutter is held, so
        // their callers release the SDK lock first (download_image, abort_exposure,
        // start_exposure) and only disconnect() still holds it. Taking the lock here
        // would deadlock in disconnect(), so these calls stay unserialized as before.
        let sdk = FujifilmSdk::installed()?.unlocked();
        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;

        // SAFETY: `self.camera_handle.0` valid since `connected == true`; out-pointers valid c_long stack locals; XSDK_RELEASE_N_BULBS1OFF closes the shutter, completing the documented bulb sequence.
        let result = unsafe {
            (sdk.release)(
                self.camera_handle.0,
                XSDK_RELEASE_N_BULBS1OFF,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            return Err(sdk_error(
                self.camera_handle.0,
                sdk,
                "closing the shutter of the bulb exposure",
            ));
        }
        if let Some(opened) = self.exposure_start {
            self.exposure_duration = opened.elapsed();
        }

        self.is_bulb_mode = false;
        tokio::time::sleep(Duration::from_millis(100)).await;

        Ok(())
    }

    /// End the running exposure and throw away the frame it leaves behind: a
    /// cancelled or stopped exposure still lands a frame in the buffer, and
    /// left there it would be downloaded as the next exposure's frame
    /// (measured on a GFX100S II, owner's NINA plugin 3.1.0.0).
    pub(crate) async fn end_exposure_and_discard_frame(&mut self) -> Result<(), DriverError> {
        if !self.is_exposing {
            return Ok(());
        }
        if self.is_bulb_mode {
            self.stop_bulb_exposure().await?;
        } else {
            let sdk = FujifilmSdk::lock().await?;
            let mut shot_opt: c_long = 0;
            let mut status: c_long = 0;
            // SAFETY: `self.camera_handle.0` is the connected XSDK handle; out-pointers are valid stack c_long locals; XSDK_RELEASE_CANCEL ends a timed exposure in progress (XAPI.h).
            let result = unsafe {
                (sdk.release)(
                    self.camera_handle.0,
                    XSDK_RELEASE_CANCEL,
                    &mut shot_opt,
                    &mut status,
                )
            };
            if result != XSDK_COMPLETE {
                tracing::warn!(
                    "Fujifilm {}: the camera refused to cancel the timed exposure ({}); it runs to the end and its frame is discarded before the next exposure",
                    self.id,
                    sdk_error(self.camera_handle.0, &sdk, "cancelling the exposure")
                );
            }
        }
        self.is_exposing = false;
        self.exposure_start = None;

        // The frame appears once the body has read out the sensor.
        let mut discarded = 0;
        for _ in 0..12 {
            tokio::time::sleep(Duration::from_millis(250)).await;
            let sdk = FujifilmSdk::lock().await?;
            discarded += discard_buffered_frames(self.camera_handle.0, &sdk);
            if discarded > 0 && frames_in_buffer(self.camera_handle.0, &sdk).is_ok_and(|n| n == 0) {
                break;
            }
        }
        tracing::info!(
            "Fujifilm {}: exposure ended early; discarded {} frame(s) it left in the camera",
            self.id,
            discarded
        );
        Ok(())
    }

    /// Query focus capabilities from the lens
    ///
    /// Focus control requires:
    /// 1. Lens attached with electronic focus motor
    /// 2. Camera/lens in MF mode (focus mode switch)
    ///
    /// This method queries the SDK for focus position range. If the lens supports
    /// electronic focus control, `has_focus_control` will be set to true and
    /// `focus_min`/`focus_max` will contain the valid range.
    pub async fn query_focus_capabilities(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = FujifilmSdk::lock().await?;

        // Query focus position capabilities via get_prop
        // The SDK returns min position (near/MOD) and max position (infinity)
        let mut focus_min: c_long = 0;
        let mut focus_max: c_long = 0;
        let mut focus_cap: c_long = 0;

        // Use blocking operations to avoid raw pointer issues across await points
        // SAFETY: `self.camera_handle.0` is the connected XSDK handle; the three `&mut c_long` out-pointers reference distinct stack locals. The `API_CODE_CAP_FOCUS_POS` variant of XSDK_GetProp is the variadic form that takes three out-pointers per XAPI.h (returns capability + min/max focus position).
        let result = unsafe {
            (sdk.get_prop)(
                self.camera_handle.0,
                API_CODE_CAP_FOCUS_POS,
                0, // lApiParam
                &mut focus_min,
                &mut focus_max,
                &mut focus_cap,
            )
        };

        if result == XSDK_COMPLETE && focus_cap != 0 {
            self.has_focus_control = true;
            self.focus_min = focus_min as i32;
            self.focus_max = focus_max as i32;
            tracing::info!(
                "Focus control available: range [{}, {}]",
                self.focus_min,
                self.focus_max
            );
        } else {
            self.has_focus_control = false;
            self.focus_min = 0;
            self.focus_max = 0;
            tracing::debug!("Focus control not available (no electronic lens or not in MF mode)");
        }

        Ok(())
    }

    /// Get the current focus position
    ///
    /// Returns the current focus motor position within the range [focus_min, focus_max].
    /// Returns an error if focus control is not available.
    pub async fn get_focus_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        if !self.has_focus_control {
            return Err(DriverError::NotSupported);
        }

        let sdk = FujifilmSdk::lock().await?;

        let mut pos: c_long = 0;
        // SAFETY: `self.camera_handle.0` valid; `&mut pos` is a valid stack out-pointer to c_long; the `API_CODE_GET_FOCUS_POS` variant of XSDK_GetProp takes a single c_long out-pointer per XAPI.h.
        let result = unsafe {
            (sdk.get_prop)(
                self.camera_handle.0,
                API_CODE_GET_FOCUS_POS,
                API_PARAM_ONE_VALUE,
                &mut pos,
            )
        };

        if result != XSDK_COMPLETE {
            return Err(sdk_error(
                self.camera_handle.0,
                &sdk,
                "reading the focus position",
            ));
        }

        Ok(pos as i32)
    }

    /// Move the focus motor to `position`, which must lie in the
    /// `[focus_min, focus_max]` range `query_focus_capabilities` reported.
    ///
    /// The motor settling delay uses a blocking `std::thread::sleep` so no raw
    /// pointer is held across an await point.
    pub async fn set_focus_position(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        if !self.has_focus_control {
            return Err(DriverError::NotSupported);
        }

        if position < self.focus_min || position > self.focus_max {
            return Err(DriverError::InvalidParameter(format!(
                "Focus position {} out of range [{}, {}]",
                position, self.focus_min, self.focus_max
            )));
        }

        let sdk = FujifilmSdk::lock().await?;

        // SAFETY: `self.camera_handle.0` valid; `position` was range-checked above (`position >= focus_min && position <= focus_max`); XSDK_SetProp's value-form takes a c_long input value (no out-pointers) per XAPI.h.
        let result = unsafe {
            (sdk.set_prop)(
                self.camera_handle.0,
                API_CODE_SET_FOCUS_POS,
                API_PARAM_ONE_VALUE,
                position as c_long,
            )
        };

        if result != XSDK_COMPLETE {
            return Err(sdk_error(
                self.camera_handle.0,
                &sdk,
                "moving the lens focus",
            ));
        }

        // Use blocking sleep to allow focus motor to settle
        // (avoid raw pointer across await point)
        std::thread::sleep(Duration::from_millis(200));

        tracing::debug!("Focus position set to {}", position);
        Ok(())
    }

    /// Check if focus control is available
    ///
    /// Returns true if the attached lens supports electronic focus control
    /// and the camera is in MF mode. Call `query_focus_capabilities` first
    /// to populate this value.
    pub fn has_focus_control(&self) -> bool {
        self.has_focus_control
    }

    /// Get the focus position range
    ///
    /// Returns (min, max) focus positions, or (0, 0) if focus control is not available.
    pub fn get_focus_range(&self) -> (i32, i32) {
        (self.focus_min, self.focus_max)
    }

    /// Start live view streaming at `quality`; frames are then read as JPEG data
    /// through `read_live_view_frame()`.
    ///
    /// The waits between SDK calls use a blocking `std::thread::sleep` so no raw
    /// pointer is held across an await point.
    pub async fn start_live_view(&mut self, quality: LiveViewQuality) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        if self.live_view_active {
            return Ok(());
        }

        let sdk = FujifilmSdk::lock().await?;

        // Copy handle to local variable to avoid packed struct issues across FFI calls
        let handle = self.camera_handle.0;

        // Set quality via XSDK_SetProp(hCamera, API_CODE, 0, value)
        let quality_code = quality.to_sdk_code();
        // SAFETY: `handle` was copied from `self.camera_handle.0` (the connected XSDK handle); XSDK_SetProp's value-form takes four POD c_long arguments (handle, api_code, api_param, value) with no out-pointers per XAPI.h. `quality_code` comes from the LiveViewQuality enum's documented SDK code mapping.
        let result = unsafe {
            (sdk.set_prop)(
                handle,
                API_CODE_SET_LIVE_VIEW_IMAGE_QUALITY,
                API_PARAM_ONE_VALUE,
                quality_code,
            )
        };
        if result != XSDK_COMPLETE {
            tracing::warn!("Failed to set live view quality: {}", result);
            // Continue anyway, some cameras may not support quality setting
        }

        // Use blocking sleep to avoid raw pointer across await issues
        std::thread::sleep(Duration::from_millis(50));

        // Set size (use Large for best framing assistance in astrophotography)
        // SAFETY: `handle` valid; XSDK_SetProp value-form with POD c_long inputs only; `SDK_LIVEVIEW_SIZE_L` is the documented "Large" size constant from XAPI.h.
        let result = unsafe {
            (sdk.set_prop)(
                handle,
                API_CODE_SET_LIVE_VIEW_IMAGE_SIZE,
                API_PARAM_ONE_VALUE,
                SDK_LIVEVIEW_SIZE_L,
            )
        };
        if result != XSDK_COMPLETE {
            tracing::warn!("Failed to set live view size: {}", result);
            // Continue anyway, some cameras may not support size setting
        }

        std::thread::sleep(Duration::from_millis(50));

        // SAFETY: `handle` valid; XSDK_SetProp's 3-argument start-action form takes (handle, api_code, api_param) with no value — this is the variadic action invocation per XAPI.h for API_CODE_START_LIVE_VIEW.
        let result = unsafe { (sdk.set_prop)(handle, API_CODE_START_LIVE_VIEW, API_PARAM_NONE) };
        if result != XSDK_COMPLETE {
            return Err(DriverError::SdkError(format!(
                "Failed to start live view: SDK returned {}",
                result
            )));
        }

        self.live_view_active = true;
        tracing::info!("Fujifilm live view started with quality {:?}", quality);

        Ok(())
    }

    /// Raw JPEG data for the current live view frame; call repeatedly to stream.
    ///
    /// Packed struct fields are copied to locals before use, because reading them
    /// in place would be a misaligned reference.
    pub async fn read_live_view_frame(&self) -> Result<Vec<u8>, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        if !self.live_view_active {
            return Err(DriverError::SdkError("Live view is not active".into()));
        }

        let sdk = FujifilmSdk::lock().await?;

        // Copy handle to local variable for safety
        let handle = self.camera_handle.0;

        // Live view frames come through ReadImageInfo with XSDK_IMAGEFORMAT_LIVE
        let mut img_info = XsdkImageInformation::default();
        // SAFETY: `handle` is a valid open XSDK handle (we early-return on !connected); `&mut img_info` is a valid stack out-pointer to a `#[repr(C, packed)]` XsdkImageInformation that the SDK populates per XAPI.h. We deliberately copy packed fields out into locals (`img_format`, `data_size`) on subsequent lines before reading to avoid misaligned-reference UB.
        let result = unsafe { (sdk.read_image_info)(handle, &mut img_info) };

        // Copy packed struct fields to local variables before using them
        let img_format = img_info.l_format;
        let data_size = img_info.l_data_size;

        if result != XSDK_COMPLETE {
            return Err(DriverError::SdkError(
                "Failed to read live view frame info".into(),
            ));
        }

        if BufferedImage::from_format(img_format) != BufferedImage::LiveView {
            return Err(DriverError::SdkError(format!(
                "Expected a live view frame, got image format 0x{img_format:X}"
            )));
        }

        if data_size <= 0 {
            return Err(DriverError::SdkError("No live view frame available".into()));
        }

        let buffer_size = data_size as usize;
        let mut buffer = vec![0u8; buffer_size];
        // SAFETY: `handle` valid; `buffer.as_mut_ptr()` points to a Vec<u8> of exactly `buffer_size` bytes (just allocated above with vec![0u8; buffer_size]); we pass that same size as the third argument so XSDK_ReadImage will not write past the allocation per XAPI.h (the SDK clamps to the supplied buffer size).
        let result =
            unsafe { (sdk.read_image)(handle, buffer.as_mut_ptr(), buffer_size as c_ulong) };

        if result != XSDK_COMPLETE {
            return Err(DriverError::SdkError(
                "Failed to read live view frame data".into(),
            ));
        }

        // XSDK_ReadImage already removed the frame from the buffer; deleting
        // again would drop the next one.
        Ok(buffer) // Returns JPEG data
    }

    pub async fn stop_live_view(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        if !self.live_view_active {
            return Ok(());
        }

        let sdk = FujifilmSdk::lock().await?;

        // Copy handle to local variable for safety
        let handle = self.camera_handle.0;

        // SAFETY: `handle` was copied from `self.camera_handle.0` which is valid while `connected == true`; XSDK_SetProp's 3-argument action form for API_CODE_STOP_LIVE_VIEW takes only (handle, api_code, api_param) per XAPI.h.
        let result = unsafe { (sdk.set_prop)(handle, API_CODE_STOP_LIVE_VIEW, API_PARAM_NONE) };

        if result != XSDK_COMPLETE {
            tracing::warn!("Failed to stop live view cleanly: SDK returned {}", result);
            // Still mark as inactive even if the SDK call failed
        }

        self.live_view_active = false;
        tracing::info!("Fujifilm live view stopped");

        Ok(())
    }

    pub fn is_live_view_active(&self) -> bool {
        self.live_view_active
    }
}
