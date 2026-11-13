//! `GPhoto2Camera` state and inherent helpers.

use super::exposure::{recorded_exposure, MadeExposure, ShutterSpeeds};
use super::*;
use crate::camera_core::{CameraCore, Frame};

/// An exposure in progress, or made and not yet read.
#[derive(Debug, Default)]
pub(crate) enum ExposureState {
    #[default]
    Idle,
    /// One of the body's timed speeds. `gp_camera_capture` runs on a blocking
    /// thread, holding the SDK lock, until the camera has written the frame,
    /// and answers the file it wrote.
    Timed {
        start: Instant,
        seconds: f64,
        capture: tokio::task::JoinHandle<Result<CameraFilePath, DriverError>>,
    },
    /// Bulb: the shutter is open until Skotiq closes it.
    Bulb { opened: Instant, requested: f64 },
}

/// A body's camera and context handles, for the capture thread.
#[derive(Clone, Copy)]
pub(crate) struct CameraHandles {
    camera: *mut GPCamera,
    context: *mut GPContext,
}

// SAFETY: the handles move to the capture thread together with the held gphoto2
// SDK lock, and are used there only while that lock is held, so no other thread
// reaches libgphoto2 with them at the same time.
unsafe impl Send for CameraHandles {}

/// How long a bulb frame may take to appear after the shutter closes (the
/// INDI driver's default download timeout, gphoto_ccd.cpp DownloadTimeoutNP).
const BULB_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(60);

/// How long a RAW+JPEG body takes between its two files.
const SECOND_FILE_WAIT: Duration = Duration::from_secs(3);

/// How often an idle body is asked whether it is still there.
const PROBE_INTERVAL: Duration = Duration::from_secs(5);

pub struct GPhoto2Camera {
    /// Camera index from autodetect
    pub(crate) camera_index: usize,
    /// Identity, connection, the sensor description and the ISO (the core's
    /// gain). The name is the model as libgphoto2 names it once connected;
    /// before that, the name the device was registered under. The sensor
    /// description comes from the model table until the first frame is
    /// decoded, then from the frames: size, color filter, ADC precision
    /// (`skotiq_imaging::RawFrame::bits_per_pixel`, an estimate of 14 before)
    /// and the saturation level when the camera records one below its white
    /// level (it varies with the ISO). The pixel pitch is 0 for a body the
    /// table does not list.
    pub(crate) core: CameraCore,
    /// The model as a device address carries it (`sanitize_id`), which is
    /// what identifies the body among the attached cameras.
    pub(crate) model_key: String,
    /// USB port path
    pub(crate) port_path: String,

    /// gPhoto2 camera handle (owned, must be freed on disconnect)
    pub(crate) gp_camera: *mut GPCamera,
    /// gPhoto2 context handle (owned, must be freed on disconnect)
    pub(crate) gp_context: *mut GPContext,

    /// Container full scale measured from the most recently decoded frame:
    /// LibRaw `color.maximum` surfaced as `skotiq_imaging::RawFrame::white_level`.
    /// `None` until the first frame is decoded, when `resolve_max_adu` falls
    /// back to the bit depth.
    pub(crate) measured_white_level: Option<u32>,

    pub(crate) can_preview: bool,
    pub(crate) facts: BodyFacts,

    /// The ISO widget's name and the speeds it offers, lowest first.
    pub(crate) iso_widget: String,
    pub(crate) iso_speeds: Vec<IsoChoice>,
    pub(crate) long_exposure_nr: LongExposureNoiseReduction,

    /// The shutter speeds the body lists, refreshed before every exposure
    /// (they change with the mode dial).
    pub(crate) shutter: ShutterSpeeds,
    pub(crate) bulb_widget: Option<BulbWidget>,
    /// The image-format widget and its RAW choice, forced before each capture.
    pub(crate) raw_format: Option<(String, String)>,

    pub(crate) exposure: ExposureState,
    pub(crate) last_probe: std::sync::Mutex<Option<Instant>>,
}

// Implement Debug manually since raw pointers don't implement Debug
impl std::fmt::Debug for GPhoto2Camera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GPhoto2Camera")
            .field("camera_index", &self.camera_index)
            .field("core", &self.core)
            .field("port_path", &self.port_path)
            .field("exposure", &self.exposure)
            .finish()
    }
}

// SAFETY: GPhoto2Camera is Send+Sync because every libgphoto2 call on it goes
// through an `SdkGuard`, which holds the gphoto2 SDK lock, so only one thread
// uses the camera at a time. The raw `gp_camera` / `gp_context` pointers stored
// in this struct are only dereferenced in `unsafe` blocks that run under that
// guard; the one exception is `Drop`, which owns the camera exclusively.
unsafe impl Send for GPhoto2Camera {}
// SAFETY: Same justification as the `Send` impl above — the `SdkGuard` serializes
// all SDK access, so concurrent `&GPhoto2Camera` references never reach libgphoto2
// at the same time.
unsafe impl Sync for GPhoto2Camera {}

/// One event a body reports.
pub(crate) enum CameraEvent {
    FileAdded(Box<CameraFilePath>),
    CaptureComplete,
    Timeout,
    Other,
}

/// Releases what `gp_camera_wait_for_event` handed out: libgphoto2 allocates
/// the event data with `malloc` and leaves it to the caller.
///
/// # Safety
/// `data` is null or the event data of one `gp_camera_wait_for_event` call,
/// not freed yet.
unsafe fn free_event_data(data: *mut c_void) {
    #[cfg(unix)]
    {
        extern "C" {
            fn free(ptr: *mut c_void);
        }
        // SAFETY: per this function's contract `data` came from libgphoto2's
        // malloc (or is null, which free accepts).
        unsafe { free(data) }
    }
    // A Windows libgphoto2 allocates from its own C runtime, which this process
    // cannot free into; the few bytes per event are left.
    #[cfg(not(unix))]
    let _ = data;
}

