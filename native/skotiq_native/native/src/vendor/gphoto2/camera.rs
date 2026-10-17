//! `GPhoto2Camera` state and inherent helpers.

use super::*;

/// Known DSLR shutter speed values mapped to durations in seconds.
/// Used to find the closest matching shutter speed for exposures <= 30s.
pub(crate) const SHUTTER_SPEEDS: &[(f64, &str)] = &[
    (0.000125, "1/8000"),
    (0.00025, "1/4000"),
    (0.0005, "1/2000"),
    (0.001, "1/1000"),
    (0.002, "1/500"),
    (0.004, "1/250"),
    (0.005, "1/200"),
    (0.008, "1/125"),
    (0.01, "1/100"),
    (0.0125, "1/80"),
    (0.01667, "1/60"),
    (0.025, "1/40"),
    (0.03333, "1/30"),
    (0.04, "1/25"),
    (0.05, "1/20"),
    (0.066667, "1/15"),
    (0.076923, "1/13"),
    (0.1, "1/10"),
    (0.125, "1/8"),
    (0.166667, "1/6"),
    (0.2, "1/5"),
    (0.25, "1/4"),
    (0.3, "0.3"),
    (0.4, "0.4"),
    (0.5, "0.5"),
    (0.625, "0.625"),
    (0.7692, "0.7692"),
    (1.0, "1"),
    (1.3, "1.3"),
    (1.6, "1.6"),
    (2.0, "2"),
    (2.5, "2.5"),
    (3.2, "3.2"),
    (4.0, "4"),
    (5.0, "5"),
    (6.0, "6"),
    (8.0, "8"),
    (10.0, "10"),
    (13.0, "13"),
    (15.0, "15"),
    (20.0, "20"),
    (25.0, "25"),
    (30.0, "30"),
];

/// Exposure state tracking
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ExposureState {
    Idle,
    /// Normal exposure via gp_camera_capture — the library blocks until done,
    /// so from the driver's perspective the exposure completes synchronously.
    /// We track the start time so `is_exposure_complete` can signal when the
    /// expected duration has elapsed.
    Exposing {
        start: Instant,
        duration_secs: f64,
    },
    /// Bulb exposure triggered via gp_camera_trigger_capture.
    /// Needs explicit stop after the desired duration.
    BulbExposing {
        start: Instant,
        duration_secs: f64,
    },
    /// Exposure done, image waiting to be downloaded from camera storage.
    Complete,
    /// Exposure failed.
    Failed,
}

/// How this camera opens/closes the shutter for a bulb (>30s) exposure.
///
/// Discovered once at connect, mirroring the reference driver
/// (gphoto_driver.cpp:1839-1884): prefer Canon's `eosremoterelease` widget,
/// else the generic `bulb` PTP toggle (Nikon and Sony bodies that expose it).
/// The correct per-brand widget MUST be driven — `gp_camera_trigger_capture`
/// alone does not hold the shutter open on Nikon/Sony, so those long subs
/// otherwise time out or come back black.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum BulbWidget {
    /// Canon EOS: a RADIO widget. Bulb opens by selecting the "Press Full"
    /// choice and closes with "Release"/"Release Full". The exact choice
    /// strings vary by libgphoto2 version, so they are discovered dynamically.
    EosRemoteRelease { press: String, release: String },
    /// Nikon / Sony (and others): a TOGGLE widget named `bulb`. Open = 1 (on),
    /// close = 0 (off) — set as an INT value, not a string.
    BulbToggle,
}

/// gPhoto2 DSLR/Mirrorless Camera implementation
pub struct GPhoto2Camera {
    /// Camera index from autodetect
    pub(crate) camera_index: usize,
    /// Camera model name
    pub(crate) model_name: String,
    /// USB port path
    pub(crate) port_path: String,
    /// Unique device ID
    pub(crate) device_id: String,
    /// Connected state
    pub(crate) connected: bool,

    /// gPhoto2 camera handle (owned, must be freed on disconnect)
    pub(crate) gp_camera: *mut GPCamera,
    /// gPhoto2 context handle (owned, must be freed on disconnect)
    pub(crate) gp_context: *mut GPContext,

    // Cached sensor info (populated on connect from EXIF/config)
    pub(crate) sensor_width: u32,
    pub(crate) sensor_height: u32,
    pub(crate) pixel_size: f64,
    /// Sensor ADC precision. Seeded from the model table in
    /// `detect_sensor_dimensions()` — a pre-first-frame ESTIMATE that guesses
    /// 14 for every body libgphoto2 supports but this driver has not tabulated
    /// — and replaced with the decoder's ground truth
    /// (`skotiq_imaging::CfaImage::bits_per_pixel`) the moment a frame has
    /// been decoded. See `adopt_decoded_depth`.
    pub(crate) bit_depth: u32,
    /// Container full scale measured from the most recently decoded frame:
    /// LibRaw `color.maximum` surfaced as `skotiq_imaging::CfaImage::max_value`.
    /// `None` until the first frame is decoded, when `resolve_max_adu` falls
    /// back to the model-table estimate.
    pub(crate) measured_white_level: Option<u32>,
    pub(crate) is_color: bool,

    // Camera capabilities (populated on connect)
    pub(crate) can_capture: bool,
    pub(crate) can_preview: bool,
    pub(crate) can_configure: bool,
    pub(crate) can_bulb: bool,

    // Available ISO values (populated on connect)
    pub(crate) iso_values: Vec<String>,
    pub(crate) current_iso_index: i32,

    // Available shutter speed values (populated on connect)
    pub(crate) shutter_speed_values: Vec<String>,

    // How to open/close the shutter for bulb exposures (discovered on connect).
    // None => no internal bulb widget found; fall back to trigger_capture.
    pub(crate) bulb_widget: Option<BulbWidget>,

    // RAW image-format config to force before capture (widget name, RAW choice),
    // discovered on connect. None => camera exposes no image-format widget.
    pub(crate) raw_format: Option<(String, String)>,

    // Exposure tracking
    pub(crate) exposure_state: ExposureState,
    pub(crate) exposure_time: f64,
    pub(crate) current_gain: i32,   // Maps to ISO index
    pub(crate) current_offset: i32, // Not used for DSLRs, always 0

