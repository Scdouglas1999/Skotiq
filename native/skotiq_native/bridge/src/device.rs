//! Device types and traits for equipment abstraction
//!
//! This module defines the common interface for all astronomical devices
//! regardless of the underlying driver protocol (ASCOM, Alpaca, INDI).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Types of devices supported by Skotiq
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DeviceType {
    Camera,
    Mount,
    Focuser,
    FilterWheel,
    Guider,
    Dome,
    Rotator,
    Weather,
    SafetyMonitor,
    Switch,
    CoverCalibrator,
}

impl DeviceType {
    pub fn as_str(&self) -> &'static str {
        match self {
            DeviceType::Camera => "Camera",
            DeviceType::Mount => "Mount",
            DeviceType::Focuser => "Focuser",
            DeviceType::FilterWheel => "Filter Wheel",
            DeviceType::Guider => "Guider",
            DeviceType::Dome => "Dome",
            DeviceType::Rotator => "Rotator",
            DeviceType::Weather => "Weather",
            DeviceType::SafetyMonitor => "Safety Monitor",
            DeviceType::Switch => "Switch",
            DeviceType::CoverCalibrator => "Cover Calibrator",
        }
    }
}

/// Connection state of a device
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Error,
}

/// Information about a discovered device
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub device_type: DeviceType,
    pub driver_type: DriverType,
    pub description: String,
    pub driver_version: String,
    /// Serial number from hardware (if available)
    pub serial_number: Option<String>,
    /// Unique identifier from driver/protocol (e.g., Alpaca UniqueID)
    pub unique_id: Option<String>,
    /// Human-readable name for UI display (includes serial/index for disambiguation)
    pub display_name: String,
}

impl DeviceInfo {
    /// Generate a display name with disambiguation info
    /// Priority: serial_number > unique_id > index suffix > plain name
    pub fn generate_display_name(
        name: &str,
        serial_number: Option<&str>,
        unique_id: Option<&str>,
        index: Option<usize>,
    ) -> String {
        if let Some(serial) = serial_number {
            if !serial.is_empty() {
                return format!("{} ({})", name, serial);
            }
        }
        if let Some(uid) = unique_id {
            if !uid.is_empty() {
                // Use last 8 chars of unique_id if it's long
                let suffix = if uid.len() > 8 {
                    &uid[uid.len() - 8..]
                } else {
                    uid
                };
                return format!("{} ({})", name, suffix);
            }
        }
        if let Some(idx) = index {
            return format!("{} #{}", name, idx + 1);
        }
        name.to_string()
    }
}

/// Type of driver/protocol
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DriverType {
    Ascom,
    Alpaca,
    Indi,
    Native,
    Simulator,
}

/// Current status of a camera
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraStatus {
    pub connected: bool,
    pub state: CameraState,
    pub sensor_temp: Option<f64>,
    pub cooler_power: Option<f64>,
    pub target_temp: Option<f64>,
    pub cooler_on: bool,
    pub gain: i32,
    pub offset: i32,
    pub bin_x: i32,
    pub bin_y: i32,
    pub sensor_width: u32,
    pub sensor_height: u32,
    pub pixel_size_x: f64,
    pub pixel_size_y: f64,
    pub max_adu: u32,
    pub can_cool: bool,
    pub can_set_gain: bool,
    pub can_set_offset: bool,
}

/// Camera operational state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CameraState {
    Idle,
    Waiting,
    Exposing,
    Reading,
    Download,
    Error,
}

/// Frame type for camera exposures
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FrameType {
    Light,
    Dark,
    Flat,
    Bias,
    DarkFlat,
}

impl FrameType {
    pub fn as_str(&self) -> &'static str {
        match self {
            FrameType::Light => "Light",
            FrameType::Dark => "Dark",
            FrameType::Flat => "Flat",
            FrameType::Bias => "Bias",
            FrameType::DarkFlat => "Dark Flat",
        }
    }
}

/// Image file format for saving
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum ImageFileFormat {
    #[default]
    Fits,
    Xisf,
    Tiff,
    Png,
    Jpeg,
}

