//! `MoravianCamera` state and inherent helpers.

use super::*;

// Handle wrapper for Send + Sync

pub(crate) struct HandleWrapper(pub(crate) PCCamera);
// SAFETY: HandleWrapper wraps a raw `*mut c_void` camera handle. The handle is opaque to us — we never deref it. It is only handed back to the gxccd SDK functions, which serialize through `moravian_mutex()`, so no concurrent access ever happens to the underlying SDK state via this pointer.
unsafe impl Send for HandleWrapper {}
// SAFETY: Same justification as `impl Send`. The pointer is opaque and access to it is gated by both the wrapping `Mutex<HandleWrapper>` (held inside MoravianCamera) and the global `moravian_mutex()`.
unsafe impl Sync for HandleWrapper {}

/// Moravian camera instance
pub struct MoravianCamera {
    pub(crate) camera_id: c_int,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: Mutex<HandleWrapper>,
    pub(crate) connected: bool,
    pub(crate) capabilities: CameraCapabilities,
    pub(crate) sensor_info: SensorInfo,
    pub(crate) state: CameraState,
    pub(crate) current_gain: i32,
    pub(crate) current_offset: i32,
    pub(crate) current_bin_x: i32,
    pub(crate) current_bin_y: i32,
    pub(crate) subframe: Option<SubFrame>,
    pub(crate) cooler_on: bool,
    pub(crate) target_temp: f64,
    pub(crate) exposure_duration: f64,
    pub(crate) exposure_started_at: Option<std::time::Instant>,
    /// Binned (width, height) requested at the last `start_exposure`; used to
    /// size the `gxccd_read_image` buffer (which takes no ROI of its own).
    pub(crate) last_frame_dims: Option<(u32, u32)>,
}

impl std::fmt::Debug for MoravianCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MoravianCamera")
            .field("name", &self.name)
            .field("camera_id", &self.camera_id)
            .finish()
    }
}

impl MoravianCamera {
    /// Create a new Moravian camera instance
    pub fn new(camera_id: c_int) -> Self {
        Self {
            camera_id,
            device_id: format!("moravian_{}", camera_id),
            name: format!("Moravian Camera {}", camera_id),
            handle: Mutex::new(HandleWrapper(std::ptr::null_mut())),
            connected: false,
            capabilities: CameraCapabilities::default(),
            sensor_info: SensorInfo::default(),
            state: CameraState::Idle,
            current_gain: 0,
            current_offset: 0,
            current_bin_x: 1,
            current_bin_y: 1,
            subframe: None,
            cooler_on: false,
            target_temp: 0.0,
            exposure_duration: 0.0,
            exposure_started_at: None,
            last_frame_dims: None,
        }
    }
}

#[async_trait]
impl NativeDevice for MoravianCamera {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Moravian
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            return Ok(());
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        // Initialize camera (gxccd_initialize_usb returns NULL on failure).
        // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); `self.camera_id` was set at construction (from MoravianCameraInfo.camera_id emitted by gxccd_enumerate_usb); gxccd_initialize_usb takes the camera ID by value and returns a fresh handle (NULL on failure, checked below).
        let handle = unsafe { (sdk.initialize_usb)(self.camera_id) };
        if handle.is_null() {
            tracing::error!(
                "Moravian gxccd_initialize_usb() returned NULL for camera ID {}. Check USB connection and driver installation.",
                self.camera_id
            );
            return Err(NativeError::SdkError(format!(
                "Failed to initialize Moravian camera ID {} - SDK returned NULL handle. Ensure camera is connected and the gxccd driver is installed.",
                self.camera_id
            )));
        }

        let cleanup_guard = CleanupGuard::new(|| {
            // SAFETY: moravian_mutex remains held for this guard's lifetime and
            // handle was returned by the successful gxccd_initialize_usb call above.
            unsafe { (sdk.release)(handle) };
        });