    // Last captured file path on camera (for download)
    pub(crate) last_capture_path: Option<CameraFilePath>,

    // Last downloaded raw image bytes (for decoding)
    pub(crate) last_raw_data: Option<Vec<u8>>,
}

// Implement Debug manually since raw pointers don't implement Debug
impl std::fmt::Debug for GPhoto2Camera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GPhoto2Camera")
            .field("camera_index", &self.camera_index)
            .field("model_name", &self.model_name)
            .field("port_path", &self.port_path)
            .field("device_id", &self.device_id)
            .field("connected", &self.connected)
            .field("sensor_width", &self.sensor_width)
            .field("sensor_height", &self.sensor_height)
            .field("exposure_state", &self.exposure_state)
            .finish()
    }
}

// SAFETY: GPhoto2Camera is Send+Sync because all gphoto2 SDK calls are protected
// by the gphoto2_mutex, ensuring only one thread accesses the camera at a time.
// The raw `gp_camera` / `gp_context` pointers stored in this struct are only
// dereferenced inside lock-held `unsafe` blocks in the impls below.
unsafe impl Send for GPhoto2Camera {}
// SAFETY: Same justification as the `Send` impl above — gphoto2_mutex serializes all
// SDK access, so concurrent `&GPhoto2Camera` references never reach libgphoto2 at the
// same time.
unsafe impl Sync for GPhoto2Camera {}

impl GPhoto2Camera {
    /// Create a new gPhoto2 camera instance from a detected camera.
    pub fn new(index: usize, model: &str, port: &str) -> Self {
        Self {
            camera_index: index,
            model_name: model.to_string(),
            port_path: port.to_string(),
            device_id: build_device_id(index, model, port),
            connected: false,
            gp_camera: std::ptr::null_mut(),
            gp_context: std::ptr::null_mut(),
            sensor_width: 0,
            sensor_height: 0,
            pixel_size: 0.0,
            // Estimate only, refined by `detect_sensor_dimensions()` on connect
            // and superseded by the decoded frame's real depth.
            bit_depth: 14,
            measured_white_level: None,
            is_color: true, // All DSLRs are color
            can_capture: false,
            can_preview: false,
            can_configure: false,
            can_bulb: false,
            iso_values: Vec::new(),
            current_iso_index: 0,
            shutter_speed_values: Vec::new(),
            bulb_widget: None,
            raw_format: None,
            exposure_state: ExposureState::Idle,
            exposure_time: 0.0,
            current_gain: 0,
            current_offset: 0,
            last_capture_path: None,
            last_raw_data: None,
        }
    }

    /// Get the closest shutter speed string for a given duration.
    /// Returns None if the duration is longer than 30s (use Bulb mode).
    pub(crate) fn find_shutter_speed(&self, duration_secs: f64) -> Option<String> {
        // First check if the camera has reported available shutter speeds
        if !self.shutter_speed_values.is_empty() {
            // Try to find exact or closest match from the camera's available values
            let mut best_match: Option<(f64, &str)> = None;

            for speed_str in &self.shutter_speed_values {
                if let Some(secs) = parse_shutter_speed_to_secs(speed_str) {
                    let ratio = if secs > 0.0 && duration_secs > 0.0 {
                        (secs / duration_secs).ln().abs()
                    } else {
                        f64::MAX
                    };
                    if best_match.is_none() || ratio < best_match.unwrap().0 {
                        best_match = Some((ratio, speed_str));
                    }
                }
            }

            if let Some((_, speed_str)) = best_match {
                return Some(speed_str.to_string());
            }
        }

        // Fall back to the known speed table
        if duration_secs > 30.0 {
            return None; // Use Bulb
        }

        let mut best: Option<(f64, &str)> = None;
        for &(secs, name) in SHUTTER_SPEEDS {
            let ratio = (secs / duration_secs).ln().abs();
            if best.is_none() || ratio < best.unwrap().0 {
                best = Some((ratio, name));
            }
        }
        best.map(|(_, name)| name.to_string())
    }

