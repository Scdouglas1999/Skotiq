use super::*;

// Mount capabilities

/// Capabilities of a mount/telescope device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MountCapabilities {
    /// Whether the mount can perform slew operations
    pub can_slew: bool,
    /// Whether the mount supports async (non-blocking) slews
    pub can_slew_async: bool,
    /// Whether the mount can sync its position to coordinates
    pub can_sync: bool,
    /// Whether the mount can be parked
    pub can_park: bool,
    /// Whether the mount can be unparked
    pub can_unpark: bool,
    /// Whether the mount can set its park position
    pub can_set_park: bool,
    /// Whether the mount supports pulse guiding
    pub can_pulse_guide: bool,
    /// Whether the mount can report side of pier
    pub can_get_side_of_pier: bool,
    /// Whether the mount can set side of pier (for meridian flips)
    pub can_set_side_of_pier: bool,
    /// Whether tracking can be enabled/disabled
    pub can_set_tracking: bool,
    /// Whether the tracking rate can be changed
    pub can_set_tracking_rate: bool,
    /// Supported tracking rates
    pub supported_tracking_rates: Vec<TrackingRate>,
    /// Whether the mount is an equatorial type (has RA/Dec)
    pub is_equatorial: bool,
    /// Whether the mount supports altitude/azimuth coordinates
    pub supports_alt_az: bool,
    /// Whether the mount can report its pointing state (normal/beyond pole)
    pub can_get_pointing_state: bool,
    /// Whether the mount has a home position
    pub can_find_home: bool,
    /// Whether the mount is currently tracking
    pub tracking: Option<bool>,
    /// Current tracking rate if known
    pub tracking_rate: Option<TrackingRate>,
    /// Whether the mount can abort slews
    pub can_abort_slew: bool,
    /// Maximum slew rate in degrees/second, if known
    pub max_slew_rate: Option<f64>,
    /// Whether the mount supports move axis commands
    pub can_move_axis: bool,
    /// Number of axes the mount supports (typically 2 for RA/Dec or Az/Alt)
    pub axis_count: u32,
    /// Minimum supported pulse-guide duration in milliseconds, if the driver
    /// publishes a guide-rate range. `None` means the driver does not report a
    /// lower bound (ASCOM/Alpaca have no such property; only INDI's
    /// `TELESCOPE_TIMED_GUIDE_*` number limits expose it).
    pub min_pulse_guide_ms: Option<f64>,
    /// Maximum supported pulse-guide duration in milliseconds, if the driver
    /// publishes a guide-rate range. `None` means the driver does not report an
    /// upper bound.
    pub max_pulse_guide_ms: Option<f64>,
}

// TrackingRate is imported from crate::device

// Camera capabilities

/// Capabilities of a camera device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CameraCapabilities {
    /// Maximum horizontal resolution in pixels
    pub max_width: u32,
    /// Maximum vertical resolution in pixels
    pub max_height: u32,
    /// Number of bits per pixel (e.g., 16 for 16-bit camera)
    pub bit_depth: u32,
    /// Whether the camera has a mechanical shutter
    pub has_shutter: bool,
    /// Whether the camera supports cooling
    pub can_set_ccd_temperature: bool,
    /// Whether the cooler can be turned on/off
    pub can_set_cooler: bool,
    /// Whether the camera reports cooler power
    pub can_get_cooler_power: bool,
    /// Whether binning is supported
    pub can_bin: bool,
    /// Maximum horizontal binning factor
    pub max_bin_x: i32,
    /// Maximum vertical binning factor
    pub max_bin_y: i32,
    /// Whether asymmetric binning is supported (bin_x != bin_y)
    pub can_asymmetric_bin: bool,
    /// Whether the camera supports gain adjustment
    pub can_set_gain: bool,
    /// Minimum gain value
    pub gain_min: Option<i32>,
    /// Maximum gain value
    pub gain_max: Option<i32>,
    /// Whether the camera supports offset adjustment
    pub can_set_offset: bool,
    /// Minimum offset value
    pub offset_min: Option<i32>,
    /// Maximum offset value
    pub offset_max: Option<i32>,
    /// Whether the camera can abort exposures
    pub can_abort_exposure: bool,
    /// Whether the camera can stop exposures (graceful stop)
    pub can_stop_exposure: bool,
    /// Whether the camera supports subframe readout
    pub can_subframe: bool,
    /// Pixel size in microns (X)
    pub pixel_size_x: Option<f64>,
    /// Pixel size in microns (Y)
    pub pixel_size_y: Option<f64>,
    /// Whether the camera has a color sensor
    pub is_color: bool,
    /// Bayer pattern if color (e.g., "RGGB")
    pub bayer_pattern: Option<String>,
    /// Sensor type description
    pub sensor_type: Option<String>,
    /// Whether the camera supports fast readout mode
    pub has_fast_readout: bool,
    /// Available readout modes
    pub readout_modes: Vec<String>,
    /// Minimum exposure time in seconds
    pub exposure_min: Option<f64>,
    /// Maximum exposure time in seconds
    pub exposure_max: Option<f64>,
    /// Current sensor temperature if available
    pub ccd_temperature: Option<f64>,
    /// Current cooler setpoint if available
    pub set_ccd_temperature: Option<f64>,
    /// Current cooler power percentage if available
    pub cooler_power: Option<f64>,
    /// Whether cooler is currently on
    pub cooler_on: Option<bool>,
    /// Minimum achievable cooler setpoint in Celsius, if the driver publishes
    /// the regulated-cooling range. `None` means the achievable range is
    /// unknown (ASCOM/Alpaca ICameraV3 has no SetCCDTemperature min/max; only
    /// INDI's `CCD_TEMPERATURE` number limits and some native vendor SDKs
    /// expose it).
    pub cooler_min_temp_c: Option<f64>,
    /// Maximum achievable cooler setpoint in Celsius, if the driver publishes
    /// the regulated-cooling range. `None` means the achievable range is
    /// unknown.
    pub cooler_max_temp_c: Option<f64>,
}

