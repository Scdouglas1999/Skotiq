//! `AtikCamera` state, inherent helpers and `NativeDevice`.

use super::*;

/// Atik camera native driver
pub struct AtikCamera {
    pub(crate) device_index: i32,
    pub(crate) serial_number: Option<String>,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: Mutex<HandleWrapper>,
    pub(crate) connected: bool,
    pub(crate) capabilities: CameraCapabilities,
    pub(crate) sensor_info: SensorInfo,
    pub(crate) state: CameraState,
    // Current settings
    pub(crate) current_gain: i32,
    pub(crate) current_offset: i32,
    pub(crate) current_bin_x: i32,
    pub(crate) current_bin_y: i32,
    pub(crate) subframe: Option<SubFrame>,
    pub(crate) cooler_on: bool,
    pub(crate) target_temp: f64,
    // Exposure tracking
    pub(crate) exposure_duration: f64,
}

impl std::fmt::Debug for AtikCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AtikCamera")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .field("device_index", &self.device_index)
            .field("serial_number", &self.serial_number)
            .finish()
    }
}

impl AtikCamera {
    /// Create a new Atik camera instance
    pub fn new(device_index: i32) -> Self {
        let serial_number = discovered_camera_serials()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&device_index)
            .cloned();
        Self {
            device_index,
            serial_number,
            device_id: format!("atik_{}", device_index),
            name: format!("Atik Camera {}", device_index),
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
            target_temp: -10.0,
            exposure_duration: 0.0,
        }
    }
}

#[async_trait]
impl NativeDevice for AtikCamera {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Atik
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
        let _lock = atik_mutex().lock().await;

        let serial_number = self.serial_number.as_deref().ok_or_else(|| {
            NativeError::DeviceNotFound(format!(
                "No discovery serial recorded for Atik camera index {}",
                self.device_index
            ))
        })?;
        let device_index = camera_index_for_serial(sdk, serial_number)?;

        // Connect to camera
        // SAFETY: atik_mutex held above ensuring exclusive Atik SDK access; device_index was
        // resolved from the discovery-time serial against the current SDK enumeration.
        // ArtemisConnect returns a handle that we null-check immediately below.
        let handle = unsafe { (sdk.connect)(device_index) };
        if handle.is_null() {
            tracing::error!(
                "Atik ArtemisConnect() returned NULL for camera serial {} at current index {}. Check USB connection.",
                serial_number,
                device_index
            );
            return Err(NativeError::SdkError(format!(
                "Failed to connect to Atik camera serial {}. SDK returned NULL handle. Ensure camera is connected and not in use.",
                serial_number
            )));
        }

        // Check connection
        // SAFETY: atik_mutex held; `handle` is the non-null pointer returned by ArtemisConnect
        // above (null check passed); ArtemisIsConnected only reads the handle's internal flag.
        if unsafe { (sdk.is_connected)(handle) } == 0 {
            tracing::error!(
                "Atik camera serial {} - ArtemisIsConnected() returned false after successful connect.",
                serial_number
            );
            // SAFETY: atik_mutex held; handle was successfully opened above.
            unsafe { (sdk.disconnect)(handle) };
            return Err(NativeError::SdkError(format!(
                "Atik camera connection verification failed for serial {}. Device may have disconnected.",
                serial_number
            )));
        }

        // Get camera properties
        // SAFETY: ArtemisProperties is `#[repr(C)]` POD (only c_int / c_float / fixed-size char
        // arrays); a zero-filled instance is a valid initial state that the SDK will overwrite.
        let mut props: ArtemisProperties = unsafe { std::mem::zeroed() };
        // SAFETY: atik_mutex held; `handle` was successfully opened and IsConnected verified;
        // &mut props is a valid stack pointer to a #[repr(C)] struct of the size the SDK
        // expects (matches AtikCameras.h ARTEMISPROPERTIES).
        let result = unsafe { (sdk.properties)(handle, &mut props) };
        if ArtemisError::from_i32(result) != ArtemisError::Ok {
            // SAFETY: atik_mutex held; `handle` was successfully opened above. ArtemisDisconnect
            // pairs with ArtemisConnect to release the handle on the error path.
            unsafe { (sdk.disconnect)(handle) };
            return Err(ArtemisError::from_i32(result).to_native_error("get properties"));
        }

