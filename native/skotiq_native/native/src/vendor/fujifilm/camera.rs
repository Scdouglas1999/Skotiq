//! `FujifilmCamera` state and inherent helpers.

use super::*;

/// Wrapper for camera handle to implement Send/Sync
/// SAFETY: The SDK mutex ensures exclusive access, making it safe to send between threads
pub(crate) struct HandleWrapper(pub(crate) XsdkHandle);
// SAFETY: The XsdkHandle raw pointer is never dereferenced or modified outside `fujifilm_mutex().lock().await` sections (see all call sites in this module — every `unsafe { (sdk.<fn>)(self.camera_handle.0, ...) }` block is inside an acquired-mutex scope). Marking Send is therefore equivalent to a hand-serialized capability.
unsafe impl Send for HandleWrapper {}
// SAFETY: Same justification as Send — every shared-reference use of HandleWrapper goes through the fujifilm_mutex, which serializes all SDK access. No interior mutability is reachable without the mutex.
unsafe impl Sync for HandleWrapper {}

impl std::fmt::Debug for HandleWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "HandleWrapper({:p})", self.0)
    }
}

/// Fujifilm camera driver
#[derive(Debug)]
pub struct FujifilmCamera {
    // Device identification
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) serial_number: String,
    pub(crate) model: FujifilmModel,

    // Connection state
    pub(crate) connected: bool,
    pub(crate) camera_handle: HandleWrapper,

    // Camera properties
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
    /// True bit depth of the last decoded RAF: `CfaImage::bits_per_pixel`.
    pub(crate) measured_bit_depth: Option<u32>,
    /// Container full scale of the last decoded RAF: `CfaImage::max_value`,
    /// i.e. LibRaw's `color.maximum` saturation level.
    pub(crate) measured_white_level: Option<u32>,

    // Exposure state
    pub(crate) is_exposing: bool,
    pub(crate) is_bulb_mode: bool,
    pub(crate) exposure_start: Option<Instant>,
    pub(crate) exposure_duration: Duration,

    // Live view state
    pub(crate) live_view_active: bool,

    // Focus control state
    pub(crate) has_focus_control: bool,
    pub(crate) focus_min: i32,
    pub(crate) focus_max: i32,

    // Current settings
    pub(crate) current_iso: i32,
    pub(crate) current_offset: i32,
    pub(crate) supported_isos: Vec<c_long>,
    pub(crate) supports_bulb: bool,
}

