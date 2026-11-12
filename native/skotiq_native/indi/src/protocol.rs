//! INDI XML protocol definitions.

pub const INDI_PROTOCOL_VERSION: &str = "1.7";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CcdFrameType {
    Light,
    Bias,
    Dark,
    Flat,
}

/// The standard INDI property and element names Skotiq reads and writes,
/// each written once. Several drivers name the same control differently;
/// the alternatives a wrapper tries are all listed here.
pub mod names {
    // Every device
    pub const ACTIVE_DEVICES: &str = "ACTIVE_DEVICES";
    pub const CONFIG_PROCESS: &str = "CONFIG_PROCESS";
    pub const CONNECT: &str = "CONNECT";
    pub const CONNECTION: &str = "CONNECTION";
    pub const DEBUG: &str = "DEBUG";
    pub const DEBUG_LEVEL: &str = "DEBUG_LEVEL";
    pub const DEVICE_PORT: &str = "DEVICE_PORT";
    pub const DEVICE_PORT_SCAN: &str = "DEVICE_PORT_SCAN";
    pub const DISCONNECT: &str = "DISCONNECT";
    pub const DRIVER_INFO: &str = "DRIVER_INFO";
    pub const DRIVER_INTERFACE: &str = "DRIVER_INTERFACE";
    pub const INDI_DISABLED: &str = "INDI_DISABLED";
    pub const INDI_ENABLED: &str = "INDI_ENABLED";
    pub const LOG_LEVEL: &str = "LOG_LEVEL";
    pub const LOG_OUTPUT: &str = "LOG_OUTPUT";
    pub const SIMULATION: &str = "SIMULATION";
    pub const UPLOAD_MODE: &str = "UPLOAD_MODE";

    // Camera
    pub const BAYERPAT: &str = "BAYERPAT";
    pub const CCD1: &str = "CCD1";
    pub const CCD2: &str = "CCD2";
    pub const CCD_ABORT_EXPOSURE: &str = "CCD_ABORT_EXPOSURE";
    pub const CCD_BAYER_PATTERN: &str = "CCD_BAYER_PATTERN";
    pub const CCD_BINNING: &str = "CCD_BINNING";
    pub const CCD_BITSPERPIXEL: &str = "CCD_BITSPERPIXEL";
    pub const CCD_CFA: &str = "CCD_CFA";
    pub const CCD_CONTROLS: &str = "CCD_CONTROLS";
    pub const CCD_COOLER: &str = "CCD_COOLER";
    pub const CCD_COOLER_POWER: &str = "CCD_COOLER_POWER";
    pub const CCD_COOLER_VALUE: &str = "CCD_COOLER_VALUE";
    pub const CCD_EXPOSURE: &str = "CCD_EXPOSURE";
    pub const CCD_EXPOSURE_VALUE: &str = "CCD_EXPOSURE_VALUE";
    pub const CCD_FRAME: &str = "CCD_FRAME";
    pub const CCD_FRAME_TYPE: &str = "CCD_FRAME_TYPE";
    pub const CCD_GAIN: &str = "CCD_GAIN";
    pub const CCD_INFO: &str = "CCD_INFO";
    pub const CCD_MAX_BIN_X: &str = "CCD_MAX_BIN_X";
    pub const CCD_MAX_BIN_Y: &str = "CCD_MAX_BIN_Y";
    pub const CCD_MAX_PIXEL: &str = "CCD_MAX_PIXEL";
    pub const CCD_MAX_PIXEL_VALUE: &str = "CCD_MAX_PIXEL_VALUE";
    pub const CCD_MAX_X: &str = "CCD_MAX_X";
    pub const CCD_MAX_Y: &str = "CCD_MAX_Y";
    pub const CCD_OFFSET: &str = "CCD_OFFSET";
    pub const CCD_PIXEL_SIZE_X: &str = "CCD_PIXEL_SIZE_X";
    pub const CCD_PIXEL_SIZE_Y: &str = "CCD_PIXEL_SIZE_Y";
    pub const CCD_READOUT_MODE: &str = "CCD_READOUT_MODE";
    pub const CCD_READOUT_SPEED: &str = "CCD_READOUT_SPEED";
    pub const CCD_READ_MODE: &str = "CCD_READ_MODE";
    pub const CCD_SENSOR_TYPE: &str = "CCD_SENSOR_TYPE";
    pub const CCD_TEMPERATURE: &str = "CCD_TEMPERATURE";
    pub const CCD_TEMPERATURE_VALUE: &str = "CCD_TEMPERATURE_VALUE";
    pub const CFA_OFFSET_X: &str = "CFA_OFFSET_X";
    pub const CFA_OFFSET_Y: &str = "CFA_OFFSET_Y";
    pub const CFA_TYPE: &str = "CFA_TYPE";
    pub const COOLER_OFF: &str = "COOLER_OFF";
    pub const COOLER_ON: &str = "COOLER_ON";
    pub const FRAME_BIAS: &str = "FRAME_BIAS";
    pub const FRAME_DARK: &str = "FRAME_DARK";
    pub const FRAME_FLAT: &str = "FRAME_FLAT";
    pub const FRAME_LIGHT: &str = "FRAME_LIGHT";
    pub const GAIN: &str = "GAIN";
    pub const HEIGHT: &str = "HEIGHT";
    pub const HOR_BIN: &str = "HOR_BIN";
    pub const OFFSET: &str = "OFFSET";
    pub const READOUT_QUALITY: &str = "READOUT_QUALITY";
    pub const VER_BIN: &str = "VER_BIN";
    pub const WIDTH: &str = "WIDTH";
    /// `CCD_CONTROLS` elements, named in mixed case by the drivers that publish them.
    pub const CONTROLS_GAIN: &str = "Gain";
    pub const CONTROLS_OFFSET: &str = "Offset";