/// Manufacturer-recommended camera gain/offset values reported by the vendor SDK.
///
/// Populated on a best-effort basis on camera connect. Vendors expose these
/// inconsistently — the field is `None` whenever the SDK does NOT report a
/// value. Callers MUST treat `None` as "the SDK didn't tell us"; never
/// fabricate a recommendation.
///
/// Sources used by the bridge:
/// - ZWO: `ASIControlCaps.default_value` for `ASI_GAIN` and `ASI_OFFSET`,
///   combined with `ASICameraInfo.elec_per_adu` for the notes string.
/// - QHY: `DefaultGain` (control ID 53) and `DefaultOffset` (control ID 54),
///   probed via `IsQHYCCDControlAvailable` first.
/// - SVBony: `SvbControlCaps.default_value` for the Gain and BlackLevel controls.
/// - All other vendors (Touptek, Player One, Atik, FLI, Moravian, ASCOM,
///   Alpaca, INDI, gphoto2/Fujifilm): currently no SDK API for unity gain —
///   honest `None`. The `notes` field will be empty.
///
/// `hcg_gain` (HCG transition point) is currently always `None` — no vendor
/// SDK exposes this programmatically (it's documented in the manual).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CameraRecommendedSettings {
    /// Manufacturer-recommended unity gain (1 e-/ADU), if the SDK exposes it.
    pub unity_gain: Option<i32>,
    /// Gain at which HCG (high conversion gain) engages, if the SDK exposes it.
    pub hcg_gain: Option<i32>,
    /// Manufacturer-recommended default offset/bias, if the SDK exposes it.
    pub default_offset: Option<i32>,
    /// Manufacturer-recommended cooling setpoint in Celsius, if the SDK exposes
    /// it. Currently always `None` — no vendor SDK we bind publishes a
    /// recommended setpoint (see the native struct's doc comment). The field
    /// gives the profile layer an honest, typed slot for the value the instant
    /// a vendor SDK starts reporting it.
    pub recommended_cooling_setpoint_c: Option<f64>,
    /// Human-readable explanation of where the values above came from.
    /// Empty when nothing was queryable.
    pub notes: String,
}

impl From<skotiq_native::camera::CameraRecommendedSettings> for CameraRecommendedSettings {
    fn from(src: skotiq_native::camera::CameraRecommendedSettings) -> Self {
        Self {
            unity_gain: src.unity_gain,
            hcg_gain: src.hcg_gain,
            default_offset: src.default_offset,
            recommended_cooling_setpoint_c: src.recommended_cooling_setpoint_c,
            notes: src.notes,
        }
    }
}

// Focuser capabilities