/// Run `gp_camera_capture` for a timed speed and answer the file it wrote.
pub(crate) fn capture_image(
    sdk: &GPhoto2Sdk,
    handles: CameraHandles,
) -> Result<CameraFilePath, DriverError> {
    let mut file_path = CameraFilePath::default();
    // SAFETY: the caller holds the SDK lock (`sdk` is the table of a held
    // guard) and `handles` are the open camera's; `file_path` is a stack POD
    // libgphoto2 fills in place.
    let ret = unsafe {
        (sdk.camera_capture)(
            handles.camera,
            CameraCaptureType::Image as c_int,
            &mut file_path,
            handles.context,
        )
    };
    check_gp_error(ret, "capture")?;
    Ok(file_path)
}

/// Frees libgphoto2's model and port lists when an open ends either way.
struct OpenLists<'a> {
    sdk: &'a GPhoto2Sdk,
    abilities: *mut CameraAbilitiesList,
    ports: *mut GPPortInfoList,
}

impl Drop for OpenLists<'_> {
    fn drop(&mut self) {
        // SAFETY: each list is null or was made by its `_new` call in
        // `open_camera` and is freed only here; the caller holds the SDK lock.
        unsafe {
            if !self.abilities.is_null() {
                (self.sdk.abilities_list_free)(self.abilities);
            }
            if !self.ports.is_null() {
                (self.sdk.port_info_list_free)(self.ports);
            }
        }
    }
}

/// Open the body of `model` on `port`, the way the INDI driver does
/// (gphoto_driver.cpp:1669-1776): the camera is given its model's abilities
/// and its port before `gp_camera_init`, which otherwise opens whichever
/// camera it finds first. Runs under the SDK lock the caller holds.
pub(crate) fn open_camera(
    sdk: &GPhoto2Sdk,
    model: &str,
    port: &str,
) -> Result<(*mut GPCamera, *mut GPContext), DriverError> {
    let c_model = CString::new(model)
        .map_err(|_| DriverError::InvalidParameter(format!("Invalid camera model: {model}")))?;
    let c_port = CString::new(port)
        .map_err(|_| DriverError::InvalidParameter(format!("Invalid camera port: {port}")))?;
    let opening = format!("opening {model} on {port}");

    // SAFETY: every out-pointer is a local; each object made here is freed on
    // every path (the lists by `OpenLists`, camera and context below unless
    // they are returned). The abilities are copied out of the list by value and
    // the port entry stays owned by its list, which outlives `gp_camera_init`.
    unsafe {
        let context = (sdk.context_new)();
        if context.is_null() {
            return Err(DriverError::SdkError(
                "gPhoto2: Failed to create context".to_string(),
            ));
        }
        let mut camera: *mut GPCamera = std::ptr::null_mut();
        let ret = (sdk.camera_new)(&mut camera);
        if ret < GP_OK || camera.is_null() {
            (sdk.context_unref)(context);
            return Err(gp_error(ret, &opening));
        }

        let mut lists = OpenLists {
            sdk,
            abilities: std::ptr::null_mut(),
            ports: std::ptr::null_mut(),
        };
        let bound = (|| {
            check_gp_error((sdk.abilities_list_new)(&mut lists.abilities), &opening)?;
            check_gp_error(
                (sdk.abilities_list_load)(lists.abilities, context),
                &opening,
            )?;
            let index = (sdk.abilities_list_lookup_model)(lists.abilities, c_model.as_ptr());
            check_gp_error(index, &opening)?;
            let mut abilities = CameraAbilities::default();
            check_gp_error(
                (sdk.abilities_list_get_abilities)(lists.abilities, index, &mut abilities),
                &opening,
            )?;
            check_gp_error((sdk.camera_set_abilities)(camera, abilities), &opening)?;

            check_gp_error((sdk.port_info_list_new)(&mut lists.ports), &opening)?;
            check_gp_error((sdk.port_info_list_load)(lists.ports), &opening)?;
            let index = (sdk.port_info_list_lookup_path)(lists.ports, c_port.as_ptr());
            check_gp_error(index, &opening)?;
            let mut info: GPPortInfo = std::ptr::null_mut();
            check_gp_error(
                (sdk.port_info_list_get_info)(lists.ports, index, &mut info),
                &opening,
            )?;
            check_gp_error((sdk.camera_set_port_info)(camera, info), &opening)?;
            check_gp_error((sdk.camera_init)(camera, context), &opening)
        })();
        drop(lists);

        match bound {
            Ok(()) => Ok((camera, context)),
            Err(e) => {
                (sdk.camera_free)(camera);
                (sdk.context_unref)(context);
                Err(e)
            }
        }
    }
}

impl GPhoto2Camera {
    /// The camera a device address names: `<index>:<port as hex>:<model key>`
    /// (`build_device_id` without its prefix). An address written before the
    /// port was recorded, or one whose port does not decode, leaves the port
    /// empty; one without a model key identifies the model by `name`.
    pub fn from_address(address: &str, name: &str) -> Result<Self, String> {
        let mut segments = address.splitn(3, ':');
        let index = segments
            .next()
            .unwrap_or_default()
            .parse()
            .map_err(|_| format!("Invalid gPhoto2 camera index in '{address}'"))?;
        let port = segments
            .next()
            .and_then(decode_port_component)
            .unwrap_or_default();
        let mut camera = Self::new(index, name, &port);
        if let Some(key) = segments.next().filter(|k| !k.is_empty()) {
            camera.model_key = key.to_string();
        }
        camera.core.device_id = format!("native:gphoto2:{address}");
        Ok(camera)
    }

    /// Create a new gPhoto2 camera instance from a detected camera.
    pub fn new(index: usize, model: &str, port: &str) -> Self {
        let mut core = CameraCore::new(build_device_id(index, model, port), model.to_string());
        core.capabilities = CameraCapabilities {
            can_cool: false,
            // ISO, as the gain number, once the body has listed its speeds.
            can_set_gain: false,
            can_set_offset: false,
            can_set_binning: false,
            can_subframe: false,
            has_shutter: true,
            has_guider_port: false,
            max_bin_x: 1,
            max_bin_y: 1,
            supports_readout_modes: false,
        };
        core.sensor_info = SensorInfo {
            bit_depth: 14,
            max_adu: resolve_max_adu(None, 14),
            color: true,
            ..SensorInfo::default()
        };
        Self {
            camera_index: index,
            core,
            model_key: sanitize_id(model),
            port_path: port.to_string(),
            gp_camera: std::ptr::null_mut(),
            gp_context: std::ptr::null_mut(),
            measured_white_level: None,
            can_preview: false,
            facts: BodyFacts::default(),
            iso_widget: String::new(),
            iso_speeds: Vec::new(),
            long_exposure_nr: LongExposureNoiseReduction::NotApplicable,
            shutter: ShutterSpeeds::default(),
            bulb_widget: None,
            raw_format: None,
            exposure: ExposureState::Idle,
            last_probe: std::sync::Mutex::new(None),
        }
    }