    // Mount
    pub const ALT: &str = "ALT";
    pub const AZ: &str = "AZ";
    pub const DEC: &str = "DEC";
    pub const EQUATORIAL_COORD: &str = "EQUATORIAL_COORD";
    pub const EQUATORIAL_EOD_COORD: &str = "EQUATORIAL_EOD_COORD";
    pub const GO: &str = "GO";
    pub const HOME_POSITION: &str = "HOME_POSITION";
    pub const HORIZONTAL_COORD: &str = "HORIZONTAL_COORD";
    pub const MOTION_EAST: &str = "MOTION_EAST";
    pub const MOTION_NORTH: &str = "MOTION_NORTH";
    pub const MOTION_SOUTH: &str = "MOTION_SOUTH";
    pub const MOTION_WEST: &str = "MOTION_WEST";
    pub const ON_COORD_SET: &str = "ON_COORD_SET";
    pub const PARK_CURRENT: &str = "PARK_CURRENT";
    pub const PARK_POSITION: &str = "PARK_POSITION";
    pub const PARK_WRITE_DATA: &str = "PARK_WRITE_DATA";
    pub const RA: &str = "RA";
    pub const SLEW: &str = "SLEW";
    pub const SLEWMODE: &str = "SLEWMODE";
    pub const SLEW_CENTERING: &str = "SLEW_CENTERING";
    pub const SLEW_FIND: &str = "SLEW_FIND";
    pub const SLEW_GUIDE: &str = "SLEW_GUIDE";
    pub const SLEW_MAX: &str = "SLEW_MAX";
    pub const TELESCOPE_ABORT_MOTION: &str = "TELESCOPE_ABORT_MOTION";
    pub const TELESCOPE_ALIGNMENT_MODE: &str = "TELESCOPE_ALIGNMENT_MODE";
    pub const TELESCOPE_HOME: &str = "TELESCOPE_HOME";
    pub const TELESCOPE_MOTION_NS: &str = "TELESCOPE_MOTION_NS";
    pub const TELESCOPE_MOTION_WE: &str = "TELESCOPE_MOTION_WE";
    pub const TELESCOPE_PARK: &str = "TELESCOPE_PARK";
    pub const TELESCOPE_PARK_OPTION: &str = "TELESCOPE_PARK_OPTION";
    pub const TELESCOPE_PIER_SIDE: &str = "TELESCOPE_PIER_SIDE";
    pub const TELESCOPE_SLEW_RATE: &str = "TELESCOPE_SLEW_RATE";
    pub const TELESCOPE_TIMED_GUIDE_NS: &str = "TELESCOPE_TIMED_GUIDE_NS";
    pub const TELESCOPE_TIMED_GUIDE_WE: &str = "TELESCOPE_TIMED_GUIDE_WE";
    pub const TELESCOPE_TRACK_MODE: &str = "TELESCOPE_TRACK_MODE";
    pub const TELESCOPE_TRACK_RATE: &str = "TELESCOPE_TRACK_RATE";
    pub const TELESCOPE_TRACK_STATE: &str = "TELESCOPE_TRACK_STATE";
    pub const TIMED_GUIDE_E: &str = "TIMED_GUIDE_E";
    pub const TIMED_GUIDE_N: &str = "TIMED_GUIDE_N";
    pub const TIMED_GUIDE_S: &str = "TIMED_GUIDE_S";
    pub const TIMED_GUIDE_W: &str = "TIMED_GUIDE_W";
    pub const TRACK: &str = "TRACK";
    pub const TRACK_OFF: &str = "TRACK_OFF";
    pub const TRACK_ON: &str = "TRACK_ON";
    pub const TRACK_RATE_DE: &str = "TRACK_RATE_DE";
    pub const TRACK_RATE_RA: &str = "TRACK_RATE_RA";

