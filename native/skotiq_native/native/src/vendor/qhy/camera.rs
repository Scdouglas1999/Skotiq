//! `QhyCamera` state and inherent helpers.

use super::*;

/// QHY Camera implementation
#[derive(Debug)]
pub struct QhyCamera {
    pub(crate) camera_id: String,
    pub(crate) device_id: String,
    pub(crate) handle: Option<QhyCamHandle>,
    pub(crate) connected: bool,

    // Camera info
    pub(crate) chip_width: f64,
    pub(crate) chip_height: f64,
    pub(crate) image_width: u32,
    pub(crate) image_height: u32,
    pub(crate) pixel_width: f64,
    pub(crate) pixel_height: f64,
    pub(crate) bits_per_pixel: u32,

    // Pixel-container description, established in connect() *after* the
    // transfer bit depth is forced. `bits_per_pixel` above comes from
    // GetQHYCCDChipInfo, which the QHY SDK manual calls the "Image data bit
    // depth" — the container, not the ADC — and which is read before that
    // force, so it must not be the source of truth for `max_adu`.
    /// Transfer/container depth actually in force (8 or 16), i.e. the width of
    /// the samples `GetQHYCCDSingleFrame` writes.
    pub(crate) output_container_bits: u32,
    /// ADC precision from `GetQHYCCDParam(OutputDataActualBits)`, or `None`
    /// when the camera does not support that query.
    pub(crate) actual_output_bits: Option<u32>,
    /// `GetQHYCCDParam(OutputDataAlignment)`: 1 = high alignment, 0 = low.
    /// Defaults to high, which is the behaviour the SDK manual documents for
    /// every camera (see [`container_max_adu`]).
    pub(crate) output_high_aligned: bool,

    // Current settings
    pub(crate) current_bin: i32,
    pub(crate) current_gain: i32,
    pub(crate) current_offset: i32,

    // Exposure tracking for timeout handling
    pub(crate) current_exposure_time: f64,

    // Capabilities
    pub(crate) has_cooler: bool,
    pub(crate) has_st4_port: bool,
    pub(crate) is_color: bool,
    pub(crate) bayer_pattern: Option<BayerPattern>,

    // Why: QHY SDK has no register to read the cooler enable state back —
    // CONTROL_COOLER is the target-temperature setpoint, not an on/off flag.
    // Track locally (mirrors Atik pattern) so get_status reflects the last
    // set_cooler call instead of hardcoding `false`.
    pub(crate) cooler_on: bool,
    pub(crate) cooler_target_c: Option<f64>,
}

// SAFETY: QhyCamera contains a raw `QhyCamHandle` (`Option<*mut c_void>`). All accesses to the
// handle go through `qhy_mutex()` (see every `unsafe { (sdk.*)(handle, ...) }` site in this
// file), serializing FFI calls across threads.
unsafe impl Send for QhyCamera {}
// SAFETY: Same justification — shared references to QhyCamera never invoke the SDK without
// taking `qhy_mutex()` first.
unsafe impl Sync for QhyCamera {}

impl QhyCamera {
    pub fn new(camera_id: String) -> Self {
        let device_id = format!("native:qhy:{}", camera_id);
        Self {
            camera_id,
            device_id,
            handle: None,
            connected: false,
            chip_width: 0.0,
            chip_height: 0.0,
            image_width: 0,
            image_height: 0,
            pixel_width: 0.0,
            pixel_height: 0.0,
            bits_per_pixel: 16,
            output_container_bits: 16,
            actual_output_bits: None,
            output_high_aligned: true,
            current_bin: 1,
            current_gain: 0,
            current_offset: 0,
            current_exposure_time: 0.0,
            has_cooler: false,
            has_st4_port: false,
            is_color: false,
            bayer_pattern: None,
            cooler_on: false,
            cooler_target_c: None,
        }
    }