impl ImageFileFormat {
    /// Get the file extension for this format
    pub fn extension(&self) -> &'static str {
        match self {
            ImageFileFormat::Fits => "fits",
            ImageFileFormat::Xisf => "xisf",
            ImageFileFormat::Tiff => "tiff",
            ImageFileFormat::Png => "png",
            ImageFileFormat::Jpeg => "jpg",
        }
    }

    /// Parse from string (case-insensitive)
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "fits" => Some(ImageFileFormat::Fits),
            "xisf" => Some(ImageFileFormat::Xisf),
            "tiff" | "tif" => Some(ImageFileFormat::Tiff),
            "png" => Some(ImageFileFormat::Png),
            "jpeg" | "jpg" => Some(ImageFileFormat::Jpeg),
            _ => None,
        }
    }
}

/// Parameters for a camera exposure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExposureParams {
    pub duration_secs: f64,
    pub frame_type: FrameType,
    pub bin_x: i32,
    pub bin_y: i32,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub subframe: Option<SubFrame>,
    // Added for imaging session support
    pub naming_pattern: Option<String>,
    pub target_name: Option<String>,
    pub filter: Option<String>,
    pub save_path: Option<String>,
    /// File format for saving (defaults to FITS)
    #[serde(default)]
    pub file_format: ImageFileFormat,
}

/// Subframe region for partial readout
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubFrame {
    pub start_x: u32,
    pub start_y: u32,
    pub width: u32,
    pub height: u32,
}

/// Per-field availability for `MountStatus` so the UI can distinguish
/// "mount reports X" from "we couldn't read X" from "mount doesn't support X".
///
/// Without this distinction, a transient driver error and a feature gap both
/// surface as a fabricated default value (e.g. `at_home=false`, `pier=Unknown`),
/// causing the sequencer/UI to silently treat broken mounts as healthy.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum FieldAvailability {
    /// Field was read successfully and the corresponding `Option<T>` is `Some`.
    Available,
    /// Driver/protocol explicitly reports the capability is not supported.
    Unsupported,
    /// Read attempt failed; carries the driver-supplied reason.
    Error(String),
}

/// Keys used in `MountStatus::availability`.
///
/// These are part of the bridge contract — Dart UI consumers and tests look
/// up fields by exact key. Defined here so all writers/readers stay in sync.
pub mod mount_status_field {
    pub const AT_HOME: &str = "at_home";
    /// `MountStatus::parked` is not optional, so a backend that cannot read
    /// park state at all (the Native `NotSupported` arm) must say so HERE —
    /// the bool it fills in is fabricated, and `parked_from_status` refuses
    /// to serve it. A mount that merely reports `can_park=false` while
    /// reading `AtPark` honestly (ASCOM mandates this) does NOT mark it.
    pub const PARKED: &str = "parked";
    pub const SIDE_OF_PIER: &str = "side_of_pier";
    pub const ALTITUDE: &str = "altitude";
    pub const AZIMUTH: &str = "azimuth";
    pub const SIDEREAL_TIME: &str = "sidereal_time";
    pub const TRACKING_RATE: &str = "tracking_rate";
}

/// Current status of a mount.
///
/// Fields that vary by driver capability or that may legitimately fail to
/// read are `Option<T>` and accompanied by an entry in `availability` so the
/// UI can render "—" for `None`+`Unsupported` versus an error indicator for
/// `None`+`Error(reason)`.
/// The site a mount is configured for, and where that answer came from.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountSite {
    /// Degrees north, negative south.
    pub latitude_deg: f64,
    /// Degrees EAST of Greenwich, negative west. Drivers whose wire format is
    /// west-positive (LX200) convert; callers only ever see east-positive.
    pub longitude_deg: f64,
    /// Metres above sea level. `None` when the protocol does not carry it —
    /// which is not the same as sea level.
    pub elevation_m: Option<f64>,
}

/// A mount's clock.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountTimeInfo {
    /// Seconds since the Unix epoch, UTC.
    pub utc_unix_seconds: i64,
    /// Hours EAST of UTC in the ordinary sense: US Eastern Standard is -5.0.
    pub utc_offset_hours: f64,
}