        // Get max binning
        let mut max_bin_x: c_int = 1;
        let mut max_bin_y: c_int = 1;
        // SAFETY: atik_mutex held; handle is valid (IsConnected verified); both out-pointers
        // are valid stack pointers to c_int.
        let max_bin_result = unsafe { (sdk.get_max_bin)(handle, &mut max_bin_x, &mut max_bin_y) };
        if ArtemisError::from_i32(max_bin_result) != ArtemisError::Ok {
            // The locals keep their 1x1 seed, which publishes can_set_binning = false
            // for the whole session. That is the safe direction, but it is a capability
            // the camera may actually have — say why it went missing.
            tracing::warn!(
                "Atik ArtemisGetMaxBin failed ({:?}); binning is reported as unsupported (1x1) for this session",
                ArtemisError::from_i32(max_bin_result)
            );
        }

        // Check for cooling support
        let mut cooling_flags: c_int = 0;
        let mut _level: c_int = 0;
        let mut _minlvl: c_int = 0;
        let mut _maxlvl: c_int = 0;
        let mut _setpoint: c_int = 0;
        // SAFETY: atik_mutex held; handle is valid (IsConnected verified); all five out-
        // pointers are valid stack pointers to c_int.
        let can_cool = unsafe {
            (sdk.cooling_info)(
                handle,
                &mut cooling_flags,
                &mut _level,
                &mut _minlvl,
                &mut _maxlvl,
                &mut _setpoint,
            ) == 0
                && (cooling_flags & 1) != 0 // ARTEMIS_COOLING_INFO_HASCOOLING
        };

        // Set capabilities
        self.capabilities = CameraCapabilities {
            can_cool,
            can_set_gain: true,
            can_set_offset: true,
            can_set_binning: max_bin_x > 1 || max_bin_y > 1,
            can_subframe: true,
            has_shutter: (props.camera_flags & ARTEMIS_CAMERA_HAS_SHUTTER) != 0,
            has_guider_port: (props.camera_flags & ARTEMIS_CAMERA_HAS_GUIDE_PORT) != 0,
            max_bin_x,
            max_bin_y,
            supports_readout_modes: false,
        };

        // Get colour properties for Bayer pattern
        let mut colour_type: c_int = 0;
        let mut _normal_offset_x: c_int = 0;
        let mut _normal_offset_y: c_int = 0;
        let mut _preview_offset_x: c_int = 0;
        let mut _preview_offset_y: c_int = 0;
        // SAFETY: atik_mutex held; handle is valid (IsConnected verified); all five out-
        // pointers are valid stack pointers to c_int.
        let colour_result = unsafe {
            (sdk.colour_properties)(
                handle,
                &mut colour_type,
                &mut _normal_offset_x,
                &mut _normal_offset_y,
                &mut _preview_offset_x,
                &mut _preview_offset_y,
            )
        };
        // This answer sets `SensorInfo.color` / `bayer_pattern` for the whole session,
        // which decides whether every frame carries a BAYERPAT card and is ever
        // debayered. A one-shot-colour sensor published as mono yields a night of
        // undebayered mosaics under a header that says the camera is monochrome — and
        // that used to happen silently, because a failed call left `colour_type` at its
        // 0 seed and ARTEMISCOLOURTYPE 0 is ARTEMIS_COLOUR_UNKNOWN ("the colour cannot
        // be determined", AtikDefs.h:56), NOT monochrome, which is 1.
        //
        // The three outcomes are separated in `atik_colour_decision`: a named CFA is
        // published, a body whose driver has no colour property connects as mono with a
        // warning, and a colour type this build cannot map is refused.
        let colour = match atik_colour_decision(ArtemisError::from_i32(colour_result), colour_type)
        {
            AtikColourDecision::Publish(colour) => Some(colour),
            AtikColourDecision::ConnectAsMono(reason) => {
                tracing::warn!(
                    "Atik camera '{}': {}. Connecting as monochrome — frames will carry no BAYERPAT card and will not be debayered. If this is a colour camera, update the AtikCameras driver.",
                    self.device_id,
                    reason
                );
                None
            }
            AtikColourDecision::Refuse(reason) => {
                tracing::error!(
                    "Atik camera '{}': {}; refusing to connect rather than guess the colour filter array",
                    self.device_id,
                    reason
                );
                // SAFETY: atik_mutex held; `handle` was successfully opened above.
                // ArtemisDisconnect pairs with ArtemisConnect to release it.
                unsafe { (sdk.disconnect)(handle) };
                return Err(NativeError::SdkError(format!(
                    "Atik camera '{}': {reason}. Skotiq will not guess a colour filter array, \
                     because debayering against the wrong one corrupts every frame of the session. \
                     Update the AtikCameras driver or report this colour type.",
                    self.device_id
                )));
            }
        };

