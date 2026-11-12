//! `AtikCamera` state, connect and disconnect.

use super::*;

pub struct AtikCamera {
    pub(crate) device_index: i32,
    pub(crate) serial_number: Option<String>,
    pub(crate) handle: SdkHandle<ArtemisHandle>,
    pub(crate) core: CameraCore,
    pub(crate) facts: AtikFacts,
    /// The mosaic cell at pixel (0, 0) of the exposure in progress or last
    /// taken; it moves with an odd subframe origin.
    pub(crate) frame_bayer: Option<BayerPattern>,
}

/// What a connected camera is and how it is driven, learned at connect.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct AtikFacts {
    pub(crate) has_shutter: bool,
    pub(crate) has_cooling: bool,
    pub(crate) gain: GainControl,
    /// The SDK's mosaic offset of a colour sensor, `None` for mono.
    pub(crate) cfa_offset: Option<(i64, i64)>,
}

impl std::fmt::Debug for AtikCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AtikCamera")
            .field("device_id", &self.core.device_id)
            .field("name", &self.core.name)
            .field("device_index", &self.device_index)
            .field("serial_number", &self.serial_number)
            .finish()
    }
}

impl AtikCamera {
    pub fn new(device_index: i32) -> Self {
        let serial_number = discovered_camera_serials()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&device_index)
            .cloned();
        Self {
            device_index,
            serial_number,
            handle: SdkHandle(std::ptr::null_mut()),
            core: CameraCore::new(
                format!("atik_{}", device_index),
                format!("Atik Camera {}", device_index),
                -10.0,
            ),
            facts: AtikFacts::default(),
            frame_bayer: None,
        }
    }

    pub(crate) fn handle(&self) -> ArtemisHandle {
        self.handle.0
    }

    fn label(&self) -> String {
        match &self.serial_number {
            Some(serial) => format!("Atik camera {serial}"),
            None => format!("Atik camera at index {}", self.device_index),
        }
    }

    /// Opens the camera and learns what it is. The caller holds the SDK lock.
    pub(crate) fn open(&mut self, sdk: &AtikSdk) -> Result<(), DriverError> {
        if self.core.connected {
            return Ok(());
        }
        let (index, serial) =
            camera_index_now(sdk, self.device_index, self.serial_number.as_deref())?;
        // SAFETY: plain int argument; the result is null-checked below.
        let handle = unsafe { (sdk.connect)(index) };
        if handle.is_null() {
            return Err(DriverError::SdkError(format!(
                "{} could not be opened. Another program may be using it, or the Atik USB driver is not installed.",
                self.label()
            )));
        }
        self.device_index = index;
        self.serial_number = serial;
        match self.learn(sdk, handle) {
            Ok(()) => {
                self.handle = SdkHandle(handle);
                self.core.connected = true;
                self.core.state = CameraState::Idle;
                Ok(())
            }
            Err(error) => {
                // SAFETY: `handle` came from ArtemisConnect above and is released once.
                unsafe { (sdk.disconnect)(handle) };
                Err(error)
            }
        }
    }

    /// Reads the camera's properties and puts it into the state Skotiq
    /// exposes with.
    fn learn(&mut self, sdk: &AtikSdk, handle: ArtemisHandle) -> Result<(), DriverError> {
        // SAFETY: the handle was just returned by ArtemisConnect.
        if unsafe { (sdk.is_connected)(handle) } == 0 {
            return Err(DriverError::SdkError(format!(
                "{} did not stay connected after it was opened",
                self.label()
            )));
        }

        // SAFETY: ArtemisProperties is plain C data; all zeroes is a valid value.
        let mut props: ArtemisProperties = unsafe { std::mem::zeroed() };
        // SAFETY: `props` has the ARTEMISPROPERTIES layout the SDK fills.
        let result = unsafe { (sdk.properties)(handle, &mut props) };
        check_artemis_error(result, "read the camera properties")?;
        let width = u32::try_from(props.pixels_x).map_err(|_| {
            DriverError::SdkError(format!("Atik reported sensor width {}", props.pixels_x))
        })?;
        let height = u32::try_from(props.pixels_y).map_err(|_| {
            DriverError::SdkError(format!("Atik reported sensor height {}", props.pixels_y))
        })?;
        if let Some(model) = c_text(&props.description) {
            self.core.name = model;
        }

        let (mut max_bin_x, mut max_bin_y): (c_int, c_int) = (1, 1);
        // SAFETY: both out-pointers are valid.
        let result = unsafe { (sdk.get_max_bin)(handle, &mut max_bin_x, &mut max_bin_y) };
        if result != ArtemisError::Ok as c_int {
            tracing::warn!(
                "Atik camera '{}': ArtemisGetMaxBin answered {:?}; binning is offered as 1x1 only",
                self.core.name,
                ArtemisError::from_i32(result)
            );
            (max_bin_x, max_bin_y) = (1, 1);
        }

        let cooling = cooling_info(sdk, handle);
        let cooling_flags = cooling.map_or(0, |c| c.flags);
        let has_cooling = cooling_flags & ARTEMIS_COOLING_INFO_HASCOOLING != 0;
        let setpoint_control = cooling_flags & ARTEMIS_COOLING_INFO_SETPOINTCONTROL != 0;
        if has_cooling && !setpoint_control {
            tracing::info!(
                "Atik camera '{}' has a cooler that cannot be given a set-point; its temperature and power are shown, but it cannot be switched or set from Skotiq",
                self.core.name
            );
        }

        let mut colour_type: c_int = ARTEMIS_COLOUR_UNKNOWN;
        let (mut offset_x, mut offset_y, mut preview_x, mut preview_y): (
            c_int,
            c_int,
            c_int,
            c_int,
        ) = (0, 0, 0, 0);
        // SAFETY: all five out-pointers are valid.
        let colour_result = unsafe {
            (sdk.colour_properties)(
                handle,
                &mut colour_type,
                &mut offset_x,
                &mut offset_y,
                &mut preview_x,
                &mut preview_y,
            )
        };
        // This answer decides whether every frame of the session carries a
        // BAYERPAT card and is debayered; see `atik_colour_decision`.
        let colour = match atik_colour_decision(ArtemisError::from_i32(colour_result), colour_type)
        {
            AtikColourDecision::Publish(colour) => Some(colour),
            AtikColourDecision::ConnectAsMono(reason) => {
                tracing::warn!(
                    "Atik camera '{}': {}. Connecting as monochrome — frames will carry no BAYERPAT card and will not be debayered. If this is a colour camera, update the AtikCameras driver.",
                    self.core.name,
                    reason
                );
                None
            }
            AtikColourDecision::Refuse(reason) => {
                return Err(DriverError::SdkError(format!(
                    "Atik camera '{}': {reason}. Skotiq will not guess a colour filter array, \
                     because debayering against the wrong one corrupts every frame of the session. \
                     Update the AtikCameras driver or report this colour type.",
                    self.core.name
                )));
            }
        };
        let cfa_offset = colour
            .filter(|c| c.is_color())
            .map(|_| (i64::from(offset_x), i64::from(offset_y)));

        // A camera without an 8-bit mode answers the call with
        // ARTEMIS_INVALID_PARAMETER and is 16-bit only.
        if props.camera_flags & ARTEMIS_CAMERA_HAS_EIGHT_BIT_MODE != 0 {
            // SAFETY: plain arguments.
            let result = unsafe { (sdk.eight_bit_mode)(handle, false) };
            check_artemis_error(result, "select 16-bit images")?;
        }

        let options = Options::of(sdk, handle);
        let (bit_depth, max_adu) = match &options {
            // The 12-bit CMOS cameras put their samples in the low 12 bits, or
            // with pad data in the high 12 bits.
            Some(options) if options.has(ID_PAD_DATA) => {
                if options.read::<1>(ID_PAD_DATA)?[0] != 0 {
                    (12, 0xFFF0)
                } else {
                    (12, 0x0FFF)
                }
            }
            _ => (16, 0xFFFF),
        };
        if let Some(options) = options.as_ref().filter(|o| o.has(ID_EXPOSURE_SPEED)) {
            if options.read_u16(ID_EXPOSURE_SPEED)? == EXPOSURE_SPEED_FAST {
                options.write_u16(ID_EXPOSURE_SPEED, EXPOSURE_SPEED_POWER_SAVE)?;
                tracing::info!(
                    "Atik camera '{}' was in fast (streaming) exposure speed, which delivers no single frames; switched it to power save",
                    self.core.name
                );
            }
        }

        let gain_control = gain::detect(sdk, handle)?;
        let (gain, offset) = gain::effective(sdk, handle, gain_control)?;

        let has_shutter = props.camera_flags & ARTEMIS_CAMERA_HAS_SHUTTER != 0;
        self.core.capabilities = CameraCapabilities {
            can_cool: has_cooling && setpoint_control,
            can_set_gain: gain_control.is_settable(),
            can_set_offset: gain_control.is_settable(),
            can_set_binning: max_bin_x > 1 || max_bin_y > 1,
            can_subframe: true,
            has_shutter,
            has_guider_port: props.camera_flags & ARTEMIS_CAMERA_HAS_GUIDE_PORT != 0,
            max_bin_x,
            max_bin_y,
            supports_readout_modes: false,
        };
        self.core.sensor_info = SensorInfo {
            width,
            height,
            pixel_size_x: f64::from(props.pixel_microns_x),
            pixel_size_y: f64::from(props.pixel_microns_y),
            max_adu,
            bit_depth,
            color: cfa_offset.is_some(),
            bayer_pattern: cfa_offset.map(|(x, y)| rggb_cell_at(x, y)),
        };
        self.facts = AtikFacts {
            has_shutter,
            has_cooling,
            gain: gain_control,
            cfa_offset,
        };
        self.frame_bayer = self.core.sensor_info.bayer_pattern;
        self.core.gain = gain;
        self.core.offset = offset;
        self.core.bin_x = 1;
        self.core.bin_y = 1;
        self.core.subframe = None;
        if let Some(cooling) = cooling {
            self.core.update_cooler(|cooler| {
                cooler.enabled = cooling.is_cooling();
                if cooling.is_cooling() {
                    cooler.target_c = cooling.setpoint_c();
                }
            });
        }

        tracing::info!(
            "Connected to Atik camera {} ({}x{}, firmware {}.{}, camera flags {:#x}, cooling flags {:#x}, gain control {:?}, colour offset {:?})",
            self.core.name,
            width,
            height,
            props.protocol >> 8,
            props.protocol & 0xff,
            props.camera_flags,
            cooling_flags,
            gain_control,
            cfa_offset
        );
        Ok(())
    }

    /// Stops any exposure, starts the cooler's warm-up and releases the
    /// camera. The caller holds the SDK lock.
    pub(crate) fn close(&mut self, sdk: &AtikSdk) -> Result<(), DriverError> {
        if !self.core.connected {
            return Ok(());
        }
        let handle = self.handle();
        // SAFETY: the handle is open; nothing to abort is not an error here.
        let _ = unsafe { (sdk.abort_exposure)(handle) };

        // Letting a cooled sensor warm up by itself can damage it (SDK guide
        // 5.6), so the warm-up is started whenever the camera reports cooling.
        let cooling_now = cooling_info(sdk, handle).is_some_and(|c| c.is_cooling());
        if cooling_now || self.core.cooler().enabled {
            // SAFETY: the handle is open.
            let result = unsafe { (sdk.cooler_warm_up)(handle) };
            if result != ArtemisError::Ok as c_int {
                tracing::error!(
                    "Atik ArtemisCoolerWarmUp failed for camera '{}' ({:?}); the sensor is being disconnected while still cooled",
                    self.core.name,
                    ArtemisError::from_i32(result)
                );
            }
        }

        // SAFETY: the handle came from ArtemisConnect and is released once.
        if unsafe { (sdk.disconnect)(handle) } == 0 {
            return Err(DriverError::SdkError(format!(
                "the Atik SDK did not release camera '{}'; unplug it or restart Skotiq before connecting again",
                self.core.name
            )));
        }
        self.handle = SdkHandle(std::ptr::null_mut());
        self.core.connected = false;
        self.core.state = CameraState::Idle;
        tracing::info!("Disconnected from Atik camera: {}", self.core.name);
        Ok(())
    }
}

