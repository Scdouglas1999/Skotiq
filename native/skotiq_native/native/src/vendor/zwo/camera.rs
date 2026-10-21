//! `ZwoCamera` state and inherent helpers.

use super::*;

/// Locally-tracked cooler state.
///
/// The ZWO SDK does not expose a reliable boolean read of "is the cooler currently
/// commanded on?". `ASIGetControlValue(ASI_COOLER_ON)` is queried first and used
/// when it succeeds; if the SDK call fails or the camera lacks a cooler, the value
/// last written via `set_cooler` is the canonical source of truth. Without this
/// `get_status` would have to lie and report `cooler_on: false` after the user
/// commanded it on.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CoolerState {
    pub(crate) enabled: bool,
    pub(crate) target_c: f64,
}

impl Default for CoolerState {
    fn default() -> Self {
        // -10 C is the documented power-on default the SDK picks for the target
        // register; using it here keeps `target_temp` consistent across drivers.
        Self {
            enabled: false,
            target_c: -10.0,
        }
    }
}

/// The cooler set-point a ZWO camera can hold for a requested `target_c`:
/// `ASI_TARGET_TEMP` is whole degrees Celsius, so the request rounds to the
/// nearest one.
pub(crate) fn zwo_target_degrees(target_c: f64) -> f64 {
    target_c.round()
}

/// Full-scale ADU of the delivered pixel container for a ZWO sensor of
/// `bit_depth` bits read out as [`ASIImgType::Raw16`].
///
/// The ASI SDK left-justifies sub-16-bit samples into the 16-bit buffer, so a
/// 12-bit ADC produces values that are multiples of 16 spanning `0 ..= 4095 <<
/// 4` (65520) — NOT `0 ..= 4095`. Verified on a live ASI1600MM-Cool: a
/// nowhere-near-saturated 2 ms frame measured min 3856, max 5792, median 4464
/// (every one an exact multiple of 16), and a saturated frame clipped at 65504
/// (`4094 << 4`). Reporting `(1 << bit_depth) - 1` here made
/// `/api/equipment/camera/status` claim `maxAdu: 4095` for the same camera whose
/// frames reach 65504 — a 16x error that made every percent-of-full-scale
/// consumer (flat-frame targets above all) unreachable.
///
/// `bit_depth >= 16` needs no shift. `bit_depth == 0` means the SDK never
/// populated the property; fall back to the container's own ceiling rather than
/// underflowing to 0, which would report "this camera cannot produce any signal".
pub(crate) fn raw16_container_max_adu(bit_depth: u32) -> u32 {
    const CONTAINER_BITS: u32 = 16;
    const CONTAINER_MAX: u32 = u16::MAX as u32;
    if bit_depth == 0 || bit_depth >= CONTAINER_BITS {
        return CONTAINER_MAX;
    }
    (((1u32 << bit_depth) - 1) << (CONTAINER_BITS - bit_depth)) & CONTAINER_MAX
}

/// Single-pass summary of a downloaded raw frame, for diagnostics only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FrameBufferStats {
    pub(crate) min: u16,
    pub(crate) max: u16,
    pub(crate) mean: u64,
    pub(crate) non_zero: usize,
}

impl FrameBufferStats {
    /// Returns `None` for an empty buffer, which has no meaningful minimum.
    pub(crate) fn of(data: &[u16]) -> Option<Self> {
        let mut iter = data.iter().copied();
        let first = iter.next()?;
        let mut stats = Self {
            min: first,
            max: first,
            // u16 widened to u64 cannot overflow before 2^48 pixels.
            mean: first as u64,
            non_zero: usize::from(first != 0),
        };
        for value in iter {
            stats.min = stats.min.min(value);
            stats.max = stats.max.max(value);
            stats.mean += value as u64;
            stats.non_zero += usize::from(value != 0);
        }
        stats.mean /= data.len() as u64;
        Some(stats)
    }
}