impl FujifilmCamera {
    /// Create a new Fujifilm camera instance
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
            supports_bulb: true,
        }
    }

    /// Recompute the published sample depth from the best evidence available.
    ///
    /// Authority order, highest first:
    ///
    /// 1. **Measured from the frame** — `CfaImage::bits_per_pixel` and
    ///    `CfaImage::max_value` (LibRaw `color.maximum`) for the RAF this
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

    /// Start a bulb exposure
    pub(crate) async fn start_bulb_exposure(
        &mut self,
        duration_secs: f64,
    ) -> Result<(), NativeError> {
        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;

        // Set shutter to BULB mode
        // SAFETY: caller (start_exposure) holds fujifilm_mutex; `self.camera_handle.0` was opened via XSDK_OpenEx in connect() and is still valid (connected==true); XSDK_SetShutterSpeed takes (handle, c_long, c_long) all POD arguments per XAPI.h.
        unsafe { (sdk.set_shutter_speed)(self.camera_handle.0, XSDK_SHUTTER_BULB, 0) };
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Start bulb: Half-press (S1ON)
        // SAFETY: caller holds fujifilm_mutex; `self.camera_handle.0` is the valid XSDK_OpenEx handle; `&mut shot_opt` and `&mut af_status` are valid stack out-pointers to c_long; XSDK_RELEASE_S1ON is the documented half-press release flag from XAPI.h.
        let result = unsafe {
            (sdk.release)(
                self.camera_handle.0,
                XSDK_RELEASE_S1ON,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            return check_xapi_error(self.camera_handle.0, sdk);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Full press to open shutter (BULBS2_ON)
        // SAFETY: caller holds fujifilm_mutex; `self.camera_handle.0` still valid; out-pointers valid c_long stack locals; XSDK_RELEASE_BULBS2_ON opens the shutter in bulb mode per XAPI.h's mandatory S1ON→BULBS2_ON sequence (also documented in this module's header).
        let result = unsafe {
            (sdk.release)(
                self.camera_handle.0,
                XSDK_RELEASE_BULBS2_ON,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            return check_xapi_error(self.camera_handle.0, sdk);
        }

        self.is_bulb_mode = true;
        self.exposure_start = Some(Instant::now());
        self.exposure_duration = Duration::from_secs_f64(duration_secs);
        self.is_exposing = true;

        Ok(())
    }

    /// Stop a bulb exposure
    pub(crate) async fn stop_bulb_exposure(&mut self) -> Result<(), NativeError> {
        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;

        // End bulb: Release S2 and S1
        // SAFETY: caller holds fujifilm_mutex (acquired in start_exposure → start_bulb_exposure, kept by stop_bulb_exposure callers); `self.camera_handle.0` valid since `connected == true`; out-pointers valid c_long stack locals; XSDK_RELEASE_N_BULBS1OFF closes the shutter, completing the documented bulb sequence (header §Important SDK Behaviors).
        let result = unsafe {
            (sdk.release)(
                self.camera_handle.0,
                XSDK_RELEASE_N_BULBS1OFF,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            return check_xapi_error(self.camera_handle.0, sdk);
        }

        self.is_bulb_mode = false;
        tokio::time::sleep(Duration::from_millis(100)).await;

        Ok(())
    }

    // Focus control

    /// Query focus capabilities from the lens
    ///
    /// Focus control requires:
    /// 1. Lens attached with electronic focus motor
    /// 2. Camera/lens in MF mode (focus mode switch)
    ///
    /// This method queries the SDK for focus position range. If the lens supports
    /// electronic focus control, `has_focus_control` will be set to true and
    /// `focus_min`/`focus_max` will contain the valid range.
    pub async fn query_focus_capabilities(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // Query focus position capabilities via get_prop
        // The SDK returns min position (near/MOD) and max position (infinity)
        let mut focus_min: c_long = 0;
        let mut focus_max: c_long = 0;
        let mut focus_cap: c_long = 0;

        // Use blocking operations to avoid raw pointer issues across await points
        // SAFETY: fujifilm_mutex held above; `self.camera_handle.0` is the connected XSDK handle; the three `&mut c_long` out-pointers reference distinct stack locals. The `API_CODE_CAP_FOCUS_POS` variant of XSDK_GetProp is the variadic form that takes three out-pointers per XAPI.h (returns capability + min/max focus position).
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
    pub async fn get_focus_position(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.has_focus_control {
            return Err(NativeError::NotSupported);
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        let mut pos: c_long = 0;
        // SAFETY: fujifilm_mutex held above; `self.camera_handle.0` valid; `&mut pos` is a valid stack out-pointer to c_long; the `API_CODE_GET_FOCUS_POS` variant of XSDK_GetProp takes a single c_long out-pointer per XAPI.h.
        let result = unsafe {
            (sdk.get_prop)(
                self.camera_handle.0,
                API_CODE_GET_FOCUS_POS,
                0, // lApiParam
                &mut pos,
            )
        };

        if result != XSDK_COMPLETE {
            check_xapi_error(self.camera_handle.0, sdk)?;
            // If check_xapi_error didn't return an error, return a generic one
            return Err(NativeError::SdkError("Failed to get focus position".into()));
        }

        Ok(pos as i32)
    }

    /// Move the focus motor to `position`, which must lie in the
    /// `[focus_min, focus_max]` range `query_focus_capabilities` reported.
    ///
    /// The motor settling delay uses a blocking `std::thread::sleep` so no raw
    /// pointer is held across an await point.
    pub async fn set_focus_position(&mut self, position: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.has_focus_control {
            return Err(NativeError::NotSupported);
        }

        // Validate position is within range
        if position < self.focus_min || position > self.focus_max {
            return Err(NativeError::InvalidParameter(format!(
                "Focus position {} out of range [{}, {}]",
                position, self.focus_min, self.focus_max
            )));
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // SAFETY: fujifilm_mutex held above; `self.camera_handle.0` valid; `position` was range-checked above (`position >= focus_min && position <= focus_max`); XSDK_SetProp's value-form takes a c_long input value (no out-pointers) per XAPI.h.
        let result = unsafe {
            (sdk.set_prop)(
                self.camera_handle.0,
                API_CODE_SET_FOCUS_POS,
                0, // lApiParam
                position as c_long,
            )
        };

        if result != XSDK_COMPLETE {
            return check_xapi_error(self.camera_handle.0, sdk);
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

    // Live view

    /// Start live view streaming at `quality`; frames are then read as JPEG data
    /// through `read_live_view_frame()`.
    ///
    /// The waits between SDK calls use a blocking `std::thread::sleep` so no raw
    /// pointer is held across an await point.
    pub async fn start_live_view(&mut self, quality: LiveViewQuality) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if self.live_view_active {
            // Already active, just return success
            return Ok(());
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // Copy handle to local variable to avoid packed struct issues across FFI calls
        let handle = self.camera_handle.0;

        // Set quality via XSDK_SetProp(hCamera, API_CODE, 0, value)
        let quality_code = quality.to_sdk_code();
        // SAFETY: fujifilm_mutex held above; `handle` was copied from `self.camera_handle.0` (the connected XSDK handle); XSDK_SetProp's value-form takes four POD c_long arguments (handle, api_code, api_param, value) with no out-pointers per XAPI.h. `quality_code` comes from the LiveViewQuality enum's documented SDK code mapping.
        let result = unsafe {
            (sdk.set_prop)(
                handle,
                API_CODE_SET_LIVE_VIEW_IMAGE_QUALITY,
                0,
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
        // SAFETY: fujifilm_mutex held above; `handle` valid; XSDK_SetProp value-form with POD c_long inputs only; `SDK_LIVEVIEW_SIZE_L` is the documented "Large" size constant from XAPI.h.
        let result = unsafe {
            (sdk.set_prop)(
                handle,
                API_CODE_SET_LIVE_VIEW_IMAGE_SIZE,
                0,
                SDK_LIVEVIEW_SIZE_L,
            )
        };
        if result != XSDK_COMPLETE {
            tracing::warn!("Failed to set live view size: {}", result);
            // Continue anyway, some cameras may not support size setting
        }

        std::thread::sleep(Duration::from_millis(50));

        // Start live view
        // SAFETY: fujifilm_mutex held above; `handle` valid; XSDK_SetProp's 3-argument start-action form takes (handle, api_code, api_param) with no value — this is the variadic action invocation per XAPI.h for API_CODE_START_LIVE_VIEW.
        let result = unsafe { (sdk.set_prop)(handle, API_CODE_START_LIVE_VIEW, 0) };
        if result != XSDK_COMPLETE {
            return Err(NativeError::SdkError(format!(
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
    pub async fn read_live_view_frame(&self) -> Result<Vec<u8>, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.live_view_active {
            return Err(NativeError::SdkError("Live view is not active".into()));
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // Copy handle to local variable for safety
        let handle = self.camera_handle.0;

        // Live view frames come through ReadImageInfo with XSDK_IMAGEFORMAT_LIVE
        let mut img_info = XsdkImageInformation::default();
        // SAFETY: fujifilm_mutex held above (in read_live_view_frame); `handle` is a valid open XSDK handle (we early-return on !connected); `&mut img_info` is a valid stack out-pointer to a `#[repr(C, packed)]` XsdkImageInformation that the SDK populates per XAPI.h. We deliberately copy packed fields out into locals (`img_format`, `data_size`) on subsequent lines before reading to avoid misaligned-reference UB.
        let result = unsafe { (sdk.read_image_info)(handle, &mut img_info) };

        // Copy packed struct fields to local variables before using them
        let img_format = img_info.l_format;
        let data_size = img_info.l_data_size;

        if result != XSDK_COMPLETE {
            return Err(NativeError::SdkError(
                "Failed to read live view frame info".into(),
            ));
        }

        if img_format != XSDK_IMAGEFORMAT_LIVE {
            return Err(NativeError::SdkError(format!(
                "Expected live view format ({}), got format {}",
                XSDK_IMAGEFORMAT_LIVE, img_format
            )));
        }

        if data_size <= 0 {
            return Err(NativeError::SdkError("No live view frame available".into()));
        }

        let buffer_size = data_size as usize;
        let mut buffer = vec![0u8; buffer_size];
        // SAFETY: fujifilm_mutex held; `handle` valid; `buffer.as_mut_ptr()` points to a Vec<u8> of exactly `buffer_size` bytes (just allocated above with vec![0u8; buffer_size]); we pass that same size as the third argument so XSDK_ReadImage will not write past the allocation per XAPI.h (the SDK clamps to the supplied buffer size).
        let result =
            unsafe { (sdk.read_image)(handle, buffer.as_mut_ptr(), buffer_size as c_ulong) };

        if result != XSDK_COMPLETE {
            return Err(NativeError::SdkError(
                "Failed to read live view frame data".into(),
            ));
        }

        // Delete the image from the buffer to make room for the next frame
        // SAFETY: fujifilm_mutex held; `handle` valid; XSDK_DeleteImage takes only the handle and clears the SDK-side image queue entry per XAPI.h. No out-pointers.
        unsafe { (sdk.delete_image)(handle) };

        Ok(buffer) // Returns JPEG data
    }

    /// Stop live view streaming
    ///
    /// # Returns
    ///
    /// `Ok(())` if live view stopped successfully, or an error if it failed.
    pub async fn stop_live_view(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if !self.live_view_active {
            // Not active, just return success
            return Ok(());
        }

        let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = fujifilm_mutex().lock().await;

        // Copy handle to local variable for safety
        let handle = self.camera_handle.0;

        // SAFETY: fujifilm_mutex held above (in stop_live_view); `handle` was copied from `self.camera_handle.0` which is valid while `connected == true`; XSDK_SetProp's 3-argument action form for API_CODE_STOP_LIVE_VIEW takes only (handle, api_code, api_param) per XAPI.h.
        let result = unsafe { (sdk.set_prop)(handle, API_CODE_STOP_LIVE_VIEW, 0) };

        if result != XSDK_COMPLETE {
            tracing::warn!("Failed to stop live view cleanly: SDK returned {}", result);
            // Still mark as inactive even if the SDK call failed
        }

        self.live_view_active = false;
        tracing::info!("Fujifilm live view stopped");

        Ok(())
    }

    /// Check if live view is currently active
    pub fn is_live_view_active(&self) -> bool {
        self.live_view_active
    }
}