    pub(crate) fn handles(&self) -> CameraHandles {
        CameraHandles {
            camera: self.gp_camera,
            context: self.gp_context,
        }
    }

    /// `gp_camera_set_config`, again while the camera answers busy (it is still
    /// writing the last frame): five tries 500 ms apart, as the INDI driver
    /// does (gphoto_driver.cpp:350-376).
    fn write_config(&self, sdk: &GPhoto2Sdk, root: *mut CameraWidget) -> Result<(), DriverError> {
        let mut attempt = 1;
        loop {
            // SAFETY: the caller holds the SDK lock; `root` is the live tree it
            // read from this camera, freed by the caller afterwards.
            let ret = unsafe { (sdk.camera_set_config)(self.gp_camera, root, self.gp_context) };
            if ret == GP_ERROR_CAMERA_BUSY && attempt < 5 {
                attempt += 1;
                std::thread::sleep(Duration::from_millis(500));
                continue;
            }
            return check_gp_error(ret, "set_config");
        }
    }

    /// Set a radio, menu or text configuration value on the camera.
    /// Runs under the SDK lock the caller already holds.
    pub(crate) fn set_config_value_str(
        &self,
        sdk: &GPhoto2Sdk,
        name: &str,
        value: &str,
    ) -> Result<(), DriverError> {
        let c_value = CString::new(value)
            .map_err(|_| DriverError::InvalidParameter(format!("Invalid config value: {value}")))?;
        self.set_config_value(sdk, name, value, |child| {
            // SAFETY: `child` is a live widget of the tree being written;
            // `c_value` outlives the call, which copies the string.
            unsafe { (sdk.widget_set_value)(child, c_value.as_ptr() as *const c_void) }
        })
    }

    /// Set a TOGGLE (on/off) config value: libgphoto2 takes an `int` for a
    /// `GP_WIDGET_TOGGLE` widget such as the `bulb` control.
    /// Runs under the SDK lock the caller already holds.
    pub(crate) fn set_config_value_toggle(
        &self,
        sdk: &GPhoto2Sdk,
        name: &str,
        on: bool,
    ) -> Result<(), DriverError> {
        let value: c_int = if on { 1 } else { 0 };
        self.set_config_value(sdk, name, &value.to_string(), |child| {
            // SAFETY: `child` is a live widget of the tree being written; a
            // toggle widget reads an `int` through the pointer.
            unsafe { (sdk.widget_set_value)(child, &value as *const c_int as *const c_void) }
        })
    }