/// ZWO ASI Camera implementation
#[derive(Debug)]
pub struct ZwoCamera {
    pub(crate) camera_id: i32,
    pub(crate) camera_info: Option<ASICameraInfo>,
    pub(crate) connected: bool,
    pub(crate) device_id: String,
    /// Hardware serial read from the OPEN camera during `connect()`.
    ///
    /// `None` means "this unit has no readable serial" — see
    /// [`NativeDevice::serial_number`]. It is populated at connect rather than
    /// at discovery on purpose: `ASIGetSerialNumber` requires the camera to be
    /// open, and opening every camera during a discovery scan would fight with
    /// any other application holding one.
    pub(crate) serial_number: Option<String>,
    /// Model as the SDK states it, e.g. `ZWO ASI1600MM-Cool`.
    ///
    /// Empty until `load_camera_info` has run, because the model only exists in
    /// `ASICameraInfo` and that needs the SDK. [`NativeDevice::name`] falls back
    /// to the id string while it is empty; see the note there for why the id is
    /// never an acceptable answer once the camera is open.
    pub(crate) model_name: String,
    pub(crate) current_bin: i32,
    pub(crate) current_width: i32,
    pub(crate) current_height: i32,
    pub(crate) image_type: ASIImgType,

    // Current settings tracking
    pub(crate) current_gain: i32,
    pub(crate) current_offset: i32,
    // Exposure metadata tracking
    pub(crate) exposure_time: f64,
    // The ASI SDK may leave ASI_EXP_SUCCESS latched after StopExposure. Track
    // whether Skotiq still owns an active acquisition so an aborted frame
    // cannot leave status permanently stuck at Downloading.
    pub(crate) exposure_active: AtomicBool,
    pub(crate) current_subframe: Option<SubFrame>,
    // Locally-tracked cooler command (last set_cooler) — see CoolerState docs.
    pub(crate) cooler_state: Mutex<CoolerState>,
    pub(crate) temperature_skip_first_pending: Mutex<bool>,
}

impl ZwoCamera {
    /// Create a new ZWO camera instance
    pub fn new(camera_id: i32) -> Self {
        Self {
            camera_id,
            camera_info: None,
            connected: false,
            device_id: format!("native:zwo:{}", camera_id),
            serial_number: None,
            model_name: String::new(),
            current_bin: 1,
            current_width: 0,
            current_height: 0,
            image_type: ASIImgType::Raw16,
            current_gain: 0,
            current_offset: 0,
            exposure_time: 0.0,
            exposure_active: AtomicBool::new(false),
            current_subframe: None,
            cooler_state: Mutex::new(CoolerState::default()),
            temperature_skip_first_pending: Mutex::new(false),
        }
    }

    /// Load camera info from SDK
    pub(crate) fn load_camera_info(&mut self) -> Result<(), NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // ASIGetCameraProperty takes the current enumeration index, while every
        // camera operation takes ASICameraInfo::CameraID. Resolve the stable ID
        // again here because USB enumeration can change between discovery and
        // connect.
        // SAFETY: caller holds zwo_camera_mutex; ASIGetNumOfConnectedCameras
        // takes no arguments and only reads SDK state.
        let num_cameras = unsafe { (sdk.get_num_cameras)() };
        let mut matched_info = None;
        for index in 0..num_cameras {
            // SAFETY: ASICameraInfo is `#[repr(C)]` POD; zeroed is a valid initial
            // state before the SDK populates it.
            let mut info: ASICameraInfo = unsafe { std::mem::zeroed() };
            // SAFETY: caller holds zwo_camera_mutex; `index` is bounded by the
            // count returned above and `info` is a valid stack out-pointer.
            let result = unsafe { (sdk.get_camera_property)(&mut info, index) };
            if result == 0 && info.camera_id == self.camera_id {
                matched_info = Some(info);
                break;
            }
        }
        let info = matched_info.ok_or_else(|| {
            NativeError::InvalidDevice(format!(
                "ZWO camera ID {} is no longer present in the SDK enumeration",
                self.camera_id
            ))
        })?;