/// Which directions a given mount can actually reconcile, so the UI offers a
/// choice the driver can honour instead of one it will refuse.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountSiteCapabilities {
    pub can_read_site: bool,
    pub can_write_site: bool,
    pub can_read_time: bool,
    pub can_write_time: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MountStatus {
    pub connected: bool,
    pub tracking: bool,
    pub slewing: bool,
    pub parked: bool,
    pub at_home: Option<bool>,
    pub side_of_pier: Option<PierSide>,
    pub right_ascension: f64,       // Hours
    pub declination: f64,           // Degrees
    pub altitude: Option<f64>,      // Degrees
    pub azimuth: Option<f64>,       // Degrees
    pub sidereal_time: Option<f64>, // Hours
    pub tracking_rate: Option<TrackingRate>,
    pub can_park: bool,
    pub can_slew: bool,
    pub can_sync: bool,
    pub can_pulse_guide: bool,
    pub can_set_tracking_rate: bool,
    /// Per-field availability for the optional fields above.
    /// Keyed by the constants in `mount_status_field`.
    pub availability: HashMap<String, FieldAvailability>,
}

/// Side of pier for German Equatorial mounts
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PierSide {
    East,
    West,
    Unknown,
}

/// Tracking rate for mount
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TrackingRate {
    Sidereal,
    Lunar,
    Solar,
    King,
    Custom,
}

/// Coordinates for slewing
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Coordinates {
    pub ra: f64,  // Right Ascension in hours (0-24)
    pub dec: f64, // Declination in degrees (-90 to +90)
}

/// Current status of a focuser
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FocuserStatus {
    pub connected: bool,
    pub position: i32,
    pub moving: bool,
    pub temperature: Option<f64>,
    pub max_position: i32,
    pub step_size: f64,
    pub is_absolute: bool,
    pub has_temperature: bool,
}

/// Current status of a filter wheel
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterWheelStatus {
    pub connected: bool,
    pub position: i32,
    pub moving: bool,
    pub filter_count: i32,
    pub filter_names: Vec<String>,
}

/// Filter information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterInfo {
    pub position: i32,
    pub name: String,
    pub focus_offset: Option<i32>,
}

/// Current status of a rotator
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RotatorStatus {
    pub connected: bool,
    pub position: f64, // Degrees
    pub moving: bool,
    pub mechanical_position: f64,
    pub is_moving: bool,
    pub can_reverse: bool,
}

/// Weather data from a weather station
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeatherData {
    pub connected: bool,
    pub temperature: Option<f64>,    // Celsius
    pub humidity: Option<f64>,       // Percent
    pub pressure: Option<f64>,       // hPa
    pub dew_point: Option<f64>,      // Celsius
    pub wind_speed: Option<f64>,     // m/s
    pub wind_direction: Option<f64>, // Degrees
    pub cloud_cover: Option<f64>,    // Percent
    pub sky_brightness: Option<f64>, // Lux
    pub sky_quality: Option<f64>,    // mag/arcsec²
    pub rain_rate: Option<f64>,      // mm/hr
    pub is_safe: bool,
}

/// Weather conditions from observing conditions device (raw sensor readings)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeatherConditions {
    pub temperature: Option<f64>,     // Celsius
    pub humidity: Option<f64>,        // Percent
    pub pressure: Option<f64>,        // hPa
    pub cloud_cover: Option<f64>,     // Percent
    pub dew_point: Option<f64>,       // Celsius
    pub wind_speed: Option<f64>,      // m/s
    pub wind_direction: Option<f64>,  // Degrees
    pub sky_quality: Option<f64>,     // mag/arcsec²
    pub sky_temperature: Option<f64>, // Celsius
    pub rain_rate: Option<f64>,       // mm/hr
}

/// Safety monitor status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SafetyStatus {
    pub connected: bool,
    pub is_safe: bool,
}