    fn set_config_value(
        &self,
        sdk: &GPhoto2Sdk,
        name: &str,
        shown: &str,
        set: impl FnOnce(*mut CameraWidget) -> c_int,
    ) -> Result<(), DriverError> {
        let c_name = CString::new(name)
            .map_err(|_| DriverError::InvalidParameter(format!("Invalid config name: {name}")))?;
        // SAFETY: `gp_camera`/`gp_context` are valid post-connect and the caller
        // holds the SDK lock. `root` is a stack out-pointer freed on every path
        // after it was read; `child` belongs to that tree.
        unsafe {
            let mut root: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.camera_get_config)(self.gp_camera, &mut root, self.gp_context);
            check_gp_error(ret, "get_config")?;
            let mut child: *mut CameraWidget = std::ptr::null_mut();
            let result =
                if (sdk.widget_get_child_by_name)(root, c_name.as_ptr(), &mut child) < GP_OK {
                    Err(DriverError::SdkError(format!(
                        "gPhoto2: config '{name}' not found on this camera"
                    )))
                } else if set(child) < GP_OK {
                    Err(DriverError::SdkError(format!(
                        "gPhoto2: the camera did not take {name} = '{shown}'"
                    )))
                } else {
                    self.write_config(sdk, root)
                };
            (sdk.widget_free)(root);
            result
        }
    }

    /// The body's whole configuration tree. Runs under the SDK lock the
    /// caller already holds.
    pub(crate) fn read_config_tree(&self, sdk: &GPhoto2Sdk) -> Result<ConfigWidget, DriverError> {
        // SAFETY: `gp_camera`/`gp_context` are valid non-null post-connect.
        // `root` is a stack out-pointer, freed after the snapshot is copied out;
        // every child pointer and string read below is owned by that tree and
        // only borrowed while it is alive.
        unsafe {
            let mut root: *mut CameraWidget = std::ptr::null_mut();
            let ret = (sdk.camera_get_config)(self.gp_camera, &mut root, self.gp_context);
            check_gp_error(ret, "get_config")?;
            let tree = snapshot_widget(sdk, root);
            (sdk.widget_free)(root);
            Ok(tree)
        }
    }

    /// Open the camera found for this device, read what it is and set it up.
    /// Runs under the SDK lock the caller holds.
    pub(crate) fn open(&mut self, sdk: &GPhoto2Sdk) -> Result<(), DriverError> {
        let detected = detect_cameras_with(sdk);
        let found = select_camera(&detected, &self.model_key, &self.port_path)?;
        self.camera_index = found.index;
        self.port_path = found.port.clone();
        self.core.name = found.model.clone();

        let (camera, context) = open_camera(sdk, &self.core.name, &self.port_path)?;
        self.gp_camera = camera;
        self.gp_context = context;
        if let Err(e) = self.populate_camera_info(sdk) {
            self.close(sdk);
            return Err(e);
        }
        Ok(())
    }

    /// Close the camera. Runs under the SDK lock the caller holds.
    pub(crate) fn close(&mut self, sdk: &GPhoto2Sdk) {
        // SAFETY: each pointer is null-checked, freed once and set to null, so
        // a later `Drop` does not free it again.
        unsafe {
            if !self.gp_camera.is_null() {
                let _ = (sdk.camera_exit)(self.gp_camera, self.gp_context);
                (sdk.camera_free)(self.gp_camera);
                self.gp_camera = std::ptr::null_mut();
            }
            if !self.gp_context.is_null() {
                (sdk.context_unref)(self.gp_context);
                self.gp_context = std::ptr::null_mut();
            }
        }
    }

    /// Read what the body is and offers, and set it up for capture. Runs under
    /// the SDK lock the caller already holds.
    pub(crate) fn populate_camera_info(&mut self, sdk: &GPhoto2Sdk) -> Result<(), DriverError> {
        let mut abilities = CameraAbilities::default();
        // SAFETY: `gp_camera` is valid post-connect; `abilities` is a stack POD
        // libgphoto2 fills by value.
        let ret = unsafe { (sdk.camera_get_abilities)(self.gp_camera, &mut abilities) };
        check_gp_error(ret, "get_abilities")?;
        let operations = abilities.operations;
        if operations & GP_OPERATION_CAPTURE_IMAGE == 0 {
            return Err(DriverError::SdkError(format!(
                "gPhoto2: libgphoto2 can read files from {} but cannot take pictures with it. \
                 Set the camera's USB mode to PC (PTP) or remote control.",
                self.core.name
            )));
        }
        self.can_preview = operations & GP_OPERATION_CAPTURE_PREVIEW != 0;

        let tree = self.read_config_tree(sdk)?;
        self.facts = body_facts(&tree);
        tracing::info!(
            "gPhoto2: {} on {}: {:?}; capture, preview {}, configuration {}, trigger {}",
            self.core.name,
            self.port_path,
            self.facts,
            self.can_preview,
            operations & GP_OPERATION_CONFIG != 0,
            operations & GP_OPERATION_TRIGGER_CAPTURE != 0,
        );
        if let Some(percent) = self.facts.battery_percent().filter(|p| *p < 20) {
            tracing::warn!(
                "gPhoto2: {} battery at {}%; a night needs a full battery or a mains adapter",
                self.core.name,
                percent
            );
        }

        self.read_iso_speeds(&tree);
        self.long_exposure_nr = self.switch_off_long_exposure_nr(sdk, &tree);

        self.shutter = shutter_speeds(&tree).unwrap_or_default();
        self.bulb_widget = bulb_control(&tree);
        tracing::info!(
            "gPhoto2: shutter speeds from '{}': {:?}; bulb {:?} via {:?}",
            self.shutter.widget,
            self.shutter
                .timed
                .iter()
                .map(|s| s.choice.as_str())
                .collect::<Vec<_>>(),
            self.shutter.bulb_choice,
            self.bulb_widget
        );

        self.raw_format = match raw_format(&tree) {
            Some((widget, Some(choice))) => {
                tracing::info!(
                    "gPhoto2: will force RAW via {}='{}' before capture",
                    widget,
                    choice
                );
                Some((widget, choice))
            }
            Some((widget, None)) => {
                tracing::warn!(
                    "gPhoto2: {} lists no RAW choice; set the camera to RAW",
                    widget
                );
                None
            }
            None => {
                tracing::warn!(
                    "gPhoto2: no image-format widget; the camera has to be set to RAW on the body"
                );
                None
            }
        };

        self.adopt_model_table();
        Ok(())
    }

    /// Sensor size, pitch and bit depth from the model table, until a frame
    /// says better.
    pub(crate) fn adopt_model_table(&mut self) {
        match models::sensor_spec(&self.core.name) {
            Some(spec) => {
                let info = &mut self.core.sensor_info;
                info.width = spec.width;
                info.height = spec.height;
                info.pixel_size_x = spec.pixel_um;
                info.pixel_size_y = spec.pixel_um;
                info.bit_depth = spec.bits;
                info.max_adu = resolve_max_adu(self.measured_white_level, spec.bits);
            }
            None => tracing::warn!(
                "gPhoto2: Skotiq does not know the pixel size of {}; frames carry no XPIXSZ \
                 and the frame size is read from the first frame",
                self.core.name
            ),
        }
    }

    /// Read the ISO speeds the body offers and the one it is set to.
    fn read_iso_speeds(&mut self, tree: &ConfigWidget) {
        let Some(widget) = iso_widget(tree) else {
            tracing::warn!(
                "gPhoto2: the camera shows no ISO setting; ISO cannot be set from Skotiq"
            );
            self.iso_speeds.clear();
            self.core.capabilities.can_set_gain = false;
            return;
        };
        self.iso_widget = widget.name.clone();
        self.iso_speeds = iso_choices(&widget.choices);
        self.core.capabilities.can_set_gain = !self.iso_speeds.is_empty();
        let skipped: Vec<&String> = widget
            .choices
            .iter()
            .filter(|c| !self.iso_speeds.iter().any(|s| &s.choice == *c))
            .collect();
        tracing::info!(
            "gPhoto2: ISO speeds {:?}; not offered as a number: {:?}",
            self.iso_speeds.iter().map(|s| s.speed).collect::<Vec<_>>(),
            skipped
        );
        match widget
            .value
            .as_deref()
            .and_then(|v| v.trim().parse::<i32>().ok())
        {
            Some(iso) => self.core.gain = iso,
            None => {
                // Auto ISO or a step name: a frame records the ISO its raw
                // file names; this stands in only where a file names none.
                self.core.gain = self.iso_speeds.first().map_or(0, |s| s.speed);
                tracing::info!(
                    "gPhoto2: camera ISO reads {:?}, which is not a speed",
                    widget.value
                );
            }
        }
    }

    /// Set the offered ISO speed nearest to `requested` and record what the
    /// body took. Runs under the SDK lock the caller already holds.
    pub(crate) fn apply_iso(
        &mut self,
        sdk: &GPhoto2Sdk,
        requested: i32,
    ) -> Result<(), DriverError> {
        let Some(chosen) = nearest_iso(&self.iso_speeds, requested).cloned() else {
            return Err(DriverError::NotSupported);
        };
        if chosen.speed != requested {
            tracing::info!(
                "gPhoto2: ISO {} is not one of the camera's speeds; using ISO {}",
                requested,
                chosen.speed
            );
        }
        self.set_config_value_str(sdk, &self.iso_widget, &chosen.choice)?;
        self.core.command_gain(chosen.speed);
        Ok(())
    }

    /// Turn the body's long exposure noise reduction off if it shows the
    /// setting, and say where it stands. Runs under the SDK lock the caller
    /// already holds.
    fn switch_off_long_exposure_nr(
        &self,
        sdk: &GPhoto2Sdk,
        tree: &ConfigWidget,
    ) -> LongExposureNoiseReduction {
        let Some(widget) = long_exposure_nr_widget(tree) else {
            tracing::info!(
                "gPhoto2: {} shows no long exposure noise reduction setting",
                self.core.name
            );
            return LongExposureNoiseReduction::Unreachable;
        };
        let name = widget.name.clone();
        let result = match noise_reduction_off(widget) {
            NoiseReductionOff::AlreadyOff => return LongExposureNoiseReduction::Off,
            NoiseReductionOff::Choose(choice) => self.set_config_value_str(sdk, &name, &choice),
            NoiseReductionOff::ClearToggle => self.set_config_value_toggle(sdk, &name, false),
            NoiseReductionOff::NoOffChoice => Err(DriverError::NotSupported),
        };
        let now_off = result.is_ok()
            && self
                .read_config_tree(sdk)
                .ok()
                .and_then(|tree| long_exposure_nr_widget(&tree).map(reads_off))
                .unwrap_or(false);
        if now_off {
            tracing::warn!(
                "gPhoto2: turned the camera's long exposure noise reduction ('{}') off. With it on, \
                 the camera shoots and subtracts its own dark after every frame.",
                name
            );
            LongExposureNoiseReduction::Off
        } else {
            tracing::warn!(
                "gPhoto2: the camera's long exposure noise reduction ('{}') is on and could not be turned off: {:?}",
                name,
                result.err()
            );
            LongExposureNoiseReduction::StaysOn
        }
    }

    /// Force the camera into its RAW image format before capture (best effort;
    /// a failure is warned, not fatal: the frame is checked for raw data when it
    /// is read). Runs under the SDK lock the caller already holds.
    pub(crate) fn apply_raw_format(&self, sdk: &GPhoto2Sdk) {
        if let Some((widget, choice)) = &self.raw_format {
            if let Err(e) = self.set_config_value_str(sdk, widget, choice) {
                tracing::warn!(
                    "gPhoto2: could not force {}='{}': {}. Capture will use the \
                     camera's current format.",
                    widget,
                    choice,
                    e
                );
            }
        }
    }

    /// Refresh the shutter speeds the body lists now. Runs under the SDK lock
    /// the caller already holds.
    pub(crate) fn refresh_shutter_speeds(&mut self, sdk: &GPhoto2Sdk) -> Result<(), DriverError> {
        let tree = self.read_config_tree(sdk)?;
        if let Some(speeds) = shutter_speeds(&tree) {
            self.shutter = speeds;
        }
        Ok(())
    }

    /// Start a timed exposure on the capture thread. Runs under the SDK lock
    /// the caller hands over.
    pub(crate) fn start_timed(
        &mut self,
        sdk: crate::vendor::sdk_loader::SdkGuard<GPhoto2Sdk>,
        speed: &super::exposure::ShutterSpeed,
    ) -> Result<(), DriverError> {
        self.set_config_value_str(&sdk, &self.shutter.widget, &speed.choice)
            .map_err(|e| {
                DriverError::SdkError(format!(
                    "gPhoto2: {} did not take shutter speed {} ({e}). Check that its mode dial is on M.",
                    self.core.name, speed.choice
                ))
            })?;
        let handles = self.handles();
        let capture = tokio::task::spawn_blocking(move || capture_image(&sdk, handles));
        self.exposure = ExposureState::Timed {
            start: Instant::now(),
            seconds: speed.seconds,
            capture,
        };
        Ok(())
    }

    /// Open the shutter for bulb with the body's bulb control. Runs under the
    /// SDK lock the caller already holds.
    pub(crate) fn open_bulb(
        &mut self,
        sdk: &GPhoto2Sdk,
        requested: f64,
    ) -> Result<(), DriverError> {
        let Some(control) = self.bulb_widget.clone() else {
            return Err(DriverError::NotSupported);
        };
        match self.shutter.bulb_choice.clone() {
            Some(choice) => self
                .set_config_value_str(sdk, &self.shutter.widget, &choice)
                .map_err(|e| {
                    DriverError::SdkError(format!(
                        "gPhoto2: {} did not switch its shutter to {choice}: {e}",
                        self.core.name
                    ))
                })?,
            // With timed speeds listed and no Bulb among them, the body is in a
            // mode without bulb, and a press would take a timed frame of the
            // current speed instead.
            None if !self.shutter.timed.is_empty() => {
                return Err(DriverError::SdkError(format!(
                    "gPhoto2: {} lists no Bulb shutter speed in its current mode, so it cannot \
                     expose {requested} s. Turn its mode dial to M (or B).",
                    self.core.name
                )))
            }
            None => {}
        }
        match &control {
            BulbWidget::EosRemoteRelease { press, .. } => {
                self.set_config_value_str(sdk, "eosremoterelease", press)
            }
            BulbWidget::BulbToggle => self.set_config_value_toggle(sdk, "bulb", true),
        }
        .map_err(|e| {
            DriverError::SdkError(format!(
                "gPhoto2: {} did not open its shutter for bulb ({control:?}): {e}",
                self.core.name
            ))
        })?;
        self.exposure = ExposureState::Bulb {
            opened: Instant::now(),
            requested,
        };
        tracing::info!("gPhoto2: bulb open for {:.1}s via {:?}", requested, control);
        Ok(())
    }

    /// Close a bulb exposure with the control that opened it, and answer how
    /// long the shutter was open. Runs under the SDK lock the caller holds.
    pub(crate) fn close_bulb(&self, sdk: &GPhoto2Sdk, opened: Instant) -> Result<f64, DriverError> {
        let result = match &self.bulb_widget {
            Some(BulbWidget::EosRemoteRelease { release, .. }) => {
                self.set_config_value_str(sdk, "eosremoterelease", release)
            }
            Some(BulbWidget::BulbToggle) => self.set_config_value_toggle(sdk, "bulb", false),
            None => Ok(()),
        };
        let open = opened.elapsed().as_secs_f64();
        result.map_err(|e| {
            DriverError::SdkError(format!(
                "gPhoto2: {} did not close its shutter after bulb: {e}",
                self.core.name
            ))
        })?;
        // The idle choice matters only to the next press, which writes the
        // widget again.
        if matches!(self.bulb_widget, Some(BulbWidget::EosRemoteRelease { .. })) {
            if let Err(e) = self.set_config_value_str(sdk, "eosremoterelease", "None") {
                tracing::warn!(
                    "gPhoto2: could not return eosremoterelease to 'None': {}",
                    e
                );
            }
        }
        tracing::info!("gPhoto2: bulb closed after {:.3}s", open);
        Ok(open)
    }

    /// The next event the body reports within `timeout_ms`. Runs under the SDK
    /// lock the caller holds.
    pub(crate) fn next_event(
        &self,
        sdk: &GPhoto2Sdk,
        timeout_ms: c_int,
    ) -> Result<CameraEvent, DriverError> {
        let mut kind: c_int = GP_EVENT_UNKNOWN;
        let mut data: *mut c_void = std::ptr::null_mut();
        // SAFETY: `gp_camera`/`gp_context` are valid post-connect; `kind` and
        // `data` are stack out-pointers. A FILE_ADDED event's data is a
        // `CameraFilePath`, copied out before the data is freed once.
        unsafe {
            let ret = (sdk.camera_wait_for_event)(
                self.gp_camera,
                timeout_ms,
                &mut kind,
                &mut data,
                self.gp_context,
            );
            let event = if ret < GP_OK {
                Err(gp_error(ret, "waiting for the camera"))
            } else {
                Ok(match kind {
                    GP_EVENT_FILE_ADDED if !data.is_null() => {
                        CameraEvent::FileAdded(Box::new((*(data as *const CameraFilePath)).clone()))
                    }
                    GP_EVENT_CAPTURE_COMPLETE => CameraEvent::CaptureComplete,
                    GP_EVENT_TIMEOUT => CameraEvent::Timeout,
                    _ => CameraEvent::Other,
                })
            };
            free_event_data(data);
            event
        }
    }

    /// The files the body reports written within `wait`, waiting `settle`
    /// after each for one more (a RAW+JPEG body writes two). Runs under the
    /// SDK lock the caller holds.
    pub(crate) fn collect_files(
        &self,
        sdk: &GPhoto2Sdk,
        wait: Duration,
        settle: Duration,
    ) -> Result<Vec<CameraFilePath>, DriverError> {
        let mut files = Vec::new();
        let mut deadline = Instant::now() + wait;
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            let timeout_ms = left.as_millis().clamp(1, 1000) as c_int;
            match self.next_event(sdk, timeout_ms)? {
                CameraEvent::FileAdded(path) => {
                    files.push(*path);
                    deadline = Instant::now() + settle;
                }
                CameraEvent::CaptureComplete if !files.is_empty() => break,
                _ => {}
            }
        }
        Ok(files)
    }

    /// The other files of a capture whose first file is no raw file: a
    /// RAW+JPEG body names the JPEG first on some models.
    pub(crate) fn rest_of_capture(
        &self,
        sdk: &GPhoto2Sdk,
        first: CameraFilePath,
    ) -> Result<Vec<CameraFilePath>, DriverError> {
        let first_is_raw = is_raw_name(&cstr_from_array(&first.name));
        let mut files = vec![first];
        if !first_is_raw {
            files.extend(self.collect_files(sdk, SECOND_FILE_WAIT, Duration::from_millis(500))?);
        }
        Ok(files)
    }

    /// The files a bulb exposure wrote after the shutter closed.
    pub(crate) fn bulb_files(&self, sdk: &GPhoto2Sdk) -> Result<Vec<CameraFilePath>, DriverError> {
        let files = self.collect_files(sdk, BULB_DOWNLOAD_TIMEOUT, Duration::from_millis(1500))?;
        if files.is_empty() {
            return Err(DriverError::Timeout(format!(
                "gPhoto2: {} wrote no file within {} s of the end of the bulb exposure",
                self.core.name,
                BULB_DOWNLOAD_TIMEOUT.as_secs()
            )));
        }
        Ok(files)
    }

    /// Delete stray files and events an earlier capture left (a late second
    /// file, a frame whose read failed), so the next exposure's files are its
    /// own (gphoto_driver.cpp:1101-1132). A file in the camera's memory is
    /// deleted; one on the card is left. Runs under the SDK lock the caller holds.
    pub(crate) fn discard_stray_events(&self, sdk: &GPhoto2Sdk) -> Result<(), DriverError> {
        for _ in 0..20 {
            match self.next_event(sdk, 10)? {
                CameraEvent::Timeout => break,
                CameraEvent::FileAdded(path) => self.discard_stray_file(sdk, &path),
                _ => {}
            }
        }
        Ok(())
    }

    fn discard_stray_file(&self, sdk: &GPhoto2Sdk, path: &CameraFilePath) {
        if self.facts.captures_to_ram() {
            self.delete_file(sdk, path);
        }
        tracing::warn!(
            "gPhoto2: discarded {}/{} from an earlier capture",
            cstr_from_array(&path.folder),
            cstr_from_array(&path.name)
        );
    }

    /// Ask an idle body whether it is still there, at most every few seconds:
    /// without it a camera unplugged between frames reads as connected until the
    /// next exposure. A stray event it answers is handled as before an exposure.
    pub(crate) fn probe(&self) -> Result<(), DriverError> {
        {
            let mut last = self.last_probe.lock().unwrap_or_else(|e| e.into_inner());
            if last.is_some_and(|t| t.elapsed() < PROBE_INTERVAL) {
                return Ok(());
            }
            *last = Some(Instant::now());
        }
        let Some(sdk) = GPhoto2Sdk::installed().ok().and_then(|sdk| sdk.try_lock()) else {
            return Ok(());
        };
        if let CameraEvent::FileAdded(path) = self.next_event(&sdk, 10)? {
            self.discard_stray_file(&sdk, &path);
        }
        Ok(())
    }

    /// Read one file of a capture. Runs under the SDK lock the caller holds.
    pub(crate) fn download_file(
        &self,
        sdk: &GPhoto2Sdk,
        path: &CameraFilePath,
    ) -> Result<Vec<u8>, DriverError> {
        let folder = cstr_from_array(&path.folder);
        let name = cstr_from_array(&path.name);
        let c_folder = CString::new(folder.as_str())
            .map_err(|_| DriverError::SdkError("gPhoto2: Invalid folder path".to_string()))?;
        let c_name = CString::new(name.as_str())
            .map_err(|_| DriverError::SdkError("gPhoto2: Invalid file name".to_string()))?;

        // SAFETY: `gp_camera`/`gp_context` are valid post-connect. `gp_file` is
        // freed on every path. The data pointer is read only after a successful
        // call and copied into a Vec before `file_free` releases it.
        unsafe {
            let mut gp_file: *mut CameraFile = std::ptr::null_mut();
            check_gp_error((sdk.file_new)(&mut gp_file), "file_new")?;
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
                return Err(gp_error(ret, &format!("reading {folder}/{name}")));
            }
            let mut data_ptr: *const c_char = std::ptr::null();
            let mut data_size: c_ulong = 0;
            let ret = (sdk.file_get_data_and_size)(gp_file, &mut data_ptr, &mut data_size);
            if ret < GP_OK || data_ptr.is_null() || data_size == 0 {
                (sdk.file_free)(gp_file);
                return Err(DriverError::SdkError(format!(
                    "gPhoto2: {folder}/{name} came back empty (code {ret})"
                )));
            }
            let bytes =
                std::slice::from_raw_parts(data_ptr as *const u8, data_size as usize).to_vec();
            (sdk.file_free)(gp_file);
            tracing::info!(
                "gPhoto2: Downloaded {} bytes from {}/{}",
                bytes.len(),
                folder,
                name
            );
            Ok(bytes)
        }
    }

    /// Delete one file from the camera. Runs under the SDK lock the caller holds.
    pub(crate) fn delete_file(&self, sdk: &GPhoto2Sdk, path: &CameraFilePath) {
        let folder = cstr_from_array(&path.folder);
        let name = cstr_from_array(&path.name);
        let (Ok(c_folder), Ok(c_name)) =
            (CString::new(folder.as_str()), CString::new(name.as_str()))
        else {
            return;
        };
        // SAFETY: `gp_camera`/`gp_context` are valid post-connect; the
        // CStrings outlive the call.
        let ret = unsafe {
            (sdk.camera_file_delete)(
                self.gp_camera,
                c_folder.as_ptr(),
                c_name.as_ptr(),
                self.gp_context,
            )
        };
        if ret < GP_OK {
            tracing::warn!(
                "gPhoto2: could not delete {}/{} from the camera (code {}); its memory may fill up",
                folder,
                name,
                ret
            );
        }
    }

    /// Delete every file of a capture that is given up.
    pub(crate) fn discard_files(&self, sdk: &GPhoto2Sdk, files: &[CameraFilePath]) {
        for file in files {
            self.delete_file(sdk, file);
        }
        if !files.is_empty() {
            tracing::info!(
                "gPhoto2: exposure ended early; discarded {} file(s)",
                files.len()
            );
        }
    }

    /// Adopt the RAW decoder's ground truth for this body's sample depth.
    ///
    /// `bits` is `skotiq_imaging::RawFrame::bits_per_pixel` (derived from
    /// LibRaw's saturation level) and `white_level` is
    /// `skotiq_imaging::RawFrame::white_level` — LibRaw `color.maximum`, the
    /// exact largest value a pixel in the delivered mosaic can take.
    ///
    /// Zero/out-of-range inputs are ignored rather than adopted: LibRaw leaves
    /// `color.maximum` at 0 for a handful of bodies, and a 0 white level would
    /// otherwise publish an unreachable `max_adu`.
    pub(crate) fn adopt_decoded_depth(&mut self, bits: u32, white_level: u32) {
        let info = &mut self.core.sensor_info;
        let previous_max_adu = info.max_adu;

        if (8..=16).contains(&bits) && bits != info.bit_depth {
            tracing::info!(
                "gPhoto2: adopting measured sensor bit depth {} (estimate was {})",
                bits,
                info.bit_depth
            );
            info.bit_depth = bits;
        }

        if white_level > 0 && self.measured_white_level != Some(white_level) {
            tracing::info!(
                "gPhoto2: adopting measured white level {} as max_adu (was {})",
                white_level,
                previous_max_adu
            );
            self.measured_white_level = Some(white_level);
        }
        info.max_adu = resolve_max_adu(self.measured_white_level, info.bit_depth);
    }

    /// Decode a raw camera file (CR2, NEF, ARW, etc.) into the single-channel
    /// LINEAR sensor mosaic that the capture pipeline expects, recording what
    /// the camera did: the exposure (see `recorded_exposure`) and the ISO its
    /// file names.
    pub(crate) fn decode_raw_to_image_data(
        &mut self,
        camera_file: skotiq_device::CameraFile,
        made: MadeExposure,
    ) -> Result<ImageData, DriverError> {
        let raw_bytes = camera_file.bytes.as_slice();
        // A body set to JPEG (or anything else that is no raw file) gets an
        // actionable message instead of LibRaw's opaque decode failure on
        // every frame.
        let Some(extension) = skotiq_imaging::camera_raw_extension(raw_bytes) else {
            let what = if raw_bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
                "it appears to be JPEG"
            } else {
                "Skotiq does not recognize its format"
            };
            return Err(DriverError::SdkError(format!(
                "gPhoto2: the camera returned a file that is not a raw image ({what}). \
                 Set the camera's image quality to RAW (or RAW+JPEG): astro capture \
                 needs the linear raw sensor data."
            )));
        };

        let frame = skotiq_imaging::read_raw_bytes(raw_bytes).map_err(|e| {
            DriverError::SdkError(format!("gPhoto2: Failed to decode RAW image: {}", e))
        })?;

        self.adopt_decoded_depth(frame.bits_per_pixel, frame.white_level);
        let bayer_pattern = crate::camera_core::mosaic_bayer_pattern(&frame.cfa);
        let info = &mut self.core.sensor_info;
        info.saturation_adu =
            (frame.saturation_level < frame.white_level).then_some(frame.saturation_level);
        info.width = frame.width;
        info.height = frame.height;
        info.bayer_pattern = Some(bayer_pattern);

        let exposure_time = recorded_exposure(&made, frame.metadata.exposure_seconds);
        if let MadeExposure::Timed(speed) = made {
            if ((exposure_time - speed) / speed).abs() > 0.05 {
                tracing::warn!(
                    "gPhoto2: {} exposed {} s where Skotiq set {} s: check that its mode dial is on M",
                    self.core.name,
                    exposure_time,
                    speed
                );
            }
        }
        let recorded_iso = frame
            .metadata
            .iso
            .filter(|iso| iso.is_finite() && *iso >= 1.0)
            .map(|iso| iso.round() as i32);
        let gain = match recorded_iso {
            Some(iso) => {
                if iso != self.core.gain {
                    tracing::warn!(
                        "gPhoto2: the frame was taken at ISO {} (Skotiq set ISO {}); it records ISO {}",
                        iso,
                        self.core.gain,
                        iso
                    );
                }
                iso
            }
            None => self.core.gain,
        };

        tracing::info!(
            "gPhoto2: Decoded RAW mosaic: {}x{}, {}-bit, filter {}, {} s at ISO {}, camera: {} {} ({})",
            frame.width,
            frame.height,
            frame.bits_per_pixel,
            frame.cfa.letters(),
            exposure_time,
            gain,
            frame.metadata.make,
            frame.metadata.model,
            extension,
        );

        let skotiq_imaging::RawFrame {
            width,
            height,
            data,
            bits_per_pixel,
            metadata,
            ..
        } = frame;

        Ok(Frame {
            exposure_time,
            gain,
            temperature: metadata.temperature.map(|t| t.celsius as f64),
            vendor_data: VendorFeatures {
                custom_data: {
                    let mut map = std::collections::HashMap::new();
                    map.insert(
                        "camera_model".to_string(),
                        serde_json::Value::String(self.core.name.clone()),
                    );
                    map
                },
                ..Default::default()
            },
            camera_file: Some(skotiq_device::CameraFile {
                // A body that names no file still gets the extension its
                // bytes are in.
                file_name: if camera_file.extension().is_some() {
                    camera_file.file_name.clone()
                } else {
                    format!("frame.{extension}")
                },
                bytes: camera_file.bytes.clone(),
            }),
            ..self
                .core
                .frame(width, height, data, bits_per_pixel, Some(bayer_pattern))
        }
        .into_image())
    }
}

