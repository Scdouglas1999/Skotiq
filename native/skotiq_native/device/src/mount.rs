//! Mount vocabulary.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TrackingRate {
    Sidereal = 0,
    Lunar = 1,
    Solar = 2,
    King = 3,
    Custom = 4,
}

/// Where the mount believes it is standing.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountSiteInfo {
    /// Degrees north, negative south.
    pub latitude_deg: f64,
    /// Degrees EAST of Greenwich, negative west. Note that the LX200 wire
    /// format is west-positive; drivers convert, callers never see that.
    pub longitude_deg: f64,
    /// Metres above sea level, when the protocol carries it.
    pub elevation_m: Option<f64>,
}

/// Reads the observing site the application holds, at the moment a driver
/// needs it. A mount that keeps no site of its own points with this one.
pub type SiteSource = std::sync::Arc<dyn Fn() -> Option<MountSiteInfo> + Send + Sync>;

/// What the mount believes the time is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountClock {
    /// Seconds since the Unix epoch, UTC.
    pub utc_unix_seconds: i64,
    /// Hours EAST of UTC, in the ordinary sense: US Eastern Standard is -5.0.
    pub utc_offset_hours: f64,
}

/// Side of the pier of a German equatorial mount, in the ASCOM sense: `East`
/// is the normal state for a target west of the meridian. The numbers are
/// ASCOM's `PierSide`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PierSide {
    East = 0,
    West = 1,
    Unknown = -1,
}

impl From<i32> for PierSide {
    fn from(value: i32) -> Self {
        match value {
            0 => PierSide::East,
            1 => PierSide::West,
            _ => PierSide::Unknown,
        }
    }
}

impl std::fmt::Display for PierSide {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PierSide::East => write!(f, "East"),
            PierSide::West => write!(f, "West"),
            PierSide::Unknown => write!(f, "Unknown"),
        }
    }
}

/// One optional reading of a mount: `Err(NotSupported)` when the mount has
/// no such reading, any other error when the read failed.
pub type Reading<T> = Result<T, crate::DriverError>;

/// What a mount reports in one status read.
#[derive(Debug)]
pub struct MountReadings {
    /// Hours, in the mount's own frame.
    pub right_ascension: f64,
    /// Degrees, in the mount's own frame.
    pub declination: f64,
    pub tracking: bool,
    pub slewing: bool,
    /// `None` for a mount with no park state.
    pub parked: Option<bool>,
    pub at_home: Reading<bool>,
    /// `Ok(Unknown)` reads as a mount that does not report its pier side.
    pub side_of_pier: Reading<PierSide>,
    /// Degrees above the horizon.
    pub altitude: Reading<f64>,
    /// Degrees, north through east.
    pub azimuth: Reading<f64>,
    /// Local apparent sidereal time in hours.
    pub sidereal_time: Reading<f64>,
    pub tracking_rate: Reading<TrackingRate>,
    pub can_park: bool,
    pub can_slew: bool,
    pub can_sync: bool,
    pub can_pulse_guide: bool,
    pub can_set_tracking_rate: bool,
}

/// What a connected mount can do: what holds for the connection, as opposed
/// to its state now.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MountDescription {
    pub can_slew: bool,
    pub can_slew_async: bool,
    pub can_sync: bool,
    pub can_park: bool,
    pub can_unpark: bool,
    /// Whether the current position can be stored as the park position.
    pub can_set_park: bool,
    pub can_find_home: bool,
    pub can_pulse_guide: bool,
    /// Whether tracking can be switched on and off.
    pub can_set_tracking: bool,
    /// The rates [`crate::MountDriver::set_tracking_rate`] takes; empty when
    /// the rate cannot be set.
    pub tracking_rates: Vec<TrackingRate>,
    pub can_get_side_of_pier: bool,
    pub is_equatorial: bool,
    pub supports_alt_az: bool,
    pub can_abort_slew: bool,
    pub can_move_axis: bool,
    pub axis_count: u32,
    /// The fastest slew rate the mount publishes, in its own unit.
    pub max_slew_rate: Option<f64>,
    /// The guide pulse lengths the mount accepts, in milliseconds, when it
    /// publishes them.
    pub min_pulse_guide_ms: Option<f64>,
    pub max_pulse_guide_ms: Option<f64>,
}

/// Which of site and clock a mount lets a driver read and write.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MountSiteAbilities {
    pub can_read_site: bool,
    pub can_write_site: bool,
    pub can_read_time: bool,
    pub can_write_time: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum GuideDirection {
    North,
    South,
    East,
    West,
}