/// ArtemisCoolingInfo's answer.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CoolingInfo {
    pub(crate) flags: c_int,
    pub(crate) level: c_int,
    pub(crate) min_level: c_int,
    pub(crate) max_level: c_int,
    pub(crate) setpoint: c_int,
}

impl CoolingInfo {
    /// Cooling on and not warming up (INDI reads the flags the same way).
    pub(crate) fn is_cooling(self) -> bool {
        self.flags & ARTEMIS_COOLING_INFO_COOLINGON != 0
            && self.flags & ARTEMIS_COOLING_INFO_WARMINGUP == 0
    }

    pub(crate) fn power_percent(self) -> Option<f64> {
        (self.max_level > self.min_level).then(|| {
            f64::from(self.level - self.min_level) / f64::from(self.max_level - self.min_level)
                * 100.0
        })
    }

    /// The set-point is reported in hundredths of a degree, as it is set
    /// (NINA reads it the same way; the SDK guide says whole degrees).
    pub(crate) fn setpoint_c(self) -> f64 {
        f64::from(self.setpoint) / 100.0
    }
}

pub(crate) fn cooling_info(sdk: &AtikSdk, handle: ArtemisHandle) -> Option<CoolingInfo> {
    let (mut flags, mut level, mut min_level, mut max_level, mut setpoint) = (0, 0, 0, 0, 0);
    // SAFETY: all five out-pointers are valid; the caller holds the lock and
    // the handle is open.
    let result = unsafe {
        (sdk.cooling_info)(
            handle,
            &mut flags,
            &mut level,
            &mut min_level,
            &mut max_level,
            &mut setpoint,
        )
    };
    (result == ArtemisError::Ok as c_int).then_some(CoolingInfo {
        flags,
        level,
        min_level,
        max_level,
        setpoint,
    })
}

#[async_trait]
impl DeviceDriver for AtikCamera {
    fn id(&self) -> &str {
        &self.core.device_id
    }

    fn name(&self) -> &str {
        &self.core.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Atik
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
        let sdk = AtikSdk::lock().await?;
        self.open(&sdk)
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.core.connected {
            return Ok(());
        }
        let sdk = AtikSdk::lock().await?;
        self.close(&sdk)
    }
}