        let is_color = colour.is_some_and(|c| c.is_color());
        let bayer_pattern = colour.and_then(|c| c.bayer_pattern());

        // Set sensor info
        // Why: `props.pixels_x` / `props.pixels_y` are `c_int` (i32) populated by ArtemisProperties.
        // A negative value would be a malformed SDK response, not a real sensor; we surface
        // it as an SdkError rather than silently re-interpreting the bit pattern via `as u32`.
        let sensor_dimensions: Result<(u32, u32), NativeError> = (|| {
            let width = u32::try_from(props.pixels_x).map_err(|_| {
                NativeError::SdkError(format!(
                    "Atik reported invalid sensor width: pixels_x={}",
                    props.pixels_x
                ))
            })?;
            let height = u32::try_from(props.pixels_y).map_err(|_| {
                NativeError::SdkError(format!(
                    "Atik reported invalid sensor height: pixels_y={}",
                    props.pixels_y
                ))
            })?;
            Ok((width, height))
        })();
        let (pixels_x_u32, pixels_y_u32) = match sensor_dimensions {
            Ok(dimensions) => dimensions,
            Err(error) => {
                // SAFETY: atik_mutex held; handle was successfully opened above.
                unsafe { (sdk.disconnect)(handle) };
                return Err(error);
            }
        };
        self.sensor_info = SensorInfo {
            width: pixels_x_u32,
            height: pixels_y_u32,
            // Why: pixel_microns_{x,y} are c_float; widening f32 -> f64 is lossless.
            pixel_size_x: props.pixel_microns_x as f64,
            pixel_size_y: props.pixel_microns_y as f64,
            max_adu: 65535,
            bit_depth: 16,
            color: is_color,
            bayer_pattern,
        };

        // Get camera name from description
        // SAFETY: `props.description` is a 40-byte fixed array of c_char inside the SDK-filled
        // ARTEMISPROPERTIES struct; ArtemisProperties guarantees NUL-termination within the
        // array (vendor header documents description as a NUL-terminated C string).
        let name = unsafe { CStr::from_ptr(props.description.as_ptr()) }
            .to_string_lossy()
            .trim()
            .to_string();
        if !name.is_empty() {
            self.name = name;
        }