    /// Read a string configuration value from the camera.
    /// Caller must hold gphoto2_mutex.
    pub(crate) fn get_config_value_str(&self, name: &str) -> Result<String, NativeError> {
        let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // SAFETY: caller holds gphoto2_mutex (documented in the doc-comment above and
        // checked by all call sites). `self.gp_camera`/`self.gp_context` are non-null
        // valid pointers obtained from `camera_new`/`context_new` while connected.
        // `root` is a stack out-pointer; `widget_free(root)` runs on every exit path.
        // `CStr::from_ptr(value_ptr)` is gated on a successful (`ret >= GP_OK`) widget
        // read and a non-null `value_ptr`, so the pointer is a NUL-terminated C string
        // borrowed from libgphoto2 internals.
        unsafe {
            let mut root: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.camera_get_config)(self.gp_camera, &mut root, self.gp_context);
            if ret < GP_OK {
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: get_config failed for '{}': code {}",
                    name, ret
                )));
            }

            let c_name = CString::new(name).map_err(|_| {
                NativeError::InvalidParameter(format!("Invalid config name: {}", name))
            })?;

            let mut child: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.widget_get_child_by_name)(root, c_name.as_ptr(), &mut child);
            if ret < GP_OK {
                (sdk.widget_free)(root);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: config '{}' not found on this camera",
                    name
                )));
            }

            let mut value_ptr: *const c_char = std::ptr::null();
            let ret =
                (sdk.widget_get_value)(child, &mut value_ptr as *mut *const c_char as *mut c_void);
            if ret < GP_OK || value_ptr.is_null() {
                (sdk.widget_free)(root);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: failed to read config '{}': code {}",
                    name, ret
                )));
            }

            let value = CStr::from_ptr(value_ptr).to_string_lossy().to_string();
            (sdk.widget_free)(root);
            Ok(value)
        }
    }

    /// Set a string configuration value on the camera.
    /// Caller must hold gphoto2_mutex.
    pub(crate) fn set_config_value_str(&self, name: &str, value: &str) -> Result<(), NativeError> {
        let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // SAFETY: caller holds gphoto2_mutex (per doc-comment). `self.gp_camera` /
        // `self.gp_context` are valid non-null pointers post-connect. `root` is a stack
        // out-pointer; `widget_free(root)` is called on every exit path. `c_name` /
        // `c_value` are CString owners that outlive their `.as_ptr()` use inside the
        // block. `widget_set_value` followed by `camera_set_config` is the libgphoto2
        // configured-write sequence.
        unsafe {
            let mut root: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.camera_get_config)(self.gp_camera, &mut root, self.gp_context);
            check_gp_error(ret, "get_config")?;

            let c_name = CString::new(name).map_err(|_| {
                NativeError::InvalidParameter(format!("Invalid config name: {}", name))
            })?;

            let mut child: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.widget_get_child_by_name)(root, c_name.as_ptr(), &mut child);
            if ret < GP_OK {
                (sdk.widget_free)(root);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: config '{}' not found on this camera",
                    name
                )));
            }

            let c_value = CString::new(value).map_err(|_| {
                NativeError::InvalidParameter(format!("Invalid config value: {}", value))
            })?;

            let ret = (sdk.widget_set_value)(child, c_value.as_ptr() as *const c_void);
            if ret < GP_OK {
                (sdk.widget_free)(root);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: failed to set config '{}' to '{}': code {}",
                    name, value, ret
                )));
            }

            let ret = (sdk.camera_set_config)(self.gp_camera, root, self.gp_context);
            (sdk.widget_free)(root);
            check_gp_error(ret, "set_config")?;

            Ok(())
        }
    }

    /// Get all available choices for a radio/menu configuration value.
    /// Caller must hold gphoto2_mutex.
    pub(crate) fn get_config_choices(&self, name: &str) -> Result<Vec<String>, NativeError> {
        let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // SAFETY: caller holds gphoto2_mutex (per doc-comment). `gp_camera`/`gp_context`
        // are valid non-null post-connect; `root` is a stack out-pointer freed on
        // every exit path. Each `widget_get_choice` call's out-pointer (`choice_ptr`)
        // is only dereferenced via `CStr::from_ptr` after the return code is checked
        // and non-null guard passes; the choice C-string is owned by the widget tree.
        unsafe {
            let mut root: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.camera_get_config)(self.gp_camera, &mut root, self.gp_context);
            check_gp_error(ret, "get_config")?;

            let c_name = CString::new(name).map_err(|_| {
                NativeError::InvalidParameter(format!("Invalid config name: {}", name))
            })?;

            let mut child: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.widget_get_child_by_name)(root, c_name.as_ptr(), &mut child);
            if ret < GP_OK {
                (sdk.widget_free)(root);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: config '{}' not found",
                    name
                )));
            }

            let count = (sdk.widget_count_choices)(child);
            let mut choices = Vec::new();

            for i in 0..count {
                let mut choice_ptr: *const c_char = std::ptr::null();
                if (sdk.widget_get_choice)(child, i, &mut choice_ptr) >= GP_OK
                    && !choice_ptr.is_null()
                {
                    let choice = CStr::from_ptr(choice_ptr).to_string_lossy().to_string();
                    choices.push(choice);
                }
            }

            (sdk.widget_free)(root);
            Ok(choices)
        }
    }

    /// Populate camera info (sensor dims, ISO values, etc.) after connecting.
    /// Caller must hold gphoto2_mutex.
    pub(crate) fn populate_camera_info(&mut self) -> Result<(), NativeError> {
        let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Query camera abilities to determine supported operations
        // SAFETY: caller holds gphoto2_mutex (per doc-comment on populate_camera_info).
        // `gp_camera` is valid non-null post-connect; `abilities` is a stack-allocated
        // POD struct (`#[derive(Default)]`) whose address is passed as the out-pointer
        // — libgphoto2 fills the struct by value, no internal pointers retained.
        unsafe {
            let mut abilities: CameraAbilities = CameraAbilities::default();
            let ret = (sdk.camera_get_abilities)(self.gp_camera, &mut abilities);
            if ret >= GP_OK {
                self.can_capture = (abilities.operations & GP_OPERATION_CAPTURE_IMAGE) != 0;
                self.can_preview = (abilities.operations & GP_OPERATION_CAPTURE_PREVIEW) != 0;
                self.can_configure = (abilities.operations & GP_OPERATION_CONFIG) != 0;
                self.can_bulb = (abilities.operations & GP_OPERATION_TRIGGER_CAPTURE) != 0;

                tracing::info!(
                    "gPhoto2 camera abilities: capture={}, preview={}, config={}, bulb={}",
                    self.can_capture,
                    self.can_preview,
                    self.can_configure,
                    self.can_bulb
                );
            }
        }

        // Try to read ISO values
        match self.get_config_choices("iso") {
            Ok(isos) => {
                tracing::info!("gPhoto2: Available ISO values: {:?}", isos);
                self.iso_values = isos;
            }
            Err(e) => {
                tracing::warn!("gPhoto2: Could not read ISO values: {}", e);
                // Use a reasonable default set
                self.iso_values = vec![
                    "100".to_string(),
                    "200".to_string(),
                    "400".to_string(),
                    "800".to_string(),
                    "1600".to_string(),
                    "3200".to_string(),
                    "6400".to_string(),
                ];
            }
        }

        // Get current ISO and map to gain index
        match self.get_config_value_str("iso") {
            Ok(current_iso) => {
                // Why: if the reported ISO does not
                // appear in the enumerated `iso_values` table (e.g. a
                // firmware-defined "Hi 1" string that libgphoto2 surfaces
                // but our parser hasn't mapped yet), fall back to index 0
                // which is the lowest legal ISO for the camera. The
                // subsequent set-gain call will then move the camera to a
                // known-good ISO before exposure.
                self.current_iso_index = self
                    .iso_values
                    .iter()
                    .position(|v| v == &current_iso)
                    .unwrap_or(0) as i32;
                self.current_gain = self.current_iso_index;
                tracing::info!(
                    "gPhoto2: Current ISO: {} (index {})",
                    current_iso,
                    self.current_iso_index
                );
            }
            Err(e) => {
                tracing::warn!("gPhoto2: Could not read current ISO: {}", e);
            }
        }

        // Try to read available shutter speeds
        match self.get_config_choices("shutterspeed") {
            Ok(speeds) => {
                tracing::info!("gPhoto2: Available shutter speeds: {:?}", speeds);
                self.shutter_speed_values = speeds;
            }
            Err(_) => {
                // Some cameras use "shutterspeed2" or other names
                match self.get_config_choices("shutterspeed2") {
                    Ok(speeds) => {
                        self.shutter_speed_values = speeds;
                    }
                    Err(_) => {
                        tracing::warn!("gPhoto2: Could not read shutter speed choices");
                    }
                }
            }
        }

        // Discover the bulb widget (Canon eosremoterelease vs generic bulb
        // toggle) so long exposures actually hold the shutter open per-brand.
        self.discover_bulb_widget();

        // Discover the RAW image-format choice so we can force RAW before every
        // capture (we always LibRaw-decode; a JPEG-configured body would fail).
        self.discover_raw_format();

        // Try to detect sensor dimensions from image format or camera model
        // Most DSLRs don't report sensor dims via PTP; we use common values
        self.detect_sensor_dimensions();

        Ok(())
    }

    /// Return the widget type (`CameraWidgetType` discriminant) for a config
    /// name, or `None` if the camera has no such widget. Caller must hold
    /// gphoto2_mutex.
    pub(crate) fn widget_type(&self, name: &str) -> Option<c_int> {
        let sdk = GPhoto2Sdk::get()?;

        // SAFETY: caller holds gphoto2_mutex. `gp_camera`/`gp_context` are valid
        // non-null post-connect. `root` is a stack out-pointer freed on every
        // exit path. `child` is owned by the widget tree (freed with `root`);
        // its type is read into a stack int.
        unsafe {
            let mut root: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.camera_get_config)(self.gp_camera, &mut root, self.gp_context);
            if ret < GP_OK {
                return None;
            }

            let c_name = CString::new(name).ok()?;
            let mut child: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.widget_get_child_by_name)(root, c_name.as_ptr(), &mut child);
            if ret < GP_OK {
                (sdk.widget_free)(root);
                return None;
            }

            let mut wtype: c_int = -1;
            let ret = (sdk.widget_get_type)(child, &mut wtype);
            (sdk.widget_free)(root);
            if ret < GP_OK {
                None
            } else {
                Some(wtype)
            }
        }
    }

    /// Set a TOGGLE (on/off) config value. Unlike `set_config_value_str`, this
    /// writes an INT value, which is what libgphoto2 requires for a
    /// `GP_WIDGET_TOGGLE` widget such as the Nikon/Sony `bulb` control.
    /// Caller must hold gphoto2_mutex.
    pub(crate) fn set_config_value_toggle(&self, name: &str, on: bool) -> Result<(), NativeError> {
        let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // SAFETY: caller holds gphoto2_mutex. `gp_camera`/`gp_context` are valid
        // non-null post-connect. `root` is a stack out-pointer freed on every
        // exit path. `value` is a stack int whose address is passed as the
        // widget value (TOGGLE widgets take `int*`, per libgphoto2). `child` is
        // owned by the widget tree.
        unsafe {
            let mut root: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.camera_get_config)(self.gp_camera, &mut root, self.gp_context);
            check_gp_error(ret, "get_config")?;

            let c_name = CString::new(name).map_err(|_| {
                NativeError::InvalidParameter(format!("Invalid config name: {}", name))
            })?;

            let mut child: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.widget_get_child_by_name)(root, c_name.as_ptr(), &mut child);
            if ret < GP_OK {
                (sdk.widget_free)(root);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: toggle config '{}' not found on this camera",
                    name
                )));
            }

            let value: c_int = if on { 1 } else { 0 };
            let ret = (sdk.widget_set_value)(child, &value as *const c_int as *const c_void);
            if ret < GP_OK {
                (sdk.widget_free)(root);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: failed to set toggle '{}' to {}: code {}",
                    name, value, ret
                )));
            }

            let ret = (sdk.camera_set_config)(self.gp_camera, root, self.gp_context);
            (sdk.widget_free)(root);
            check_gp_error(ret, "set_config")?;

            Ok(())
        }
    }

    /// Discover how this body opens/closes a bulb exposure. Prefers Canon's
    /// `eosremoterelease` (discovering the Press/Release choice strings
    /// dynamically, since their order varies by libgphoto2 version), else falls
    /// back to a generic `bulb` toggle widget (Nikon / Sony). Caller must hold
    /// gphoto2_mutex.
    pub(crate) fn discover_bulb_widget(&mut self) {
        // Canon EOS: eosremoterelease RADIO widget.
        if let Ok(choices) = self.get_config_choices("eosremoterelease") {
            let (press, release) = pick_eos_bulb_choices(&choices);
            tracing::info!(
                "gPhoto2: bulb via eosremoterelease (press='{}', release='{}')",
                press,
                release
            );
            self.bulb_widget = Some(BulbWidget::EosRemoteRelease { press, release });
            return;
        }

        // Nikon / Sony: generic `bulb` TOGGLE widget.
        if let Some(t) = self.widget_type("bulb") {
            if t == CameraWidgetType::Toggle as c_int {
                tracing::info!("gPhoto2: bulb via generic 'bulb' toggle widget");
                self.bulb_widget = Some(BulbWidget::BulbToggle);
                return;
            }
            // A non-toggle `bulb` widget is unusual; still try to drive it as a
            // toggle rather than dropping to the trigger-only fallback.
            tracing::info!(
                "gPhoto2: 'bulb' widget present with type {} — treating as toggle",
                t
            );
            self.bulb_widget = Some(BulbWidget::BulbToggle);
            return;
        }

        tracing::warn!(
            "gPhoto2: no bulb widget (eosremoterelease/bulb) found; long exposures \
             will fall back to trigger_capture, which may not hold the shutter open"
        );
        self.bulb_widget = None;
    }

    /// Discover a RAW image-format choice to force before capture. libgphoto2
    /// exposes this as `imageformat` (Canon/Sony) or `imagequality` (Nikon).
    /// We prefer a pure-RAW choice, then RAW+JPEG. Caller must hold
    /// gphoto2_mutex.
    pub(crate) fn discover_raw_format(&mut self) {
        for widget in ["imageformat", "imagequality"] {
            let Ok(choices) = self.get_config_choices(widget) else {
                continue;
            };
            if let Some(choice) = pick_raw_format_choice(&choices) {
                tracing::info!(
                    "gPhoto2: will force RAW via {}='{}' before capture",
                    widget,
                    choice
                );
                self.raw_format = Some((widget.to_string(), choice));
                return;
            }
            tracing::warn!(
                "gPhoto2: {} widget present but no RAW choice found in {:?}",
                widget,
                choices
            );
            return;
        }
        tracing::warn!(
            "gPhoto2: no image-format widget found; cannot force RAW (relying on \
             the camera already being set to RAW)"
        );
    }

    /// Force the camera into its RAW image format before capture (best effort;
    /// a failure is warned, not fatal, since some bodies expose no such
    /// widget). Caller must hold gphoto2_mutex.
    pub(crate) fn apply_raw_format(&self) {
        if let Some((widget, choice)) = &self.raw_format {
            if let Err(e) = self.set_config_value_str(widget, choice) {
                tracing::warn!(
                    "gPhoto2: could not force {}='{}': {}. Capture will use the \
                     camera's current format.",
                    widget,
                    choice,
                    e
                );
            } else {
                tracing::debug!("gPhoto2: forced {}='{}'", widget, choice);
            }
        }
    }

    /// Detect sensor dimensions based on camera model or image quality settings.
    /// Most DSLRs don't expose raw sensor dimensions via PTP, so we use a lookup
    /// of known models. Falls back to reasonable defaults.
    ///
    /// The `bit_depth` this sets is a PRE-FIRST-FRAME ESTIMATE, not an
    /// authority: libgphoto2 supports ~2500 bodies and this table lists ~30, so
    /// every other body — including the many genuinely 12-bit ones (Canon
    /// 350D/400D/450D, Nikon D3xxx/D5xxx in 12-bit mode, older Olympus and
    /// Panasonic) — lands on the 14-bit fallback. `adopt_decoded_depth`
    /// replaces it with LibRaw's measurement as soon as a frame is decoded.
    pub(crate) fn detect_sensor_dimensions(&mut self) {
        let model_lower = self.model_name.to_lowercase();

        // Common DSLR sensor dimensions by model family
        // (width, height, pixel_size_um, bit_depth)
        let (w, h, px, bits) = if model_lower.contains("6d mark ii") || model_lower.contains("6d2")
        {
            (6240, 4160, 5.7, 14)
        } else if model_lower.contains("5d mark iv") || model_lower.contains("5d4") {
            (6720, 4480, 5.4, 14)
        } else if model_lower.contains("5d mark iii") || model_lower.contains("5d3") {
            (5760, 3840, 6.3, 14)
        } else if model_lower.contains("eos r5") {
            (8192, 5464, 4.4, 14)
        } else if model_lower.contains("eos r6") || model_lower.contains("eos r6 ii") {
            (5472, 3648, 6.5, 14)
        } else if model_lower.contains("eos r")
            && !model_lower.contains("eos r5")
            && !model_lower.contains("eos r6")
            && !model_lower.contains("eos rp")
        {
            (6720, 4480, 5.4, 14)
        } else if model_lower.contains("eos rp") {
            (6240, 4160, 5.7, 14)
        } else if model_lower.contains("eos ra") {
            (6720, 4480, 5.4, 14) // Same as EOS R, H-alpha modified
        } else if model_lower.contains("d850") {
            (8256, 5504, 4.3, 14)
        } else if model_lower.contains("d810") {
            (7360, 4912, 4.9, 14)
        } else if model_lower.contains("d750") {
            (6016, 4016, 5.9, 14)
        } else if model_lower.contains("d610") || model_lower.contains("d600") {
            (6016, 4016, 5.9, 14)
        } else if model_lower.contains("z5") || model_lower.contains("z 5") {
            (6016, 4016, 5.9, 14)
        } else if model_lower.contains("z6") || model_lower.contains("z 6") {
            (6048, 4024, 5.9, 14)
        } else if model_lower.contains("z7") || model_lower.contains("z 7") {
            (8256, 5504, 4.3, 14)
        } else if model_lower.contains("a7r iv") || model_lower.contains("ilce-7rm4") {
            (9504, 6336, 3.7, 14)
        } else if model_lower.contains("a7r iii") || model_lower.contains("ilce-7rm3") {
            (7952, 5304, 4.5, 14)
        } else if model_lower.contains("a7 iii") || model_lower.contains("ilce-7m3") {
            (6000, 4000, 5.9, 14)
        } else if model_lower.contains("a7s") || model_lower.contains("ilce-7s") {
            (4240, 2832, 8.4, 14)
        } else if model_lower.contains("a6600") || model_lower.contains("ilce-6600") {
            (6000, 4000, 3.9, 14)
        } else if model_lower.contains("1000d") || model_lower.contains("rebel xs") {
            (3888, 2592, 5.7, 12)
        } else if model_lower.contains("1100d") || model_lower.contains("rebel t3") {
            (4272, 2848, 5.2, 12)
        } else if model_lower.contains("1200d") || model_lower.contains("rebel t5") {
            (5184, 3456, 4.3, 14)
        } else if model_lower.contains("1300d") || model_lower.contains("rebel t6") {
            (5184, 3456, 4.3, 14)
        } else if model_lower.contains("600d") || model_lower.contains("rebel t3i") {
            (5184, 3456, 4.3, 14)
        } else if model_lower.contains("700d") || model_lower.contains("rebel t5i") {
            (5184, 3456, 4.3, 14)
        } else if model_lower.contains("800d") || model_lower.contains("rebel t7i") {
            (6000, 4000, 3.7, 14)
        } else if model_lower.contains("200d") || model_lower.contains("rebel sl2") {
            (6000, 4000, 3.7, 14)
        } else if model_lower.contains("60da") || model_lower.contains("60d") {
            (5184, 3456, 4.3, 14)
        } else if model_lower.contains("k-70") || model_lower.contains("k70") {
            (6000, 4000, 3.9, 14)
        } else if model_lower.contains("k-1") || model_lower.contains("k1") {
            (7360, 4912, 4.9, 14)
        } else {
            // Reasonable defaults for an unknown full-frame DSLR
            tracing::warn!(
                "gPhoto2: Unknown camera model '{}', using default 6000x4000 sensor dimensions",
                self.model_name
            );
            (6000, 4000, 5.9, 14)
        };

        self.sensor_width = w;
        self.sensor_height = h;
        self.pixel_size = px;
        self.bit_depth = bits;

        tracing::info!(
            "gPhoto2: Sensor dimensions: {}x{}, pixel size: {:.1}um, bit depth: {}",
            w,
            h,
            px,
            bits
        );
    }

    /// Adopt the RAW decoder's ground truth for this body's sample depth.
    ///
    /// `bits` is `skotiq_imaging::CfaImage::bits_per_pixel` (derived from
    /// LibRaw's saturation level) and `white_level` is
    /// `skotiq_imaging::CfaImage::max_value` — LibRaw `color.maximum`, the
    /// exact largest value a pixel in the delivered mosaic can take. Both are
    /// measured from the frame in hand and outrank the model table, which only
    /// guesses.
    ///
    /// Zero/out-of-range inputs are ignored rather than adopted: LibRaw leaves
    /// `color.maximum` at 0 for a handful of bodies, and a 0 white level would
    /// otherwise publish an unreachable `max_adu`.
    pub(crate) fn adopt_decoded_depth(&mut self, bits: u32, white_level: u32) {
        let previous_max_adu = resolve_max_adu(self.measured_white_level, self.bit_depth);

        if (8..=16).contains(&bits) && bits != self.bit_depth {
            tracing::info!(
                "gPhoto2: adopting measured sensor bit depth {} (model-table estimate was {})",
                bits,
                self.bit_depth
            );
            self.bit_depth = bits;
        }

        if white_level > 0 && self.measured_white_level != Some(white_level) {
            tracing::info!(
                "gPhoto2: adopting measured white level {} as max_adu (was {})",
                white_level,
                previous_max_adu
            );
            self.measured_white_level = Some(white_level);
        }
    }

    /// Perform a standard (non-bulb) capture. Blocks until the camera completes the exposure.
    /// Caller must hold gphoto2_mutex.
    pub(crate) fn do_capture(&mut self) -> Result<(), NativeError> {
        let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;

        let mut file_path = CameraFilePath::default();

        // SAFETY: caller holds gphoto2_mutex (per doc-comment). `gp_camera` and
        // `gp_context` are valid non-null pointers post-connect. `file_path` is a stack
        // POD that libgphoto2 fills in-place with the folder/name buffers.
        unsafe {
            let ret = (sdk.camera_capture)(
                self.gp_camera,
                CameraCaptureType::Image as c_int,
                &mut file_path,
                self.gp_context,
            );
            check_gp_error(ret, "camera_capture")?;
        }

        tracing::info!(
            "gPhoto2: Captured image: {}/{}",
            cstr_from_array(&file_path.folder),
            cstr_from_array(&file_path.name)
        );

        self.last_capture_path = Some(file_path);
        Ok(())
    }

    /// Open the shutter for a bulb exposure using the brand-correct widget.
    ///
    /// Mirrors the reference driver's bulb-open path
    /// (gphoto_driver.cpp:1241-1255): set the camera to Bulb shutter, then
    /// drive the discovered widget — Canon `eosremoterelease` = Press-Full, or
    /// the Nikon/Sony `bulb` toggle = ON. Critically this does NOT use
    /// `gp_camera_trigger_capture` for the widget paths: on Nikon/Sony that
    /// never holds the shutter open, so long subs would time out / come back
    /// black. Caller must hold gphoto2_mutex.
    pub(crate) fn do_bulb_start(&mut self) -> Result<(), NativeError> {
        // Set camera to Bulb shutter speed (needed so the body honours the
        // held-open shutter). Non-fatal if absent on eosremoterelease bodies.
        if let Err(e) = self.set_config_value_str("shutterspeed", "Bulb") {
            if let Err(e2) = self.set_config_value_str("shutterspeed", "bulb") {
                // Only hard-fail when we also have no bulb widget to fall back
                // on; an EOS body may accept the press without a Bulb preset.
                if self.bulb_widget.is_none() {
                    tracing::warn!(
                        "gPhoto2: Could not set Bulb mode (tried 'Bulb' and 'bulb'): {}, {}",
                        e,
                        e2
                    );
                    return Err(NativeError::SdkError(
                        "gPhoto2: Camera does not support Bulb mode for long exposures".to_string(),
                    ));
                }
                tracing::debug!(
                    "gPhoto2: shutterspeed 'Bulb' not settable ({}); relying on bulb widget",
                    e2
                );
            }
        }

        match self.bulb_widget.clone() {
            Some(BulbWidget::EosRemoteRelease { press, .. }) => {
                // Canon EOS: Press-Full opens (and holds) the shutter.
                self.set_config_value_str("eosremoterelease", &press)
                    .map_err(|e| {
                        NativeError::SdkError(format!(
                            "gPhoto2: failed to open Canon bulb shutter (eosremoterelease='{}'): {}",
                            press, e
                        ))
                    })?;
                tracing::info!("gPhoto2: Bulb open via eosremoterelease='{}'", press);
            }
            Some(BulbWidget::BulbToggle) => {
                // Nikon / Sony: bulb toggle ON holds the shutter open.
                self.set_config_value_toggle("bulb", true).map_err(|e| {
                    NativeError::SdkError(format!(
                        "gPhoto2: failed to open bulb shutter (bulb toggle ON): {}",
                        e
                    ))
                })?;
                tracing::info!("gPhoto2: Bulb open via 'bulb' toggle = ON");
            }
            None => {
                // Last resort: no internal bulb widget. Trigger a capture; this
                // does not truly hold the shutter for bulb, but it is the only
                // option for bodies exposing neither widget.
                let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;
                // SAFETY: caller holds gphoto2_mutex. `gp_camera`/`gp_context`
                // are valid non-null post-connect; `camera_trigger_capture`
                // takes them by-value and returns a checked result code.
                unsafe {
                    let ret = (sdk.camera_trigger_capture)(self.gp_camera, self.gp_context);
                    check_gp_error(ret, "trigger_capture (bulb start fallback)")?;
                }
                tracing::warn!(
                    "gPhoto2: Bulb started via trigger_capture fallback (no bulb widget)"
                );
            }
        }

        Ok(())
    }

    /// Close the shutter, ending the bulb exposure, using the same widget that
    /// opened it. Mirrors the reference `stop_bulb` (gphoto_driver.cpp:652-664):
    /// eosremoterelease = Release, or bulb toggle = OFF. Caller must hold
    /// gphoto2_mutex.
    pub(crate) fn do_bulb_stop(&mut self) -> Result<(), NativeError> {
        match self.bulb_widget.clone() {
            Some(BulbWidget::EosRemoteRelease { release, .. }) => {
                self.set_config_value_str("eosremoterelease", &release)
                    .map_err(|e| {
                        NativeError::SdkError(format!(
                            "gPhoto2: failed to close Canon bulb shutter (eosremoterelease='{}'): {}",
                            release, e
                        ))
                    })?;
                tracing::info!("gPhoto2: Bulb closed via eosremoterelease='{}'", release);
                // The shutter is already closed (checked above); returning the widget to
                // its idle "None" choice only matters for the NEXT bulb start, which
                // re-writes the widget anyway. Report a failure so a camera stuck in the
                // release position is diagnosable instead of silent.
                if let Err(e) = self.set_config_value_str("eosremoterelease", "None") {
                    tracing::warn!(
                        "gPhoto2: could not return eosremoterelease to 'None' after closing the bulb shutter: {}",
                        e
                    );
                }
                Ok(())
            }
            Some(BulbWidget::BulbToggle) => {
                self.set_config_value_toggle("bulb", false).map_err(|e| {
                    NativeError::SdkError(format!(
                        "gPhoto2: failed to close bulb shutter (bulb toggle OFF): {}",
                        e
                    ))
                })?;
                tracing::info!("gPhoto2: Bulb closed via 'bulb' toggle = OFF");
                Ok(())
            }
            None => {
                // Trigger-capture fallback: nothing to release. Drain a
                // file-added event so the subsequent download can proceed.
                let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;
                // SAFETY: caller holds gphoto2_mutex. `gp_camera`/`gp_context`
                // are valid non-null. `event_type`/`event_data` are stack
                // out-pointers filled by libgphoto2; we only read `event_type`.
                unsafe {
                    let mut event_type: c_int = 0;
                    let mut event_data: *mut c_void = std::ptr::null_mut();
                    let ret = (sdk.camera_wait_for_event)(
                        self.gp_camera,
                        2000,
                        &mut event_type,
                        &mut event_data,
                        self.gp_context,
                    );
                    if ret >= GP_OK {
                        tracing::info!("gPhoto2: Bulb stop - received event type {}", event_type);
                    }
                }
                tracing::info!("gPhoto2: Bulb exposure stopped (trigger fallback)");
                Ok(())
            }
        }
    }

    /// Download the last captured image from the camera as raw bytes.
    /// Caller must hold gphoto2_mutex.
    pub(crate) fn download_from_camera(&mut self) -> Result<Vec<u8>, NativeError> {
        let sdk = GPhoto2Sdk::get().ok_or(NativeError::SdkNotLoaded)?;

        let file_path = self.last_capture_path.as_ref().ok_or_else(|| {
            NativeError::SdkError("gPhoto2: No captured image to download".to_string())
        })?;

        let folder_str = cstr_from_array(&file_path.folder);
        let name_str = cstr_from_array(&file_path.name);

        let c_folder = CString::new(folder_str.as_str())
            .map_err(|_| NativeError::SdkError("gPhoto2: Invalid folder path".to_string()))?;
        let c_name = CString::new(name_str.as_str())
            .map_err(|_| NativeError::SdkError("gPhoto2: Invalid file name".to_string()))?;

        // SAFETY: caller holds gphoto2_mutex (per download_from_camera's doc-comment).
        // `gp_camera`/`gp_context` are valid non-null post-connect. `gp_file` is a
        // stack out-pointer paired with `file_free` on every exit path. `c_folder`/
        // `c_name` are CString owners that outlive their `.as_ptr()` use. The
        // `data_ptr` / `data_size` out-pointers are read only after checking the
        // return code and non-null guard; the slice we build is immediately copied
        // into a Vec before `file_free` invalidates the underlying buffer.
        unsafe {
            // Create a CameraFile to receive the data
            let mut gp_file: *mut CameraFile = std::ptr::null_mut();
            let ret = (sdk.file_new)(&mut gp_file);
            check_gp_error(ret, "file_new")?;

            // Download the file from camera
            let ret = (sdk.camera_file_get)(
                self.gp_camera,
                c_folder.as_ptr(),
                c_name.as_ptr(),
                CameraFileType::Normal as c_int,
                gp_file,
                self.gp_context,
            );
            if ret < GP_OK {
                (sdk.file_free)(gp_file);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: Failed to download image {}/{}: code {}",
                    folder_str, name_str, ret
                )));
            }

            // Get the data pointer and size
            let mut data_ptr: *const c_char = std::ptr::null();
            let mut data_size: u64 = 0;
            let ret = (sdk.file_get_data_and_size)(gp_file, &mut data_ptr, &mut data_size);
            if ret < GP_OK || data_ptr.is_null() || data_size == 0 {
                (sdk.file_free)(gp_file);
                return Err(NativeError::SdkError(format!(
                    "gPhoto2: Failed to read image data: code {}",
                    ret
                )));
            }

            // Copy data into our own buffer (gp_file owns the pointer)
            let data = std::slice::from_raw_parts(data_ptr as *const u8, data_size as usize);
            let raw_bytes = data.to_vec();

            tracing::info!(
                "gPhoto2: Downloaded {} bytes from {}/{}",
                raw_bytes.len(),
                folder_str,
                name_str
            );

            // Free the CameraFile
            (sdk.file_free)(gp_file);

            // Delete the file from camera to free space (optional, but good practice)
            let del_ret = (sdk.camera_file_delete)(
                self.gp_camera,
                c_folder.as_ptr(),
                c_name.as_ptr(),
                self.gp_context,
            );
            if del_ret < GP_OK {
                tracing::warn!(
                    "gPhoto2: Could not delete image from camera (code {}), card may fill up",
                    del_ret
                );
            }

            Ok(raw_bytes)
        }
    }

    /// Decode a raw camera file (CR2, NEF, ARW, etc.) into the single-channel
    /// LINEAR Bayer mosaic that the capture pipeline expects.
    ///
    /// Uses `read_cfa_mosaic_from_bytes` (unpack + raw2image, NO dcraw_process)
    /// so the result is the sensor's native linear CFA mosaic — one u16 sample
    /// per pixel, `data.len() == width*height`, with a valid Bayer pattern —
    /// NOT a demosaiced/white-balanced/gamma-encoded 3-channel sRGB image.
    /// Feeding processed RGB into the mono-mosaic contract corrupts every DSLR
    /// frame (3× oversize, non-linear, double-debayered).
    pub(crate) fn decode_raw_to_image_data(
        &mut self,
        raw_bytes: &[u8],
    ) -> Result<ImageData, NativeError> {
        // Detect the RAW format from magic bytes. If it is NOT a recognised
        // RAW (i.e. the body handed us a JPEG because it is in JPEG-only mode),
        // fail with an actionable message instead of feeding JPEG to LibRaw's
        // RAW decoder and emitting an opaque "failed to decode" every frame.
        let Some(extension) = skotiq_imaging::raw_format_extension(raw_bytes) else {
            return Err(NativeError::SdkError(
                "gPhoto2: the camera returned a non-RAW file (it appears to be JPEG). \
                 Set the camera's image quality to RAW (or RAW+JPEG) — astro capture \
                 requires the linear RAW sensor data."
                    .to_string(),
            ));
        };

        // Decode to the native linear CFA mosaic (single channel, no demosaic).
        let (cfa, metadata) = skotiq_imaging::read_cfa_mosaic_from_bytes(raw_bytes, extension)
            .map_err(|e| {
                NativeError::SdkError(format!("gPhoto2: Failed to decode RAW image: {}", e))
            })?;

        // Contract guard: the mono mosaic MUST be exactly width*height samples.
        // A mismatch here means the decode path silently regressed to a
        // multi-channel buffer — refuse rather than ship corrupt geometry.
        let expected = (cfa.width as usize) * (cfa.height as usize);
        if cfa.data.len() != expected {
            return Err(NativeError::SdkError(format!(
                "gPhoto2: CFA decode produced {} samples for a {}x{} frame (expected {}) — \
                 refusing to emit a corrupt frame",
                cfa.data.len(),
                cfa.width,
                cfa.height,
                expected
            )));
        }

        // The decoder knows this body's real numbers; the model table only
        // guessed. `bits_per_pixel` and `max_value` (LibRaw `color.maximum`)
        // become this camera's published depth and container ceiling from here
        // on. The mosaic is RIGHT-JUSTIFIED at its native depth — the decode is
        // `unpack` + `raw2image` with no `dcraw_process` (imaging/src/raw.rs
        // :1097-1108, contract in imaging/src/libraw_shim.c:98-102) — so the
        // white level IS the container full scale and must not be scaled up.
        self.adopt_decoded_depth(cfa.bits_per_pixel, cfa.max_value);

        tracing::info!(
            "gPhoto2: Decoded RAW mosaic: {}x{}, {}-bit, pattern {:?}, camera: {} {}",
            cfa.width,
            cfa.height,
            cfa.bits_per_pixel,
            cfa.cfa_pattern,
            metadata.camera_make,
            metadata.camera_model,
        );

        // Map the detected 2×2 CFA orientation to our BayerPattern. Canon/Nikon/
        // Sony DSLRs are always Bayer, so a `None` here (LibRaw failed to
        // classify the CFA) is unexpected — fall back to RGGB (most common) with
        // a warning so the frame still debayers to colour.
        let bayer_pattern = match cfa.cfa_pattern {
            Some(skotiq_imaging::CfaPattern::Rggb) => Some(BayerPattern::Rggb),
            Some(skotiq_imaging::CfaPattern::Grbg) => Some(BayerPattern::Grbg),
            Some(skotiq_imaging::CfaPattern::Gbrg) => Some(BayerPattern::Gbrg),
            Some(skotiq_imaging::CfaPattern::Bggr) => Some(BayerPattern::Bggr),
            None => {
                tracing::warn!(
                    "gPhoto2: LibRaw did not classify the CFA (color_desc='{}'); \
                     defaulting to RGGB for this DSLR frame",
                    metadata.color_desc
                );
                Some(BayerPattern::Rggb)
            }
        };

        Ok(ImageData {
            width: cfa.width,
            height: cfa.height,
            data: cfa.data,
            // Truthful sensor bit depth derived from LibRaw's saturation level.
            bits_per_pixel: cfa.bits_per_pixel,
            bayer_pattern,
            metadata: ImageMetadata {
                exposure_time: self.exposure_time,
                gain: self.current_gain,
                offset: self.current_offset,
                bin_x: 1,
                bin_y: 1,
                temperature: None, // DSLRs don't report sensor temp
                timestamp: chrono::Utc::now(),
                subframe: None,
                readout_mode: None,
                vendor_data: VendorFeatures {
                    custom_data: {
                        let mut map = std::collections::HashMap::new();
                        if let Some(iso_str) = self.iso_values.get(self.current_gain as usize) {
                            map.insert(
                                "iso".to_string(),
                                serde_json::Value::String(iso_str.clone()),
                            );
                        }
                        map.insert(
                            "camera_model".to_string(),
                            serde_json::Value::String(self.model_name.clone()),
                        );
                        if metadata.iso_speed.is_some() {
                            map.insert(
                                "exif_iso".to_string(),
                                serde_json::json!(metadata.iso_speed),
                            );
                        }
                        if metadata.shutter_speed.is_some() {
                            map.insert(
                                "exif_shutter".to_string(),
                                serde_json::json!(metadata.shutter_speed),
                            );
                        }
                        map
                    },
                    ..Default::default()
                },
            },
        })
    }
}
