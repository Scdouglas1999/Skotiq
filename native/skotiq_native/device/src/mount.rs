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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum GuideDirection {
    North,
    South,
    East,
    West,
}