/// Capabilities of a focuser device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FocuserCapabilities {
    /// Maximum position in steps
    pub max_position: i32,
    /// Maximum step increment per move
    pub max_increment: i32,
    /// Step size in microns (if known)
    pub step_size: Option<f64>,
    /// Whether the focuser can move in absolute positions
    pub absolute: bool,
    /// Whether the focuser supports temperature compensation
    pub temp_comp_available: bool,
    /// Whether temperature compensation is currently enabled
    pub temp_comp: bool,
    /// Current temperature at focuser (if sensor available)
    pub temperature: Option<f64>,
    /// Whether the focuser is currently moving
    pub is_moving: bool,
    /// Current position in steps
    pub position: Option<i32>,
    /// Whether the focuser can halt movement
    pub can_halt: bool,
    /// Whether the focuser can reverse direction
    pub can_reverse: bool,
    /// Current reverse setting
    pub reverse: Option<bool>,
}

/// Every ASCOM focuser property needed to build a [`FocuserCapabilities`].
///
/// Mirrors `skotiq_ascom`'s `FocuserCapabilities` + `FocuserFullStatus`
/// without naming those Windows-only types, so
/// [`focuser_capabilities_from_ascom`] stays compilable and unit-testable on
/// Linux. `None` on any field means the driver's property threw (typically
/// `PropertyNotImplementedException`).
#[derive(Debug, Clone, Default)]
pub struct AscomFocuserReadings {
    pub max_step: Option<i32>,
    pub max_increment: Option<i32>,
    pub step_size: Option<f64>,
    pub absolute: Option<bool>,
    pub temp_comp_available: Option<bool>,
    pub temp_comp: Option<bool>,
    pub temperature: Option<f64>,
    pub position: Option<i32>,
    pub is_moving: Option<bool>,
}

/// Build the wire-facing focuser capabilities from raw ASCOM property reads.
///
/// Every field is mapped from a driver read; none may fall back to
/// `Default::default()`. Defaulted fields make
/// `/api/equipment/focuser/capabilities` report `isMoving: false`,
/// `position: null`, `temperature: null` and `canHalt: false` whatever the
/// driver says — a focuser that is demonstrably travelling reported as idle,
/// and a `canHalt: false` contradicted by a halt that works.
///
/// Separate from the Windows-only capability probe so the mapping has a
/// regression test on every platform.
pub fn focuser_capabilities_from_ascom(r: AscomFocuserReadings) -> FocuserCapabilities {
    FocuserCapabilities {
        // Why: ASCOM IFocuserV3.MaxStep — when the read returns None the
        // property threw PropertyNotImplementedException. 0 means "no travel
        // range advertised", which disables absolute-position UI.
        max_position: r.max_step.unwrap_or(0),
        max_increment: r.max_increment.unwrap_or(0), // IFocuserV3.MaxIncrement — same contract as MaxStep
        step_size: r.step_size,
        absolute: r.absolute.unwrap_or(false), // IFocuserV3.Absolute — assume relative if omitted (safer UX)
        temp_comp_available: r.temp_comp_available.unwrap_or(false), // IFocuserV3.TempCompAvailable (optional)
        temp_comp: r.temp_comp.unwrap_or(false),
        temperature: r.temperature,
        position: r.position,
        is_moving: r.is_moving.unwrap_or(false),
        // Why true: Halt() is a member of the IFocuserV2/V3 interface that every
        // ASCOM focuser implements, and ASCOM exposes no `CanHalt` property to
        // probe. Reporting false disabled the stop control for a focuser whose
        // Halt demonstrably works. A driver that does not implement Halt raises
        // its own error at call time — the same contract already used for ASCOM
        // rotators, which hardcode `can_halt: true` for this reason.
        can_halt: true,
        // ASCOM focusers have no Reverse property (that belongs to IRotatorV3).
        can_reverse: false,
        reverse: None,
    }
}

// Filter wheel capabilities

/// Capabilities of a filter wheel device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FilterWheelCapabilities {
    /// Number of filter positions
    pub position_count: i32,
    /// Current filter position (0-indexed)
    pub current_position: Option<i32>,
    /// Filter names for each position
    pub filter_names: Vec<String>,
    /// Focus offsets for each filter (in focuser steps)
    pub focus_offsets: Vec<i32>,
    /// Whether the wheel is currently moving
    pub is_moving: bool,
    /// Whether filter names can be set
    pub can_set_filter_names: bool,
    /// Whether focus offsets can be set
    pub can_set_focus_offsets: bool,
}

// Rotator capabilities