/// Dome status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DomeStatus {
    pub connected: bool,
    pub azimuth: f64,
    pub altitude: Option<f64>,
    pub shutter_status: ShutterState,
    pub slewing: bool,
    pub at_home: bool,
    pub at_park: bool,
    pub can_set_altitude: bool,
    pub can_set_azimuth: bool,
    pub can_set_shutter: bool,
    pub can_slave: bool,
    pub is_slaved: bool,
}

/// Dome shutter state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShutterState {
    Open,
    Closed,
    Opening,
    Closing,
    Error,
    Unknown,
}

/// Cover calibrator status (flat panel / dust cover combination device)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoverCalibratorStatus {
    pub connected: bool,
    pub cover_state: CoverState,
    pub calibrator_state: CalibratorState,
    pub brightness: i32,
    pub max_brightness: i32,
}

/// Cover (dust cap) state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CoverState {
    /// Device does not have a cover
    NotPresent,
    /// Cover is closed
    Closed,
    /// Cover is moving
    Moving,
    /// Cover is open
    Open,
    /// Cover state is unknown
    Unknown,
    /// Error condition
    Error,
}

impl CoverState {
    /// Create from ASCOM/Alpaca integer value
    pub fn from_i32(value: i32) -> Self {
        match value {
            0 => CoverState::NotPresent,
            1 => CoverState::Closed,
            2 => CoverState::Moving,
            3 => CoverState::Open,
            4 => CoverState::Unknown,
            5 => CoverState::Error,
            _ => CoverState::Unknown,
        }
    }

    /// Convert to ASCOM/Alpaca integer value
    pub fn to_i32(&self) -> i32 {
        match self {
            CoverState::NotPresent => 0,
            CoverState::Closed => 1,
            CoverState::Moving => 2,
            CoverState::Open => 3,
            CoverState::Unknown => 4,
            CoverState::Error => 5,
        }
    }
}

/// Calibrator (flat light) state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CalibratorState {
    /// Device does not have a calibrator
    NotPresent,
    /// Calibrator is off
    Off,
    /// Calibrator is stabilizing (warming up)
    NotReady,
    /// Calibrator is on and stable
    Ready,
    /// Calibrator state is unknown
    Unknown,
    /// Error condition
    Error,
}

impl CalibratorState {
    /// Create from ASCOM/Alpaca integer value
    pub fn from_i32(value: i32) -> Self {
        match value {
            0 => CalibratorState::NotPresent,
            1 => CalibratorState::Off,
            2 => CalibratorState::NotReady,
            3 => CalibratorState::Ready,
            4 => CalibratorState::Unknown,
            5 => CalibratorState::Error,
            _ => CalibratorState::Unknown,
        }
    }

    /// Convert to ASCOM/Alpaca integer value
    pub fn to_i32(&self) -> i32 {
        match self {
            CalibratorState::NotPresent => 0,
            CalibratorState::Off => 1,
            CalibratorState::NotReady => 2,
            CalibratorState::Ready => 3,
            CalibratorState::Unknown => 4,
            CalibratorState::Error => 5,
        }
    }
}

/// API version information for a connected device
///
/// This tracks the interface version and driver information for
/// version-aware API calls. Different protocols report versions differently:
/// - Alpaca: InterfaceVersion property (1, 2, 3, etc.)
/// - ASCOM: InterfaceVersion from COM (1, 2, 3, etc.)
/// - INDI: Protocol version from server greeting ("1.7", "1.8", etc.)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceApiVersion {
    /// The raw device ID this version info applies to
    pub device_id: String,

    /// The driver type (Alpaca, ASCOM, INDI, Native)
    pub driver_type: DriverType,

    /// Interface version number (e.g., 1, 2, 3 for ASCOM/Alpaca)
    /// For INDI, this is the major version number
    pub interface_version: Option<u32>,

    /// Protocol version string (e.g., "1.7" for INDI, "v1" for Alpaca)
    pub protocol_version: Option<String>,

    /// Driver version string as reported by the device
    pub driver_version: Option<String>,

    /// Driver info/description as reported by the device
    pub driver_info: Option<String>,

    /// List of supported actions (for ASCOM/Alpaca devices)
    pub supported_actions: Vec<String>,

    /// When the version info was last queried (epoch milliseconds)
    pub queried_at: i64,
}