        // max_width/max_height are c_long in the SDK (i64 on Linux LP64, i32 on
        // Windows LLP64). Our own fields are i32; sensor dimensions always fit.
        self.current_width = info.max_width as i32;
        self.current_height = info.max_height as i32;
        self.camera_info = Some(info);
        // Cache the model now that the SDK has answered. `name()` has to hand
        // back a `&str`, so the owned copy has to live in the struct — without
        // it the only borrowable string was `device_id`, and every caller of
        // `NativeDevice::name()` was handed the enumeration index instead of
        // the model.
        self.model_name = self.camera_name();
        Ok(())
    }

    /// Read this unit's hardware serial from the SDK.
    ///
    /// Preconditions: the caller holds `zwo_camera_mutex` AND the camera has
    /// already been opened — `ASIGetSerialNumber` answers
    /// `ASI_ERROR_CAMERA_CLOSED` on a closed handle.
    ///
    /// `None` is a normal outcome, not a failure: on the reference rig the
    /// ASI178MM returns a serial while the ASI1600MM-Cool beside it answers
    /// `ASI_ERROR_GENERAL_ERROR` (16), because that model stores no serial.
    pub(crate) fn read_serial_number_locked(&self) -> Option<String> {
        let get_serial = asi_get_serial_number_fn()?;
        let mut sn = AsiSerialNumber::default();
        // SAFETY: per this function's contract the caller holds
        // zwo_camera_mutex and the camera is open (connect() calls this only
        // after ASIOpenCamera and ASIInitCamera both succeeded). `sn` is a
        // valid stack out-pointer whose layout matches ASI_SN exactly.
        let rc = unsafe { get_serial(self.camera_id, &mut sn) };
        if rc != 0 {
            tracing::debug!(
                "ZWO camera {} reports no serial number (ASI error {})",
                self.camera_id,
                rc
            );
            return None;
        }
        // An all-zero payload means the flash field was never programmed. Treat
        // it as absent rather than handing every such camera the same "serial",
        // which would make two different bodies look like one device.
        if sn.id.iter().all(|&b| b == 0) {
            tracing::debug!(
                "ZWO camera {} returned an all-zero serial; treating as absent",
                self.camera_id
            );
            return None;
        }
        Some(sn.id.iter().map(|b| format!("{:02x}", b)).collect())
    }

    /// Get camera name using safe string conversion
    pub(crate) fn camera_name(&self) -> String {
        if let Some(info) = &self.camera_info {
            // Use safe string conversion with bounded length
            safe_cstr_to_string(info.name.as_ptr(), 64)
        } else {
            format!("ZWO Camera {}", self.camera_id)
        }
    }

    pub(crate) fn take_temperature_skip_first_pending(&self) -> bool {
        let mut pending = self
            .temperature_skip_first_pending
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let should_skip = *pending;
        *pending = false;
        should_skip
    }

    pub(crate) fn read_temperature_celsius_sync(&self) -> Result<f64, NativeError> {
        if self.take_temperature_skip_first_pending() {
            tracing::debug!(
                "Discarding first ZWO temperature read after connect for {}",
                self.camera_name()
            );
            let _ = self.get_control(ASIControlType::ASI_TEMPERATURE)?;
        }

        let value = self.get_control(ASIControlType::ASI_TEMPERATURE)?;
        Ok(value as f64 / 10.0)
    }

    /// Get a control value (mutex protected)
    pub(crate) async fn get_control_async(
        &self,
        control: ASIControlType,
    ) -> Result<c_long, NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = zwo_camera_mutex().lock().await;
        let mut value: c_long = 0;
        let mut is_auto: ASIBool = ASI_FALSE;
        // SAFETY: zwo_camera_mutex is held above guaranteeing single-threaded SDK access; `value` and `is_auto` are stack-allocated and outlive the call; camera_id was validated when the camera was opened.
        let result = unsafe {
            (sdk.get_control_value)(self.camera_id, control as c_int, &mut value, &mut is_auto)
        };
        check_asi_error(result)?;
        Ok(value)
    }

    /// Get a control value (synchronous version - caller must hold mutex)
    pub(crate) fn get_control(&self, control: ASIControlType) -> Result<c_long, NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let mut value: c_long = 0;
        let mut is_auto: ASIBool = ASI_FALSE;
        // SAFETY: per function contract the caller already holds zwo_camera_mutex (called only from connect/get_status/download_image while lock is held). `value`/`is_auto` are valid stack pointers; camera_id was validated at open time.
        let result = unsafe {
            (sdk.get_control_value)(self.camera_id, control as c_int, &mut value, &mut is_auto)
        };
        check_asi_error(result)?;
        Ok(value)
    }

    /// Set a control value (mutex protected)
    pub(crate) async fn set_control_async(
        &mut self,
        control: ASIControlType,
        value: c_long,
        auto: bool,
    ) -> Result<(), NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = zwo_camera_mutex().lock().await;
        // SAFETY: zwo_camera_mutex is held above; all arguments are pass-by-value primitives validated by ASI control range; camera_id is valid (camera was opened).
        let result = unsafe {
            (sdk.set_control_value)(
                self.camera_id,
                control as c_int,
                value,
                if auto { ASI_TRUE } else { ASI_FALSE },
            )
        };
        check_asi_error(result)
    }

    /// Set a control value (synchronous version - caller must hold mutex)
    pub(crate) fn set_control(
        &mut self,
        control: ASIControlType,
        value: c_long,
        auto: bool,
    ) -> Result<(), NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        // SAFETY: caller-must-hold-mutex contract documented on the function. All args are pass-by-value primitives; camera_id is valid since this method is only called between connect()/disconnect() while the mutex is held.
        let result = unsafe {
            (sdk.set_control_value)(
                self.camera_id,
                control as c_int,
                value,
                if auto { ASI_TRUE } else { ASI_FALSE },
            )
        };
        check_asi_error(result)
    }

    /// Read a control back after writing it, falling back to `requested`
    /// when the SDK refuses to answer.
    ///
    /// Caller must already hold `zwo_camera_mutex` (same contract as
    /// [`Self::get_control`]). See [`commit_zwo_cached_setting`] for why the
    /// read-back matters: `ASISetControlValue` clamps out-of-range values
    /// and still reports success.
    pub(crate) fn read_back_control_sync(&self, control: ASIControlType, requested: i32) -> i32 {
        match self.get_control(control) {
            Ok(actual) => {
                let actual = actual as i32;
                if actual != requested {
                    tracing::warn!(
                        "ZWO clamped control {:?}: requested {}, sensor is at {}",
                        control,
                        requested,
                        actual
                    );
                }
                actual
            }
            Err(error) => {
                // The write succeeded, so the sensor did change; we just
                // cannot confirm to what. Reporting the request is the only
                // remaining estimate.
                tracing::warn!(
                    "ZWO control {:?} read-back failed after write ({}); \
                     reporting requested value {}",
                    control,
                    error,
                    requested
                );
                requested
            }
        }
    }

    /// Async sibling of [`Self::read_back_control_sync`] for callers that do
    /// NOT already hold `zwo_camera_mutex`.
    pub(crate) async fn read_back_control_async(
        &self,
        control: ASIControlType,
        requested: i32,
    ) -> i32 {
        match self.get_control_async(control).await {
            Ok(actual) => {
                let actual = actual as i32;
                if actual != requested {
                    tracing::warn!(
                        "ZWO clamped control {:?}: requested {}, sensor is at {}",
                        control,
                        requested,
                        actual
                    );
                }
                actual
            }
            Err(error) => {
                tracing::warn!(
                    "ZWO control {:?} read-back failed after write ({}); \
                     reporting requested value {}",
                    control,
                    error,
                    requested
                );
                requested
            }
        }
    }

    /// Read a control's `(min, max, default)` WITHOUT narrowing to `i32`.
    ///
    /// [`Self::get_control_caps_async`] casts to `i32` on the documented
    /// assumption that "ZWO controls never exceed i32 in practice (gain <= 600,
    /// offset <= 255)". That assumption does not hold for `ASI_EXPOSURE`, whose
    /// values are MICROSECONDS: a 2000 s maximum is 2_000_000_000 µs, one
    /// rounding away from `i32::MAX`, and longer-exposure models overflow it
    /// outright. Exposure limits must therefore come through this variant.
    pub(crate) async fn get_control_caps_raw_async(
        &self,
        target_control: ASIControlType,
    ) -> Result<(i64, i64, i64), NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = zwo_camera_mutex().lock().await;

        let mut num_controls: c_int = 0;
        // SAFETY: zwo_camera_mutex held above; `num_controls` is a valid stack
        // pointer; camera_id is valid (camera opened during connect).
        let result = unsafe { (sdk.get_num_controls)(self.camera_id, &mut num_controls) };
        check_asi_error(result)?;

        for i in 0..num_controls {
            // SAFETY: ASIControlCaps is `#[repr(C)]` POD; zeroed is a safe
            // initial state per the SDK contract.
            let mut caps: ASIControlCaps = unsafe { std::mem::zeroed() };
            // SAFETY: zwo_camera_mutex held; `caps` is a valid stack pointer;
            // `i` is bounded by num_controls; camera_id is valid.
            let result = unsafe { (sdk.get_control_caps)(self.camera_id, i, &mut caps) };
            if result == 0 && caps.control_type as c_int == target_control as c_int {
                // c_long is i32 on Windows and i64 on Linux; widening to i64 is
                // lossless on both.
                return Ok((
                    caps.min_value as i64,
                    caps.max_value as i64,
                    caps.default_value as i64,
                ));
            }
        }

        Err(NativeError::NotSupported)
    }

    /// Get the min/max range for a control (mutex protected)
    pub(crate) async fn get_control_range_async(
        &self,
        target_control: ASIControlType,
    ) -> Result<(i32, i32), NativeError> {
        let (min, max, _default) = self.get_control_caps_async(target_control).await?;
        Ok((min, max))
    }

    /// Get the full caps tuple `(min, max, default)` for a control (mutex protected).
    ///
    /// ZWO publishes per-control `default_value` via `ASIGetControlCaps`. For the
    /// `ASI_GAIN` control this is the manufacturer's recommended starting gain,
    /// which the SDK header documents as "the manufacturer's recommended default"
    /// and which matches the unity-gain table ZWO publishes for each camera.
    pub(crate) async fn get_control_caps_async(
        &self,
        target_control: ASIControlType,
    ) -> Result<(i32, i32, i32), NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = zwo_camera_mutex().lock().await;

        // Get number of controls
        let mut num_controls: c_int = 0;
        // SAFETY: zwo_camera_mutex is held (acquired above); `num_controls` is a valid stack pointer; camera_id is valid (camera opened during connect).
        let result = unsafe { (sdk.get_num_controls)(self.camera_id, &mut num_controls) };
        check_asi_error(result)?;

        // Search for the specific control
        for i in 0..num_controls {
            // SAFETY: ASIControlCaps is `#[repr(C)]` POD; zeroed is a safe initial state per SDK contract.
            let mut caps: ASIControlCaps = unsafe { std::mem::zeroed() };
            // SAFETY: zwo_camera_mutex held; `caps` is a valid stack pointer; `i` is bounded by num_controls returned by the SDK above; camera_id is valid.
            let result = unsafe { (sdk.get_control_caps)(self.camera_id, i, &mut caps) };
            if result == 0 {
                // Check if this is the control we're looking for
                // The control_type field tells us which control this is
                if caps.control_type as c_int == target_control as c_int {
                    // Why: caps fields are `c_long` (i32 on Windows, i64 on Linux);
                    // ZWO controls never exceed i32 in practice (gain <= 600,
                    // offset <= 255). The cast is a no-op on Windows (hence the
                    // clippy allow) but necessary for portability.
                    #[allow(clippy::unnecessary_cast)]
                    return Ok((
                        caps.min_value as i32,
                        caps.max_value as i32,
                        caps.default_value as i32,
                    ));
                }
            }
        }

        Err(NativeError::NotSupported)
    }

    /// Get the min/max range for a control (synchronous version - caller must hold mutex)
    pub(crate) fn get_control_range(
        &self,
        target_control: ASIControlType,
    ) -> Result<(i32, i32), NativeError> {
        let sdk = AsiSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Get number of controls
        let mut num_controls: c_int = 0;
        // SAFETY: per function contract the caller already holds zwo_camera_mutex; `num_controls` is a valid stack pointer; camera_id is valid.
        let result = unsafe { (sdk.get_num_controls)(self.camera_id, &mut num_controls) };
        check_asi_error(result)?;

        // Search for the specific control
        for i in 0..num_controls {
            // SAFETY: ASIControlCaps is `#[repr(C)]` POD; zeroed is a safe initial state.
            let mut caps: ASIControlCaps = unsafe { std::mem::zeroed() };
            // SAFETY: caller-held mutex (function contract); `caps` is a valid stack pointer; `i` is bounded by num_controls; camera_id is valid.
            let result = unsafe { (sdk.get_control_caps)(self.camera_id, i, &mut caps) };
            if result == 0 {
                // Check if this is the control we're looking for
                // The control_type field tells us which control this is
                if caps.control_type as c_int == target_control as c_int {
                    // min/max_value are c_long (i64 on Linux); gain/offset ranges
                    // fit in i32, which is what our public API exposes.
                    return Ok((caps.min_value as i32, caps.max_value as i32));
                }
            }
        }

        Err(NativeError::NotSupported)
    }

    /// Poll `is_exposure_complete()` until the exposure finishes or the deadline
    /// — the exposure duration plus the config's margin — passes.
    pub async fn wait_for_exposure_complete(
        &self,
        config: &NativeTimeoutConfig,
    ) -> Result<(), NativeError> {
        wait_for_exposure(
            || async { self.is_exposure_complete().await },
            config,
            self.exposure_time,
        )
        .await
    }

    /// Download the frame under a hard `config.image_download_timeout`; a
    /// download that overruns it is cancelled rather than left to hang.
    pub async fn download_image_with_timeout(
        &mut self,
        config: &NativeTimeoutConfig,
    ) -> Result<ImageData, NativeError> {
        let timeout_duration = config.image_download_timeout;

        match tokio::time::timeout(timeout_duration, self.download_image()).await {
            Ok(result) => result,
            Err(_elapsed) => {
                tracing::error!("ZWO image download timed out after {:?}", timeout_duration);
                // Why: current_width/height are i32 dimensions set from validated SDK ROI;
                // bin-divided sensor sizes are always non-negative. We treat any negative
                // sentinel as 0 in the diagnostic message rather than wrapping to giant u32.
                Err(NativeError::download_timeout(
                    timeout_duration,
                    u32::try_from(self.current_width).unwrap_or(0),
                    u32::try_from(self.current_height).unwrap_or(0),
                ))
            }
        }
    }
}