/// Capabilities of a rotator device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RotatorCapabilities {
    /// Whether the rotator can reverse direction
    pub can_reverse: bool,
    /// Current reverse setting
    pub reverse: bool,
    /// Step size in degrees
    pub step_size: Option<f64>,
    /// Whether the rotator is currently moving
    pub is_moving: bool,
    /// Current mechanical position in degrees
    pub mechanical_position: Option<f64>,
    /// Current position in degrees (may differ from mechanical due to sync)
    pub position: Option<f64>,
    /// Whether the rotator can move to absolute positions
    pub can_move_absolute: bool,
    /// Whether the rotator can halt movement
    pub can_halt: bool,
    /// Whether the rotator can sync to a position
    pub can_sync: bool,
    /// Minimum mechanical angle in degrees, if the driver publishes the angle
    /// range. `None` means the range is implicit/unknown (ASCOM/Alpaca IRotator
    /// has no min/max property — the mechanical range is unbounded 0–360 by
    /// contract; only INDI's `ABS_ROTATOR_ANGLE` number limits expose it).
    pub min_angle_deg: Option<f64>,
    /// Maximum mechanical angle in degrees, if the driver publishes the angle
    /// range. `None` means the range is implicit/unknown.
    pub max_angle_deg: Option<f64>,
}

// Dome capabilities

/// Capabilities of a dome device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DomeCapabilities {
    /// Whether the dome can slew to a specific azimuth
    pub can_set_azimuth: bool,
    /// Whether the dome can be parked
    pub can_park: bool,
    /// Whether the dome can find home
    pub can_find_home: bool,
    /// Whether the dome has a controllable shutter
    pub can_set_shutter: bool,
    /// Whether the dome can sync its position
    pub can_sync_azimuth: bool,
    /// Current azimuth in degrees (if known)
    pub azimuth: Option<f64>,
    /// Whether the dome is currently slewing
    pub slewing: bool,
    /// Whether the dome is at home
    pub at_home: bool,
    /// Whether the dome is at park
    pub at_park: bool,
    /// Current shutter status
    pub shutter_status: Option<ShutterStatus>,
    /// Whether slave mode is available
    pub can_slave: bool,
    /// Whether slave mode is currently enabled
    pub slaved: bool,
    /// Whether the dome can abort movement
    pub can_abort: bool,
}

/// Dome shutter status
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShutterStatus {
    /// Shutter is fully open
    Open,
    /// Shutter is fully closed
    Closed,
    /// Shutter is currently opening
    Opening,
    /// Shutter is currently closing
    Closing,
    /// Shutter status is unknown or error state
    Unknown,
}

impl Default for ShutterStatus {
    fn default() -> Self {
        ShutterStatus::Unknown
    }
}

// Cover calibrator capabilities

/// Capabilities of a cover calibrator device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CoverCalibratorCapabilities {
    /// Maximum brightness level (0 if no calibrator)
    pub max_brightness: i32,
    /// Whether the device has a cover
    pub cover_present: bool,
    /// Whether the device has a calibrator light
    pub calibrator_present: bool,
    /// Current cover state
    pub cover_state: Option<CoverState>,
    /// Current calibrator state
    pub calibrator_state: Option<CalibratorState>,
    /// Current brightness level
    pub brightness: Option<i32>,
}

// CoverState is imported from crate::device

// CalibratorState is imported from crate::device

// Weather capabilities

/// Capabilities of a weather/observing conditions device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WeatherCapabilities {
    /// Whether cloud cover is reported
    pub has_cloud_cover: bool,
    /// Whether dew point is reported
    pub has_dew_point: bool,
    /// Whether humidity is reported
    pub has_humidity: bool,
    /// Whether pressure is reported
    pub has_pressure: bool,
    /// Whether rain rate is reported
    pub has_rain_rate: bool,
    /// Whether sky brightness is reported
    pub has_sky_brightness: bool,
    /// Whether sky quality (mag/arcsec^2) is reported
    pub has_sky_quality: bool,
    /// Whether sky temperature is reported
    pub has_sky_temperature: bool,
    /// Whether seeing is reported
    pub has_seeing: bool,
    /// Whether temperature is reported
    pub has_temperature: bool,
    /// Whether wind direction is reported
    pub has_wind_direction: bool,
    /// Whether wind gust is reported
    pub has_wind_gust: bool,
    /// Whether wind speed is reported
    pub has_wind_speed: bool,
    /// Average time between sensor updates in seconds
    pub average_period: Option<f64>,
}

// Safety monitor capabilities

/// Capabilities of a safety monitor device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SafetyMonitorCapabilities {
    /// Current safe status
    pub is_safe: bool,
    /// Description of current safety state
    pub safety_description: Option<String>,
}