impl DeviceApiVersion {
    /// Create a new DeviceApiVersion with minimal information
    pub fn new(device_id: String, driver_type: DriverType) -> Self {
        Self {
            device_id,
            driver_type,
            interface_version: None,
            protocol_version: None,
            driver_version: None,
            driver_info: None,
            supported_actions: Vec::new(),
            queried_at: chrono::Utc::now().timestamp_millis(),
        }
    }

    /// Create from Alpaca device info
    pub fn from_alpaca(
        device_id: String,
        interface_version: i32,
        driver_version: Option<String>,
        driver_info: Option<String>,
        supported_actions: Vec<String>,
    ) -> Self {
        Self {
            device_id,
            driver_type: DriverType::Alpaca,
            // Why: ASCOM/Alpaca interface versions are
            // small single-digit integers (currently {1, 2, 3, 4}); the
            // ASCOM spec defines them as i32 but they are physically u32
            // values. Saturating try_from rejects an impossible-but-defined
            // negative.
            interface_version: Some(u32::try_from(interface_version).unwrap_or(0)),
            protocol_version: Some("v1".to_string()), // Alpaca uses v1 API
            driver_version,
            driver_info,
            supported_actions,
            queried_at: chrono::Utc::now().timestamp_millis(),
        }
    }

    /// Create from ASCOM device info
    pub fn from_ascom(
        device_id: String,
        interface_version: i32,
        driver_version: Option<String>,
        driver_info: Option<String>,
        supported_actions: Vec<String>,
    ) -> Self {
        Self {
            device_id,
            driver_type: DriverType::Ascom,
            // Why: see Alpaca counterpart above —
            // interface version is single-digit positive i32 by spec.
            interface_version: Some(u32::try_from(interface_version).unwrap_or(0)),
            protocol_version: None, // ASCOM doesn't have a protocol version
            driver_version,
            driver_info,
            supported_actions,
            queried_at: chrono::Utc::now().timestamp_millis(),
        }
    }

    /// Create from INDI device info
    pub fn from_indi(device_id: String, protocol_version: Option<String>) -> Self {
        // Parse protocol version to extract major version number
        let interface_version = protocol_version.as_ref().and_then(|v| {
            v.split('.')
                .next()
                .and_then(|major| major.parse::<u32>().ok())
        });

        Self {
            device_id,
            driver_type: DriverType::Indi,
            interface_version,
            protocol_version,
            driver_version: None, // INDI doesn't provide driver version separately
            driver_info: None,
            supported_actions: Vec::new(), // INDI doesn't have supported actions concept
            queried_at: chrono::Utc::now().timestamp_millis(),
        }
    }

    /// Check if a specific interface version is supported
    ///
    /// Returns true if the device reports an interface version >= the required version.
    /// Returns false if no interface version is known.
    pub fn supports_version(&self, required_version: u32) -> bool {
        match self.interface_version {
            Some(version) => version >= required_version,
            None => false,
        }
    }

    /// Check if a specific action is supported
    ///
    /// For ASCOM/Alpaca devices, checks the supported_actions list.
    /// Returns true only when the action is explicitly listed.
    pub fn supports_action(&self, action: &str) -> bool {
        if self.supported_actions.is_empty() {
            false
        } else {
            self.supported_actions
                .iter()
                .any(|a| a.eq_ignore_ascii_case(action))
        }
    }

    /// Check if this version info is still fresh (less than 5 minutes old)
    pub fn is_fresh(&self) -> bool {
        let now = chrono::Utc::now().timestamp_millis();
        now - self.queried_at < 300_000 // 5 minutes
    }
}

impl Default for DeviceApiVersion {
    fn default() -> Self {
        Self {
            device_id: String::new(),
            driver_type: DriverType::Simulator,
            interface_version: None,
            protocol_version: None,
            driver_version: None,
            driver_info: None,
            supported_actions: Vec::new(),
            queried_at: 0,
        }
    }
}