    // Focuser
    pub const ABS_FOCUS_POSITION: &str = "ABS_FOCUS_POSITION";
    pub const FOCUS_ABORT_MOTION: &str = "FOCUS_ABORT_MOTION";
    pub const FOCUS_ABSOLUTE_POSITION: &str = "FOCUS_ABSOLUTE_POSITION";
    pub const FOCUS_BACKLASH_STEPS: &str = "FOCUS_BACKLASH_STEPS";
    pub const FOCUS_BACKLASH_TOGGLE: &str = "FOCUS_BACKLASH_TOGGLE";
    pub const FOCUS_BACKLASH_VALUE: &str = "FOCUS_BACKLASH_VALUE";
    pub const FOCUS_IN: &str = "FOCUS_IN";
    pub const FOCUS_MAX: &str = "FOCUS_MAX";
    pub const FOCUS_MAX_VALUE: &str = "FOCUS_MAX_VALUE";
    pub const FOCUS_MOTION: &str = "FOCUS_MOTION";
    pub const FOCUS_OUT: &str = "FOCUS_OUT";
    pub const FOCUS_RELATIVE_POSITION: &str = "FOCUS_RELATIVE_POSITION";
    pub const FOCUS_SPEED: &str = "FOCUS_SPEED";
    pub const FOCUS_STEP: &str = "FOCUS_STEP";
    pub const FOCUS_STEP_VALUE: &str = "FOCUS_STEP_VALUE";
    pub const FOCUS_TEMPERATURE: &str = "FOCUS_TEMPERATURE";
    pub const FOCUS_TEMPERATURE_COMP: &str = "FOCUS_TEMPERATURE_COMP";
    pub const FOCUS_TEMP_COMP: &str = "FOCUS_TEMP_COMP";
    pub const FOCUS_TIMER: &str = "FOCUS_TIMER";
    pub const REL_FOCUS_POSITION: &str = "REL_FOCUS_POSITION";

    // Filter wheel
    pub const FILTER_NAME: &str = "FILTER_NAME";
    pub const FILTER_SLOT: &str = "FILTER_SLOT";
    pub const FILTER_SLOT_VALUE: &str = "FILTER_SLOT_VALUE";

    // Dome
    pub const ABS_DOME_POSITION: &str = "ABS_DOME_POSITION";
    pub const DOME_ABORT_MOTION: &str = "DOME_ABORT_MOTION";
    pub const DOME_ABSOLUTE_POSITION: &str = "DOME_ABSOLUTE_POSITION";
    pub const DOME_AUTOSYNC: &str = "DOME_AUTOSYNC";
    pub const DOME_AUTOSYNC_DISABLE: &str = "DOME_AUTOSYNC_DISABLE";
    pub const DOME_AUTOSYNC_ENABLE: &str = "DOME_AUTOSYNC_ENABLE";
    pub const DOME_CCW: &str = "DOME_CCW";
    pub const DOME_CW: &str = "DOME_CW";
    pub const DOME_GOTO: &str = "DOME_GOTO";
    pub const DOME_HOME: &str = "DOME_HOME";
    pub const DOME_MOTION: &str = "DOME_MOTION";
    pub const DOME_PARAMS: &str = "DOME_PARAMS";
    pub const DOME_PARK: &str = "DOME_PARK";
    pub const DOME_SHUTTER: &str = "DOME_SHUTTER";
    pub const DOME_SYNC: &str = "DOME_SYNC";
    pub const DOME_SYNC_VALUE: &str = "DOME_SYNC_VALUE";
    pub const SHUTTER_CLOSE: &str = "SHUTTER_CLOSE";
    pub const SHUTTER_OPEN: &str = "SHUTTER_OPEN";

    // Rotator
    pub const ABS_ROTATOR_ANGLE: &str = "ABS_ROTATOR_ANGLE";
    pub const ANGLE: &str = "ANGLE";
    pub const MECHANICAL_POSITION: &str = "MECHANICAL_POSITION";
    pub const POSITION: &str = "POSITION";
    pub const ROTATOR_ABORT_MOTION: &str = "ROTATOR_ABORT_MOTION";
    pub const ROTATOR_ANGLE: &str = "ROTATOR_ANGLE";
    pub const ROTATOR_POSITION: &str = "ROTATOR_POSITION";
    pub const ROTATOR_RAW_ANGLE: &str = "ROTATOR_RAW_ANGLE";
    pub const ROTATOR_REVERSE: &str = "ROTATOR_REVERSE";
    pub const SYNC_ROTATOR_ANGLE: &str = "SYNC_ROTATOR_ANGLE";