    /// Read the ADC precision behind the delivered container, or `None` when
    /// this camera cannot report it.
    ///
    /// `OutputDataActualBits` is documented in the QHYCCD SDK API manual §21 as
    /// "the actual number of bits of raw data output by the chip" — the ADC
    /// precision, which `GetQHYCCDChipInfo`'s `bpp` (the container) is not.
    /// `IsQHYCCDControlAvailable` entry 55 is "Check whether the camera can get
    /// the actual bits of output data" and returns QHYCCD_SUCCESS (0) when it can.
    ///
    /// SAFETY (callers): `qhy_mutex()` must be held and `handle` must be an
    /// open, initialized camera handle.
    pub(crate) fn probe_output_data_actual_bits(
        &self,
        sdk: &QhySdk,
        handle: QhyCamHandle,
    ) -> Option<u32> {
        // SAFETY: caller holds qhy_mutex() and `handle` came from a successful
        // OpenQHYCCD/InitQHYCCD pair. Both FFI calls take the handle plus a
        // plain control-id integer, with no out-pointers.
        let available = unsafe {
            (sdk.is_qhyccd_control_available)(handle, QhyControl::OutputDataActualBits as c_int)
        };
        if available != 0 {
            return None;
        }
        // SAFETY: as above; GetQHYCCDParam returns the value by f64 return.
        let raw =
            unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::OutputDataActualBits as c_int) };
        // QHY signals a failed read by returning QHYCCD_ERROR (0xFFFFFFFF) widened
        // into the f64; anything outside a plausible ADC width is not usable.
        if !(1.0..=16.0).contains(&raw) {
            tracing::debug!(
                "QHY camera {}: OutputDataActualBits returned {}, outside 1..=16; \
                 falling back to the container ceiling",
                self.camera_id,
                raw
            );
            return None;
        }
        Some(raw as u32)
    }

    /// Whether the ADC bits sit at the top of the container.
    ///
    /// QHYCCD SDK API manual §22: "Get the alignment format of the camera output
    /// data. If the return value is 1, it indicates high alignment; if the return
    /// value is 0, it indicates low alignment." The parameter is optional (the
    /// manual's Get-parameter table marks it "Not enabled" on many models), so
    /// when it is unavailable we use the behaviour §14/§21 document for every
    /// camera: 16-bit output is produced by "low zero padding" of the raw data,
    /// i.e. high alignment.
    ///
    /// SAFETY (callers): `qhy_mutex()` must be held and `handle` must be an
    /// open, initialized camera handle.
    pub(crate) fn probe_output_data_high_aligned(
        &self,
        sdk: &QhySdk,
        handle: QhyCamHandle,
    ) -> bool {
        // SAFETY: caller holds qhy_mutex() and `handle` came from a successful
        // OpenQHYCCD/InitQHYCCD pair; control-id integer argument only.
        let available = unsafe {
            (sdk.is_qhyccd_control_available)(handle, QhyControl::OutputDataAlignment as c_int)
        };
        if available != 0 {
            return true;
        }
        // SAFETY: as above.
        let raw =
            unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::OutputDataAlignment as c_int) };
        if raw == 0.0 {
            tracing::info!(
                "QHY camera {}: OutputDataAlignment reports low alignment; \
                 publishing the ADC range as the container ceiling",
                self.camera_id
            );
            return false;
        }
        true
    }

    /// Load camera chip info from SDK
    pub(crate) fn load_camera_info(&mut self) -> Result<(), NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        let mut chip_w: c_double = 0.0;
        let mut chip_h: c_double = 0.0;
        let mut img_w: c_uint = 0;
        let mut img_h: c_uint = 0;
        let mut pixel_w: c_double = 0.0;
        let mut pixel_h: c_double = 0.0;
        let mut bpp: c_uint = 0;

        // SAFETY: load_camera_info is a private helper called from connect() and check_cfw_available
        // contexts where qhy_mutex() is already held by the caller; `handle` came from a successful
        // OpenQHYCCD/InitQHYCCD pair (verified above via self.handle.ok_or). All eight out-pointers
        // are valid stack pointers to the SDK-expected types.
        let result = unsafe {
            (sdk.get_qhyccd_chip_info)(
                handle,
                &mut chip_w,
                &mut chip_h,
                &mut img_w,
                &mut img_h,
                &mut pixel_w,
                &mut pixel_h,
                &mut bpp,
            )
        };
        check_qhy_error(result, "GetQHYCCDChipInfo")?;

        self.chip_width = chip_w;
        self.chip_height = chip_h;
        self.image_width = img_w;
        self.image_height = img_h;
        self.pixel_width = pixel_w;
        self.pixel_height = pixel_h;
        self.bits_per_pixel = bpp;

        // Check capabilities
        // SAFETY: caller holds qhy_mutex(); `handle` validated above; IsQHYCCDControlAvailable
        // takes the handle and a control-id integer with no out-pointers.
        self.has_cooler = unsafe {
            (sdk.is_qhyccd_control_available)(handle, QhyControl::CONTROL_COOLER as c_int)
        } == 0;
        // SAFETY: caller holds qhy_mutex(); handle validated above; same FFI signature as above.
        self.has_st4_port = unsafe {
            (sdk.is_qhyccd_control_available)(handle, QhyControl::CONTROL_ST4PORT as c_int)
        } == 0;
        // SAFETY: caller holds qhy_mutex(); handle validated above; same FFI signature as above.
        self.is_color =
            unsafe { (sdk.is_qhyccd_control_available)(handle, QhyControl::CAM_IS_COLOR as c_int) }
                == 0;

        // Detect bayer pattern for color cameras
        if self.is_color {
            // SAFETY: caller holds qhy_mutex(); handle validated above; GetQHYCCDParam returns a
            // c_double by value with no out-pointers.
            // Why: GetQHYCCDParam returns c_double encoding a small integer Bayer code
            // (1..=4). The match below treats anything outside that range as None, so
            // a saturating truncation here is sound: we only need the value to compare
            // against 1-4. `as i32` on a finite f64 in that range is well-defined.
            let bayer_val =
                unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CAM_COLOR as c_int) } as i32;
            self.bayer_pattern = match bayer_val {
                1 => Some(BayerPattern::Rggb),
                2 => Some(BayerPattern::Grbg),
                3 => Some(BayerPattern::Gbrg),
                4 => Some(BayerPattern::Bggr),
                _ => None,
            };
        }

        Ok(())
    }

    /// Get a control value (mutex protected)
    pub(crate) async fn get_control_async(&self, control: QhyControl) -> Result<f64, NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;
        // SAFETY: qhy_mutex held just above; handle was validated via Option::ok_or; control
        // discriminant fits in c_int. GetQHYCCDParam returns c_double by value, no out-pointers.
        Ok(unsafe { (sdk.get_qhyccd_param)(handle, control as c_int) })
    }

    /// Get a control value (synchronous - caller must hold mutex)
    pub(crate) fn get_control(&self, control: QhyControl) -> Result<f64, NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;
        // SAFETY: caller must hold qhy_mutex (documented in the function doc comment above);
        // handle validated; control discriminant fits in c_int. Return by value.
        Ok(unsafe { (sdk.get_qhyccd_param)(handle, control as c_int) })
    }

    /// Set a control value (mutex protected)
    pub(crate) async fn set_control_async(
        &mut self,
        control: QhyControl,
        value: f64,
    ) -> Result<(), NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;
        // SAFETY: qhy_mutex held above; handle validated; control discriminant fits in c_int;
        // value is pass-by-value c_double. SDK validates the value internally.
        let result = unsafe { (sdk.set_qhyccd_param)(handle, control as c_int, value) };
        check_qhy_error(result, "SetQHYCCDParam")
    }

    /// Set a control value (synchronous - caller must hold mutex)
    pub(crate) fn set_control(
        &mut self,
        control: QhyControl,
        value: f64,
    ) -> Result<(), NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;
        // SAFETY: caller must hold qhy_mutex (per the function doc above); handle validated;
        // control discriminant fits in c_int; value is pass-by-value c_double.
        let result = unsafe { (sdk.set_qhyccd_param)(handle, control as c_int, value) };
        check_qhy_error(result, "SetQHYCCDParam")
    }

    /// Get the min/max/step range for a control (mutex protected)
    pub(crate) async fn get_control_range_async(
        &self,
        control: QhyControl,
    ) -> Result<(f64, f64, f64), NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        // Acquire mutex before extracting handle to avoid Send issues
        let _lock = qhy_mutex().lock().await;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        let mut min_val: c_double = 0.0;
        let mut max_val: c_double = 0.0;
        let mut step: c_double = 0.0;

        // SAFETY: qhy_mutex held above; handle validated; control discriminant fits in c_int;
        // all three out-pointers are valid stack pointers to c_double.
        let result = unsafe {
            (sdk.get_qhyccd_param_min_max_step)(
                handle,
                control as c_int,
                &mut min_val,
                &mut max_val,
                &mut step,
            )
        };
        check_qhy_error(result, "GetQHYCCDParamMinMaxStep")?;

        Ok((min_val, max_val, step))
    }

    /// Get the min/max/step range for a control (synchronous - caller must hold mutex)
    pub(crate) fn get_control_range(
        &self,
        control: QhyControl,
    ) -> Result<(f64, f64, f64), NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        let mut min_val: c_double = 0.0;
        let mut max_val: c_double = 0.0;
        let mut step: c_double = 0.0;

        // SAFETY: caller must hold qhy_mutex (per the function doc above); handle validated;
        // control discriminant fits in c_int; all three out-pointers are valid stack pointers.
        let result = unsafe {
            (sdk.get_qhyccd_param_min_max_step)(
                handle,
                control as c_int,
                &mut min_val,
                &mut max_val,
                &mut step,
            )
        };
        check_qhy_error(result, "GetQHYCCDParamMinMaxStep")?;

        Ok((min_val, max_val, step))
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
            self.current_exposure_time,
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
                tracing::error!("QHY image download timed out after {:?}", timeout_duration);
                Err(NativeError::download_timeout(
                    timeout_duration,
                    self.image_width,
                    self.image_height,
                ))
            }
        }
    }
}