fn widget_kind(code: c_int) -> CameraWidgetType {
    match code {
        0 => CameraWidgetType::Window,
        1 => CameraWidgetType::Section,
        2 => CameraWidgetType::Text,
        3 => CameraWidgetType::Range,
        4 => CameraWidgetType::Toggle,
        5 => CameraWidgetType::Radio,
        6 => CameraWidgetType::Menu,
        7 => CameraWidgetType::Button,
        _ => CameraWidgetType::Date,
    }
}

/// Copy a widget and its children out of a libgphoto2 configuration tree.
///
/// # Safety
/// `widget` is a live widget of a tree the caller frees afterwards, and the
/// caller holds the SDK lock.
unsafe fn snapshot_widget(sdk: &GPhoto2Sdk, widget: *mut CameraWidget) -> ConfigWidget {
    let text = |ptr: *const c_char| {
        if ptr.is_null() {
            String::new()
        } else {
            CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    };
    let mut name_ptr: *const c_char = std::ptr::null();
    let mut label_ptr: *const c_char = std::ptr::null();
    (sdk.widget_get_name)(widget, &mut name_ptr);
    (sdk.widget_get_label)(widget, &mut label_ptr);
    let mut code: c_int = -1;
    (sdk.widget_get_type)(widget, &mut code);
    let kind = widget_kind(code);

    let value = match kind {
        CameraWidgetType::Text | CameraWidgetType::Radio | CameraWidgetType::Menu => {
            let mut value_ptr: *const c_char = std::ptr::null();
            let ret =
                (sdk.widget_get_value)(widget, &mut value_ptr as *mut *const c_char as *mut c_void);
            (ret >= GP_OK && !value_ptr.is_null()).then(|| text(value_ptr))
        }
        CameraWidgetType::Toggle => {
            let mut on: c_int = 0;
            let ret = (sdk.widget_get_value)(widget, &mut on as *mut c_int as *mut c_void);
            (ret >= GP_OK).then(|| on.to_string())
        }
        _ => None,
    };

    let mut choices = Vec::new();
    if matches!(kind, CameraWidgetType::Radio | CameraWidgetType::Menu) {
        for i in 0..(sdk.widget_count_choices)(widget).max(0) {
            let mut choice_ptr: *const c_char = std::ptr::null();
            if (sdk.widget_get_choice)(widget, i, &mut choice_ptr) >= GP_OK && !choice_ptr.is_null()
            {
                choices.push(text(choice_ptr));
            }
        }
    }

    let mut children = Vec::new();
    for i in 0..(sdk.widget_count_children)(widget).max(0) {
        let mut child: *mut CameraWidget = std::ptr::null_mut();
        if (sdk.widget_get_child)(widget, i, &mut child) >= GP_OK && !child.is_null() {
            children.push(snapshot_widget(sdk, child));
        }
    }

    ConfigWidget {
        name: text(name_ptr),
        label: text(label_ptr),
        kind,
        value,
        choices,
        children,
    }
}