        // Probe camera info before publishing the handle as connected.
        {
            // Name
            let mut name_buf = [0 as c_char; 256];
            // SAFETY: moravian_mutex held above; `handle` is the
            // just-successfully-initialized camera handle; name_buf is 256 bytes and
            // its truthful length is passed as `size_t`.
            if unsafe {
                (sdk.get_string_parameter)(
                    handle,
                    GSP_CAMERA_DESCRIPTION,
                    name_buf.as_mut_ptr(),
                    name_buf.len(),
                )
            } >= 0
            {
                // SAFETY: name_buf is 256 bytes; the SDK guarantees NUL-termination within on success.
                self.name = unsafe { std::ffi::CStr::from_ptr(name_buf.as_ptr()) }
                    .to_string_lossy()
                    .trim()
                    .to_string();
            }

            // Integer + boolean parameters. Every status must be checked: a
            // failed SDK query leaves its out-parameter unchanged.
            let mut width_i: c_int = 0;
            let mut height_i: c_int = 0;
            let mut pixel_w: c_int = 0;
            let mut pixel_d: c_int = 0;
            let mut max_bin_x: c_int = 1;
            let mut max_bin_y: c_int = 1;
            let mut max_pixel_value: c_int = 0;
            let mut is_rgb: GxBool = 0;
            let mut is_cmy: GxBool = 0;
            let mut is_cmyg: GxBool = 0;
            let mut deb_x_odd: GxBool = 0;
            let mut deb_y_odd: GxBool = 0;
            let mut has_cooler: GxBool = 0;
            let mut has_shutter: GxBool = 0;
            let mut has_guide: GxBool = 0;
            let mut has_gain: GxBool = 0;
            let mut has_subframe: GxBool = 0;

            let query_integer =
                |index: c_int, value: &mut c_int, name: &str| -> Result<(), NativeError> {
                    // SAFETY: moravian_mutex held; handle is initialized and value is a
                    // valid c_int out-pointer for gxccd_get_integer_parameter.
                    let result = unsafe { (sdk.get_integer_parameter)(handle, index, value) };
                    if result < 0 {
                        // SAFETY: handle remains valid on this error path.
                        let detail = unsafe { sdk_last_error(sdk, handle) };
                        return Err(NativeError::SdkError(format!(
                            "Moravian failed to query {}: {}",
                            name, detail
                        )));
                    }
                    Ok(())
                };
            let query_boolean =
                |index: c_int, value: &mut GxBool, name: &str| -> Result<(), NativeError> {
                    // SAFETY: moravian_mutex held; handle is initialized and value is a
                    // valid GxBool out-pointer for gxccd_get_boolean_parameter.
                    let result = unsafe { (sdk.get_boolean_parameter)(handle, index, value) };
                    if result < 0 {
                        // SAFETY: handle remains valid on this error path.
                        let detail = unsafe { sdk_last_error(sdk, handle) };
                        return Err(NativeError::SdkError(format!(
                            "Moravian failed to query {}: {}",
                            name, detail
                        )));
                    }
                    Ok(())
                };

            query_integer(GIP_CHIP_W, &mut width_i, "sensor width")?;
            query_integer(GIP_CHIP_D, &mut height_i, "sensor height")?;
            query_integer(GIP_PIXEL_W, &mut pixel_w, "pixel width")?;
            query_integer(GIP_PIXEL_D, &mut pixel_d, "pixel height")?;
            query_integer(GIP_MAX_BINNING_X, &mut max_bin_x, "maximum X binning")?;
            query_integer(GIP_MAX_BINNING_Y, &mut max_bin_y, "maximum Y binning")?;
            query_integer(
                GIP_MAX_PIXEL_VALUE,
                &mut max_pixel_value,
                "maximum pixel value",
            )?;
            query_boolean(GBP_RGB, &mut is_rgb, "RGB sensor capability")?;
            query_boolean(GBP_CMY, &mut is_cmy, "CMY sensor capability")?;
            query_boolean(GBP_CMYG, &mut is_cmyg, "CMYG sensor capability")?;
            query_boolean(GBP_DEBAYER_X_ODD, &mut deb_x_odd, "horizontal Bayer phase")?;
            query_boolean(GBP_DEBAYER_Y_ODD, &mut deb_y_odd, "vertical Bayer phase")?;
            query_boolean(GBP_COOLER, &mut has_cooler, "cooler capability")?;
            query_boolean(GBP_SHUTTER, &mut has_shutter, "shutter capability")?;
            query_boolean(GBP_GUIDE, &mut has_guide, "guider capability")?;
            query_boolean(GBP_GAIN, &mut has_gain, "gain capability")?;
            query_boolean(GBP_SUB_FRAME, &mut has_subframe, "subframe capability")?;

            if width_i <= 0
                || height_i <= 0
                || pixel_w <= 0
                || pixel_d <= 0
                || max_bin_x <= 0
                || max_bin_y <= 0
                || max_pixel_value <= 0
            {
                return Err(NativeError::SdkError(format!(
                    "Moravian reported invalid camera parameters: sensor={}x{}, pixel={}x{}nm, max_bin={}x{}, max_adu={}",
                    width_i,
                    height_i,
                    pixel_w,
                    pixel_d,
                    max_bin_x,
                    max_bin_y,
                    max_pixel_value
                )));
            }

            let width = width_i as u32;
            let height = height_i as u32;

            // GIP_PIXEL_W/D are in NANOMETERS (gxccd.h:267-268); the reference
            // converts to microns with /1000.0 (mi_ccd.cpp:435).
            let pixel_size_x = pixel_w.max(0) as f64 / 1000.0;
            let pixel_size_y = pixel_d.max(0) as f64 / 1000.0;

            // GIP_MAX_PIXEL_VALUE is the saturation ADU (gxccd.h:282). Data is
            // always delivered 16-bit (gxccd_read_image), so bit_depth stays 16.
            let max_adu = max_pixel_value as u32;

            // Color: only RGB Bayer is representable by BayerPattern. For CMY/CMYG
            // we flag color but leave the pattern None (an honest "unknown CFA"
            // rather than a wrong RGGB).
            let color = is_rgb != 0 || is_cmy != 0 || is_cmyg != 0;
            let bayer_pattern = if is_rgb != 0 {
                let native = native_bayer(deb_x_odd != 0, deb_y_odd != 0);
                // We vertically mirror every frame; for even sensor height that
                // mirror swaps the two Bayer rows, so report the flipped phase.
                if height.is_multiple_of(2) {
                    Some(flip_bayer_vertical(native))
                } else {
                    Some(native)
                }
            } else {
                None
            };

            self.sensor_info = SensorInfo {
                width,
                height,
                pixel_size_x,
                pixel_size_y,
                max_adu,
                bit_depth: 16,
                color,
                bayer_pattern,
            };

            self.capabilities = CameraCapabilities {
                can_cool: has_cooler != 0,
                can_set_gain: has_gain != 0,
                can_set_offset: false, // Moravian doesn't have separate offset
                can_set_binning: max_bin_x > 1 || max_bin_y > 1,
                can_subframe: has_subframe != 0,
                has_shutter: has_shutter != 0,
                has_guider_port: has_guide != 0,
                max_bin_x: max_bin_x.max(1),
                max_bin_y: max_bin_y.max(1),
                supports_readout_modes: true,
            };
        }

        {
            let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            *h = HandleWrapper(handle);
        }
        cleanup_guard.defuse();

        // The current gxccd SDK has no separate Open() step — the handle from
        // gxccd_initialize_usb is ready for imaging.
        self.connected = true;
        self.state = CameraState::Idle;

        tracing::info!(
            "Connected to Moravian camera: {} ({}x{})",
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

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = moravian_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Release camera (no separate Close() in the current SDK).
        // SAFETY: moravian_mutex held above; handle was Initialize()'d (we're on the connected path); gxccd_release() pairs with gxccd_initialize_usb() and is the required final cleanup per gxccd.h:206-211.
        unsafe { (sdk.release)(handle) };

        {
            let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            *h = HandleWrapper(std::ptr::null_mut());
        }
        self.connected = false;
        self.state = CameraState::Idle;
        self.exposure_started_at = None;
        self.last_frame_dims = None;

        tracing::info!("Disconnected from Moravian camera: {}", self.name);

        Ok(())
    }
}