// Switch capabilities

/// Capabilities of a switch device
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SwitchCapabilities {
    /// Number of switches
    pub switch_count: i32,
    /// Switch details
    pub switches: Vec<SwitchInfo>,
}

/// Information about a single switch
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SwitchInfo {
    /// Switch index
    pub index: i32,
    /// Switch name
    pub name: String,
    /// Switch description
    pub description: String,
    /// Whether this is a boolean switch (vs. analog)
    pub is_boolean: bool,
    /// Minimum value (for analog switches)
    pub min_value: f64,
    /// Maximum value (for analog switches)
    pub max_value: f64,
    /// Step increment (for analog switches)
    pub step: f64,
    /// Whether the switch can be written
    pub can_write: bool,
    /// Current value
    pub value: f64,
}

/// Unified device capabilities enum
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum DeviceCapabilities {
    Mount(MountCapabilities),
    Camera(CameraCapabilities),
    Focuser(FocuserCapabilities),
    FilterWheel(FilterWheelCapabilities),
    Rotator(RotatorCapabilities),
    Dome(DomeCapabilities),
    CoverCalibrator(CoverCalibratorCapabilities),
    Weather(WeatherCapabilities),
    SafetyMonitor(SafetyMonitorCapabilities),
    Switch(SwitchCapabilities),
}

#[cfg(test)]
mod ascom_focuser_capability_tests {
    use super::{focuser_capabilities_from_ascom, AscomFocuserReadings};

    /// Readings matching the ASCOM Focuser Simulator on the rig, captured while
    /// it was genuinely travelling.
    fn moving_focuser() -> AscomFocuserReadings {
        AscomFocuserReadings {
            max_step: Some(50000),
            max_increment: Some(50000),
            step_size: Some(20.0),
            absolute: Some(true),
            temp_comp_available: Some(true),
            temp_comp: Some(false),
            temperature: Some(182.43),
            position: Some(44880),
            is_moving: Some(true),
        }
    }

    #[test]
    fn live_state_is_reported_not_defaulted() {
        // These four must not come from `Default::default()`: that reports a
        // moving focuser as isMoving false / position null / temperature null.
        let caps = focuser_capabilities_from_ascom(moving_focuser());

        assert!(caps.is_moving, "a travelling focuser must report is_moving");
        assert_eq!(caps.position, Some(44880));
        assert_eq!(caps.temperature, Some(182.43));
        assert_eq!(caps.max_position, 50000);
        assert_eq!(caps.step_size, Some(20.0));
        assert!(caps.absolute);
        assert!(caps.temp_comp_available);
        assert!(!caps.temp_comp);
    }

    #[test]
    fn halt_is_advertised_for_every_ascom_focuser() {
        // Halt() is an IFocuserV2/V3 interface member and ASCOM has no CanHalt
        // property; reporting false disabled the stop control for a focuser
        // whose Halt was verified working on the rig.
        assert!(focuser_capabilities_from_ascom(moving_focuser()).can_halt);
        assert!(
            focuser_capabilities_from_ascom(AscomFocuserReadings::default()).can_halt,
            "can_halt must not depend on any property read succeeding"
        );
    }

    #[test]
    fn unreadable_properties_degrade_without_inventing_values() {
        // Every property threw: report "unknown" rather than a fabricated
        // number. 0 travel disables absolute-position UI, which is the intended
        // signal for a driver whose MaxStep is not implemented.
        let caps = focuser_capabilities_from_ascom(AscomFocuserReadings::default());

        assert_eq!(caps.max_position, 0);
        assert_eq!(caps.max_increment, 0);
        assert_eq!(caps.step_size, None);
        assert_eq!(caps.temperature, None);
        assert_eq!(caps.position, None);
        assert!(!caps.is_moving);
        assert!(!caps.absolute);
    }

    #[test]
    fn reverse_stays_unsupported_for_focusers() {
        // Reverse belongs to IRotatorV3, not IFocuserV3.
        let caps = focuser_capabilities_from_ascom(moving_focuser());
        assert!(!caps.can_reverse);
        assert_eq!(caps.reverse, None);
    }

    #[test]
    fn a_settled_focuser_reports_not_moving() {
        let caps = focuser_capabilities_from_ascom(AscomFocuserReadings {
            is_moving: Some(false),
            position: Some(50000),
            ..moving_focuser()
        });
        assert!(!caps.is_moving);
        assert_eq!(caps.position, Some(50000));
    }
}