    // Weather and safety
    pub const AUX_SAFETY: &str = "AUX_SAFETY";
    pub const ENABLED: &str = "ENABLED";
    pub const SAFE: &str = "SAFE";
    pub const SAFETY_STATUS: &str = "SAFETY_STATUS";
    pub const WEATHER_CLOUDS: &str = "WEATHER_CLOUDS";
    pub const WEATHER_CLOUD_COVER: &str = "WEATHER_CLOUD_COVER";
    pub const WEATHER_DEWPOINT: &str = "WEATHER_DEWPOINT";
    pub const WEATHER_HUMIDITY: &str = "WEATHER_HUMIDITY";
    pub const WEATHER_PARAMETERS: &str = "WEATHER_PARAMETERS";
    pub const WEATHER_PRESSURE: &str = "WEATHER_PRESSURE";
    pub const WEATHER_RAIN: &str = "WEATHER_RAIN";
    pub const WEATHER_RAIN_RATE: &str = "WEATHER_RAIN_RATE";
    pub const WEATHER_SAFE: &str = "WEATHER_SAFE";
    pub const WEATHER_SKY_BRIGHTNESS: &str = "WEATHER_SKY_BRIGHTNESS";
    pub const WEATHER_SKY_QUALITY: &str = "WEATHER_SKY_QUALITY";
    pub const WEATHER_SKY_TEMPERATURE: &str = "WEATHER_SKY_TEMPERATURE";
    pub const WEATHER_STATUS: &str = "WEATHER_STATUS";
    pub const WEATHER_TEMPERATURE: &str = "WEATHER_TEMPERATURE";
    pub const WEATHER_WIND: &str = "WEATHER_WIND";
    pub const WEATHER_WIND_DIRECTION: &str = "WEATHER_WIND_DIRECTION";
    pub const WEATHER_WIND_GUST: &str = "WEATHER_WIND_GUST";
    pub const WEATHER_WIND_SPEED: &str = "WEATHER_WIND_SPEED";

    // Dust cap, flat panel and cover
    pub const BRIGHTNESS: &str = "BRIGHTNESS";
    pub const CAP_ABORT: &str = "CAP_ABORT";
    pub const CAP_PARK: &str = "CAP_PARK";
    pub const CAP_UNPARK: &str = "CAP_UNPARK";
    pub const CLOSE: &str = "CLOSE";
    pub const CLOSED: &str = "CLOSED";
    pub const COVER_CLOSED: &str = "COVER_CLOSED";
    pub const COVER_ERROR: &str = "COVER_ERROR";
    pub const COVER_MOVING: &str = "COVER_MOVING";
    pub const COVER_OPEN: &str = "COVER_OPEN";
    pub const DUSTCAP_CONTROL: &str = "DUSTCAP_CONTROL";
    pub const DUST_CAP: &str = "DUST_CAP";
    pub const DUST_CAP_CLOSE: &str = "DUST_CAP_CLOSE";
    pub const DUST_CAP_CLOSED: &str = "DUST_CAP_CLOSED";
    pub const DUST_CAP_OPEN: &str = "DUST_CAP_OPEN";
    pub const ERROR: &str = "ERROR";
    pub const FLAT_COVER_CLOSED: &str = "FLAT_COVER_CLOSED";
    pub const FLAT_COVER_ERROR: &str = "FLAT_COVER_ERROR";
    pub const FLAT_COVER_MOVING: &str = "FLAT_COVER_MOVING";
    pub const FLAT_COVER_OPEN: &str = "FLAT_COVER_OPEN";
    pub const FLAT_COVER_STATE: &str = "FLAT_COVER_STATE";
    pub const FLAT_LIGHT_CONTROL: &str = "FLAT_LIGHT_CONTROL";
    pub const FLAT_LIGHT_INTENSITY: &str = "FLAT_LIGHT_INTENSITY";
    pub const FLAT_LIGHT_INTENSITY_VALUE: &str = "FLAT_LIGHT_INTENSITY_VALUE";
    pub const FLAT_LIGHT_OFF: &str = "FLAT_LIGHT_OFF";
    pub const FLAT_LIGHT_ON: &str = "FLAT_LIGHT_ON";
    pub const LIGHTBOX_BRIGHTNESS: &str = "LIGHTBOX_BRIGHTNESS";
    pub const LIGHTBOX_CONTROL: &str = "LIGHTBOX_CONTROL";
    pub const MOVING: &str = "MOVING";
    pub const OPEN: &str = "OPEN";
    pub const PARKED: &str = "PARKED";
    pub const UNPARKED: &str = "UNPARKED";

    // Elements several properties share
    pub const ABORT: &str = "ABORT";
    pub const PARK: &str = "PARK";
    pub const SYNC: &str = "SYNC";
    pub const TEMPERATURE: &str = "TEMPERATURE";
    pub const UNPARK: &str = "UNPARK";
}