        // Set 16-bit mode. This is not optional: `sensor_info` above publishes
        // bit_depth = 16 / max_adu = 65535, and download_image reads the SDK buffer as
        // exactly `width * height * 2` little-endian bytes. A camera left in 8-bit mode
        // holds half that many bytes, so a swallowed failure here would read past the
        // SDK buffer and hand the pipeline garbage pixels under a 16-bit header.
        // SAFETY: atik_mutex held; handle is valid (IsConnected verified); ArtemisEightBitMode
        // takes a pass-by-value c_int (0 = 16-bit per AtikCameras.h).
        let bit_mode_result = unsafe { (sdk.eight_bit_mode)(handle, 0) };
        match ArtemisError::from_i32(bit_mode_result) {
            ArtemisError::Ok => {}
            // A camera that does not implement the call has no 8-bit mode to leave —
            // it is 16-bit only, which is the mode we are asking for.
            ArtemisError::NotImplemented => {
                tracing::debug!(
                    "Atik camera '{}' does not implement ArtemisEightBitMode; it is 16-bit only",
                    self.name
                );
            }
            other => {
                tracing::error!(
                    "Atik ArtemisEightBitMode(16-bit) failed for camera '{}' ({:?}); refusing to connect rather than decode a possibly 8-bit buffer as 16-bit",
                    self.name,
                    other
                );
                // SAFETY: atik_mutex held; `handle` was successfully opened above. ArtemisDisconnect
                // pairs with ArtemisConnect to release the handle on the error path.
                unsafe { (sdk.disconnect)(handle) };
                return Err(other.to_native_error("select 16-bit output mode"));
            }
        }

        // Get initial gain/offset
        let mut gain: c_int = 0;
        let mut offset: c_int = 0;
        // SAFETY: atik_mutex held; handle is valid; preview=0 is a valid mode constant; both
        // out-pointers are valid stack pointers to c_int.
        if unsafe { (sdk.get_gain)(handle, 0, &mut gain, &mut offset) } == 0 {
            self.current_gain = gain;
            self.current_offset = offset;
        }

        {
            let mut stored_handle = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            *stored_handle = HandleWrapper(handle);
        }
        self.device_index = device_index;
        self.connected = true;
        self.state = CameraState::Idle;

        tracing::info!(
            "Connected to Atik camera: {} ({}x{})",
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
        let _lock = atik_mutex().lock().await;

        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;

        // Abort any exposure
        // SAFETY: atik_mutex held; `handle` is valid because `self.connected` was true (only set
        // after successful connect() above) and disconnect hasn't run yet.
        let _ = unsafe { (sdk.abort_exposure)(handle) };

        // Warm up cooler gracefully. If the camera refuses the warm-up it stays at its
        // cold setpoint until power is removed — a thermal-shock risk the operator can
        // only act on if we say it happened.
        if self.cooler_on {
            // SAFETY: atik_mutex held; handle is valid (connected=true); ArtemisCoolerWarmUp
            // takes only the handle, no out-pointers.
            let warm_up_result = unsafe { (sdk.cooler_warm_up)(handle) };
            if ArtemisError::from_i32(warm_up_result) != ArtemisError::Ok {
                tracing::error!(
                    "Atik ArtemisCoolerWarmUp failed for camera '{}' ({:?}); the sensor is being disconnected while still cooled",
                    self.name,
                    ArtemisError::from_i32(warm_up_result)
                );
            }
        }

        // Disconnect
        // SAFETY: atik_mutex held; handle was successfully opened during connect(). ArtemisDisconnect
        // pairs with ArtemisConnect to release the SDK-owned handle.
        let result = unsafe { (sdk.disconnect)(handle) };
        if result == 0 {
            tracing::error!(
                "Atik ArtemisDisconnect() failed for camera '{}'. Device may be in an inconsistent state.",
                self.name
            );
            return Err(NativeError::SdkError(format!(
                "Failed to disconnect from Atik camera '{}'. Device may need reconnection.",
                self.name
            )));
        }

        {
            let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            *h = HandleWrapper(std::ptr::null_mut());
        }
        self.connected = false;
        self.state = CameraState::Idle;

        tracing::info!("Disconnected from Atik camera: {}", self.name);

        Ok(())
    }
}