pub(crate) fn validate_zwo_eaf_target(
    position: i32,
    max_position: i32,
) -> Result<i32, NativeError> {
    if position < 0 || position > max_position {
        return Err(NativeError::InvalidParameter(format!(
            "ZWO EAF target position {} outside valid range 0-{}",
            position, max_position
        )));
    }
    Ok(position)
}

/// Commit a control value to the driver's status cache after the SDK write
/// succeeded.
///
/// `effective_value` MUST be a read-back of the control, not the value that
/// was requested. `ASISetControlValue` returns `ASI_SUCCESS` for values
/// outside a control's published range and silently clamps them — measured on
/// an ASI1600MM-Cool (published gain 0-600, offset 0-100), gain 601/1000/99999
/// all read out as gain 600 and offset 101/500/5000 all produced the gain-600
/// pedestal. The cached number reaches `ImageMetadata.gain`/`.offset` and so
/// the FITS `GAIN`/`OFFSET` keywords, and a dark library keyed on gain 99999
/// can never match a light actually taken at gain 600.
pub(crate) fn commit_zwo_cached_setting(
    cache: &mut i32,
    effective_value: i32,
    sdk_result: Result<(), NativeError>,
) -> Result<(), NativeError> {
    sdk_result?;
    *cache = effective_value;
    Ok(())
}
